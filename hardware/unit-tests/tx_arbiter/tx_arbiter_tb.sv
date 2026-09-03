`timescale 1ns / 1ps

import lynxTypes::*;

// tx_arbiter: at most one grant, held for the whole transfer, rotating so nobody starves.
//
// Sections 1-3 drive `req` by hand, which assumes the claimants keep their side of the contract.
// Section 4 instantiates the REAL claimants -- http_req_stream through this arbiter, wired as
// handler_multi wires them -- because the one failure this pair has that neither half has alone is a
// claimant that asks for the bus and then cannot use it. See the header there.
module tx_arbiter_tb;

    localparam int N = 4;

    logic clk = 0, rst_n = 0;
    always #2 clk = ~clk;

    logic [N-1:0] req = '0, grant;
    logic [$clog2(N)-1:0] sel;
    logic busy;

    tx_arbiter #(.N(N)) dut (
        .clk(clk), .rst_n(rst_n), .req(req), .grant(grant), .sel(sel), .busy(busy)
    );

    int pass_cnt = 0, fail_cnt = 0;
    task automatic ok (input string n); $display("[PASS] %s", n); pass_cnt++; endtask
    task automatic bad(input string n); $display("[FAIL] %s", n); fail_cnt++; endtask

    // THE safety property: never two grants at once, checked every cycle of the whole run.
    int unsigned multi_grant_cycles = 0;
    always @(posedge clk) begin
        if (rst_n && $countones(grant) > 1) multi_grant_cycles <= multi_grant_cycles + 1;
    end

    // A grant must never move while its holder still wants the bus.
    int unsigned preempt_cycles = 0;
    logic [N-1:0] grant_q;
    always @(posedge clk) begin
        if (rst_n) begin
            grant_q <= grant;
            for (int i = 0; i < N; i++) begin
                if (grant_q[i] && req[i] && !grant[i]) preempt_cycles <= preempt_cycles + 1;
            end
        end
    end

    task automatic reset_all();
        req = '0; rst_n = 0;
        multi_grant_cycles = 0; preempt_cycles = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);
    endtask

    // One lane's whole transfer: ask, wait for the grant, hold it, release.
    task automatic transfer(input int lane, input int cycles);
        req[lane] <= 1'b1;
        @(posedge clk);
        while (!grant[lane]) @(posedge clk);
        repeat (cycles) @(posedge clk);
        req[lane] <= 1'b0;
        @(posedge clk);
    endtask

    int order [$];
    always @(posedge clk) begin
        if (rst_n && busy && $countones(grant) == 1) begin
            if (order.size() == 0 || order[order.size()-1] != int'(sel)) order.push_back(int'(sel));
        end
    end

    // =============================================================================================
    // SECTION 4 SCAFFOLDING -- the real claimants.
    //
    // THE WEDGE. http_req_stream held `bus_req = (remaining_q != 0)`, with no reference to conn_up.
    // A lane whose connection goes away between the ARM and the GRANT therefore goes on asking for a
    // bus it can no longer leave ST_IDLE to use -- leaving ST_IDLE needs conn_up, which is precisely
    // what it has lost. The arbiter, doing exactly what it is told, hands the dead lane the bus and
    // waits for it to finish. It never does. ONE dead lane stops the transmit path for ALL of them.
    //
    // Neither half can see this alone: sections 1-3 drive `req` by hand and so cannot express a
    // claimant that lies, and http_req_stream's own bench has one lane and a tied-high grant. It also
    // needs a lane to be armed and NOT yet granted, which on hardware means multi-chunk request text
    // holding the bus while a neighbour dies -- rare, and never yet produced by a bench. So this
    // section builds the pair: three http_req_stream lanes, one arbiter, one TOE, wired as
    // handler_multi wires them.
    // =============================================================================================
    localparam int M        = 3;                    // lanes in section 4
    localparam int MSEL     = (M > 1) ? $clog2(M) : 1;
    localparam int TXLANES  = AXI_DATA_BITS / 8;
    localparam int SID_BASE = 16;                   // session id of lane L is SID_BASE + L

    logic rst2_n = 0;

    logic [M-1:0]                s_conn_up = '0;
    logic [31:0]                 s_total   [M];
    logic [M-1:0]                s_start   = '0;

    logic [M-1:0]                s_rq_valid = '0, s_rq_ready, s_rq_last = '0;
    logic [AXI_DATA_BITS-1:0]    s_rq_data  [M];
    logic [TXLANES-1:0]          s_rq_keep  [M];

    logic [M-1:0]                s_meta_valid, s_data_valid, s_data_last, s_stat_ready;
    logic [TCP_TX_META_BITS-1:0] s_meta_data [M];
    logic [AXI_DATA_BITS-1:0]    s_data_data [M];
    logic [TXLANES-1:0]          s_data_keep [M];

    logic [M-1:0]                s_req, s_grant, s_busy;
    logic [MSEL-1:0]             sel2;
    logic                        busy2;

    // The shared TOE transmit interface, exactly one of them for all M lanes.
    logic                        txm2_valid, txm2_ready;
    logic [TCP_TX_META_BITS-1:0] txm2_data;
    logic                        txd2_valid, txd2_ready, txd2_last;
    logic [AXI_DATA_BITS-1:0]    txd2_data;
    logic [TXLANES-1:0]          txd2_keep;
    logic                        txs2_valid, txs2_ready;
    logic [TCP_TX_STAT_BITS-1:0] txs2_data;

    tx_arbiter #(.N(M)) dut2 (
        .clk(clk), .rst_n(rst2_n), .req(s_req), .grant(s_grant), .sel(sel2), .busy(busy2)
    );

    // Only the holder reaches the wire -- handler_multi.sv, verbatim.
    assign txm2_valid  = busy2 && s_meta_valid[sel2];
    assign txm2_data   = s_meta_data[sel2];
    assign txd2_valid  = busy2 && s_data_valid[sel2];
    assign txd2_data   = s_data_data[sel2];
    assign txd2_keep   = s_data_keep[sel2];
    assign txd2_last   = s_data_last[sel2];
    assign txs2_ready  = busy2 && s_stat_ready[sel2];

    for (genvar L = 0; L < M; L++) begin : gen_stream
        http_req_stream #(.CHUNK_BYTES(4096)) inst (
            .clk(clk), .rst_n(rst2_n),
            .conn_up(s_conn_up[L]), .session_id(16'(SID_BASE + L)),
            .req_total_bytes(s_total[L]), .req_start(s_start[L]),
            .s_axis_req_TVALID(s_rq_valid[L]), .s_axis_req_TREADY(s_rq_ready[L]),
            .s_axis_req_TDATA (s_rq_data[L]),  .s_axis_req_TKEEP (s_rq_keep[L]),
            .s_axis_req_TLAST (s_rq_last[L]),
            .m_axis_tx_meta_TVALID(s_meta_valid[L]),
            .m_axis_tx_meta_TREADY(txm2_ready && busy2 && (sel2 == MSEL'(L))),
            .m_axis_tx_meta_TDATA (s_meta_data[L]),
            .m_axis_tx_data_TVALID(s_data_valid[L]),
            .m_axis_tx_data_TREADY(txd2_ready && busy2 && (sel2 == MSEL'(L))),
            .m_axis_tx_data_TDATA (s_data_data[L]),
            .m_axis_tx_data_TKEEP (s_data_keep[L]),
            .m_axis_tx_data_TLAST (s_data_last[L]),
            .s_axis_tx_status_TVALID(txs2_valid && busy2 && (sel2 == MSEL'(L))),
            .s_axis_tx_status_TREADY(s_stat_ready[L]),
            .s_axis_tx_status_TDATA (txs2_data),
            .bus_req(s_req[L]), .bus_grant(s_grant[L]),
            .busy(s_busy[L]), .refused_sticky(), .tx_space(), .state_debug()
        );
    end

    // TOE model: grant every reservation, then take exactly the announced number of bytes. Counting
    // per session is what makes "lane 0 sent nothing" and "lane 1 sent all of it" separate facts.
    int sent_bytes [int];
    int metas_for  [int];

    // Who owns the currently open reservation. Latched by the model below, checked by the monitor
    // after it; declared here because the model writes it.
    logic [MSEL-1:0] sel_at_meta;
    bit              reservation_open = 0;

    initial begin
        txm2_ready = 1'b0;
        txd2_ready = 1'b0;
        txs2_valid = 1'b0;
        txs2_data  = '0;
        @(posedge rst2_n);
        forever begin
            automatic int sid, len, got, b;
            @(posedge clk);
            txm2_ready <= 1'b1;
            @(posedge clk);
            while (!(txm2_valid && txm2_ready)) @(posedge clk);
            sid = int'(txm2_data[TCP_SESSION_BITS-1:0]);
            len = int'(txm2_data[TCP_SESSION_BITS +: 16]);
            txm2_ready <= 1'b0;
            if (!metas_for.exists(sid)) metas_for[sid] = 0;
            metas_for[sid]++;
            // The reservation is now open. Whoever holds the bus at this moment owns every byte
            // until it is filled; the monitor above fails any beat that arrives from someone else.
            sel_at_meta      = sel2;
            reservation_open = 1'b1;

            repeat (2) @(posedge clk);
            txs2_data  <= {2'd0, 30'd65536, 16'(len), TCP_SESSION_BITS'(sid)};
            txs2_valid <= 1'b1;
            @(posedge clk);
            while (!txs2_ready) @(posedge clk);
            txs2_valid <= 1'b0;

            got = 0;
            txd2_ready <= 1'b1;
            while (got < len) begin
                @(posedge clk);
                if (txd2_valid && txd2_ready) begin
                    for (b = 0; b < TXLANES; b++) begin
                        if (txd2_keep[b] && got < len) begin
                            if (!sent_bytes.exists(sid)) sent_bytes[sid] = 0;
                            sent_bytes[sid]++;
                            got++;
                        end
                    end
                end
            end
            txd2_ready       <= 1'b0;
            reservation_open  = 1'b0;
        end
    end

    // Exclusivity again, on the real claimants this time.
    int unsigned multi_grant2 = 0;
    always @(posedge clk) if (rst2_n && $countones(s_grant) > 1) multi_grant2 <= multi_grant2 + 1;

    // The grant must not move between a reservation and the bytes that belong to it. That is the
    // corruption the arbiter exists to prevent, and it is what the `state_q != ST_IDLE` half of the
    // bus_req fix protects: a fix that only looked at conn_up would hand the bus away mid-transfer
    // the moment a lane's connection went down, splicing the next lane's text into this one's
    // reservation -- on the wire, a 400 and every request behind it misframed.
    //
    // Checked from the outside: the TOE model latches `sel` when it accepts a tx_meta and the
    // monitor below fails any data beat that arrives with `sel` somewhere else.
    int unsigned     midtransfer_drop = 0;
    // Sampled on the falling edge: the TOE model above opens the reservation on a rising edge, and
    // reading it half a cycle later is what keeps this a check rather than a race.
    always @(negedge clk) begin
        if (rst2_n && reservation_open && txd2_valid && txd2_ready && (sel2 !== sel_at_meta))
            midtransfer_drop <= midtransfer_drop + 1;
    end

    task automatic reset2();
        s_conn_up  = '0;
        s_start    = '0;
        s_rq_valid = '0;
        s_rq_last  = '0;
        for (int L = 0; L < M; L++) begin
            s_total[L]   = 32'd0;
            s_rq_data[L] = '0;
            s_rq_keep[L] = '0;
        end
        sent_bytes.delete();
        metas_for.delete();
        multi_grant2     = 0;
        midtransfer_drop = 0;
        reservation_open = 1'b0;
        rst2_n = 0;
        repeat (6) @(posedge clk);
        rst2_n = 1;
        repeat (4) @(posedge clk);
    endtask

    // Arm a lane: the byte count and the pulse, exactly as handler_multi drives them from a cfg beat.
    task automatic arm2(input int L, input int nbytes);
        s_total[L] <= 32'(nbytes);
        s_start[L] <= 1'b1;
        @(posedge clk);
        s_start[L] <= 1'b0;
        @(posedge clk);
    endtask

    // The host DMA for one lane, whole beats with TLAST on the last, as Coyote moves it.
    task automatic dma2(input int L, input int nbytes);
        automatic int nbeats = (nbytes + TXLANES - 1) / TXLANES;
        for (int i = 0; i < nbeats; i++) begin
            automatic logic [AXI_DATA_BITS-1:0] beat = '0;
            automatic logic [TXLANES-1:0]       keep = '0;
            for (int b = 0; b < TXLANES; b++) begin
                automatic int idx = i*TXLANES + b;
                if (idx < nbytes) begin
                    beat[b*8 +: 8] = 8'((idx + L) & 32'hFF);
                    keep[b]        = 1'b1;
                end
            end
            s_rq_data[L]  <= beat;
            s_rq_keep[L]  <= keep;
            s_rq_last[L]  <= (i == nbeats-1);
            s_rq_valid[L] <= 1'b1;
            @(posedge clk);
            while (!s_rq_ready[L]) @(posedge clk);
            s_rq_valid[L] <= 1'b0;
            s_rq_last[L]  <= 1'b0;
        end
    endtask

    function automatic int bytes_for(input int sid);
        return sent_bytes.exists(sid) ? sent_bytes[sid] : 0;
    endfunction

    initial begin
        automatic int seen [N];
        automatic bit good;

        // ---- 1. exclusivity under full contention -------------------------------------------
        $display("--- contention ---");
        reset_all();
        order.delete();
        fork
            transfer(0, 20);
            transfer(1, 20);
            transfer(2, 20);
            transfer(3, 20);
        join

        if (multi_grant_cycles == 0) ok("exclusive (never two grants at once)");
        else bad($sformatf("exclusive (%0d cycles with >1 grant)", multi_grant_cycles));

        if (preempt_cycles == 0) ok("no_preempt (a holder keeps the bus until it releases)");
        else bad($sformatf("no_preempt (%0d cycles of a grant moving off a live requester)",
                           preempt_cycles));

        // Every lane must have had it exactly once -- that is fairness, not just liveness.
        for (int i = 0; i < N; i++) seen[i] = 0;
        foreach (order[i]) seen[order[i]]++;
        good = 1;
        for (int i = 0; i < N; i++) if (seen[i] != 1) good = 0;
        if (good) ok("fair (all 4 lanes served, once each)");
        else bad($sformatf("fair (grants per lane: %0d %0d %0d %0d)",
                           seen[0], seen[1], seen[2], seen[3]));

        // ---- 2. a busy neighbour cannot starve a lane ---------------------------------------
        //
        // Lane 0 asks continuously; lane 2 asks once, late. Rotating priority means lane 2 is
        // examined before lane 0 gets a second turn. With fixed priority lane 2 would wait forever.
        $display("--- starvation ---");
        reset_all();
        order.delete();
        fork
            begin
                for (int k = 0; k < 6; k++) transfer(0, 10);
            end
            begin
                repeat (40) @(posedge clk);
                transfer(2, 10);
            end
        join

        good = 0;
        foreach (order[i]) if (order[i] == 2) good = 1;
        if (good) ok("no_starvation (lane 2 served despite a continuously armed lane 0)");
        else bad("no_starvation (lane 2 never got the bus)");

        if (multi_grant_cycles == 0) ok("exclusive_under_starvation");
        else bad("exclusive_under_starvation");

        // ---- 3. idle -------------------------------------------------------------------------
        $display("--- idle ---");
        reset_all();
        repeat (20) @(posedge clk);
        if (!busy && grant == '0) ok("idle (no grant with no request)");
        else bad("idle (granted with nothing asking)");

        // ---- 4. a lane that dies while armed must let go of the bus -------------------------
        //
        // Lane 1 holds the grant with a reservation open and no data yet. Lane 0 arms behind it and
        // then loses its connection -- the shape handler_multi produces when a lane goes fatal with
        // request text armed but not yet granted. Lane 0 can never leave ST_IDLE again, so if it
        // keeps asking, the arbiter will hand it the bus the moment lane 1 releases and hold there
        // forever. Lanes 1 and 2 completing afterwards is the whole property.
        $display("--- dead_lane_releases_bus ---");
        begin
            automatic int t = 0;
            automatic int nbytes = 600;   // one chunk, well under CHUNK_BYTES

            reset2();
            s_conn_up = 3'b111;

            // Lane 1 takes the bus and stops there: armed, announced, waiting for host bytes that
            // have not been DMA'd yet.
            arm2(1, nbytes);
            t = 0;
            while (!(metas_for.exists(SID_BASE+1) && metas_for[SID_BASE+1] == 1) && t < 5000) begin
                @(posedge clk); t++;
            end
            if (!s_grant[1]) bad("wedge/setup (lane 1 never got the bus)");

            // Lane 0 arms behind it -- asking, not holding.
            arm2(0, nbytes);
            repeat (10) @(posedge clk);
            if (s_grant[0]) bad("wedge/setup (lane 0 was granted while lane 1 held the bus)");
            if (!s_req[0])  bad("wedge/setup (a healthy armed lane is not asking for the bus)");

            // ...and then its connection goes away, as a fatal lane's does.
            s_conn_up[0] = 1'b0;
            repeat (4) @(posedge clk);
            if (!s_req[0])
                ok("wedge/dead_lane_stops_asking (bus_req drops with conn_up while parked in ST_IDLE)");
            else
                bad("wedge/dead_lane_stops_asking (a lane that cannot transmit is still claiming the bus)");

            // Release lane 1, then ask two other lanes to transmit. With the old bus_req the bus
            // goes to lane 0 here and never comes back.
            dma2(1, nbytes);
            arm2(2, nbytes);
            fork
                dma2(2, nbytes);
                begin
                    repeat (200) @(posedge clk);
                    arm2(1, nbytes);
                    dma2(1, nbytes);
                end
            join

            t = 0;
            while ((bytes_for(SID_BASE+1) < 2*nbytes || bytes_for(SID_BASE+2) < nbytes)
                   && t < 20000) begin
                @(posedge clk); t++;
            end

            if (bytes_for(SID_BASE+1) == 2*nbytes && bytes_for(SID_BASE+2) == nbytes)
                ok($sformatf("wedge/survivors_served (lane 1 sent %0d, lane 2 sent %0d bytes after the kill)",
                             bytes_for(SID_BASE+1), bytes_for(SID_BASE+2)));
            else
                bad($sformatf("wedge/survivors_served (lane 1 sent %0d of %0d, lane 2 sent %0d of %0d -- the dead lane is holding the bus)",
                              bytes_for(SID_BASE+1), 2*nbytes, bytes_for(SID_BASE+2), nbytes));

            // And the dead lane put nothing on the wire, which is the other half: dropping bus_req
            // must not be a way to transmit without a reservation.
            if (bytes_for(SID_BASE+0) == 0 && !metas_for.exists(SID_BASE+0))
                ok("wedge/dead_lane_silent (no reservation, no bytes)");
            else
                bad($sformatf("wedge/dead_lane_silent (%0d metas, %0d bytes from the dead lane)",
                              metas_for.exists(SID_BASE+0) ? metas_for[SID_BASE+0] : 0,
                              bytes_for(SID_BASE+0)));
        end

        // ---- 5. a grant already in flight completes -----------------------------------------
        //
        // The other half of the fix, and the reason it is `conn_up || state_q != ST_IDLE` rather
        // than `conn_up` alone. A reservation is already open and the bytes that fill it are on
        // their way; taking the bus away now would splice the next lane's request text into this
        // lane's reservation, which is the exact corruption the arbiter exists to prevent. Losing
        // the connection does not change that -- the reservation is the TOE's, not the lane's.
        $display("--- inflight_grant_completes ---");
        begin
            automatic int t = 0;
            automatic int nbytes = 600;

            reset2();
            s_conn_up = 3'b111;

            arm2(1, nbytes);
            fork
                dma2(1, nbytes);
                begin
                    // Kill it once the bytes are genuinely flowing, i.e. after the reservation was
                    // granted and part of it filled.
                    t = 0;
                    while (bytes_for(SID_BASE+1) < 64 && t < 5000) begin @(posedge clk); t++; end
                    s_conn_up[1] = 1'b0;
                end
            join

            t = 0;
            while (bytes_for(SID_BASE+1) < nbytes && t < 20000) begin @(posedge clk); t++; end

            if (bytes_for(SID_BASE+1) == nbytes)
                ok($sformatf("inflight/transfer_completes (all %0d bytes reached the wire after conn_up dropped mid-transfer)",
                             nbytes));
            else
                bad($sformatf("inflight/transfer_completes (%0d of %0d bytes -- the grant was dropped inside a reservation)",
                              bytes_for(SID_BASE+1), nbytes));

            if (midtransfer_drop == 0 && multi_grant2 == 0)
                ok("inflight/reservation_intact (no beat arrived from a lane other than the one holding the reservation)");
            else
                bad($sformatf("inflight/reservation_intact (%0d misattributed beats, %0d cycles with >1 grant)",
                              midtransfer_drop, multi_grant2));
        end

        $display("========================================");
        $display("tx_arbiter_tb: %0d passed, %0d failed", pass_cnt, fail_cnt);
        $display("========================================");
        if (fail_cnt != 0) $fatal(1, "failures");
        $finish;
    end

    // Sections 4 and 5 run real transfers through real claimants, so the bench is no longer a few
    // hundred cycles of hand-driven req/grant. The bound is still far below any real hang.
    initial begin
        #2_000_000;
        $fatal(1, "global timeout");
    end

endmodule
