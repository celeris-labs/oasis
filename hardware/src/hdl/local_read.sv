`timescale 1ns / 1ps

`include "axi_macros.svh"

import libstf::data8_t;
import lynxTypes::AXI_DATA_BITS;
import lynxTypes::LOCAL_READ;
import oasis::read_req_t;

/*
 * Issues local (host-memory) reads from a configured (vaddr, len) and streams the returned data
 * out as an ndata stream. The data arrives on the corresponding axis_host_recv stream.
 */
module LocalRead #(
    parameter AXI_STRM_ID = 0,
    parameter DATABEAT_SIZE = AXI_DATA_BITS / 8
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s conf, // #(read_req_t)
    metaIntf.m sq_rd,     // #(.STYPE(req_t))

    AXI4S.s in,   // #(AXI_DATA_BITS)
                  // NOTE: This must be axis_host_recv[AXI_STRM_ID]
    ndata_i.m out // #(data8_t, DATABEAT_SIZE)
);

ready_valid_i #(read_req_t) req (clk, rst_n);

ReadReqGenerator #(
    .OPCODE(LOCAL_READ),
    .DEST(AXI_STRM_ID)
) inst_req_gen (
    .clk(clk),
    .rst_n(rst_n),

    .conf(conf),
    .sq_rd(sq_rd),
    .req(req)
);

assign req.ready = 1'b1;

AXIToNData #(
  .data_t(data8_t),
  .NUM_ELEMENTS(DATABEAT_SIZE)
) inst_axi_to_ndata(
    .clk(clk),
    .rst_n(rst_n),

    .in(in),
    .out(out)
);

endmodule
