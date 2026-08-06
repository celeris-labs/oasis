`timescale 1ns / 1ps

import lynxTypes::*;

// Unit test for rx_dispatch: the arrival-order receive dispatcher.
//
// The properties that matter are the ones whose violation cost builds 90/91/92:
//
//   1. readPkg is issued in GLOBAL ARRIVAL ORDER, interleaved across connections. The TOE pops the
//      head of one shared fifo regardless of which session asked, so any reordering hands one
//      session's bytes to another session's reader.
//   2. Beats are routed to the connection named by rx_metadata, and to no other.
//   3. s_axis_rx_data_TREADY is NEVER low during an active packet. Back-pressure belongs at the
//      decision to issue a readPkg, not on the data stream -- stalling the stream stalls every
//      other session at the same time.
//   4. A readPkg is not issued for a connection whose fifo has no room.
//   5. `closed` is sticky per connection and survives a zero-length notification.
module rx_dispatch_tb;

    localparam int NUM_CONNS = 4;
    localparam int LANES     = AXI_DATA_BITS/8;

    logic clk = 0, rst_n = 0;
    always #2 clk = ~clk;

    logic                       note_valid, note_ready;
    logic [TCP_NOTIFY_BITS-1:0] note_data;

    logic                        bind_en, release_en;
    logic [1:0]                  bind_conn, release_conn;
    logic [TCP_SESSION_BITS-1:0] bind_sid;

    logic                           rdpkg_valid, rdpkg_ready;
    logic [TCP_RD_PKG_REQ_BITS-1:0] rdpkg_data;

    logic                        meta_valid, meta_ready;
    logic [TCP_RX_META_BITS-1:0] meta_data;

    logic                     rxd_valid, rxd_ready, rxd_last;
    logic [AXI_DATA_BITS-1:0] rxd_data;
    logic [LANES-1:0]         rxd_keep;

    logic [NUM_CONNS-1:0]     conn_tvalid, conn_tready, conn_closed, dbg_has_pending;
    logic [AXI_DATA_BITS-1:0] conn_tdata;
    logic [LANES-1:0]         conn_tkeep;
    logic                     conn_tlast;
    logic [NUM_CONNS-1:0]     conn_space_ok;
    logic                     dbg_overflow, dbg_route_stall;

    int unsigned passes = 0, fails = 0;

    rx_dispatch #(.NUM_CONNS(NUM_CONNS), .NOTIFY_DEPTH(16)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_notifications_TVALID(note_valid),
        .s_axis_notifications_TREADY(note_ready),
        .s_axis_notifications_TDATA (note_data),
        .bind_en(bind_en), .bind_conn(bind_conn), .bind_sid(bind_sid),
        .release_en(release_en), .release_conn(release_conn),
        .m_axis_read_package_TVALID(rdpkg_valid),
        .m_axis_read_package_TREADY(rdpkg_ready),
        .m_axis_read_package_TDATA (rdpkg_data),
        .s_axis_rx_metadata_TVALID(meta_valid),
        .s_axis_rx_metadata_TREADY(meta_ready),
        .s_axis_rx_metadata_TDATA (meta_data),
        .s_axis_rx_data_TVALID(rxd_valid), .s_axis_rx_data_TREADY(rxd_ready),
        .s_axis_rx_data_TDATA(rxd_data), .s_axis_rx_data_TKEEP(rxd_keep),
        .s_axis_rx_data_TLAST(rxd_last),
        .conn_tvalid(conn_tvalid), .conn_tready(conn_tready),
        .conn_tdata(conn_tdata), .conn_tkeep(conn_tkeep), .conn_tlast(conn_tlast),
        .conn_space_ok(conn_space_ok),
        .conn_closed(conn_closed),
        .dbg_has_pending(dbg_has_pending),
        .dbg_overflow(dbg_overflow),
        .dbg_route_stall(dbg_route_stall)
    );

    // ---------------------------------------------------------------------------------------------
    // Monitors
    // ---------------------------------------------------------------------------------------------
    int          issued_sid[$];     // sessions, in the order readPkg went out
    int          issued_len[$];
    int unsigned data_stall_cycles = 0;
    int          routed_to[$];      // connection each delivered beat landed on

    always @(posedge clk) if (rst_n) begin
        if (rdpkg_valid && rdpkg_ready) begin
            issued_sid.push_back(int'(rdpkg_data[TCP_SESSION_BITS-1:0]));
            issued_len.push_back(int'(rdpkg_data[TCP_SESSION_BITS +: TCP_LEN_BITS]));
        end
        // Property 3. During an active packet the dispatcher must accept every beat offered.
        if (rxd_valid && !rxd_ready && dut.pkt_active_q) data_stall_cycles++;
        if (rxd_valid && rxd_ready) begin
            for (int c = 0; c < NUM_CONNS; c++) if (conn_tvalid[c]) routed_to.push_back(c);
        end
    end

    task automatic ok(input string name);
        $display("[PASS] %s", name); passes++;
    endtask
    task automatic bad(input string name);
        $error("[FAIL] %s", name); fails++;
    endtask

    // ---------------------------------------------------------------------------------------------
    // Drivers. Everything is sampled at negedge and held past the posedge: setting a value in the
    // same delta as the edge the DUT samples on makes it see the NEXT value, which silently broke
    // every framing test in strip_http_tb once already.
    // ---------------------------------------------------------------------------------------------
    task automatic notify(input int sid, input int len, input bit closed);
        @(negedge clk);
        note_data                                        = '0;
        note_data[TCP_SESSION_BITS-1:0]                  = sid[TCP_SESSION_BITS-1:0];
        note_data[TCP_SESSION_BITS +: TCP_LEN_BITS]      = len[TCP_LEN_BITS-1:0];
        note_data[TCP_SESSION_BITS+TCP_LEN_BITS+32+16]   = closed;
        note_valid = 1'b1;
        @(posedge clk); #1;
        note_valid = 1'b0;
    endtask

    task automatic bind_conn_sid(input int c, input int sid);
        @(negedge clk);
        bind_en = 1'b1; bind_conn = c[1:0]; bind_sid = sid[TCP_SESSION_BITS-1:0];
        @(posedge clk); #1;
        bind_en = 1'b0;
    endtask

    // Delivers one packet of `beats` beats for session `sid`, exactly as the TOE would: one meta
    // beat, then data to tlast. Holds tvalid high while waiting, so a stalling DUT is visible.
    // Wait until, AT A NEGEDGE, valid && ready both hold -- that is the handshake the next posedge
    // will actually perform. Checking ready after the posedge instead sees it already deasserted,
    // which is a spin-forever, and is exactly how this task hung the first time.
    task automatic deliver(input int sid, input int beats);
        @(negedge clk);
        meta_data = '0;
        meta_data[TCP_SESSION_BITS-1:0] = sid[TCP_SESSION_BITS-1:0];
        meta_valid = 1'b1;
        while (!meta_ready) @(negedge clk);
        @(posedge clk); #1;
        meta_valid = 1'b0;

        for (int b = 0; b < beats; b++) begin
            @(negedge clk);
            rxd_data  = {8{64'h1111_1111_0000_0000}} + sid;
            rxd_keep  = '1;
            rxd_last  = (b == beats-1);
            rxd_valid = 1'b1;
            while (!rxd_ready) @(negedge clk);
            @(posedge clk); #1;
        end
        @(negedge clk);
        rxd_valid = 1'b0; rxd_last = 1'b0;
    endtask

    // ---------------------------------------------------------------------------------------------
    initial begin
        note_valid = 0; note_data = '0;
        bind_en = 0; release_en = 0; bind_conn = 0; release_conn = 0; bind_sid = '0;
        rdpkg_ready = 1'b1;
        meta_valid = 0; meta_data = '0;
        rxd_valid = 0; rxd_data = '0; rxd_keep = '0; rxd_last = 0;
        conn_tready   = '1;
        conn_space_ok = '1;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // Four connections, sessions 100..103.
        for (int c = 0; c < NUM_CONNS; c++) bind_conn_sid(c, 100 + c);

        // ---- 1. arrival order, interleaved across connections -----------------------------------
        // Announce in a deliberately non-request order. The dispatcher must reproduce it exactly.
        notify(102, 4096, 0);
        notify(100, 1024, 0);
        notify(103, 2048, 0);
        notify(100, 512,  0);
        notify(101, 4096, 0);
        repeat (20) @(posedge clk);

        if (issued_sid.size() != 5) begin
            bad($sformatf("arrival_order: %0d readPkgs, expected 5", issued_sid.size()));
        end else if (issued_sid[0] != 102 || issued_sid[1] != 100 || issued_sid[2] != 103
                     || issued_sid[3] != 100 || issued_sid[4] != 101) begin
            bad($sformatf("arrival_order: got %0d,%0d,%0d,%0d,%0d expected 102,100,103,100,101",
                          issued_sid[0], issued_sid[1], issued_sid[2], issued_sid[3], issued_sid[4]));
        end else begin
            ok("arrival_order (5 readPkgs interleaved across 4 connections, order preserved)");
        end

        // The length must be passed through untouched -- coalescing announcements runs the receive
        // window ahead of what was really consumed. See the header of tcp_session_table.sv.
        if (issued_len[0] != 4096 || issued_len[3] != 512)
            bad("length_passthrough");
        else
            ok("length_passthrough (no coalescing)");

        // ---- 2. routing --------------------------------------------------------------------------
        routed_to.delete();
        deliver(102, 3);
        deliver(100, 2);
        repeat (10) @(posedge clk);
        if (routed_to.size() != 5) begin
            bad($sformatf("routing: %0d beats delivered, expected 5", routed_to.size()));
        end else if (routed_to[0] != 2 || routed_to[1] != 2 || routed_to[2] != 2
                     || routed_to[3] != 0 || routed_to[4] != 0) begin
            bad("routing: beats landed on the wrong connection");
        end else begin
            ok("routing (session 102 -> conn 2, session 100 -> conn 0)");
        end

        // ---- 3. the data stream is never stalled -------------------------------------------------
        // Refuse every consumer, then deliver a packet. The dispatcher must STILL take every beat:
        // stalling here would stall the shared fifo for all four sessions at once.
        conn_tready = '0;
        deliver(101, 4);
        repeat (10) @(posedge clk);
        conn_tready = '1;
        if (data_stall_cycles != 0)
            bad($sformatf("no_data_stall: TREADY dropped for %0d cycles mid-packet", data_stall_cycles));
        else
            ok("no_data_stall (every beat accepted even with all consumers refusing)");
        if (!dbg_route_stall)
            bad("route_stall_flag: consumers refused beats but the sticky flag did not set");
        else
            ok("route_stall_flag (refusal is reported, not hidden)");

        // ---- 4. issue is gated on destination space ---------------------------------------------
        issued_sid.delete();
        conn_space_ok = '1;
        conn_space_ok[1] = 1'b0;          // connection 1 is full
        notify(101, 4096, 0);             // for the full connection
        notify(103, 4096, 0);             // for a connection with room
        repeat (20) @(posedge clk);
        // Arrival order is absolute: 101 is at the head and cannot be overtaken, so NOTHING may be
        // issued while it is blocked. Serving 103 first would be a reordering.
        if (issued_sid.size() != 0)
            bad($sformatf("space_gate: %0d readPkg issued while the head's fifo was full", issued_sid.size()));
        else
            ok("space_gate (head blocked -> nothing issued, order not broken)");

        conn_space_ok = '1;
        repeat (20) @(posedge clk);
        if (issued_sid.size() != 2 || issued_sid[0] != 101 || issued_sid[1] != 103)
            bad("space_gate_release: queue did not drain in order once space returned");
        else
            ok("space_gate_release (drains in order once space returns)");

        // ---- 5. sticky FIN -----------------------------------------------------------------------
        notify(103, 0, 1);
        repeat (10) @(posedge clk);
        if (!conn_closed[3]) bad("sticky_fin: zero-length closed notification not recorded");
        else                 ok("sticky_fin (conn 3 closed)");
        if (conn_closed[0] || conn_closed[1] || conn_closed[2])
            bad("sticky_fin: FIN leaked to other connections");
        else
            ok("sticky_fin_isolated (other connections unaffected)");

        if (dbg_overflow) bad("overflow latched unexpectedly");
        else              ok("no_overflow");

        $display("========================================");
        $display("rx_dispatch_tb: %0d passed, %0d failed", passes, fails);
        $display("========================================");
        if (fails != 0) $fatal(1, "test failed");
        $finish;
    end

    initial begin
        #2_000_000;
        $fatal(1, "timeout");
    end

endmodule
