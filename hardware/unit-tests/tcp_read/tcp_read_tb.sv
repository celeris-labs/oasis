`timescale 1ns / 1ps

// Standalone testbench for tcp_read (+ strip_http) on a persistent connection.
//
// http_pipeline covers the happy path end to end. This bench exists for the three things that are
// awkward to force through the whole handler and that are exactly where keep-alive can go wrong:
//
//   1. RESUME MID-PACKET. A TCP segment may carry the tail of body k and the head of response k+1.
//      When that happens the read for response k must stop with the packet half-consumed and the
//      read for k+1 must pick it up where it left off -- not issue a new readPkg, because the TOE
//      has already advanced its app read pointer for that packet and there is nothing to re-read.
//
//   2. CLEAN ABORT. The peer FINs with nothing left to read and no body byte of the current
//      response emitted. Nothing has reached the decoder, so the handler may reopen the connection
//      and replay: error=1, error_dirty=0.
//
//   3. DIRTY ABORT. The peer FINs in the MIDDLE of a body. Those bytes are already in the decoder
//      stream and cannot be unsent, so replaying would duplicate them: error=1, error_dirty=1. This
//      is the guard that keeps a lost connection from silently corrupting a column.
//
// The TOE model is deliberately small: a byte stream, a queue of announced segment lengths, and a
// readPkg responder that hands back exactly ONE announced segment per request -- the real contract
// under TCP_STACK_RX_DDR_BYPASS_EN=1, where a readPkg is a bare token and rxAppMemDataRead pops one
// packet from the shared FIFO regardless of the length asked for.

import lynxTypes::*;

module tcp_read_tb;

    localparam int LANES  = AXI_DATA_BITS / 8;
    localparam int CLK_NS = 10;

    logic clk = 0;
    logic rst_n = 0;
    always #(CLK_NS/2) clk = ~clk;

    logic        start;
    logic [15:0] session_id = 16'h0100;
    logic        body_last;
    logic        clear_framing;

    logic [TCP_LEN_BITS-1:0] rx_req_len;
    logic                    rx_closed;
    logic                    rx_take_en;

    logic                           rdpkg_valid, rdpkg_ready;
    logic [TCP_RD_PKG_REQ_BITS-1:0] rdpkg_data;
    logic                           rxmeta_valid, rxmeta_ready;
    logic [TCP_RX_META_BITS-1:0]    rxmeta_data;
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
    // $clog2(RX_FIFO_DEPTH+1). Was 11 when the fifo was 1024 deep; 4096 needs 13, and a too-narrow
    // net here silently truncates the level the assertions read.
    logic [12:0] rx_fifo_level;
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
        .session_id(session_id),
        .body_last(body_last),
        .clear_framing(clear_framing),

        .rx_req_len(rx_req_len),
        .rx_closed (rx_closed),
        .rx_take_en(rx_take_en),

        .m_axis_read_package_TVALID(rdpkg_valid),
        .m_axis_read_package_TREADY(rdpkg_ready),
        .m_axis_read_package_TDATA (rdpkg_data),
        .s_axis_rx_metadata_TVALID (rxmeta_valid),
        .s_axis_rx_metadata_TREADY (rxmeta_ready),
        .s_axis_rx_metadata_TDATA  (rxmeta_data),
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
        .rx_fifo_level(rx_fifo_level),
        .rx_fifo_stall(rx_fifo_stall),
        .read_timeout(read_timeout),
        .debug_rx_write_ptr(),
        .debug_rx_buffer_w0(),
        .debug_rx_buffer_w1(),
        .state_debug(state_debug)
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
    // ---------------------------------------------------------------------------------------------
    int unsigned stall_cycles = 0;
    always @(posedge clk) begin
        if (rst_n && rxdata_valid && !rxdata_ready && (state_debug == 4'd9)) begin
            stall_cycles <= stall_cycles + 1;
        end
    end

    // ---------------------------------------------------------------------------------------------
    // TOE model
    // ---------------------------------------------------------------------------------------------
    logic [7:0] wire_q[$];   // the connection's byte stream
    int         seg_q[$];    // announced-but-unread segment lengths
    int         delivered = 0;
    int         readpkgs  = 0;

    // rx_req_len is the oldest announcement, recomputed mid-cycle so it is settled by the posedge
    // where the DUT samples it. The queue is popped by the readPkg responder below, which is also
    // where the one-readPkg-per-announcement contract is enforced.
    always @(negedge clk) rx_req_len = (seg_q.size() > 0) ? TCP_LEN_BITS'(seg_q[0]) : '0;

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

    // readPkg -> rx meta + rx data. Hands back exactly the oldest announced segment.
    initial begin
        rdpkg_ready  = 1'b0;
        rxmeta_valid = 1'b0;
        rxmeta_data  = '0;
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
            rdpkg_ready <= 1'b1;
            @(posedge clk);
            while (!(rdpkg_valid && rdpkg_ready)) @(posedge clk);
            len = int'(rdpkg_data[TCP_LEN_BITS+TCP_SESSION_BITS-1:TCP_SESSION_BITS]);
            rdpkg_ready <= 1'b0;
            readpkgs++;

            if (seg_q.size() == 0) $fatal(1, "readPkg with no announcement outstanding");
            if (len != seg_q[0]) begin
                $fatal(1, "readPkg asked for %0d bytes but the oldest announcement is %0d -- one readPkg must name exactly one announced segment",
                       len, seg_q[0]);
            end
            len = seg_q.pop_front();

            repeat (2) @(posedge clk);
            rxmeta_data  <= session_id;
            rxmeta_valid <= 1'b1;
            @(posedge clk);
            while (!rxmeta_ready) @(posedge clk);
            rxmeta_valid <= 1'b0;

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
                while (!rxdata_ready) @(posedge clk);
                rxdata_valid <= 1'b0;
                rxdata_last  <= 1'b0;
                delivered    = off + (i + 1) * LANES > off + len ? off + len : off + (i + 1) * LANES;
            end
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
        readpkgs  = 0;
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

    // Two responses announced as ONE segment, so the boundary falls inside a readPkg. The first read
    // must stop mid-packet; the second must resume it without asking the TOE for anything new.
    task automatic case_resume_mid_packet();
        int pkgs_after_first;

        $display("--- case_resume_mid_packet ---");
        reset_all();
        append_response(120, 8'h10);
        append_response(90,  8'h80);
        announce(wire_q.size());          // a single segment covering both responses

        read_one();
        pkgs_after_first = readpkgs;
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

        if (readpkgs != pkgs_after_first) begin
            $error("[resume] second read issued %0d extra readPkg(s); the packet was already half consumed",
                   readpkgs - pkgs_after_first);
            fails++;
        end else begin
            $display("[PASS] resume/no_extra_readpkg (%0d readPkg total)", readpkgs);
            passes++;
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

    // Nothing ever arrives. Before the watchdog, ST_WAIT_NOTIFY had no exit for this at all: it left
    // only on the framer finishing, an announcement arriving, or the connection closing. After a
    // reconnect none of those can happen if the pending announcement belonged to the dead session,
    // so the reader waited forever and the board needed a reprogram. A scale-30 run hit exactly this
    // and burned 900 seconds.
    task automatic case_read_watchdog();
        int unsigned waited;
        $display("--- case_read_watchdog ---");
        reset_all();
        // No announcement, no data, no close. The one situation with no way out.
        rx_req_len = '0;
        rx_closed  = 1'b0;

        start = 1'b1;
        waited = 0;
        while (!done && waited < 20000) begin
            @(posedge clk);
            waited++;
        end

        if (!done) begin
            $error("[watchdog] still waiting after %0d cycles -- ST_WAIT_NOTIFY has no timeout and this hangs the board", waited);
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

    initial begin
        start         = 1'b0;
        clear_framing = 1'b1;
        body_last     = 1'b1;
        rx_closed     = 1'b0;
        body_tready   = 1'b1;
        rx_req_len    = '0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        case_resume_mid_packet();
        case_clean_abort();
        case_dirty_abort();
        case_split_chunk();
        case_read_watchdog();

        // Every case above ran a real response through the header parser. If the parser were still
        // in the TCP stack's back-pressure path, each one would have contributed hundreds of stall
        // cycles. See the monitor above for why zero is the only acceptable answer.
        $display("--- decoupling ---");
        if (stall_cycles != 0) begin
            $error("[decoupling] parser back-pressured the TCP stack for %0d cycles -- strip_http is in the drain path again", stall_cycles);
            fails++;
        end else begin
            $display("[PASS] no_toe_backpressure (0 cycles of TVALID && !TREADY in ST_RECV_DATA)");
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
