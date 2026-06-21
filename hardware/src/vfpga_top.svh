`timescale 1ns / 1ps

import oasis::*;
import parcore::*;
import http_types::*;

// -- Tie-off unused interfaces and signals --------------------------------------------------------
`ifdef EN_TCP
always_comb sq_rd.tie_off_m();
always_comb cq_rd.tie_off_s();
always_comb rq_wr.tie_off_s();
// HTTP client does active opens only; the listen path is unused.
always_comb tcp_listen_req.tie_off_m();
always_comb tcp_listen_rsp.tie_off_s();
`elsif EN_RDMA
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

`ASSERT_ELAB(N_STRM_AXI == N_RDMA_AXI)
`else
always_comb sq_rd.tie_off_m();
always_comb cq_rd.tie_off_s();
`endif

localparam NUM_STREAMS        = N_STRM_AXI;
localparam DATABEAT_SIZE      = AXI_DATA_BITS / 8;
// MemConfig write side needs NUM_STREAMS+1 regs, read side needs 3 (ID, num_streams, max_enqueued).
localparam MEM_CONFIG_NUM_REGS = (NUM_STREAMS + 1 > 3) ? NUM_STREAMS + 1 : 3;

`ifdef EN_TCP
localparam NUM_CONFIGS   = 4;
localparam NUM_DECODERS  = NUM_STREAMS - 1;
`elsif EN_RDMA
localparam NUM_CONFIGS   = 4;
localparam NUM_DECODERS  = NUM_STREAMS - 1;
`else
localparam NUM_CONFIGS   = 3;
localparam NUM_DECODERS  = NUM_STREAMS;
`endif

// -- Fix clock and reset names --------------------------------------------------------------------
logic clk;
logic rst_n;

assign clk   = aclk;
assign rst_n = aresetn;

// -- Configuration --------------------------------------------------------------------------------
write_config_i                write_configs[NUM_CONFIGS](.*);
read_config_i                 read_configs [NUM_CONFIGS](.*);
mem_config_i                  mem_conf[NUM_STREAMS](.*);
`ifdef EN_TCP
http_read_config_i            http_conf[NUM_STREAMS](.*);
`elsif EN_RDMA
rdma_read_config_i            rdma_conf[NUM_STREAMS](.*);
`endif
column_chunk_decoder_config_i column_chunk_conf[NUM_DECODERS](.*);
page_decoder_config_i         page_conf[NUM_DECODERS](.*);

GlobalConfig #(
    .SYSTEM_ID(OASIS_SYSTEM_ID),
    .NUM_CONFIGS(NUM_CONFIGS),
    .ADDR_SPACE_SIZES({
        MEM_CONFIG_NUM_REGS,
        COLUMN_CHUNK_DECODER_CONFIG_REGS * NUM_DECODERS,
        PAGE_DECODER_CONFIG_REGS * NUM_DECODERS
`ifdef EN_TCP
        , NUM_HTTP_READ_CONFIG_REGS * NUM_STREAMS
`elsif EN_RDMA
        , NUM_RDMA_READ_CONFIG_REGS * NUM_STREAMS
`endif
    })
) inst_config (
    .clk(clk),
    .rst_n(rst_n),

    .axi_ctrl(axi_ctrl),

    .write_configs(write_configs),
    .read_configs(read_configs)
);

MemConfig #(
    .NUM_STREAMS(NUM_STREAMS)
) inst_mem_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[0]),
    .read_config(read_configs[0]),

    .out(mem_conf)
);

ColumnChunkDecoderConfig #(
    .NUM_DECODERS(NUM_DECODERS)
) inst_column_chunk_decoder_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[1]),
    .read_config(read_configs[1]),

    .out(column_chunk_conf)
);

PageDecoderConfig #(
    .NUM_DECODERS(NUM_DECODERS)
) inst_page_decoder_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[2]),
    .read_config(read_configs[2]),

    .out(page_conf)
);

`ifdef EN_TCP
HTTPReadConfig #(
    .NUM_STREAMS(NUM_STREAMS)
) inst_http_read_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[3]),
    .read_config(read_configs[3]),

    .out(http_conf)
);
`elsif EN_RDMA
RDMAReadConfig #(
    .NUM_STREAMS(NUM_STREAMS)
) inst_rdma_read_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[3]),
    .read_config(read_configs[3]),

    .out(rdma_conf)
);

metaIntf #(.STYPE(req_t)) sq_rd_strm [NUM_STREAMS](.aclk(clk), .aresetn(rst_n));
metaIntf #(.STYPE(ack_t)) cq_rd_strm [NUM_STREAMS](.aclk(clk), .aresetn(rst_n));

MetaIntfArbiter #(
    .N_INTERFACES(NUM_STREAMS),
    .STYPE(req_t)
) inst_sq_wr_arbiter (
    .clk(clk),
    .rst_n(rst_n),

    .intf_in(sq_rd_strm),
    .intf_out(sq_rd)
);

CQDemultiplexer #(
    .N_STREAMS(NUM_STREAMS)
) inst_cq_wr_de_mux (
    .clk(clk),
    .rst_n(rst_n),

    .data_in(cq_rd),
    .data_out(cq_rd_strm)
);
`endif

// -- Decoders -------------------------------------------------------------------------------------
AXI4S axi_out[NUM_STREAMS](.aclk(clk), .aresetn(rst_n));
generate
for (genvar I = 0; I < NUM_DECODERS; I++) begin : gen_decoders
    AXI4S axi_in (.aclk(clk), .aresetn(rst_n));
    ndata_i       #(data8_t, DATABEAT_SIZE) decoder_in();
    typed_ndata_i #(DATABEAT_SIZE)          typed_out();
    ndata_i       #(data8_t, DATABEAT_SIZE) out();

`ifdef EN_RDMA
    `AXIS_ASSIGN(axis_rreq_recv[I], axi_in)

    RDMARead #(
        .AXI_STRM_ID(I),
        .DATABEAT_SIZE(DATABEAT_SIZE)
    ) inst_rdma_read (
        .clk(clk),
        .rst_n(rst_n),

        .sq_rd(sq_rd_strm[I]),
        .cq_rd(cq_rd_strm[I]),

        .conf(rdma_conf[I]),

        .in(axi_in),
        .out(decoder_in)
    );
`else
    `AXIS_ASSIGN(axis_host_recv[I], axi_in)

    AXIToNData #(data8_t, DATABEAT_SIZE) inst_axi_to_ndata (
        .clk(clk),
        .rst_n(rst_n),

        .in(axi_in),
        .out(decoder_in)
    );
`endif

    ColumnChunkDecoder #(
        .DATABEAT_SIZE(DATABEAT_SIZE)
    ) inst_column_chunk_decoder (
        .clk(clk),
        .rst_n(rst_n),

        .column_chunk_conf(column_chunk_conf[I]),
        .page_conf(page_conf[I]),

        .in(decoder_in),
        .out(typed_out)
    );

    `DATA_ASSIGN(typed_out, out);

    NDataToAXI #(data8_t, DATABEAT_SIZE) inst_ndata_to_axi (
        .clk(clk),
        .rst_n(rst_n),

        .in(out),
        .out(axi_out[I])
    );
end
endgenerate

// -- Bypass stream (last slot, no decoder) --------------------------------------------------------
localparam BYPASS_ID = NUM_STREAMS - 1;

`ifdef EN_TCP
HTTPRead inst_http_read_bypass (
    .clk(clk),
    .rst_n(rst_n),

    .conf(http_conf[BYPASS_ID]),

    .m_axis_open_connection_TVALID(tcp_open_req.valid),
    .m_axis_open_connection_TREADY(tcp_open_req.ready),
    .m_axis_open_connection_TDATA (tcp_open_req.data),
    .s_axis_open_status_TVALID    (tcp_open_rsp.valid),
    .s_axis_open_status_TREADY    (tcp_open_rsp.ready),
    .s_axis_open_status_TDATA     (tcp_open_rsp.data),
    .m_axis_close_connection_TVALID(tcp_close_req.valid),
    .m_axis_close_connection_TREADY(tcp_close_req.ready),
    .m_axis_close_connection_TDATA (tcp_close_req.data),

    .s_axis_notifications_TVALID  (tcp_notify.valid),
    .s_axis_notifications_TREADY  (tcp_notify.ready),
    .s_axis_notifications_TDATA   (tcp_notify.data),
    .m_axis_read_package_TVALID   (tcp_rd_pkg.valid),
    .m_axis_read_package_TREADY   (tcp_rd_pkg.ready),
    .m_axis_read_package_TDATA    (tcp_rd_pkg.data),
    .s_axis_rx_metadata_TVALID    (tcp_rx_meta.valid),
    .s_axis_rx_metadata_TREADY    (tcp_rx_meta.ready),
    .s_axis_rx_metadata_TDATA     (tcp_rx_meta.data),
    .s_axis_rx_data_TVALID        (axis_tcp_recv.tvalid),
    .s_axis_rx_data_TREADY        (axis_tcp_recv.tready),
    .s_axis_rx_data_TDATA         (axis_tcp_recv.tdata),
    .s_axis_rx_data_TKEEP         (axis_tcp_recv.tkeep),
    .s_axis_rx_data_TLAST         (axis_tcp_recv.tlast),

    .m_axis_tx_meta_TVALID        (tcp_tx_meta.valid),
    .m_axis_tx_meta_TREADY        (tcp_tx_meta.ready),
    .m_axis_tx_meta_TDATA         (tcp_tx_meta.data),
    .m_axis_tx_data_TVALID        (axis_tcp_send.tvalid),
    .m_axis_tx_data_TREADY        (axis_tcp_send.tready),
    .m_axis_tx_data_TDATA         (axis_tcp_send.tdata),
    .m_axis_tx_data_TKEEP         (axis_tcp_send.tkeep),
    .m_axis_tx_data_TLAST         (axis_tcp_send.tlast),
    .s_axis_tx_status_TVALID      (tcp_tx_stat.valid),
    .s_axis_tx_status_TREADY      (tcp_tx_stat.ready),
    .s_axis_tx_status_TDATA       (tcp_tx_stat.data)
);

// strip_http inside HTTPRead does not yet stream into OutputWriter
always_comb axi_out[BYPASS_ID].tie_off_m();
`elsif EN_RDMA
AXI4S axi_in (.aclk(clk), .aresetn(rst_n));
ndata_i #(data8_t, DATABEAT_SIZE) bypass_ndata();

`AXIS_ASSIGN(axis_rreq_recv[BYPASS_ID], axi_in)

RDMARead #(
    .AXI_STRM_ID(BYPASS_ID),
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_rdma_read_bypass (
    .clk(clk),
    .rst_n(rst_n),

    .sq_rd(sq_rd_strm[BYPASS_ID]),
    .cq_rd(cq_rd_strm[BYPASS_ID]),

    .conf(rdma_conf[BYPASS_ID]),

    .in(axi_in),
    .out(bypass_ndata)
);

NDataToAXI #(data8_t, DATABEAT_SIZE) inst_ndata_to_axi_bypass (
    .clk(clk),
    .rst_n(rst_n),

    .in(bypass_ndata),
    .out(axi_out[BYPASS_ID])
);
`else
always_comb axi_out[BYPASS_ID].tie_off_m();
`endif

// -- Output writer --------------------------------------------------------------------------------
OutputWriter inst_output_writer (
    .clk(clk),
    .rst_n(rst_n),

    .sq_wr(sq_wr),
    .cq_wr(cq_wr),
    .notify(notify),

    .mem_config(mem_conf),

    .data_in(axi_out),
    .data_out(axis_host_send)
);
