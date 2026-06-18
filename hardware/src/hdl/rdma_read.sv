`timescale 1ns / 1ps

`include "axi_macros.svh"

import libstf::data8_t;
import libstf::data64_t;
import lynxTypes::AXI_DATA_BITS;
import oasis::read_req_t;

/*
 * For RDMA transfers, Coyote currently leaves one last signal for every MTU (4K). This module
 * removes those and only leaves the last one of the transfer. This can be removed if we change this
 * behavior in Coyote.
 */
module RDMARead #(
    parameter AXI_STRM_ID = 0,
    parameter DATABEAT_SIZE = AXI_DATA_BITS / 8
) (
    input logic clk,
    input logic rst_n,

    metaIntf.m sq_rd,    // #(.STYPE(req_t))

    ready_valid_i.s conf, // #(read_req_t)

    AXI4S.s in,          // #(AXI_DATA_BITS)
                         // NOTE: This must be axis_rreq_recv[AXI_STRM_ID]
    ndata_i.m out        // #(data8_t, DATABEAT_SIZE)
);

localparam RDMA_READ = 12;

// -- Request generation ---------------------------------------------------------------------------
ready_valid_i #(read_req_t) req (clk, rst_n);

ReadReqGenerator #(
    .OPCODE(RDMA_READ),
    .DEST(AXI_STRM_ID)
) inst_req_gen (
    .clk(clk),
    .rst_n(rst_n),

    .conf(conf),
    .sq_rd(sq_rd),
    .req(req)
);

// -- Last fixing ----------------------------------------------------------------------------------
ndata_i #(data8_t, DATABEAT_SIZE) out_inner ();
AXIToNData #(
  .data_t(data8_t),
  .NUM_ELEMENTS(DATABEAT_SIZE)
) inst_axi_to_ndata(
    .clk(clk),
    .rst_n(rst_n),

    .in(in),
    .out(out_inner)
);

// DataRewriteLast needs just the length of the request whose data is currently streaming. Expose
// the head-of-FIFO request's length on a ready/valid interface.
ready_valid_i #(data64_t) req_len (clk, rst_n);
assign req_len.data  = req.data.len;
assign req_len.valid = req.valid;
assign req.ready     = req_len.ready;

DataRewriteLast #(
    .data_t(data8_t),
    .NUM_ELEMENTS(DATABEAT_SIZE),
    .size_t(data64_t)
) inst_rewrite_last (
    .clk(clk),
    .rst_n(rst_n),

    .num_elements(req_len),

    .in(out_inner),
    .out(out)
);

`ifdef SYNTHESIS
ila_rdma_read inst_ila_rdma_read (
    .clk(clk),
    .probe0(rst_n),

    .probe1(sq_rd.data),
    .probe2(sq_rd.valid),
    .probe3(sq_rd.ready),

    .probe4(conf.data),
    .probe5(conf.valid),
    .probe6(conf.ready),

    .probe7(req.data),
    .probe8(req.valid),
    .probe9(req.ready),

    .probe10(in.tkeep),
    .probe11(in.tlast),
    .probe12(in.tvalid),
    .probe13(in.tready),

    .probe14(out.keep),
    .probe15(out.last),
    .probe16(out.valid),
    .probe17(out.ready)
);
`endif

endmodule
