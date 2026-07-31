`timescale 1ns/1ps

// Standalone check of http_restart_seq: START -> soft_reset window -> single run pulse.
// Also models a handler-style consumer (sits in IDLE, watches run while out of local reset) to
// prove the run pulse is actually caught after the flush window.
module http_restart_seq_tb;

    localparam int RST_CYCLES = 8;

    logic clk = 0;
    logic rst_n = 0;
    logic start = 0;
    logic soft_reset;
    logic run;

    always #5 clk = ~clk;

    http_restart_seq #(.RST_CYCLES(RST_CYCLES)) dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .soft_reset(soft_reset), .run(run)
    );

    // Local reset the datapath would see.
    wire local_rst_n = rst_n && !soft_reset;

    int errors = 0;

    // ---- Model a handler: IDLE until it sees `run` while out of local reset ----
    typedef enum logic [1:0] {H_IDLE, H_BUSY} hstate_t;
    hstate_t hstate = H_IDLE;
    int      started_count = 0;

    always_ff @(posedge clk) begin
        if (!local_rst_n) begin
            hstate <= H_IDLE;              // local reset forces handler to IDLE (flush)
        end else begin
            case (hstate)
                H_IDLE: if (run) begin
                    hstate <= H_BUSY;
                    started_count <= started_count + 1;
                end
                H_BUSY: ; // stays busy until test drives it back (simulate a transfer)
                default: hstate <= H_IDLE;
            endcase
        end
    end

    // ---- Measurement of one START event ----
    task automatic do_start_and_check(input int expect_started);
        int rst_low_cycles;
        int run_pulses;
        rst_low_cycles = 0;
        run_pulses = 0;

        @(negedge clk);
        start = 1;
        @(negedge clk);
        start = 0;

        // Observe for a generous window
        for (int i = 0; i < RST_CYCLES + 20; i++) begin
            @(negedge clk);
            if (!soft_reset && run) begin
                // fine: run only asserts when out of soft_reset
            end
            if (soft_reset) rst_low_cycles++;
            if (run) begin
                run_pulses++;
                if (soft_reset) begin
                    $display("FAIL: run asserted while soft_reset still high");
                    errors++;
                end
            end
        end

        if (run_pulses != 1) begin
            $display("FAIL: expected exactly 1 run pulse, got %0d", run_pulses);
            errors++;
        end
        if (rst_low_cycles < RST_CYCLES) begin
            $display("FAIL: soft_reset held only %0d cycles, expected >= %0d", rst_low_cycles, RST_CYCLES);
            errors++;
        end
        if (hstate != H_BUSY) begin
            $display("FAIL: handler did not reach BUSY after run");
            errors++;
        end
        if (started_count != expect_started) begin
            $display("FAIL: started_count=%0d expected %0d", started_count, expect_started);
            errors++;
        end
        $display("  start event ok: soft_reset held %0d cyc, run pulses=%0d, started_count=%0d",
                 rst_low_cycles, run_pulses, started_count);
    endtask

    // ---- Force the modeled handler back to IDLE to emulate a fresh (or wedged->flushed) start ----
    task automatic force_handler_idle();
        // In real HW the flush window (soft_reset) drives local_rst_n low which forces H_IDLE.
        // Here we just rely on the next START's soft_reset to do that; nothing to do.
    endtask

    initial begin
        // Reset
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        // Case 1: first (clean) start
        do_start_and_check(1);

        // Case 2: a second start AFTER the handler is "wedged" in BUSY (never returned to IDLE).
        // The flush window must force the handler back to IDLE and let it restart -> started_count 2.
        // (hstate is H_BUSY here; soft_reset -> local_rst_n low -> H_IDLE, then run -> BUSY again.)
        do_start_and_check(2);

        // Case 3: another start
        do_start_and_check(3);

        if (errors == 0) $display("ALL TESTS PASSED (3/3)");
        else             $display("TESTS FAILED: %0d errors", errors);
        $finish;
    end

endmodule
