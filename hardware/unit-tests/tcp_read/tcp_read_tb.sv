`timescale 1ns / 1ps

// Standalone testbench for tcp_read (+ strip_http) on a persistent connection, as the handlers
// instantiate it: the bytes of one session arrive pre-routed by the handler's receive dispatcher.
//
// lane_drain and http_multilane cover the handlers end to end. This bench exists for the things that
// are awkward to force through the whole handler and that are exactly where keep-alive can go wrong:
//
//   1. A RESPONSE BOUNDARY MID-PACKET. A TCP segment may carry the tail of body k and the head of
//      response k+1. The read for response k must end at the boundary, and the bytes behind it must
//      stay buffered for the read of k+1 -- the dispatcher has already delivered them and will not
//      deliver them again.
//
//   2. CLEAN ABORT. The peer FINs with nothing left to read and no body byte of the current
//      response emitted. Nothing has reached the decoder, so the handler may reopen the connection
//      and replay: error=1, error_dirty=0.
//
//   3. DIRTY ABORT. The peer FINs in the MIDDLE of a body. Those bytes are already in the decoder
//      stream and cannot be unsent, so replaying would duplicate them: error=1, error_dirty=1. This
//      is the guard that keeps a lost connection from silently corrupting a column.
//
//   4. THE READPKG RESERVATION, in both forms: one MSS per readPkg (RSV_EXACT=0, handler_multi,
//      dut_m, including the exact fifo level where admission has to stop) and the exact one
//      (RSV_EXACT=1, handler_toe, dut_x). Every beat the lane has promised room for must be
//      accepted.
//
// The dispatcher model for the default DUT (handler_multi's configuration) is deliberately small: a
// byte stream and a queue of announced segment lengths; a segment is delivered whole, in order,
// once the lane offers rx_space_ok, with rx_pkg_issued pulsed for it -- the contract rx_dispatch
// keeps under TCP_STACK_RX_DDR_BYPASS_EN=1, where one readPkg pops one packet from the shared FIFO.

import lynxTypes::*;

module tcp_read_tb;

    localparam int LANES  = AXI_DATA_BITS / 8;
    localparam int CLK_NS = 10;

    logic clk = 0;
    logic rst_n = 0;
    always #(CLK_NS/2) clk = ~clk;

    logic        start;
    logic        body_last;
    logic        clear_framing;

    logic                    rx_closed;
    logic                    pkg_issued;
    logic                    space_ok;

    logic                           rxdata_valid, rxdata_ready;
    logic [AXI_DATA_BITS-1:0]       rxdata_data;
    logic [LANES-1:0]               rxdata_keep;
    logic                           rxdata_last;

    logic                     body_tvalid, body_tready;
    logic [AXI_DATA_BITS-1:0] body_tdata;
    logic [LANES-1:0]         body_tkeep;
    logic                     body_tlast;

    logic        done, error, error_dirty, resp_error, status_ok;
    logic [23:0] status_ascii;
    logic [31:0] body_remaining;
    logic [3:0]  state_debug;
    // $clog2(RX_FIFO_DEPTH+1) for the default depth of 8192. A too-narrow net here silently
    // truncates the level the assertions read.
    logic [13:0] rx_fifo_level;
    logic        rx_fifo_stall;
    logic        read_timeout;

    int unsigned fails  = 0;
    int unsigned passes = 0;

    // WATCHDOG_BITS is dialled down from the synthesis default of 29 (~2.1 s at 250 MHz) to 12
    // (4096 cycles = 41 us here). The whole rest of this bench runs in ~8 us, so it cannot fire by
    // accident, and case_read_watchdog below can actually reach it. At the real value a test would
    // have to simulate two seconds of wall clock to prove the timeout exists at all.
    tcp_read #(.WATCHDOG_BITS(12)) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .body_last(body_last),
        .clear_framing(clear_framing),

        .rx_pkg_issued(pkg_issued),
        .rx_pkg_beats ('0),
        .rx_closed    (rx_closed),

        .s_axis_rx_data_TVALID     (rxdata_valid),
        .s_axis_rx_data_TREADY     (rxdata_ready),
        .s_axis_rx_data_TDATA      (rxdata_data),
        .s_axis_rx_data_TKEEP      (rxdata_keep),
        .s_axis_rx_data_TLAST      (rxdata_last),

        .m_axis_body_tvalid(body_tvalid),
        .m_axis_body_tready(body_tready),
        .m_axis_body_tdata (body_tdata),
        .m_axis_body_tkeep (body_tkeep),
        .m_axis_body_tlast (body_tlast),

        .done(done),
        .error(error),
        .error_dirty(error_dirty),
        .resp_error(resp_error),
        .status_ascii(status_ascii),
        .status_ok(status_ok),
        .body_remaining(body_remaining),
        .content_length(),
        .rx_fifo_level(rx_fifo_level),
        .rx_fifo_stall(rx_fifo_stall),
        .read_timeout(read_timeout),
        .rx_space_ok(space_ok),
        .rx_free_beats(),
        .debug_rx_write_ptr(),
        .debug_rx_buffer_w0(),
        .debug_rx_buffer_w1(),
        .state_debug(state_debug)
    );

    // ---------------------------------------------------------------------------------------------
    // SECOND DUT: RSV_EXACT=1 (toe_rx's lane, TOE in non-bypass mode).
    //
    // The caller reserves exactly the beats of each readPkg (rx_pkg_issued + rx_pkg_beats) and
    // may only do so while rx_free_beats covers them; the data then arrives unconditionally. A
    // small fifo (XDEPTH) so the case can fill it to the last promised beat with the decoder held
    // off. See case_rsv_exact.
    // ---------------------------------------------------------------------------------------------
    localparam int XDEPTH = 64;
    localparam int XLB    = $clog2(XDEPTH + 1);
    logic                     x_start, x_clear, x_pkg, x_closed;
    logic [XLB-1:0]           x_pkg_beats, x_free, x_level;
    logic                     x_dvalid, x_dready, x_dlast;
    logic [AXI_DATA_BITS-1:0] x_ddata;
    logic [LANES-1:0]         x_dkeep;
    logic                     x_bvalid, x_bready, x_blast;
    logic [AXI_DATA_BITS-1:0] x_bdata;
    logic [LANES-1:0]         x_bkeep;
    logic                     x_done, x_error, x_fifo_stall;

    tcp_read #(.RX_FIFO_DEPTH(XDEPTH), .WATCHDOG_BITS(16), .RSV_EXACT(1)) dut_x (
        .clk(clk), .rst_n(rst_n),
        .start(x_start), .body_last(1'b1), .clear_framing(x_clear),
        .rx_pkg_issued(x_pkg), .rx_pkg_beats(x_pkg_beats),
        .rx_closed(x_closed),
        .s_axis_rx_data_TVALID(x_dvalid), .s_axis_rx_data_TREADY(x_dready),
        .s_axis_rx_data_TDATA (x_ddata),  .s_axis_rx_data_TKEEP (x_dkeep),
        .s_axis_rx_data_TLAST (x_dlast),
        .m_axis_body_tvalid(x_bvalid), .m_axis_body_tready(x_bready),
        .m_axis_body_tdata (x_bdata),  .m_axis_body_tkeep (x_bkeep), .m_axis_body_tlast(x_blast),
        .done(x_done), .error(x_error), .error_dirty(), .resp_error(),
        .status_ascii(), .status_ok(), .content_length(), .body_remaining(), .read_timeout(),
        .rx_fifo_level(x_level), .rx_fifo_stall(x_fifo_stall),
        .rx_space_ok(), .rx_free_beats(x_free),
        .debug_rx_write_ptr(), .debug_rx_buffer_w0(), .debug_rx_buffer_w1(), .state_debug()
    );

    // ---------------------------------------------------------------------------------------------
    // THIRD DUT: RSV_EXACT=0 (handler_multi's lane, rx_dispatch, TOE in bypass mode) with a small
    // fifo (MDEPTH), so the one-MSS-per-readPkg reservation can be driven to its limit with the
    // decoder held off. See case_rsv_mss.
    // ---------------------------------------------------------------------------------------------
    localparam int MDEPTH = 256;
    localparam int MLB    = $clog2(MDEPTH + 1);
    logic                     m_start, m_clear, m_pkg, m_space;
    logic [MLB-1:0]           m_level;
    logic                     m_dvalid, m_dready, m_dlast;
    logic [AXI_DATA_BITS-1:0] m_ddata;
    logic [LANES-1:0]         m_dkeep;
    logic                     m_bvalid, m_bready, m_blast;
    logic [AXI_DATA_BITS-1:0] m_bdata;
    logic [LANES-1:0]         m_bkeep;
    logic                     m_done, m_error, m_fifo_stall;

    tcp_read #(.RX_FIFO_DEPTH(MDEPTH), .WATCHDOG_BITS(16)) dut_m (
        .clk(clk), .rst_n(rst_n),
        .start(m_start), .body_last(1'b1), .clear_framing(m_clear),
        .rx_pkg_issued(m_pkg), .rx_pkg_beats('0),
        .rx_closed(1'b0),
        .s_axis_rx_data_TVALID(m_dvalid), .s_axis_rx_data_TREADY(m_dready),
        .s_axis_rx_data_TDATA (m_ddata),  .s_axis_rx_data_TKEEP (m_dkeep),
        .s_axis_rx_data_TLAST (m_dlast),
        .m_axis_body_tvalid(m_bvalid), .m_axis_body_tready(m_bready),
        .m_axis_body_tdata (m_bdata),  .m_axis_body_tkeep (m_bkeep), .m_axis_body_tlast(m_blast),
        .done(m_done), .error(m_error), .error_dirty(), .resp_error(),
        .status_ascii(), .status_ok(), .content_length(), .body_remaining(), .read_timeout(),
        .rx_fifo_level(m_level), .rx_fifo_stall(m_fifo_stall),
        .rx_space_ok(m_space), .rx_free_beats(),
        .debug_rx_write_ptr(), .debug_rx_buffer_w0(), .debug_rx_buffer_w1(), .state_debug()
    );

    // ---------------------------------------------------------------------------------------------
    // Back-pressure monitor: the point of the whole decoupling.
    //
    // strip_http walks a header one byte per cycle. It used to drive s_axis_rx_data_TREADY directly,
    // so for the ~550 cycles of a MinIO 206 header the TCP stack was told to stop while data kept
    // arriving into its single shared 64 KB rx fifo. That backlog is what made a 32 KiB response fine
    // and a 64 KiB one fall off a cliff.
    //
    // With the decoupling fifo in between, TREADY may only ever drop because the fifo is genuinely
    // full -- never because the parser is busy. At these test sizes the fifo never fills, so the
    // correct count is exactly zero, and any non-zero value means the parser is back in the path.
    // The dispatcher does not hold a beat for TREADY, so every one of these is also a lost beat.
    // ---------------------------------------------------------------------------------------------
    int unsigned stall_cycles = 0;
    always @(posedge clk) begin
        if (rst_n && rxdata_valid && !rxdata_ready) begin
            stall_cycles <= stall_cycles + 1;
        end
    end

    // ---------------------------------------------------------------------------------------------
    // Dispatcher model
    // ---------------------------------------------------------------------------------------------
    logic [7:0] wire_q[$];   // the connection's byte stream
    int         seg_q[$];    // announced-but-undelivered segment lengths
    int         delivered = 0;
    int         pkts      = 0;

    task automatic push_str(input string s);
        for (int i = 0; i < s.len(); i++) wire_q.push_back(8'(s.getc(i)));
    endtask

    task automatic push_crlf();
        wire_q.push_back(8'h0D);
        wire_q.push_back(8'h0A);
    endtask

    task automatic append_response(input int body_len, input byte unsigned base);
        push_str("HTTP/1.1 206 Partial Content");                 push_crlf();
        push_str($sformatf("Content-Length: %0d", body_len));     push_crlf();
        push_str("Server: MinIO");                                push_crlf();
        push_crlf();
        for (int i = 0; i < body_len; i++) wire_q.push_back(base + i[7:0]);
    endtask

    int announced = 0;
    task automatic announce(input int n);
        seg_q.push_back(n);
        announced += n;
    endtask

    // One announced segment at a time, once the lane offers room for an MSS: rx_pkg_issued for one
    // cycle, then the segment's beats back to back after the readPkg's round trip, tlast on the
    // last. A beat is never held for TREADY (see the monitor above).
    initial begin
        pkg_issued   = 1'b0;
        rxdata_valid = 1'b0;
        rxdata_data  = '0;
        rxdata_keep  = '0;
        rxdata_last  = 1'b0;
        @(posedge rst_n);
        forever begin
            automatic int len, off, n, i, lane;
            automatic logic [AXI_DATA_BITS-1:0] beat;
            automatic logic [LANES-1:0]         keep;

            @(posedge clk);
            if (seg_q.size() == 0 || !space_ok || clear_framing) continue;
            len = seg_q.pop_front();
            pkg_issued <= 1'b1;
            @(posedge clk);
            pkg_issued <= 1'b0;
            pkts++;
            repeat (2) @(posedge clk);

            off = delivered;
            n   = (len + LANES - 1) / LANES;
            for (i = 0; i < n; i++) begin
                automatic int in_beat = ((len - i * LANES) > LANES) ? LANES : (len - i * LANES);
                beat = '0;
                keep = '0;
                for (lane = 0; lane < in_beat; lane++) begin
                    beat[lane*8 +: 8] = wire_q[off + i * LANES + lane];
                    keep[lane]        = 1'b1;
                end
                rxdata_data  <= beat;
                rxdata_keep  <= keep;
                rxdata_last  <= (i == n - 1);
                rxdata_valid <= 1'b1;
                @(posedge clk);
                delivered = off + i * LANES + in_beat;
            end
            rxdata_valid <= 1'b0;
            rxdata_last  <= 1'b0;
            delivered = off + len;
        end
    end

    // ---------------------------------------------------------------------------------------------
    // Consumer
    // ---------------------------------------------------------------------------------------------
    logic [7:0] got[$];
    int         tlasts = 0;

    always @(negedge clk) begin
        if (rst_n && body_tvalid && body_tready) begin
            for (int lane = 0; lane < LANES; lane++) begin
                if (body_tkeep[lane]) got.push_back(body_tdata[lane*8 +: 8]);
            end
            if (body_tlast) tlasts++;
        end
    end

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------
    task automatic reset_all();
        clear_framing = 1'b1;
        start         = 1'b0;
        body_last     = 1'b1;
        rx_closed     = 1'b0;
        body_tready   = 1'b1;
        wire_q.delete();
        seg_q.delete();
        got.delete();
        delivered = 0;
        announced = 0;
        pkts      = 0;
        tlasts    = 0;
        repeat (3) @(posedge clk);
        #1;
        clear_framing = 1'b0;
        @(posedge clk);
        #1;
    endtask

    // Run one response through the reader. Returns when it reports done.
    task automatic read_one(input int timeout = 20000);
        int guard;
        start = 1'b1;
        guard = 0;
        while (!done && guard < timeout) begin
            @(negedge clk);
            guard++;
        end
        if (!done) begin
            $error("read_one: timed out with state=%0d", state_debug);
            fails++;
        end
    endtask

    task automatic finish_read();
        @(posedge clk);
        #1;
        start = 1'b0;
        repeat (3) @(posedge clk);
        #1;
    endtask

    task automatic expect_body(input string name, input int len, input byte unsigned base,
                               input int from);
        if (got.size() < from + len) begin
            $error("[%s] only %0d bytes collected, need %0d", name, got.size(), from + len);
            fails++;
            return;
        end
        for (int i = 0; i < len; i++) begin
            if (got[from + i] !== byte'(base + i[7:0])) begin
                $error("[%s] byte %0d = 0x%02x, expected 0x%02x", name, i, got[from + i],
                       byte'(base + i[7:0]));
                fails++;
                return;
            end
        end
        $display("[PASS] %s (%0d bytes)", name, len);
        passes++;
    endtask

    // ---------------------------------------------------------------------------------------------
    // Cases
    // ---------------------------------------------------------------------------------------------

    // Two responses announced as ONE segment, so the boundary falls inside a packet. The first read
    // must end at the boundary; the second must frame the rest out of what is already buffered --
    // nothing more is delivered.
    task automatic case_resume_mid_packet();
        $display("--- case_resume_mid_packet ---");
        reset_all();
        append_response(120, 8'h10);
        append_response(90,  8'h80);
        announce(wire_q.size());          // a single segment covering both responses

        read_one();
        if (error) begin
            $error("[resume] first read reported error (dirty=%0b)", error_dirty);
            fails++;
        end
        expect_body("resume/body0", 120, 8'h10, 0);
        finish_read();

        read_one();
        if (error) begin
            $error("[resume] second read reported error (dirty=%0b)", error_dirty);
            fails++;
        end
        expect_body("resume/body1", 90, 8'h80, 120);
        if (got.size() != 210) begin
            $error("[resume] %0d bytes total, expected 210", got.size());
            fails++;
        end
        finish_read();

        if (pkts != 1) begin
            $error("[resume] %0d packets delivered, expected the one", pkts);
            fails++;
        end
        if (tlasts != 2) begin
            $error("[resume] %0d tlast, expected 2", tlasts);
            fails++;
        end
    endtask

    // The peer FINs with nothing announced and no body byte emitted. Replayable.
    task automatic case_clean_abort();
        $display("--- case_clean_abort ---");
        reset_all();
        rx_closed = 1'b1;

        read_one();
        if (!error) begin
            $error("[clean_abort] no error reported");
            fails++;
        end else if (error_dirty) begin
            $error("[clean_abort] reported DIRTY -- the handler would refuse to replay a request that never delivered a byte");
            fails++;
        end else begin
            $display("[PASS] clean_abort (error, not dirty)");
            passes++;
        end
        finish_read();
    endtask

    // Nothing ever arrives. Before the watchdog, waiting for data had no exit for this at all: it
    // ended only on the framer finishing, an announcement arriving, or the connection closing. After
    // a reconnect none of those can happen if the pending announcement belonged to the dead session,
    // so the reader waited forever and the board needed a reprogram. A scale-30 run hit exactly this
    // and burned 900 seconds.
    task automatic case_read_watchdog();
        int unsigned waited;
        $display("--- case_read_watchdog ---");
        reset_all();
        // No announcement, no data, no close. The one situation with no way out.
        rx_closed  = 1'b0;

        start = 1'b1;
        waited = 0;
        while (!done && waited < 20000) begin
            @(posedge clk);
            waited++;
        end

        if (!done) begin
            $error("[watchdog] still waiting after %0d cycles -- no timeout, and this hangs the board", waited);
            fails++;
        end else if (!error) begin
            $error("[watchdog] finished without reporting an error -- the handler would treat a dead read as a success");
            fails++;
        end else if (error_dirty) begin
            $error("[watchdog] reported DIRTY -- no byte was ever delivered, so the handler must be allowed to replay");
            fails++;
        end else if (!read_timeout) begin
            $error("[watchdog] aborted but read_timeout is clear -- the host cannot tell a timeout from a server error");
            fails++;
        end else begin
            $display("[PASS] read_watchdog (aborted after %0d cycles, clean, timeout flagged)", waited);
            passes++;
        end
        start = 1'b0;
        @(posedge clk);
    endtask

    // The peer FINs in the middle of a body. Those bytes are already downstream: not replayable.
    task automatic case_dirty_abort();
        $display("--- case_dirty_abort ---");
        reset_all();
        append_response(400, 8'h20);
        // Announce only the header plus part of the body, then FIN. The reader gets a truncated body
        // and must say so.
        announce(64);
        announce(64);

        start = 1'b1;
        // Let the two segments drain, then FIN.
        while (delivered < 128) @(negedge clk);
        repeat (20) @(negedge clk);
        rx_closed = 1'b1;

        begin
            int guard = 0;
            while (!done && guard < 20000) begin
                @(negedge clk);
                guard++;
            end
        end

        if (!done) begin
            $error("[dirty_abort] never finished, state=%0d", state_debug);
            fails++;
        end else if (!error) begin
            $error("[dirty_abort] no error reported for a truncated body");
            fails++;
        end else if (!error_dirty) begin
            $error("[dirty_abort] reported CLEAN -- the handler would replay and duplicate %0d bytes in the decoder stream",
                   got.size());
            fails++;
        end else begin
            $display("[PASS] dirty_abort (error + dirty after %0d body bytes, %0d still expected)",
                     got.size(), body_remaining);
            passes++;
        end
        if (tlasts != 0) begin
            $error("[dirty_abort] a truncated body raised tlast %0d time(s)", tlasts);
            fails++;
        end
        finish_read();
    endtask

    // body_last=0 concatenates two responses into one decoder stream with a single tlast.
    task automatic case_split_chunk();
        $display("--- case_split_chunk ---");
        reset_all();
        append_response(100, 8'h30);
        append_response(50,  8'h90);
        announce(wire_q.size());

        body_last = 1'b0;
        read_one();
        finish_read();
        body_last = 1'b1;
        read_one();
        finish_read();

        expect_body("split_chunk/part0", 100, 8'h30, 0);
        expect_body("split_chunk/part1", 50,  8'h90, 100);
        if (got.size() != 150) begin
            $error("[split_chunk] %0d bytes total, expected 150", got.size());
            fails++;
        end
        if (tlasts != 1) begin
            $error("[split_chunk] %0d tlast, expected exactly 1 for one decoder stream", tlasts);
            fails++;
        end else begin
            $display("[PASS] split_chunk/single_tlast");
            passes++;
        end
    endtask

    // ---------------------------------------------------------------------------------------------
    // RSV_EXACT=0 (dut_m): one MSS per readPkg.
    //
    // A readPkg may be issued only while rx_space_ok, which counts every issued-and-undelivered
    // readPkg as a whole MSS segment (64 beats + 2). With the decoder held off the issuer keeps
    // going until rx_space_ok falls; every beat of every issued segment must still be ACCEPTED.
    // Then the decoder runs, the body must be byte-exact with one tlast, and clear_framing must drop
    // every promise.
    // ---------------------------------------------------------------------------------------------
    logic [7:0] m_wire[$];
    int         m_pend[$];
    int         m_sent, m_deliv, m_refused, m_held_pkts;
    logic [7:0] m_got[$];
    int         m_tlasts;

    always @(posedge clk) begin
        if (rst_n && m_dvalid && !m_dready) m_refused++;
        if (rst_n && m_bvalid && m_bready) begin
            for (int lane = 0; lane < LANES; lane++) if (m_bkeep[lane]) m_got.push_back(m_bdata[lane*8 +: 8]);
            if (m_blast) m_tlasts++;
        end
    end

    task automatic case_rsv_mss();
        int body, total, guard, stuck;
        $display("--- case_rsv_mss (RSV_EXACT=0, DEPTH %0d) ---", MDEPTH);
        body = 30000;
        m_wire.delete(); m_pend.delete(); m_got.delete();
        m_sent = 0; m_deliv = 0; m_refused = 0; m_tlasts = 0; m_held_pkts = 0;
        begin
            string h;
            h = $sformatf("HTTP/1.1 206 Partial Content\015\012Content-Length: %0d\015\012\015\012", body);
            for (int i = 0; i < h.len(); i++) m_wire.push_back(8'(h.getc(i)));
            for (int i = 0; i < body; i++) m_wire.push_back(8'h60 + i[7:0]);
        end
        total = m_wire.size();
        m_bready = 1'b0;           // the decoder is held off for the first phase
        m_start  = 1'b1;
        fork
            begin : issuer
                while (m_sent < total) begin
                    automatic int len;
                    @(posedge clk);
                    if (!m_space || ($urandom_range(0, 3) == 0)) continue;
                    len = (total - m_sent > 4096) ? 4096 : (total - m_sent);
                    m_pkg <= 1'b1;
                    m_pend.push_back(len);
                    m_sent += len;
                    if (!m_bready) m_held_pkts++;
                    @(posedge clk);
                    m_pkg <= 1'b0;
                    repeat (2) @(posedge clk);   // until the charge shows up in rx_space_ok
                end
            end
            begin : deliverer
                while (m_deliv < total) begin
                    @(posedge clk);
                    if (m_pend.size() > 0) begin
                        automatic int len = m_pend.pop_front();
                        automatic int n   = (len + LANES - 1) / LANES;
                        repeat ($urandom_range(2, 12)) @(posedge clk);
                        for (int i = 0; i < n; i++) begin
                            automatic int nb = ((len - i*LANES) > LANES) ? LANES : (len - i*LANES);
                            automatic logic [AXI_DATA_BITS-1:0] d = '0;
                            automatic logic [LANES-1:0]         k = '0;
                            for (int b = 0; b < nb; b++) begin
                                d[b*8 +: 8] = m_wire[m_deliv + i*LANES + b];
                                k[b] = 1'b1;
                            end
                            m_ddata <= d; m_dkeep <= k; m_dlast <= (i == n - 1); m_dvalid <= 1'b1;
                            @(posedge clk);
                        end
                        m_dvalid <= 1'b0; m_dlast <= 1'b0;
                        m_deliv += len;
                    end
                end
            end
            begin : stall_watch
                stuck = 0;
                guard = 0;
                while (stuck < 400 && guard < 200000) begin
                    automatic int s0 = m_sent;
                    @(posedge clk);
                    guard++;
                    if (m_sent == s0 && m_pend.size() == 0 && !m_dvalid) stuck++; else stuck = 0;
                end
                if (m_space !== 1'b0 || m_sent >= total) begin
                    $error("[rsv_mss] held decoder: rx_space_ok=%0b with %0d of %0d bytes issued -- the reservation never stopped the issuer",
                           m_space, m_sent, total);
                    fails++;
                end else begin
                    $display("[PASS] rsv_mss/bounded (%0d MSS readPkgs while held, level %0d of %0d, rx_space_ok low)",
                             m_held_pkts, m_level, MDEPTH);
                    passes++;
                end
                m_bready = 1'b1;
            end
        join
        guard = 0;
        while (!m_done && guard < 100000) begin @(posedge clk); guard++; end
        repeat (10) @(posedge clk);
        if (m_refused != 0) begin
            $error("[rsv_mss] %0d promised beat(s) were REFUSED by the fifo", m_refused);
            fails++;
        end else if (m_fifo_stall !== 1'b0) begin
            $error("[rsv_mss] sticky overflow_stall set");
            fails++;
        end else begin
            $display("[PASS] rsv_mss/never_refused");
            passes++;
        end
        if (!m_done || m_error || m_tlasts != 1 || m_got.size() != body) begin
            $error("[rsv_mss] done=%0b error=%0b tlasts=%0d body bytes %0d of %0d",
                   m_done, m_error, m_tlasts, m_got.size(), body);
            fails++;
        end else begin
            automatic int bad = -1;
            for (int i = 0; i < body; i++) if (bad < 0 && m_got[i] !== 8'h60 + i[7:0]) bad = i;
            if (bad >= 0) begin
                $error("[rsv_mss] body byte %0d = 0x%02x", bad, m_got[bad]);
                fails++;
            end else begin
                $display("[PASS] rsv_mss/body (%0d bytes byte-exact, one tlast)", body);
                passes++;
            end
        end
        // one MSS charged on an empty fifo, then clear_framing drops it
        m_start = 1'b0;
        m_pkg <= 1'b1;
        @(posedge clk);
        m_pkg <= 1'b0;
        repeat (3) @(posedge clk);
        if (dut_m.rsv_beats_q != 66) begin
            $error("[rsv_mss] after one charge on an empty fifo: rsv=%0d, want 66", dut_m.rsv_beats_q);
            fails++;
        end
        m_clear = 1'b1;
        repeat (3) @(posedge clk);
        m_clear = 1'b0;
        repeat (3) @(posedge clk);
        if (dut_m.rsv_beats_q != 0 || m_space !== 1'b1) begin
            $error("[rsv_mss] after clear_framing: rsv=%0d space_ok=%0b (want 0/1)", dut_m.rsv_beats_q, m_space);
            fails++;
        end else begin
            $display("[PASS] rsv_mss/charge_and_clear (one MSS charged, clear drops it)");
            passes++;
        end
    endtask

    // ---------------------------------------------------------------------------------------------
    // RSV_EXACT=0 (dut_m): the admission edge.
    //
    // rx_space_ok may admit a segment only if every beat of it is accepted with the reader taking
    // nothing. The fifo refuses a beat at level >= DEPTH - ALMOST_FULL_SLACK (4), so with nothing
    // else reserved a 64-beat segment fits up to level DEPTH - 68 and not from DEPTH - 67 on. For
    // each level around that edge, with the decoder held off: fill the fifo to exactly that level
    // with beats nobody reserved (so the reservation is 0), then, if rx_space_ok says yes, issue one
    // readPkg and deliver one full segment back to back, not held for TREADY. Every admitted
    // segment must be accepted whole, and DEPTH - 68 must still be admitted.
    // ---------------------------------------------------------------------------------------------
    int m_ptr;

    task automatic m_drive_beat(input logic last);
        automatic logic [AXI_DATA_BITS-1:0] d = '0;
        for (int b = 0; b < LANES; b++) d[b*8 +: 8] = m_wire[m_ptr + b];
        m_ptr += LANES;
        m_ddata <= d; m_dkeep <= '1; m_dlast <= last; m_dvalid <= 1'b1;
        @(posedge clk);
        m_dvalid <= 1'b0; m_dlast <= 1'b0;
    endtask

    task automatic case_rsv_mss_edge();
        int levels [4];
        int target, refused, guard;
        bit admitted, ok, setup_ok;
        levels = '{MDEPTH - 69, MDEPTH - 68, MDEPTH - 67, MDEPTH - 66};
        $display("--- case_rsv_mss_edge (RSV_EXACT=0, DEPTH %0d, refusal at level %0d) ---", MDEPTH, MDEPTH - 4);
        m_wire.delete();
        begin
            string h;
            h = $sformatf("HTTP/1.1 206 Partial Content\015\012Content-Length: %0d\015\012\015\012", 1000000);
            for (int i = 0; i < h.len(); i++) m_wire.push_back(8'(h.getc(i)));
            while (m_wire.size() < (MDEPTH + 128) * LANES) m_wire.push_back(8'h5A);
        end
        ok = 1'b1;
        for (int k = 0; k < 4; k++) begin
            target = levels[k];
            // a fresh connection: fifo, framer and reservation cleared, decoder held off
            m_start = 1'b0; m_bready = 1'b0;
            m_clear = 1'b1; repeat (3) @(posedge clk);
            m_clear = 1'b0; @(posedge clk);
            m_start = 1'b1;
            m_ptr   = 0;
            // the header and a few body beats, until the framer stalls on the held decoder
            for (int i = 0; i < 8; i++) m_drive_beat(1'b1);
            repeat (300) @(posedge clk);
            // then one beat at a time up to the level
            for (guard = 0; guard < MDEPTH; guard++) begin
                if (int'(m_level) >= target) break;
                m_drive_beat(1'b1);
                repeat (8) @(posedge clk);
            end
            repeat (100) @(posedge clk);
            setup_ok = (int'(m_level) == target) && (dut_m.rsv_beats_q == 0);
            admitted = 1'b0;
            refused  = 0;
            if (!setup_ok) begin
                $error("[rsv_mss_edge] setup: level %0d rsv %0d, wanted level %0d rsv 0",
                       m_level, dut_m.rsv_beats_q, target);
                fails++;
                ok = 1'b0;
            end else begin
                admitted = m_space;
                if (admitted) begin
                    m_pkg <= 1'b1;
                    @(posedge clk);
                    m_pkg <= 1'b0;
                    repeat (2) @(posedge clk);
                    m_refused = 0;
                    for (int i = 0; i < 4096 / LANES; i++) m_drive_beat(i == 4096 / LANES - 1);
                    repeat (2) @(posedge clk);
                    refused = m_refused;
                end
                $display("  level %0d: rx_space_ok=%0b%s", target, admitted,
                         admitted ? $sformatf(", %0d of %0d beats refused", refused, 4096 / LANES) : "");
                if (refused != 0) begin
                    $error("[rsv_mss_edge] level %0d admitted a segment and the fifo refused %0d of its beats -- each one is lost",
                           target, refused);
                    fails++;
                    ok = 1'b0;
                end
                if (target <= MDEPTH - 68 && !admitted) begin
                    $error("[rsv_mss_edge] level %0d has room for a whole segment and was not admitted", target);
                    fails++;
                    ok = 1'b0;
                end
            end
        end
        if (ok) begin
            $display("[PASS] rsv_mss_edge (admitted up to level %0d, every admitted segment accepted whole)", MDEPTH - 68);
            passes++;
        end
        m_start = 1'b0;
        m_bready = 1'b1;
        m_clear = 1'b1; repeat (3) @(posedge clk);
        m_clear = 1'b0; repeat (3) @(posedge clk);
    endtask

    // ---------------------------------------------------------------------------------------------
    // RSV_EXACT (dut_x): the exact reservation.
    //
    // A readPkg may be issued for n bytes only while rx_free_beats >= ceil(n/64), and the caller
    // does not look at rx_free_beats again until its charge is visible (3 cycles, as toe_rx). With
    // the decoder held off, the issuer keeps going until the fifo is promised to the last beat;
    // then every promised beat must still be ACCEPTED (never refused), and the promise must reach
    // exactly DEPTH - 4 -- one beat less means the formula wastes space, one more means a refusal.
    // Then the decoder runs, the body must be byte-exact with one tlast, and clear_framing must
    // drop every promise.
    // ---------------------------------------------------------------------------------------------
    logic [7:0] x_wire[$];
    int         x_pend[$];       // bytes of each issued-but-undelivered readPkg, in issue order
    int         x_sent, x_deliv, x_refused, x_max_fill;
    logic [7:0] x_got[$];
    int         x_tlasts;

    always @(posedge clk) begin
        if (rst_n && x_dvalid && !x_dready) x_refused++;
        if (rst_n && (int'(x_level) + int'(dut_x.rsv_beats_q)) > x_max_fill)
            x_max_fill = int'(x_level) + int'(dut_x.rsv_beats_q);
        if (rst_n && x_bvalid && x_bready) begin
            for (int lane = 0; lane < LANES; lane++) if (x_bkeep[lane]) x_got.push_back(x_bdata[lane*8 +: 8]);
            if (x_blast) x_tlasts++;
        end
    end

    task automatic case_rsv_exact();
        int body, total, guard, stuck;
        $display("--- case_rsv_exact (RSV_EXACT=1, DEPTH %0d) ---", XDEPTH);
        body = 9000;
        x_wire.delete(); x_pend.delete(); x_got.delete();
        x_sent = 0; x_deliv = 0; x_refused = 0; x_max_fill = 0; x_tlasts = 0;
        begin
            string h;
            h = $sformatf("HTTP/1.1 206 Partial Content\015\012Content-Length: %0d\015\012\015\012", body);
            for (int i = 0; i < h.len(); i++) x_wire.push_back(8'(h.getc(i)));
            for (int i = 0; i < body; i++) x_wire.push_back(8'h40 + i[7:0]);
        end
        total = x_wire.size();
        x_bready = 1'b0;           // the decoder is held off for the first phase
        x_start  = 1'b1;
        fork
            begin : issuer
                while (x_sent < total) begin
                    automatic int free, len, maxb;
                    @(posedge clk);
                    free = int'(x_free);
                    if (free < 1 || ($urandom_range(0, 3) == 0)) continue;
                    maxb = free * LANES;
                    if (maxb > total - x_sent) maxb = total - x_sent;
                    len  = ($urandom_range(0, 2) == 0) ? maxb : $urandom_range(1, maxb);
                    x_pkg       <= 1'b1;
                    x_pkg_beats <= XLB'((len + LANES - 1) / LANES);
                    x_pend.push_back(len);
                    x_sent += len;
                    @(posedge clk);
                    x_pkg <= 1'b0;
                    repeat (3) @(posedge clk);   // until the charge shows up in rx_free_beats
                end
            end
            begin : deliverer
                while (x_deliv < total) begin
                    @(posedge clk);
                    if (x_pend.size() > 0) begin
                        automatic int len = x_pend.pop_front();
                        automatic int n   = (len + LANES - 1) / LANES;
                        repeat ($urandom_range(0, 12)) @(posedge clk);
                        for (int i = 0; i < n; i++) begin
                            automatic int nb = ((len - i*LANES) > LANES) ? LANES : (len - i*LANES);
                            automatic logic [AXI_DATA_BITS-1:0] d = '0;
                            automatic logic [LANES-1:0]         k = '0;
                            for (int b = 0; b < nb; b++) begin
                                d[b*8 +: 8] = x_wire[x_deliv + i*LANES + b];
                                k[b] = 1'b1;
                            end
                            x_ddata <= d; x_dkeep <= k; x_dlast <= (i == n - 1); x_dvalid <= 1'b1;
                            @(posedge clk);
                            // The data is NOT held for TREADY: the reservation promised room, and a
                            // refusal is counted (x_refused) and the beat is lost, exactly as it
                            // would be behind toe_rx's constant-high TREADY.
                        end
                        x_dvalid <= 1'b0; x_dlast <= 1'b0;
                        x_deliv += len;
                    end
                end
            end
            begin : stall_watch
                // Phase 1 ends when nothing has been issued for a long time with the decoder held:
                // the fifo is promised to the last beat. Then the decoder runs.
                stuck = 0;
                guard = 0;
                while (stuck < 400 && guard < 200000) begin
                    automatic int s0 = x_sent;
                    @(posedge clk);
                    guard++;
                    if (x_sent == s0 && x_pend.size() == 0 && !x_dvalid) stuck++; else stuck = 0;
                end
                if (x_free !== '0 || (int'(x_level) + int'(dut_x.rsv_beats_q)) != XDEPTH - 4) begin
                    $error("[rsv_exact] held decoder: free=%0d level=%0d rsv=%0d -- the promise must fill to exactly DEPTH-4=%0d",
                           x_free, x_level, dut_x.rsv_beats_q, XDEPTH - 4);
                    fails++;
                end else begin
                    $display("[PASS] rsv_exact/fills_to_depth_minus_4 (level %0d + reserved %0d, %0d of %0d bytes issued)",
                             x_level, dut_x.rsv_beats_q, x_sent, total);
                    passes++;
                end
                x_bready = 1'b1;
            end
        join
        guard = 0;
        while (!x_done && guard < 100000) begin @(posedge clk); guard++; end
        repeat (10) @(posedge clk);
        if (x_refused != 0) begin
            $error("[rsv_exact] %0d promised beat(s) were REFUSED by the fifo", x_refused);
            fails++;
        end else if (x_fifo_stall !== 1'b0) begin
            $error("[rsv_exact] sticky overflow_stall set");
            fails++;
        end else if (x_max_fill != XDEPTH - 4) begin
            $error("[rsv_exact] most promised at once %0d, expected exactly %0d", x_max_fill, XDEPTH - 4);
            fails++;
        end else begin
            $display("[PASS] rsv_exact/never_refused (max level+reserved %0d = DEPTH-4)", x_max_fill);
            passes++;
        end
        if (!x_done || x_error || x_tlasts != 1 || x_got.size() != body) begin
            $error("[rsv_exact] done=%0b error=%0b tlasts=%0d body bytes %0d of %0d",
                   x_done, x_error, x_tlasts, x_got.size(), body);
            fails++;
        end else begin
            automatic int bad = -1;
            for (int i = 0; i < body; i++) if (bad < 0 && x_got[i] !== 8'h40 + i[7:0]) bad = i;
            if (bad >= 0) begin
                $error("[rsv_exact] body byte %0d = 0x%02x", bad, x_got[bad]);
                fails++;
            end else begin
                $display("[PASS] rsv_exact/body (%0d bytes byte-exact, one tlast)", body);
                passes++;
            end
        end
        // clear_framing drops every promise (a torn-down lane), and free reads 0 while it is high
        x_start = 1'b0;
        x_pkg <= 1'b1; x_pkg_beats <= XLB'(10);
        @(posedge clk);
        x_pkg <= 1'b0;
        repeat (3) @(posedge clk);
        if (dut_x.rsv_beats_q != 10 || int'(x_free) != XDEPTH - 4 - 10) begin
            $error("[rsv_exact] after a 10-beat charge on an empty fifo: rsv=%0d free=%0d", dut_x.rsv_beats_q, x_free);
            fails++;
        end
        x_clear = 1'b1;
        repeat (3) @(posedge clk);
        if (dut_x.rsv_beats_q != 0 || x_free !== '0) begin
            $error("[rsv_exact] under clear_framing: rsv=%0d free=%0d (want 0/0)", dut_x.rsv_beats_q, x_free);
            fails++;
        end
        x_clear = 1'b0;
        repeat (3) @(posedge clk);
        if (int'(x_free) != XDEPTH - 4) begin
            $error("[rsv_exact] after clear_framing: free=%0d, want %0d", x_free, XDEPTH - 4);
            fails++;
        end else begin
            $display("[PASS] rsv_exact/charge_and_clear (10-beat charge seen, clear drops it)");
            passes++;
        end
    endtask

    initial begin
        x_start = 1'b0; x_clear = 1'b1; x_pkg = 1'b0; x_pkg_beats = '0; x_closed = 1'b0;
        x_dvalid = 1'b0; x_dlast = 1'b0; x_ddata = '0; x_dkeep = '0; x_bready = 1'b1;
        @(posedge rst_n);
        repeat (3) @(posedge clk);
        x_clear = 1'b0;
    end

    initial begin
        m_start = 1'b0; m_clear = 1'b1; m_pkg = 1'b0;
        m_dvalid = 1'b0; m_dlast = 1'b0; m_ddata = '0; m_dkeep = '0; m_bready = 1'b1;
        @(posedge rst_n);
        repeat (3) @(posedge clk);
        m_clear = 1'b0;
    end

    initial begin
        start         = 1'b0;
        clear_framing = 1'b1;
        body_last     = 1'b1;
        rx_closed     = 1'b0;
        body_tready   = 1'b1;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        case_resume_mid_packet();
        case_clean_abort();
        case_dirty_abort();
        case_split_chunk();
        case_read_watchdog();
        repeat (5) @(posedge clk);
        case_rsv_mss();
        repeat (5) @(posedge clk);
        case_rsv_mss_edge();
        repeat (5) @(posedge clk);
        case_rsv_exact();

        // Every case above ran a real response through the header parser. If the parser were still
        // in the TCP stack's back-pressure path, each one would have contributed hundreds of stall
        // cycles. See the monitor above for why zero is the only acceptable answer.
        $display("--- decoupling ---");
        if (stall_cycles != 0) begin
            $error("[decoupling] parser back-pressured the TCP stack for %0d cycles -- strip_http is in the drain path again", stall_cycles);
            fails++;
        end else begin
            $display("[PASS] no_toe_backpressure (0 cycles of TVALID && !TREADY)");
            passes++;
        end
        if (rx_fifo_stall !== 1'b0) begin
            $error("[decoupling] rx_fifo refused the TCP stack -- RX_FIFO_DEPTH is too small");
            fails++;
        end else begin
            $display("[PASS] rx_fifo_never_full (sticky overflow_stall clear)");
            passes++;
        end

        $display("========================================");
        $display("tcp_read_tb: %0d passed, %0d failed", passes, fails);
        $display("========================================");
        if (fails != 0) $fatal(1, "test failed");
        $finish;
    end

    initial begin
        #5_000_000;
        $fatal(1, "timeout");
    end

endmodule
