`timescale 1ns / 1ps

// Round-robin arbiter for the lanes that share the TOE transmit interface. A grant covers a whole
// transfer (tx_meta, tx_status, data beats), not one beat: tx_status does not say which tx_meta it
// answers, so two interleaved transfers would put one lane's bytes into the other's reservation.
// Priority starts one past the last holder, so a busy lane cannot starve its neighbours.
module tx_arbiter #(
    parameter int N = 4,
    localparam int SEL_BITS = (N > 1) ? $clog2(N) : 1
) (
    input  logic         clk,
    input  logic         rst_n,

    // One bit per claimant, high for the whole transfer and dropped when it completes.
    input  logic [N-1:0] req,
    output logic [N-1:0] grant,

    output logic [SEL_BITS-1:0] sel,
    output logic                busy
);

    logic [SEL_BITS-1:0] hold_q, next_w;
    logic                busy_q;
    logic                found_w;

    always_comb begin
        found_w = 1'b0;
        next_w  = hold_q;
        for (int i = 1; i <= N; i++) begin
            automatic int idx = (int'(hold_q) + i) % N;
            if (!found_w && req[idx]) begin
                found_w = 1'b1;
                next_w  = SEL_BITS'(idx);
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            hold_q <= '0;
            busy_q <= 1'b0;
        end else if (busy_q) begin
            // No preemption: the holder's reservation is made and its bytes must follow it.
            if (!req[hold_q]) busy_q <= 1'b0;
        end else if (found_w) begin
            hold_q <= next_w;
            busy_q <= 1'b1;
        end
    end

    always_comb begin
        grant = '0;
        if (busy_q) grant[hold_q] = 1'b1;
    end

    assign sel  = hold_q;
    assign busy = busy_q;

endmodule
