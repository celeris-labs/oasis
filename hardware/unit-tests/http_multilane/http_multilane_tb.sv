`timescale 1ns / 1ps

import lynxTypes::*;

// =================================================================================================
// rx_dispatch + N x tcp_read(EXTERNAL_DISPATCH=1) -- the multi-session receive path, end to end.
//
// rx_dispatch has its own unit tests and so does tcp_read; neither can catch what this bench is
// for. The claim under test is the one the whole arrangement exists to make:
//
//     N HTTP responses arriving INTERLEAVED AT PACKET GRANULARITY on one shared TCP receive
//     stream come out correctly framed, on their own lanes, and a lane whose consumer stalls
//     does not stall the others.
//
// That last clause is the point. The single-connection design demuxes AFTER strip_http
// (vfpga_top.svh gen_http_lane_sel), where a busy lane back-pressures the shared body stream and
// stalls every lane -- its own comment concedes "the same head-of-line behaviour the single-lane
// design had". Moving the demux upstream is only worth doing if that goes away, so test 2 fails
// the build if it has not.
// =================================================================================================
module http_multilane_tb;

    localparam int NUM_CONNS = 4;
    localparam int LANES     = AXI_DATA_BITS / 8;   // bytes per beat
    localparam int RX_DEPTH  = 512;                 // small: the space gate must be reachable

    logic clk = 0, rst_n = 0;
    always #2 clk = ~clk;

    // -- shared TOE side --------------------------------------------------------------------------
    logic                       notif_valid, notif_ready;
    logic [TCP_NOTIFY_BITS-1:0] notif_data;

    logic                           rdpkg_valid, rdpkg_ready;
    logic [TCP_RD_PKG_REQ_BITS-1:0] rdpkg_data;

    logic                        rxmeta_valid, rxmeta_ready;
    logic [TCP_RX_META_BITS-1:0] rxmeta_data;

    logic                       rxdata_valid, rxdata_ready;
    logic [AXI_DATA_BITS-1:0]   rxdata_data;
    logic [AXI_DATA_BITS/8-1:0] rxdata_keep;
    logic                       rxdata_last;

    // -- dispatcher fan-out -----------------------------------------------------------------------
    logic [NUM_CONNS-1:0]       conn_tvalid, conn_tready, conn_space_ok, conn_closed;
    logic [AXI_DATA_BITS-1:0]   conn_tdata;
    logic [AXI_DATA_BITS/8-1:0] conn_tkeep;
    logic                       conn_tlast;

    logic bind_en, release_en;
    logic [$clog2(NUM_CONNS)-1:0] bind_conn, release_conn;
    logic [TCP_SESSION_BITS-1:0]  bind_sid;

    logic [NUM_CONNS-1:0] dbg_has_pending;
    logic                 dbg_overflow, dbg_route_stall;

    rx_dispatch #(
        .NUM_CONNS   (NUM_CONNS),
        .NOTIFY_DEPTH(64)
    ) dut_dispatch (
        .clk(clk), .rst_n(rst_n),
        .s_axis_notifications_TVALID(notif_valid),
        .s_axis_notifications_TREADY(notif_ready),
        .s_axis_notifications_TDATA (notif_data),
        .bind_en(bind_en), .bind_conn(bind_conn), .bind_sid(bind_sid),
        .release_en(release_en), .release_conn(release_conn),
        .m_axis_read_package_TVALID(rdpkg_valid),
        .m_axis_read_package_TREADY(rdpkg_ready),
        .m_axis_read_package_TDATA (rdpkg_data),
        .s_axis_rx_metadata_TVALID(rxmeta_valid),
        .s_axis_rx_metadata_TREADY(rxmeta_ready),
        .s_axis_rx_metadata_TDATA (rxmeta_data),
        .s_axis_rx_data_TVALID(rxdata_valid),
        .s_axis_rx_data_TREADY(rxdata_ready),
        .s_axis_rx_data_TDATA (rxdata_data),
        .s_axis_rx_data_TKEEP (rxdata_keep),
        .s_axis_rx_data_TLAST (rxdata_last),
        .conn_tvalid(conn_tvalid), .conn_tready(conn_tready),
        .conn_tdata (conn_tdata),  .conn_tkeep (conn_tkeep), .conn_tlast(conn_tlast),
        .conn_space_ok(conn_space_ok),
        .conn_closed  (conn_closed),
        .dbg_has_pending(dbg_has_pending),
        .dbg_overflow   (dbg_overflow),
        .dbg_route_stall(dbg_route_stall)
    );

    // -- one receive lane per connection ----------------------------------------------------------
    logic [NUM_CONNS-1:0]     lane_start, lane_clear;
    logic [NUM_CONNS-1:0]     body_tvalid, body_tready, body_tlast;
    logic [AXI_DATA_BITS-1:0] body_tdata [NUM_CONNS];
    logic [LANES-1:0]         body_tkeep [NUM_CONNS];
    logic [NUM_CONNS-1:0]     lane_done, lane_error, lane_status_ok, lane_fifo_stall;
    logic [3:0]               lane_state [NUM_CONNS];

    for (genvar L = 0; L < NUM_CONNS; L++) begin : gen_lane
        tcp_read #(
            .RX_FIFO_DEPTH    (RX_DEPTH),
            .WATCHDOG_BITS    (16),
            .EXTERNAL_DISPATCH(1)
        ) dut_read (
            .clk(clk), .rst_n(rst_n),
            .start        (lane_start[L]),
            .session_id   (16'(100 + L)),
            .body_last    (1'b1),
            .clear_framing(lane_clear[L]),

            // Owned by rx_dispatch now.
            .rx_req_len('0), .rx_closed(conn_closed[L]), .rx_take_en(),
            .m_axis_read_package_TVALID(), .m_axis_read_package_TREADY(1'b0),
            .m_axis_read_package_TDATA (),
            .s_axis_rx_metadata_TVALID (1'b0), .s_axis_rx_metadata_TREADY(),
            .s_axis_rx_metadata_TDATA  ('0),

            .s_axis_rx_data_TVALID(conn_tvalid[L]),
            .s_axis_rx_data_TREADY(conn_tready[L]),
            .s_axis_rx_data_TDATA (conn_tdata),
            .s_axis_rx_data_TKEEP (conn_tkeep),
            .s_axis_rx_data_TLAST (conn_tlast),

            .m_axis_body_tvalid(body_tvalid[L]),
            .m_axis_body_tready(body_tready[L]),
            .m_axis_body_tdata (body_tdata[L]),
            .m_axis_body_tkeep (body_tkeep[L]),
            .m_axis_body_tlast (body_tlast[L]),

            .done(lane_done[L]), .error(lane_error[L]), .error_dirty(),
            .resp_error(), .status_ascii(), .status_ok(lane_status_ok[L]),
            .content_length(), .body_remaining(), .read_timeout(),
            .rx_fifo_level(), .rx_fifo_stall(lane_fifo_stall[L]),
            .rx_space_ok  (conn_space_ok[L]),
            .debug_rx_write_ptr(), .debug_rx_buffer_w0(), .debug_rx_buffer_w1(),
            .state_debug(lane_state[L])
        );
    end

    // ---------------------------------------------------------------------------------------------
    // Scoreboard
    // ---------------------------------------------------------------------------------------------
    int pass_cnt = 0, fail_cnt = 0;
    task automatic ok(input string n);
        $display("[PASS] %s", n); pass_cnt++;
    endtask
    task automatic bad(input string n);
        $display("[FAIL] %s", n); fail_cnt++;
    endtask

    // ---------------------------------------------------------------------------------------------
    // TOE model
    //
    // One byte stream per session, plus ONE globally ordered packet queue -- which is the whole
    // point: the shared rx fifo has no per-session structure, so packets leave it in the order they
    // landed, whatever session each belongs to.
    // ---------------------------------------------------------------------------------------------
    logic [7:0] sess_bytes [NUM_CONNS][$];
    int         sess_off   [NUM_CONNS];

    int pkt_conn_q [$];   // arrival-ordered: which connection each packet belongs to
    int pkt_len_q  [$];   // and how many bytes it carries

    int readpkgs = 0;

    task automatic push_str(input int c, input string s);
        for (int i = 0; i < s.len(); i++) sess_bytes[c].push_back(8'(s.getc(i)));
    endtask
    task automatic push_crlf(input int c);
        sess_bytes[c].push_back(8'h0D); sess_bytes[c].push_back(8'h0A);
    endtask

    // A MinIO-shaped 206, body filled with a per-lane ramp so a mis-route is unmistakable.
    task automatic append_response(input int c, input int body_len, input byte unsigned base);
        push_str(c, "HTTP/1.1 206 Partial Content");             push_crlf(c);
        push_str(c, $sformatf("Content-Length: %0d", body_len)); push_crlf(c);
        push_str(c, "Server: MinIO");                            push_crlf(c);
        push_crlf(c);
        for (int i = 0; i < body_len; i++) sess_bytes[c].push_back(base + i[7:0]);
    endtask

    // Announce a segment for connection c. Order of these calls IS the arrival order.
    task automatic announce(input int c, input int n);
        pkt_conn_q.push_back(c);
        pkt_len_q.push_back(n);
        notif_data <= {6'd0, 1'b0, 1'b0, 16'd9000, 32'h0A00_0001,
                       TCP_LEN_BITS'(n), TCP_SESSION_BITS'(100 + c)};
        notif_valid <= 1'b1;
        @(posedge clk);
        while (!notif_ready) @(posedge clk);
        notif_valid <= 1'b0;
        @(posedge clk);
    endtask

    // readPkg -> one rx_metadata beat -> that packet's data beats, from the head of the queue.
    initial begin
        rdpkg_ready  = 1'b0;
        rxmeta_valid = 1'b0; rxmeta_data = '0;
        rxdata_valid = 1'b0; rxdata_data = '0; rxdata_keep = '0; rxdata_last = 1'b0;
        @(posedge rst_n);
        forever begin
            automatic int c, len, off, n, i, b;
            automatic logic [AXI_DATA_BITS-1:0] beat;
            automatic logic [LANES-1:0]         keep;

            @(posedge clk);
            rdpkg_ready <= 1'b1;
            @(posedge clk);
            while (!(rdpkg_valid && rdpkg_ready)) @(posedge clk);
            rdpkg_ready <= 1'b0;
            readpkgs++;

            if (pkt_conn_q.size() == 0) $fatal(1, "readPkg with no packet outstanding");
            c   = pkt_conn_q.pop_front();
            len = pkt_len_q.pop_front();

            // The session id in the readPkg must name the packet at the HEAD of the shared fifo.
            // Anything else means the dispatcher reordered, which hands one session's bytes to
            // another session's reader -- builds 90/91/92.
            if (int'(rdpkg_data[TCP_SESSION_BITS-1:0]) != 100 + c) begin
                $fatal(1, "readPkg named session %0d but the fifo head belongs to session %0d",
                       int'(rdpkg_data[TCP_SESSION_BITS-1:0]), 100 + c);
            end

            repeat (2) @(posedge clk);
            rxmeta_data  <= TCP_RX_META_BITS'(100 + c);
            rxmeta_valid <= 1'b1;
            @(posedge clk);
            while (!rxmeta_ready) @(posedge clk);
            rxmeta_valid <= 1'b0;

            off = sess_off[c];
            n   = (len + LANES - 1) / LANES;
            for (i = 0; i < n; i++) begin
                automatic int in_beat = ((len - i*LANES) > LANES) ? LANES : (len - i*LANES);
                beat = '0; keep = '0;
                for (b = 0; b < in_beat; b++) begin
                    beat[b*8 +: 8] = sess_bytes[c][off + i*LANES + b];
                    keep[b]        = 1'b1;
                end
                rxdata_data  <= beat;
                rxdata_keep  <= keep;
                rxdata_last  <= (i == n-1);
                rxdata_valid <= 1'b1;
                @(posedge clk);
                while (!rxdata_ready) @(posedge clk);
                rxdata_valid <= 1'b0;
                rxdata_last  <= 1'b0;
            end
            sess_off[c] = off + len;
        end
    end

    // ---------------------------------------------------------------------------------------------
    // Per-lane consumers, each independently stallable -- test 2 needs exactly that.
    // ---------------------------------------------------------------------------------------------
    logic [7:0] got    [NUM_CONNS][$];
    int         tlasts [NUM_CONNS];
    logic [NUM_CONNS-1:0] consumer_stall;

    for (genvar L = 0; L < NUM_CONNS; L++) begin : gen_consumer
        assign body_tready[L] = !consumer_stall[L];
    end

    always @(negedge clk) begin
        if (rst_n) begin
            for (int L = 0; L < NUM_CONNS; L++) begin
                if (body_tvalid[L] && body_tready[L]) begin
                    for (int b = 0; b < LANES; b++) begin
                        if (body_tkeep[L][b]) got[L].push_back(body_tdata[L][b*8 +: 8]);
                    end
                    if (body_tlast[L]) tlasts[L]++;
                end
            end
        end
    end

    // ---------------------------------------------------------------------------------------------
    // The decoupling monitor. The shared data stream must NEVER be refused: rx_dispatch decides
    // whether to ask for a packet, and once asked it takes every beat. A non-zero count here means
    // back-pressure reached the TOE, which stalls every session at once.
    // ---------------------------------------------------------------------------------------------
    int unsigned shared_stall_cycles = 0;
    always @(posedge clk) begin
        if (rst_n && rxdata_valid && !rxdata_ready) shared_stall_cycles <= shared_stall_cycles + 1;
    end

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------
    task automatic reset_all();
        bind_en = 0; release_en = 0; bind_conn = '0; release_conn = '0; bind_sid = '0;
        lane_start = '0; lane_clear = '1; consumer_stall = '0;
        notif_valid = 0; notif_data = '0;
        rst_n = 0;
        for (int L = 0; L < NUM_CONNS; L++) begin
            sess_bytes[L].delete(); got[L].delete();
            sess_off[L] = 0; tlasts[L] = 0;
        end
        pkt_conn_q.delete(); pkt_len_q.delete();
        readpkgs = 0; shared_stall_cycles = 0;
        repeat (6) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);
        lane_clear = '0;
        repeat (2) @(posedge clk);
    endtask

    task automatic bind_all();
        for (int L = 0; L < NUM_CONNS; L++) begin
            bind_conn <= $clog2(NUM_CONNS)'(L);
            bind_sid  <= TCP_SESSION_BITS'(100 + L);
            bind_en   <= 1'b1;
            @(posedge clk);
            bind_en   <= 1'b0;
            @(posedge clk);
        end
    endtask

    task automatic start_all();
        lane_start <= '1;
        @(posedge clk);
    endtask

    task automatic expect_body(input string name, input int c, input int len, input byte unsigned base);
        automatic bit good = 1;
        if (got[c].size() != len) begin
            $display("        lane %0d: %0d body bytes, expected %0d", c, got[c].size(), len);
            good = 0;
        end else begin
            for (int i = 0; i < len; i++) begin
                if (got[c][i] !== (base + i[7:0])) begin
                    $display("        lane %0d byte %0d: got %02h expected %02h",
                             c, i, got[c][i], base + i[7:0]);
                    good = 0;
                    break;
                end
            end
        end
        if (good) ok(name); else bad(name);
    endtask

    // `mask` names the lanes that actually carry a response in this case; waiting on an idle lane
    // would always time out and print a failure-shaped line next to passing assertions.
    task automatic wait_lanes_done(input int n_expected_tlast,
                                   input logic [NUM_CONNS-1:0] mask = '1,
                                   input int timeout = 200000);
        automatic int t = 0;
        automatic bit all_done;
        forever begin
            all_done = 1;
            for (int L = 0; L < NUM_CONNS; L++)
                if (mask[L] && tlasts[L] < n_expected_tlast) all_done = 0;
            if (all_done) break;
            @(posedge clk);
            t++;
            if (t > timeout) begin
                $display("        timeout: tlasts = %0d %0d %0d %0d",
                         tlasts[0], tlasts[1], tlasts[2], tlasts[3]);
                break;
            end
        end
    endtask

    // ---------------------------------------------------------------------------------------------
    // 1. Routing -- four sessions, packets interleaved, each lane frames its own response.
    // ---------------------------------------------------------------------------------------------
    task automatic case_routing();
        $display("--- case_routing ---");
        reset_all();
        bind_all();

        // Each lane gets a 200-byte body with its own ramp base.
        for (int L = 0; L < NUM_CONNS; L++) append_response(L, 200, byte'(8'h10 * (L+1)));
        start_all();

        // Interleave: announce a slice of each session round-robin, so no lane ever sees two of
        // its own packets in a row and the shared fifo is genuinely mixed.
        for (int round = 0; round < 4; round++) begin
            for (int L = 0; L < NUM_CONNS; L++) begin
                automatic int total = sess_bytes[L].size();
                automatic int chunk = (total + 3) / 4;
                automatic int base  = round * chunk;
                automatic int n     = (base + chunk > total) ? (total - base) : chunk;
                if (n > 0) announce(L, n);
            end
        end

        wait_lanes_done(1);

        for (int L = 0; L < NUM_CONNS; L++) begin
            expect_body($sformatf("routing/lane%0d", L), L, 200, byte'(8'h10 * (L+1)));
        end

        if (shared_stall_cycles == 0) ok("routing/no_toe_backpressure");
        else bad($sformatf("routing/no_toe_backpressure (%0d cycles refused)", shared_stall_cycles));

        if (!dbg_overflow) ok("routing/no_overflow");
        else bad("routing/no_overflow");
    endtask

    // ---------------------------------------------------------------------------------------------
    // 2. Head-of-line -- THE test. Lane 1's consumer is held off; the other three must finish.
    //
    // Under the old post-strip demux this is exactly what could not happen: one busy lane
    // back-pressured the shared body stream and every lane stopped with it.
    // ---------------------------------------------------------------------------------------------
    task automatic case_head_of_line();
        automatic int others_done;
        $display("--- case_head_of_line ---");
        reset_all();
        bind_all();

        for (int L = 0; L < NUM_CONNS; L++) append_response(L, 200, byte'(8'h20 * (L+1)));
        start_all();

        // Lane 1 refuses its body from the outset -- a decoder mid-Snappy-block, or one whose
        // output buffer has not been returned yet.
        consumer_stall[1] = 1'b1;

        for (int round = 0; round < 4; round++) begin
            for (int L = 0; L < NUM_CONNS; L++) begin
                automatic int total = sess_bytes[L].size();
                automatic int chunk = (total + 3) / 4;
                automatic int base  = round * chunk;
                automatic int n     = (base + chunk > total) ? (total - base) : chunk;
                if (n > 0) announce(L, n);
            end
        end

        // Give the healthy lanes ample time to complete WITHOUT releasing lane 1.
        repeat (40000) @(posedge clk);

        others_done = 0;
        for (int L = 0; L < NUM_CONNS; L++) if (L != 1 && tlasts[L] >= 1) others_done++;

        if (others_done == NUM_CONNS - 1)
            ok("head_of_line/healthy_lanes_complete (3 of 3 while lane 1 is stalled)");
        else
            bad($sformatf("head_of_line/healthy_lanes_complete (%0d of 3 -- a stalled lane is still blocking the others)",
                          others_done));

        for (int L = 0; L < NUM_CONNS; L++) begin
            if (L != 1) expect_body($sformatf("head_of_line/lane%0d", L), L, 200, byte'(8'h20 * (L+1)));
        end

        // Release lane 1: it must still be intact, not corrupted by having waited.
        consumer_stall[1] = 1'b0;
        wait_lanes_done(1);
        expect_body("head_of_line/lane1_after_release", 1, 200, byte'(8'h40));
    endtask

    // ---------------------------------------------------------------------------------------------
    // 3. The space gate -- a lane whose fifo cannot hold another whole segment must not be asked
    //    for one, and the queue must not be reordered around it.
    //
    // The fifo is RX_DEPTH * 64 = 32 KiB, so filling it needs real traffic: a large response
    // delivered as MSS-sized segments, exactly as the TOE would. An earlier version of this test
    // announced one 460-byte response and asserted nothing could be issued past it -- which was
    // wrong, because that lane's fifo was 1.4% full and the gate had no reason to close.
    // ---------------------------------------------------------------------------------------------
    task automatic case_space_gate();
        automatic int pkgs_before, quiet, seg;
        localparam int MSS      = 4000;
        localparam int BIG_BODY = 48000;   // > 32 KiB, so lane 0 fills while stalled

        $display("--- case_space_gate ---");
        reset_all();
        bind_all();

        append_response(0, BIG_BODY, 8'h30);
        append_response(1, 400,      8'h31);
        start_all();

        // Lane 0 refuses everything, so its fifo fills and stays full.
        consumer_stall[0] = 1'b1;

        seg = 0;
        while (seg < sess_bytes[0].size()) begin
            automatic int n = ((sess_bytes[0].size() - seg) > MSS) ? MSS : (sess_bytes[0].size() - seg);
            announce(0, n);
            seg += n;
        end

        // Let the dispatcher drain what it can, then wait until it has genuinely gone quiet --
        // that is the gate closing, not merely a slow cycle.
        quiet = 0;
        pkgs_before = readpkgs;
        while (quiet < 2000) begin
            @(posedge clk);
            if (readpkgs != pkgs_before) begin
                pkgs_before = readpkgs;
                quiet = 0;
            end else quiet++;
        end

        if (dbg_has_pending[0]) ok("space_gate/gate_closed (lane 0 still owes packets, none issued)");
        else bad("space_gate/gate_closed (lane 0's queue drained -- the fifo never filled, test is not exercising the gate)");

        // Now queue a packet for a HEALTHY lane, behind lane 0's blocked head. Arrival order is
        // the contract, so it must NOT be issued -- overtaking would hand lane 1's bytes to
        // whichever reader popped the shared fifo next.
        announce(1, sess_bytes[1].size());
        repeat (5000) @(posedge clk);

        if (readpkgs == pkgs_before)
            ok("space_gate/order_preserved (healthy lane does not overtake a blocked head)");
        else
            bad($sformatf("space_gate/order_preserved (%0d readPkgs issued past the blocked head)",
                          readpkgs - pkgs_before));

        if (!dbg_route_stall) ok("space_gate/no_route_stall (gate held, shared stream never refused)");
        else bad("space_gate/no_route_stall (a consumer refused a beat -- conn_space_ok is too loose)");

        // Release lane 0: everything must still arrive intact and in order, on both lanes.
        consumer_stall[0] = 1'b0;
        wait_lanes_done(1, 4'b0011);
        expect_body("space_gate/lane0_after_release", 0, BIG_BODY, 8'h30);
        expect_body("space_gate/lane1_after_release", 1, 400,      8'h31);
    endtask

    // ---------------------------------------------------------------------------------------------
    initial begin
        case_routing();
        case_head_of_line();
        case_space_gate();

        $display("========================================");
        $display("http_multilane_tb: %0d passed, %0d failed", pass_cnt, fail_cnt);
        $display("========================================");
        if (fail_cnt != 0) $fatal(1, "failures");
        $finish;
    end

    initial begin
        #40_000_000;
        $fatal(1, "global timeout");
    end

endmodule
