`timescale 1ns / 1ps

// =================================================================================================
// Round-robin grant for N claimants sharing ONE TOE transmit interface.
//
// WHY THIS IS NOT A MUX
// ---------------------
// The obvious thing -- mux tx_meta and tx_data by some select -- is wrong here, because a transmit
// is not one beat. It is a SEQUENCE:
//
//     tx_meta(session, length)  ->  tx_status(reservation granted / refused)  ->  N data beats
//
// and `tx_status` is a single ordered response stream with nothing in it naming which announcement
// it answers. If lane 0 announces and lane 1 announces before lane 0 has pushed its data, the first
// status belongs to lane 0 and the second to lane 1 -- but each lane reads whichever arrives while
// it happens to be in ST_WAIT_STAT. Lane 1 then pushes its bytes into lane 0's reservation. On the
// wire that is one request's text spliced into the middle of another, which the server answers 400,
// and every later request on that connection is misframed behind it.
//
// So the unit of arbitration is the whole transfer, not the beat. A lane raises `req` when it is
// armed and drops it when its last byte is sent; the grant is held for that entire span.
//
// WHY WHOLE-TRANSFER AND NOT PER-CHUNK
// ------------------------------------
// Per-chunk grants would let lanes interleave at CHUNK_BYTES (4 KiB) granularity and would work,
// with a more delicate hand-off at each chunk boundary. It is not worth it: request text is a few
// hundred bytes per GET against a ~800 us server round trip (ARCHITECTURE.md ADR-3), so transmit is
// nowhere near the critical path and serialising it costs nothing measurable. Buying zero
// throughput with a new class of interleaving bug is a bad trade.
//
// FAIRNESS
// --------
// The rotating priority starts one past the last holder, so a lane that just transmitted goes to
// the back. With N lanes all continuously armed, each gets every N-th transfer; no lane can be
// starved by a busier neighbour, which matters because a starved lane's TCP connection sits idle
// and MinIO closes an idle connection after ~30 s.
// =================================================================================================
module tx_arbiter #(
    parameter int N = 4,
    localparam int SEL_BITS = (N > 1) ? $clog2(N) : 1
) (
    input  logic         clk,
    input  logic         rst_n,

    // One bit per claimant. Must stay high for the whole transfer and drop when it completes.
    input  logic [N-1:0] req,
    // At most one bit set, ever.
    output logic [N-1:0] grant,

    // Who holds it, and whether anyone does -- for muxing the shared interface and for readback.
    output logic [SEL_BITS-1:0] sel,
    output logic                busy
);

    logic [SEL_BITS-1:0] hold_q, next_w;
    logic                busy_q;
    logic                found_w;

    // Rotating priority: scan from hold_q+1 so the last holder is examined last.
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
            // Hold until the holder drops its request. Nothing preempts a transfer in progress:
            // its reservation is already made and its bytes must follow it.
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
