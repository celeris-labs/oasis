`timescale 1ns / 1ps

import lynxTypes::*;

// =================================================================================================
// Two-entry AXI-Stream skid buffer: a FULL register slice. Nothing combinational crosses it in
// either direction, and it still moves one beat per cycle with no bubbles under any back-pressure.
//
// WHY IT EXISTS
// -------------
// handler_multi puts one on each lane's body output (see the instantiation there for the timing
// report it answers). It is a boundary, not a buffer: its whole job is to end the forward cone out
// of strip_http + axis_rewrite_last at a register, and to end the decoder's tready chain at one.
// tcp_read puts another between its decoupling fifo and strip_http, for the same two reasons on the
// framer's input side.
//
// WHERE IT COMES FROM
// -------------------
// This is libstf's SkidBuffer (parcore/libstf/hardware/src/hdl/util/skid_buffer.sv:3-49), the
// decoder's own `inst_skid_buffer`, re-expressed on plain AXI-Stream ports. Same two registers,
// same update rules. It is not instantiated from libstf because that module speaks libstf's
// ready_valid_i interface and its file only compiles next to the libstf package, the libstf
// interfaces and a compilation-unit `import lynxTypes::*` -- all of which synthesis has and none of
// which the http_read benches (lane_drain included) compile. One deliberate difference: the payload
// registers are not held in reset (libstf's are, through the reset if/else), because the valid
// bits already gate them and a reset term on ~1150 clock enables is pure fanout.
//
// HOW IT WORKS
// ------------
//   tmp  -- the input register. Loaded on EVERY cycle s_tready is high, valid or not.
//   over -- the overflow register. Catches tmp's beat on a cycle the output refused it.
//
//   s_tready = !tmp_valid || !over_valid      two flops: no path from m_tready
//   m_tvalid = tmp_valid || over_valid        two flops: no path from s_tvalid
//   m_t*     = over_valid ? over : tmp        a 2:1 mux on flops: no path from s_t*
//
// m_tready reaches exactly one register, over_valid. That is the point on the backward side:
// without the slice the decoder's ready chain ends at strip_http's skid clock enables (~1150
// flops); with it, at one flop.
//
// Throughput: s_tready is low only when BOTH registers hold a beat, and then m_tvalid is high -- so
// the input is refused only while the output has something to offer, and the output idles only
// while the slice is empty. With the sink always ready it is one beat per cycle at one cycle of
// latency; under any back-pressure pattern, a source that keeps offering has a beat move on every
// cycle the sink is ready. lane_drain runs every lane through it under its back-pressure patterns.
// =================================================================================================
module axis_skid #(
    parameter int DATA_BITS = AXI_DATA_BITS
) (
    input  logic                   clk,
    input  logic                   rst_n,

    input  logic                   s_tvalid,
    output logic                   s_tready,
    input  logic [DATA_BITS-1:0]   s_tdata,
    input  logic [DATA_BITS/8-1:0] s_tkeep,
    input  logic                   s_tlast,

    output logic                   m_tvalid,
    input  logic                   m_tready,
    output logic [DATA_BITS-1:0]   m_tdata,
    output logic [DATA_BITS/8-1:0] m_tkeep,
    output logic                   m_tlast
);

    logic                   tmp_valid_q,  over_valid_q;
    logic [DATA_BITS-1:0]   tmp_data_q,   over_data_q;
    logic [DATA_BITS/8-1:0] tmp_keep_q,   over_keep_q;
    logic                   tmp_last_q,   over_last_q;

    assign s_tready = !tmp_valid_q || !over_valid_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            tmp_valid_q  <= 1'b0;
            over_valid_q <= 1'b0;
        end else begin
            if (s_tready) tmp_valid_q <= s_tvalid;

            // A beat the sink refused is parked in over; a ready sink empties over. The two are
            // exclusive (one needs !m_tready, the other m_tready), so their order is immaterial.
            if (!over_valid_q && !m_tready) over_valid_q <= tmp_valid_q;
            if (m_tready)                   over_valid_q <= 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        if (s_tready) begin
            tmp_data_q <= s_tdata;
            tmp_keep_q <= s_tkeep;
            tmp_last_q <= s_tlast;
        end
        if (!over_valid_q) begin
            over_data_q <= tmp_data_q;
            over_keep_q <= tmp_keep_q;
            over_last_q <= tmp_last_q;
        end
    end

    assign m_tvalid = tmp_valid_q || over_valid_q;
    assign m_tdata  = over_valid_q ? over_data_q : tmp_data_q;
    assign m_tkeep  = over_valid_q ? over_keep_q : tmp_keep_q;
    assign m_tlast  = over_valid_q ? over_last_q : tmp_last_q;

endmodule
