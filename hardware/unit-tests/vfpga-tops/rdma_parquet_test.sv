`timescale 1ns / 1ps

import oasis::*;
import parcore::*;

/* -- Tie-off unused interfaces and signals ----------------------------- */
always_comb notify.tie_off_m();
always_comb sq_wr.tie_off_m();
always_comb cq_wr.tie_off_s();

always_comb rq_rd.tie_off_s();
always_comb rq_wr.tie_off_s();

for (genvar I = 0; I < N_STRM_AXI; I++) begin
    always_comb axis_host_recv[I].tie_off_s();
end

for (genvar I = 0; I < N_RDMA_AXI; I++) begin
    always_comb axis_rrsp_send[I].tie_off_m();
    always_comb axis_rrsp_recv[I].tie_off_s();
    always_comb axis_rreq_send[I].tie_off_m();
end

localparam N_STREAMS = N_STRM_AXI;
`ASSERT_ELAB(N_STRM_AXI == N_RDMA_AXI)
localparam DATABEAT_SIZE = 64;

// -- Fix clock and reset names ----------------------------------------- */
logic clk;
logic rst_n;

assign clk   = aclk;
assign rst_n = aresetn;

/* -- CONFIG ------------------------------------------------------------ */
write_config_i write_configs[2](.*);
read_config_i  read_configs [2](.*);
GlobalConfig #(
    .SYSTEM_ID(OASIS_SYSTEM_ID),
    .NUM_CONFIGS(2),
    .ADDR_SPACE_SIZES({RDMA_READ_CONFIG_REGS*N_STREAMS, PAGE_DECODER_CONFIG_REGS*N_STREAMS})
) inst_config (
    .clk(clk),
    .rst_n(rst_n),

    .axi_ctrl(axi_ctrl),

    .write_configs(write_configs),
    .read_configs(read_configs)
);

rdma_read_config_i rdma_conf[N_STREAMS](.*);
RDMAReadConfig #(
    .NUM_STREAMS(N_STREAMS)
) inst_rdma_read_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[0]),
    .read_config(read_configs[0]),

    .out(rdma_conf)
);

page_decoder_config_i decoder_conf[N_STREAMS](.*);
PageDecoderConfig #(
    .NUM_DECODERS(N_STREAMS)
) inst_page_decoder_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[1]),
    .read_config(read_configs[1]),

    .out(decoder_conf)
);

// -- De-mux and arbiter the queue and notify signals ----------------------------------------------
metaIntf #(.STYPE(req_t)) sq_rd_strm [N_STREAMS](.aclk(clk), .aresetn(rst_n));
metaIntf #(.STYPE(ack_t)) cq_rd_strm [N_STREAMS](.aclk(clk), .aresetn(rst_n));

MetaIntfArbiter #(
  .N_INTERFACES(N_STREAMS),
  .STYPE(req_t)
) inst_sq_wr_arbiter (
  .clk(clk),
  .rst_n(rst_n),

  .intf_in(sq_rd_strm),
  .intf_out(sq_rd)
);

CQDemultiplexer #(
  .N_STREAMS(N_STREAMS)
) inst_cq_wr_de_mux (
  .clk(clk),
  .rst_n(rst_n),

  .data_in(cq_rd),
  .data_out(cq_rd_strm)
);

for (genvar I = 0; I < N_STREAMS; I++) begin
    /* -- INPUT ------------------------------------------------------------- */

    AXI4S in (.aclk(aclk), .aresetn(aresetn));
    `AXIS_ASSIGN(axis_rreq_recv[I], in)

    /* -- OUTPUT ------------------------------------------------------------ */

    AXI4S out_host (.aclk(clk), .aresetn(rst_n));
    `AXIS_ASSIGN(out_host, axis_host_send[I])

    ndata_i #(data8_t, DATABEAT_SIZE) out_u8 ();
    NDataToAXI #(data8_t, DATABEAT_SIZE) inst_ndata_to_axi (
        .clk(clk),
        .rst_n(rst_n),

        .in(out_u8),
        .out(out_host)
    );

    // discard typed interface
    typed_ndata_i #(DATABEAT_SIZE) out();
    `DATA_ASSIGN(out, out_u8);

    /* -- DESIGN WIRING ----------------------------------------------------- */

    RDMAParquet #(
        .AXI_STRM_ID(I),
        .DATABEAT_SIZE(DATABEAT_SIZE)
    ) inst_rdma_parquet (
        .clk(clk),
        .rst_n(rst_n),

        .sq_rd(sq_rd_strm[I]),
        .cq_rd(cq_rd_strm[I]),

        .rdma_conf(rdma_conf[I]),
        .decoder_conf(decoder_conf[I]),

        .in(in),
        .out(out)
    );
end
