`timescale 1ns / 1ps

`include "axi_macros.svh"

import libstf::data8_t;
import lynxTypes::AXI_DATA_BITS;

module RDMAParquet #(
    parameter AXI_STRM_ID = 0,
    parameter DATABEAT_SIZE = AXI_DATA_BITS / 8
) (
    input logic clk,
    input logic rst_n,

    metaIntf.m sq_rd,    // #(.STYPE(req_t))
    metaIntf.s cq_rd,    // #(.STYPE(ack_t))

    rdma_read_config_i.s    rdma_conf,
    page_decoder_config_i.s decoder_conf,

    AXI4S.s in,          // #(AXI_DATA_BITS)
                         // NOTE: This must be axis_rreq_recv[AXI_STRM_ID]
    typed_ndata_i.m out  // #(DATABEAT_SIZE)
);

`RESET_RESYNC // Reset pipelining

ndata_i #(data8_t, DATABEAT_SIZE) rdma_data ();

RDMARead #(
    .AXI_STRM_ID(AXI_STRM_ID),
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_rdma_read (
    .clk(clk),
    .rst_n(reset_synced),

    .sq_rd(sq_rd),
    .cq_rd(cq_rd),

    .conf(rdma_conf),

    .in(in),
    .out(rdma_data)
);

PageDecoder #(
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_page_decoder (
    .clk(clk),
    .rst_n(reset_synced),

    .conf(decoder_conf),

    .in(rdma_data),
    .out(out)
);

endmodule
