`timescale 1ns / 1ps

// tx_arbiter: at most one grant, held for the whole transfer, rotating so nobody starves.
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

        $display("========================================");
        $display("tx_arbiter_tb: %0d passed, %0d failed", pass_cnt, fail_cnt);
        $display("========================================");
        if (fail_cnt != 0) $fatal(1, "failures");
        $finish;
    end

    initial begin
        #200_000;
        $fatal(1, "global timeout");
    end

endmodule
