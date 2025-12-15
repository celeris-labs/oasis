`timescale 1ns / 1ps

`include "parcore_types.svh"
import parcore::rdma_buffer_t;

/* -- Tie-off unused interfaces and signals ----------------------------- */
always_comb axi_ctrl.tie_off_s();
always_comb notify.tie_off_m();
always_comb sq_wr.tie_off_m();
always_comb cq_wr.tie_off_s();

always_comb axis_rrsp_send[0].tie_off_m();
always_comb axis_rrsp_recv[0].tie_off_s();
always_comb axis_rreq_send[0].tie_off_m();

always_comb sq_wr.tie_off_m();
always_comb cq_wr.tie_off_s();

// -- Fix clock and reset names ----------------------------------------- */
logic clk;
logic rst_n;

assign clk   = aclk;
assign rst_n = aresetn;

/* -- INPUT ------------------------------------------------------------- */

AXI4S axi_host_recv_0 (.aclk(aclk), .aresetn(aresetn));
`AXIS_ASSIGN(axis_host_recv[0], axi_host_recv_0)

AXI4S axi_rreq_recv_0 (.aclk(aclk), .aresetn(aresetn));
`AXIS_ASSIGN(axis_rreq_recv[0], axi_rreq_recv_0)

data_i #(rdma_buffer_t) data_in ();
AXIToData #(
  .data_t(rdma_buffer_t)
) inst_axi_to_ndata(
    .clk(clk),
    .rst_n(rst_n),

    .in(axi_host_recv_0),
    .out(data_in)
);

ready_valid_i #(rdma_buffer_t) in ();
assign data_in.ready = in.ready;
assign in.valid = data_in.valid && data_in.keep;
assign in.data = data_in.data;

/* -- OUTPUT ------------------------------------------------------------ */

AXI4S axi_host_send_0 (.aclk(aclk), .aresetn(aresetn));
`AXIS_ASSIGN(axi_host_send_0, axis_host_send[0])

ndata_i #(data8_t, 64) out ();
NDataToAXI #(data8_t, 64) inst_ndata_to_axi (
    .clk(clk),
    .rst_n(rst_n),

    .in(out),
    .out(axi_host_send_0)
);

/* -- DESIGN WIRING ----------------------------------------------------- */

RDMARead inst_rdma_read (
    .clk(clk),
    .rst_n(rst_n),

    .sq_rd(sq_rd),
    .cq_rd(cq_rd),
    .rdma_in(axi_rreq_recv_0),

    .in(in),
    .out(out)
);
