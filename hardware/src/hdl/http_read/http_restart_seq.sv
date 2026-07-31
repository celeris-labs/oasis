// Per-request flush-then-run sequencer for the HTTP read datapath.
//
// The host fires a ranged GET by writing the START CSR, which produces a single-cycle `start`
// pulse. On its own, START just kicks the handler -- but if the *previous* read ended badly (host
// aborted mid-body, or the handler wedged in ST_RECV_DATA because the host stopped draining), the
// handler FSM and the downstream normalize/convert pipeline still hold stale state, and the next
// read inherits it (the "stuck state 9 / no re-arm / body doubled from leftover beats" symptoms).
//
// This sequencer turns every START into: assert `soft_reset` for RST_CYCLES clocks (during which
// the caller holds the whole HTTP datapath -- handler + AXIToNData + DataNormalizer + NDataToAXI --
// in reset, flushing any stale state), then emit a single-cycle `run` pulse once the datapath is
// back out of reset so the handler starts a fresh transaction from a clean slate. The TOE is NOT
// reset by this (it stays on the global reset); the handler simply opens a new session afterwards.
//
// `run` is emitted the cycle after `soft_reset` deasserts, so the handler (already released from
// reset and sitting in ST_IDLE) samples it on the following edge -- exactly like the old 1-cycle
// runTx pulse, just gated behind the flush window.
module http_restart_seq #(
    parameter int RST_CYCLES = 8
) (
    input  logic clk,
    input  logic rst_n,
    input  logic start,      // 1-cycle pulse: host wrote the START CSR
    output logic soft_reset, // high during the flush window (drive the datapath's local reset low)
    output logic run         // 1-cycle pulse after the flush window: begin the transaction
);

    localparam int CW = $clog2(RST_CYCLES + 1);

    logic [CW-1:0] cnt_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            soft_reset <= 1'b0;
            run        <= 1'b0;
            cnt_q      <= '0;
        end else begin
            run <= 1'b0; // run is a single-cycle pulse
            if (start) begin
                // New request: open the flush window. A START arriving mid-window simply restarts it.
                soft_reset <= 1'b1;
                cnt_q      <= RST_CYCLES[CW-1:0];
            end else if (soft_reset) begin
                if (cnt_q != 0) begin
                    cnt_q <= cnt_q - 1'b1;
                end else begin
                    // Window elapsed: release the datapath and start the transaction next cycle.
                    soft_reset <= 1'b0;
                    run        <= 1'b1;
                end
            end
        end
    end

endmodule
