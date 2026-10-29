`timescale 1ns / 1ps

import lynxTypes::*;

// Two-entry AXI4-Stream skid buffer: a full register slice that cuts every combinational path in
// both directions and still moves one beat per cycle under any back-pressure. handler_multi puts
// one on each lane's body output. It is libstf's SkidBuffer on plain AXI4-Stream ports, so the
// http_read unit tests compile it without the libstf interfaces; unlike SkidBuffer, the payload
// registers have no reset, since the valid bits already gate them.
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

            // over fills on a refused beat and empties on an accepted one; the two never coincide.
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
