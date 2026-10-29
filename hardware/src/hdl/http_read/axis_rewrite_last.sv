`timescale 1ns / 1ps

import lynxTypes::*;

// Sets tlast at the end of each decoder stream by counting bytes: the host queues one length (and
// decoder lane) per column chunk, and the beat that completes it gets tlast. That takes one queue
// entry per column chunk rather than one flag per ranged GET, so how many GETs a chunk took is
// invisible downstream. Same idea as libstf's RewriteLastCore, on AXI4-Stream ports.
module axis_rewrite_last #(
    // Column chunks that can be queued ahead of the data.
    parameter int CFG_DEPTH = 64,
    parameter int NUM_DEST  = 1,
    parameter int DEST_BITS = (NUM_DEST > 1) ? $clog2(NUM_DEST) : 1
) (
    input  logic clk,
    input  logic rst_n,

    // Length of the next stream in bytes, one per column chunk.
    input  logic        cfg_valid,
    output logic        cfg_ready,
    input  logic [31:0] cfg_len,
    // Decoder lane of the chunk. The host chooses it; the hardware does not second-guess it.
    input  logic [DEST_BITS-1:0] cfg_dest,

    input  logic                       s_tvalid,
    output logic                       s_tready,
    input  logic [AXI_DATA_BITS-1:0]   s_tdata,
    input  logic [AXI_DATA_BITS/8-1:0] s_tkeep,

    output logic                       m_tvalid,
    input  logic                       m_tready,
    output logic [AXI_DATA_BITS-1:0]   m_tdata,
    output logic [AXI_DATA_BITS/8-1:0] m_tkeep,
    output logic                       m_tlast,
    // Constant for a whole chunk, so a demux can hold its selection until tlast.
    output logic [DEST_BITS-1:0]       m_tdest,

    // High while a queued chunk is still incomplete, i.e. more response bytes are owed.
    output logic        busy,

    // Sticky: data arrived with no length queued, i.e. the host queued too few chunk lengths.
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

    logic [31:0]          len_mem  [CFG_DEPTH];
    logic [DEST_BITS-1:0] dest_mem [CFG_DEPTH];
    logic [PTR_BITS-1:0]  wr_ptr_q, rd_ptr_q;
    logic [CNT_BITS-1:0]  cnt_q;
    logic                 q_empty, q_full;
    assign q_empty  = (cnt_q == '0);
    assign q_full   = (cnt_q == CNT_BITS'(CFG_DEPTH));
    assign cfg_ready = !q_full;

    logic [31:0] remaining_q;
    logic [DEST_BITS-1:0] dest_q;
    logic        active_q;
    logic        starved_q;

    logic [$clog2(LANES):0] beat_bytes;
    assign beat_bytes = ($countones(s_tkeep));

    logic do_push, do_pop;
    assign do_push = cfg_valid && cfg_ready;
    assign do_pop  = !active_q && !q_empty;

    logic beat_fire, is_last;
    // No beat passes before a length is loaded: without one there is no telling where it ends.
    assign m_tvalid = s_tvalid && active_q;
    assign s_tready = m_tready && active_q;
    assign beat_fire = m_tvalid && m_tready;
    assign is_last  = active_q && (remaining_q <= 32'(beat_bytes));

    assign m_tdata = s_tdata;
    assign m_tkeep = s_tkeep;
    assign m_tlast = is_last;
    assign m_tdest = dest_q;

    assign busy          = active_q || !q_empty;
    assign starved       = starved_q;
    assign remaining_dbg = remaining_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr_q    <= '0;
            rd_ptr_q    <= '0;
            cnt_q       <= '0;
            remaining_q <= '0;
            dest_q      <= '0;
            active_q    <= 1'b0;
            starved_q   <= 1'b0;
        end else begin
            if (do_push) begin
                len_mem [wr_ptr_q] <= cfg_len;
                dest_mem[wr_ptr_q] <= cfg_dest;
                wr_ptr_q           <= wr_ptr_q + 1'b1;
            end
            if (do_pop) begin
                remaining_q <= len_mem [rd_ptr_q];
                dest_q      <= dest_mem[rd_ptr_q];
                active_q    <= 1'b1;
                rd_ptr_q    <= rd_ptr_q + 1'b1;
            end
            case ({do_push, do_pop})
                2'b10:   cnt_q <= cnt_q + 1'b1;
                2'b01:   cnt_q <= cnt_q - 1'b1;
                default: cnt_q <= cnt_q;
            endcase

            if (beat_fire) begin
                if (is_last) begin
                    active_q    <= 1'b0;
                    remaining_q <= '0;
                end else begin
                    remaining_q <= remaining_q - 32'(beat_bytes);
                end
            end

            if (s_tvalid && !active_q && q_empty) starved_q <= 1'b1;
        end
    end

endmodule
