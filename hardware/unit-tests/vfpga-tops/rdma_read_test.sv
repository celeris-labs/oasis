`timescale 1ns / 1ps

import oasis::*;

/* -- Tie-off unused interfaces and signals ----------------------------- */
always_comb notify.tie_off_m();
always_comb sq_wr.tie_off_m();
always_comb cq_wr.tie_off_s();
// RDMARead no longer consumes the read completion queue.
always_comb cq_rd.tie_off_s();

always_comb rq_rd.tie_off_s();
always_comb rq_wr.tie_off_s();

for (genvar I = 1; I < N_STRM_AXI; I++) begin
    always_comb axis_host_send[I].tie_off_m();
end

for (genvar I = 0; I < N_STRM_AXI; I++) begin
    always_comb axis_host_recv[I].tie_off_s();
end

for (genvar I = 0; I < N_RDMA_AXI; I++) begin
    always_comb axis_rrsp_send[I].tie_off_m();
    always_comb axis_rrsp_recv[I].tie_off_s();
    always_comb axis_rreq_send[I].tie_off_m();
end

for (genvar I = 1; I < N_RDMA_AXI; I++) begin
    always_comb axis_rreq_recv[I].tie_off_s();
end

// -- Fix clock and reset names ----------------------------------------- */
logic clk;
logic rst_n;

assign clk   = aclk;
assign rst_n = aresetn;

/* -- CONFIG ------------------------------------------------------------ */
write_config_i write_configs[1](.*);
read_config_i  read_configs [1](.*);
GlobalConfig #(
    .SYSTEM_ID(OASIS_SYSTEM_ID),
    .NUM_CONFIGS(1),
    .ADDR_SPACE_SIZES({NUM_READ_REQ_CONFIG_REGS * 1})
) inst_config (
    .clk(clk),
    .rst_n(rst_n),

    .axi_ctrl(axi_ctrl),

    .write_configs(write_configs),
    .read_configs(read_configs)
);

ready_valid_i #(read_req_t) conf[1](.*);
ReadReqConfig #(
    .NUM_STREAMS(1)
) inst_rdma_read_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[0]),
    .read_config(read_configs[0]),

    .out(conf)
);

/* -- INPUT ------------------------------------------------------------- */

AXI4S axi_rreq_recv_0 (.aclk(aclk), .aresetn(aresetn));
`AXIS_ASSIGN(axis_rreq_recv[0], axi_rreq_recv_0)

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

    .conf(conf[0]),

    .in(axi_rreq_recv_0),
    .out(out)
);
