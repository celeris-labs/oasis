`timescale 1ns / 1ps

`include "axi_macros.svh"
`include "libstf_macros.svh"

import libstf::data8_t;
import libstf::data64_t;
import lynxTypes::AXI_DATA_BITS;
import lynxTypes::PID_BITS;
import oasis::read_req_t;

/*
 * For RDMA transfers, Coyote currently leaves one last signal for every MTU (4K). This module
 * removes those and only leaves the last one of the transfer. It also pads the requests to multiple
 * of 64 Byte length because Coyote returns arbitrarily long streams otherwise. Both of these fixes
 * can be removed if we change this behavior in Coyote.
 *
 * This module gets a Coyote thread id so each stream has a separate queue pair so we don't overrun
 * the server side with too many parallel requests.
 */
module RDMARead #(
    parameter AXI_STRM_ID = 0,
    parameter DATABEAT_SIZE = AXI_DATA_BITS / 8
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s           conf, // #(read_req_t)
    input logic[PID_BITS-1:0] ctid,

    metaIntf.m      sq_rd, // #(.STYPE(req_t))

    AXI4S.s in,          // #(AXI_DATA_BITS) // NOTE: This must be axis_rreq_recv[AXI_STRM_ID]
    ndata_i.m out        // #(data8_t, DATABEAT_SIZE)
);

`RESET_RESYNC // Reset pipelining

localparam RDMA_READ = 12;

// -- Request generation ---------------------------------------------------------------------------
ready_valid_i #(read_req_t) req (clk, reset_synced);

ReadReqGenerator #(
    .OPCODE(RDMA_READ),
    .DEST(AXI_STRM_ID),
    .PAD_LEN_TO(DATABEAT_SIZE) // Pad request length to DATABEAT_SIZE
) inst_req_gen (
    .clk(clk),
    .rst_n(reset_synced),

    .ctid(ctid),

    .conf(conf),
    .sq_rd(sq_rd),
    .req(req)
);

// -- Last fixing ----------------------------------------------------------------------------------
ndata_i #(data8_t, DATABEAT_SIZE) in_ndata(clk, reset_synced);
AXIToNData #(
  .data_t(data8_t),
  .NUM_ELEMENTS(DATABEAT_SIZE)
) inst_axi_to_ndata(
    .clk(clk),
    .rst_n(reset_synced),

    .in(in),
    .out(in_ndata)
);

// DataRewriteLast needs just the length of the request whose data is currently streaming. Expose
// the head-of-FIFO request's length on a ready/valid interface.
ready_valid_i #(data64_t) req_len (clk, reset_synced);
assign req_len.data  = req.data.len;
assign req_len.valid = req.valid;
assign req.ready     = req_len.ready;

ndata_i #(data8_t, DATABEAT_SIZE) out_inner(clk, reset_synced);
DataRewriteLast #(
    .data_t(data8_t),
    .NUM_ELEMENTS(DATABEAT_SIZE),
    .size_t(data64_t),
    .STRIP_TRAILING(1) // Remove padding
) inst_rewrite_last (
    .clk(clk),
    .rst_n(reset_synced),

    .num_elements(req_len),

    .in(in_ndata),
    .out(out_inner)
);

NDataSkidBuffer #(
    .data_t(data8_t),
    .NUM_ELEMENTS(DATABEAT_SIZE)
) inst_out_skid (
    .clk(clk),
    .rst_n(reset_synced),

    .in(out_inner),
    .out(out)
);

`ifdef SYNTHESIS
ila_read inst_ila_rdma_read (
    .clk(clk),
    .probe0(reset_synced),

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
