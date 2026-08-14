`timescale 1ns / 1ps

import lynxTypes::*;

// Marks the end of a decoder stream by COUNTING BYTES, not by trusting a per-response flag.
//
// WHY THIS REPLACES body_last
// ---------------------------
// The decoder needs to know where one column chunk stops and the next begins; the DataNormalizer
// resets its running byte offset on tlast, so exactly one tlast per chunk is the contract.
//
// That used to be carried per RESPONSE: the host set a body_last bit on the last ranged GET of each
// chunk, the bit travelled in the request queue, and strip_http asserted tlast when it framed that
// response. It works, but it makes the bookkeeping scale with the number of REQUESTS -- one bit per
// outstanding response, thousands of them once requests are pushed in bulk -- and the queue holding
// them became the only arbitrary limit left in the design.
//
// A byte count scales with the number of COLUMN CHUNKS instead. A row group has a handful of those
// however finely each one is split into ranged GETs, so CFG_DEPTH can be small and never fill. How
// many GETs a chunk took becomes invisible to everything downstream.
//
// The same idea as libstf's RewriteLastCore (hardware/src/hdl/stream/data_rewrite_last.sv), written
// against AXI-Stream because that is what the body path speaks; adapting the ndata_i wrappers would
// have been more plumbing than the counter itself.
module axis_rewrite_last #(
    // Column chunks that may be configured ahead of the data. A row group's worth is a handful, so
    // this exists to decouple the host from the wire, not to bound anything.
    parameter int CFG_DEPTH = 64
) (
    input  logic clk,
    input  logic rst_n,

    // Length of the next logical stream, in bytes. One per column chunk.
    input  logic        cfg_valid,
    output logic        cfg_ready,
    input  logic [31:0] cfg_len,

    input  logic                       s_tvalid,
    output logic                       s_tready,
    input  logic [AXI_DATA_BITS-1:0]   s_tdata,
    input  logic [AXI_DATA_BITS/8-1:0] s_tkeep,

    output logic                       m_tvalid,
    input  logic                       m_tready,
    output logic [AXI_DATA_BITS-1:0]   m_tdata,
    output logic [AXI_DATA_BITS/8-1:0] m_tkeep,
    output logic                       m_tlast,

    // High while any configured chunk is still incomplete. This is what tells the handler that more
    // responses are coming: the module knows exactly how many bytes are still owed, so nothing else
    // has to count responses.
    output logic        busy,

    // Sticky: data arrived with no length configured. Means the host queued fewer chunk lengths
    // than the responses it asked for, which would silently merge two columns into one stream.
    output logic        starved,
    output logic [31:0] remaining_dbg
);

    localparam int LANES    = AXI_DATA_BITS / 8;
    localparam int PTR_BITS = $clog2(CFG_DEPTH);
    localparam int CNT_BITS = $clog2(CFG_DEPTH + 1);

    initial begin
        if (CFG_DEPTH < 2 || (CFG_DEPTH & (CFG_DEPTH - 1)))
            $error("axis_rewrite_last: CFG_DEPTH must be a power of two >= 2");
    end

    // Length queue.
    logic [31:0]          len_mem [CFG_DEPTH];
    logic [PTR_BITS-1:0]  wr_ptr_q, rd_ptr_q;
    logic [CNT_BITS-1:0]  cnt_q;
    logic                 q_empty, q_full;
    assign q_empty  = (cnt_q == '0);
    assign q_full   = (cnt_q == CNT_BITS'(CFG_DEPTH));
    assign cfg_ready = !q_full;

    // Bytes still owed on the stream currently being counted. Loaded from the queue head.
    logic [31:0] remaining_q;
    logic        active_q;
    logic        starved_q;

    logic [$clog2(LANES):0] beat_bytes;
    assign beat_bytes = ($countones(s_tkeep));

    logic do_push, do_pop;
    assign do_push = cfg_valid && cfg_ready;
    assign do_pop  = !active_q && !q_empty;

    logic beat_fire, is_last;
    // A beat may only pass once a length is loaded: without one there is no way to know whether it
    // ends a stream, and guessing merges columns.
    assign m_tvalid = s_tvalid && active_q;
    assign s_tready = m_tready && active_q;
    assign beat_fire = m_tvalid && m_tready;
    assign is_last  = active_q && (remaining_q <= 32'(beat_bytes));

    assign m_tdata = s_tdata;
    assign m_tkeep = s_tkeep;
    assign m_tlast = is_last;

    assign busy          = active_q || !q_empty;
    assign starved       = starved_q;
    assign remaining_dbg = remaining_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr_q    <= '0;
            rd_ptr_q    <= '0;
            cnt_q       <= '0;
            remaining_q <= '0;
            active_q    <= 1'b0;
            starved_q   <= 1'b0;
        end else begin
            // Push and pop can happen in the same cycle, so the count is adjusted ONCE from both
            // rather than by two assignments where the later silently wins.
            if (do_push) begin
                len_mem[wr_ptr_q] <= cfg_len;
                wr_ptr_q          <= wr_ptr_q + 1'b1;
            end
            if (do_pop) begin
                remaining_q <= len_mem[rd_ptr_q];
                active_q    <= 1'b1;
                rd_ptr_q    <= rd_ptr_q + 1'b1;
            end
            case ({do_push, do_pop})
                2'b10:   cnt_q <= cnt_q + 1'b1;
                2'b01:   cnt_q <= cnt_q - 1'b1;
                default: cnt_q <= cnt_q;   // both or neither
            endcase

            // count down
            if (beat_fire) begin
                if (is_last) begin
                    active_q    <= 1'b0;
                    remaining_q <= '0;
                end else begin
                    remaining_q <= remaining_q - 32'(beat_bytes);
                end
            end

            // data with nothing configured: the host under-queued.
            if (s_tvalid && !active_q && q_empty) starved_q <= 1'b1;
        end
    end

endmodule
