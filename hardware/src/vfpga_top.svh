`timescale 1ns / 1ps

import oasis::*;
import parcore::*;
import http_types::*;
import lynxTypes::*;
import libstf::*;

// -- Tie-off unused interfaces and signals --------------------------------------------------------
`ifdef EN_TCP
always_comb sq_rd.tie_off_m();
always_comb cq_rd.tie_off_s();
always_comb rq_wr.tie_off_s();
// handler.sv opens/closes TCP itself (legacy Coyote-http style).
// The ColumnChunkDecoder is now fed by the HTTP stack (not host DMA), so the host-recv streams are unused.
for (genvar I = 0; I < N_STRM_AXI; I++) begin
    always_comb axis_host_recv[I].tie_off_s();
end
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
// HttpConfig: 31 param regs + START; read side has 3 status regs.
localparam HTTP_CONFIG_ADDR_SPACE = 32;
localparam NUM_CONFIGS   = 3;
localparam NUM_DECODERS  = NUM_STREAMS - 1;
`elsif EN_RDMA
localparam NUM_CONFIGS   = 3;
localparam NUM_DECODERS  = NUM_STREAMS - 1;
`else
localparam NUM_CONFIGS   = 2;
localparam NUM_DECODERS  = NUM_STREAMS;
`endif

// -- Fix clock and reset names --------------------------------------------------------------------
logic clk;
logic rst_n;

assign clk   = aclk;
assign rst_n = aresetn;

// -- Configuration --------------------------------------------------------------------------------
write_config_i                       write_configs[NUM_CONFIGS](.*);
read_config_i                        read_configs [NUM_CONFIGS](.*);
mem_config_i                         mem_conf[NUM_STREAMS](.*);
`ifdef EN_RDMA
rdma_read_config_i                   rdma_conf[NUM_STREAMS](.*);
`endif
decoder_profile_i                    profile[NUM_DECODERS](.*);
ready_valid_i #(column_chunk_conf_t) column_chunk_conf[NUM_DECODERS](.*);

GlobalConfig #(
    .SYSTEM_ID(OASIS_SYSTEM_ID),
    .NUM_CONFIGS(NUM_CONFIGS),
    .ADDR_SPACE_SIZES({
        MEM_CONFIG_NUM_REGS,
        COLUMN_CHUNK_DECODER_READ_REGS(NUM_DECODERS)
`ifdef EN_TCP
        , HTTP_CONFIG_ADDR_SPACE
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

    .out(column_chunk_conf),
    .profile(profile)
);

`ifdef EN_TCP
// HttpConfig latches params; START write emits one http_config_t beat → runTx pulse.
http_config_t                  http_cfg_live;
ready_valid_i #(http_config_t) http_start();
logic [3:0]                    http_client_state;
logic [31:0]                   http_total_word;
http_config_t                  http_cfg_q;
logic                          http_run_tx;

HttpConfig #(
    .NUM_PARAM_REGS(31),
    .START_ADDR    (31)
) inst_http_config (
    .clk         (clk),
    .rst_n       (rst_n),
    .write_config(write_configs[2]),
    .read_config (read_configs[2]),
    .cfg         (http_cfg_live),
    .start_cfg   (http_start),
    .client_state(http_client_state),
    .total_word  (http_total_word)
);

assign http_start.ready = 1'b1;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        http_cfg_q  <= '0;
        http_run_tx <= 1'b0;
    end else if (http_start.valid && http_start.ready) begin
        http_cfg_q  <= http_start.data;
        http_run_tx <= 1'b1;
    end else begin
        http_run_tx <= 1'b0;
    end
end
`elsif EN_RDMA
RDMAReadConfig #(
    .NUM_STREAMS(NUM_STREAMS)
) inst_rdma_read_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[2]),
    .read_config(read_configs[2]),

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
// EN_TCP feeds its single ColumnChunkDecoder from the HTTP stack below (mirrors the RDMA decoder
// path), so this host-DMA / RDMA-fed decoder loop is only built for the non-TCP modes.
`ifndef EN_TCP
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

        .conf(column_chunk_conf[I]),
        .profile(profile[I]),

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
`endif

// -- Bypass stream (last slot, no decoder) --------------------------------------------------------
localparam BYPASS_ID = NUM_STREAMS - 1;

`ifdef EN_TCP
// Open/listen/close are Coyote user ports again (restored in user_logic_tmplt).
// Listen unused for the HTTP client; open/close driven by handler.
always_comb tcp_listen_req.tie_off_m();
always_comb tcp_listen_rsp.tie_off_s();

logic [3:0]   dbg_rx_ptr;
logic [AXI_DATA_BITS-1:0] dbg_rx_buf_0, dbg_rx_buf_1, dbg_tx_acc;
logic [6:0]   dbg_tx_acc_cnt;
logic         dbg_tx_acc_last;
logic [15:0]  dbg_http_len;
logic [3:0]   dbg_builder_state;
logic [AXI_DATA_BITS-1:0] dbg_req_lo, dbg_req_hi;
logic [7:0]   dbg_req_cnt;

// Stripped HTTP body (unaligned keep) → DataNormalizer → OutputWriter bypass.
// ENABLE_COMPACTOR(0): barrel-shift + beat merge only (lighter than COMPACTOR=1).
AXI4S axi_http_body (.aclk(clk), .aresetn(rst_n));
ndata_i #(data8_t, DATABEAT_SIZE) http_body_ndata();
ndata_i #(data8_t, DATABEAT_SIZE) http_body_norm();

handler inst_handler (
    .ap_clk  (clk),
    .ap_rst_n(rst_n),

    .m_axis_open_connection_TVALID (tcp_open_req.valid),
    .m_axis_open_connection_TREADY (tcp_open_req.ready),
    .m_axis_open_connection_TDATA  (tcp_open_req.data),
    .s_axis_open_status_TVALID     (tcp_open_rsp.valid),
    .s_axis_open_status_TREADY     (tcp_open_rsp.ready),
    .s_axis_open_status_TDATA      (tcp_open_rsp.data),
    .m_axis_close_connection_TVALID(tcp_close_req.valid),
    .m_axis_close_connection_TREADY(tcp_close_req.ready),
    .m_axis_close_connection_TDATA (tcp_close_req.data),

    .s_axis_notifications_TVALID   (tcp_notify.valid),
    .s_axis_notifications_TREADY   (tcp_notify.ready),
    .s_axis_notifications_TDATA    (tcp_notify.data),
    .m_axis_read_package_TVALID    (tcp_rd_pkg.valid),
    .m_axis_read_package_TREADY    (tcp_rd_pkg.ready),
    .m_axis_read_package_TDATA     (tcp_rd_pkg.data),
    .s_axis_rx_metadata_TVALID     (tcp_rx_meta.valid),
    .s_axis_rx_metadata_TREADY     (tcp_rx_meta.ready),
    .s_axis_rx_metadata_TDATA      (tcp_rx_meta.data[TCP_RX_META_BITS-1:0]),
    .s_axis_rx_data_TVALID         (axis_tcp_recv.tvalid),
    .s_axis_rx_data_TREADY         (axis_tcp_recv.tready),
    .s_axis_rx_data_TDATA          (axis_tcp_recv.tdata),
    .s_axis_rx_data_TKEEP          (axis_tcp_recv.tkeep),
    .s_axis_rx_data_TLAST          (axis_tcp_recv.tlast),
    .s_axis_rx_data_TSTRB          ('0),

    .m_axis_tx_meta_TVALID         (tcp_tx_meta.valid),
    .m_axis_tx_meta_TREADY         (tcp_tx_meta.ready),
    .m_axis_tx_meta_TDATA          (tcp_tx_meta.data),
    .m_axis_tx_data_TVALID         (axis_tcp_send.tvalid),
    .m_axis_tx_data_TREADY         (axis_tcp_send.tready),
    .m_axis_tx_data_TDATA          (axis_tcp_send.tdata),
    .m_axis_tx_data_TKEEP          (axis_tcp_send.tkeep),
    .m_axis_tx_data_TLAST          (axis_tcp_send.tlast),
    .s_axis_tx_status_TVALID       (tcp_tx_stat.valid),
    .s_axis_tx_status_TREADY       (tcp_tx_stat.ready),
    .s_axis_tx_status_TDATA        (tcp_tx_stat.data),

    .runTx                         (http_run_tx),
    .numSessions                   (http_cfg_q.num_sessions),
    .pkgWordCount                  (http_cfg_q.pkg_word_count),
    .serverIpAddress               (http_cfg_q.server_ip),
    .ipHexLen                      (http_cfg_q.ip_hex_len),
    .ipHexWord0                    (http_cfg_q.ip_hex_w0),
    .ipHexWord1                    (http_cfg_q.ip_hex_w1),
    .ipHexWord2                    (http_cfg_q.ip_hex_w2),
    .ipHexWord3                    (http_cfg_q.ip_hex_w3),
    .portHexWord0                  (http_cfg_q.port_hex),
    .serverPort                    (http_cfg_q.server_port),
    .fileLen                       (http_cfg_q.file_len),
    .fileWord0                     (http_cfg_q.file_w0),
    .fileWord1                     (http_cfg_q.file_w1),
    .fileWord2                     (http_cfg_q.file_w2),
    .fileWord3                     (http_cfg_q.file_w3),
    .fileWord4                     (http_cfg_q.file_w4),
    .fileWord5                     (http_cfg_q.file_w5),
    .fileWord6                     (http_cfg_q.file_w6),
    .fileWord7                     (http_cfg_q.file_w7),
    .rangeBeginLen                 (http_cfg_q.range_begin_len),
    .rangeBeginW0                  (http_cfg_q.range_begin_w0),
    .rangeBeginW1                  (http_cfg_q.range_begin_w1),
    .rangeBeginW2                  (http_cfg_q.range_begin_w2),
    .rangeBeginW3                  (http_cfg_q.range_begin_w3),
    .rangeEndLen                   (http_cfg_q.range_end_len),
    .rangeEndW0                    (http_cfg_q.range_end_w0),
    .rangeEndW1                    (http_cfg_q.range_end_w1),
    .rangeEndW2                    (http_cfg_q.range_end_w2),
    .rangeEndW3                    (http_cfg_q.range_end_w3),
    .userFrequency                 (http_cfg_q.user_frequency),
    .timeInSeconds                 (http_cfg_q.time_in_seconds),
    .totalWord                     (http_total_word),
    .state_debug                   (http_client_state),

    .m_axis_body_tvalid  (axi_http_body.tvalid),
    .m_axis_body_tready  (axi_http_body.tready),
    .m_axis_body_tdata   (axi_http_body.tdata),
    .m_axis_body_tkeep   (axi_http_body.tkeep),
    .m_axis_body_tlast   (axi_http_body.tlast),

    .debug_rx_write_ptr  (dbg_rx_ptr),
    .debug_rx_buffer_w0  (dbg_rx_buf_0),
    .debug_rx_buffer_w1  (dbg_rx_buf_1),
    .debug_tx_acc        (dbg_tx_acc),
    .debug_tx_acc_cnt    (dbg_tx_acc_cnt),
    .debug_tx_acc_last   (dbg_tx_acc_last),
    .debug_http_len      (dbg_http_len),
    .debug_builder_state (dbg_builder_state),
    .debug_req_lo        (dbg_req_lo),
    .debug_req_hi        (dbg_req_hi),
    .debug_req_cnt       (dbg_req_cnt)
);

AXIToNData #(data8_t, DATABEAT_SIZE) inst_http_axi_to_ndata (
    .clk(clk),
    .rst_n(rst_n),

    .in(axi_http_body),
    .out(http_body_ndata)
);

DataNormalizer #(
    .data_t(data8_t),
    .NUM_ELEMENTS(DATABEAT_SIZE),
    .ENABLE_COMPACTOR(0)
) inst_http_body_normalizer (
    .clk(clk),
    .rst_n(rst_n),

    .in(http_body_ndata),
    .out(http_body_norm)
);

// Mirror the RDMA decoder path: HTTP-fetched raw column-chunk bytes → ColumnChunkDecoder → axi_out[0].
// The raw bypass is replaced entirely; the host reads DECODED output from stream 0 (like the RDMA
// oasis_scan flow). column_chunk_conf[0]/profile[0] are the same config slots the RDMA decoder used.
typed_ndata_i #(DATABEAT_SIZE)          http_typed_out();
ndata_i       #(data8_t, DATABEAT_SIZE) http_decoded();

ColumnChunkDecoder #(
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_http_column_chunk_decoder (
    .clk(clk),
    .rst_n(rst_n),

    .conf(column_chunk_conf[0]),
    .profile(profile[0]),

    .in(http_body_norm),
    .out(http_typed_out)
);

`DATA_ASSIGN(http_typed_out, http_decoded);

NDataToAXI #(data8_t, DATABEAT_SIZE) inst_http_ndata_to_axi (
    .clk(clk),
    .rst_n(rst_n),

    .in(http_decoded),
    .out(axi_out[0])
);

// Raw bypass removed — nothing flows to the bypass output slot now.
always_comb axi_out[BYPASS_ID].tie_off_m();



ila_perf_tcp inst_ila_perf_tcp (
    .clk(aclk),
    .probe0  (tcp_open_req.valid),
    .probe1  (tcp_open_req.ready),
    .probe2  (tcp_open_req.data),
    .probe3  (tcp_open_rsp.valid),
    .probe4  (tcp_open_rsp.ready),
    .probe5  (tcp_open_rsp.data),
    .probe6  (tcp_close_req.valid),
    .probe7  (tcp_close_req.ready),
    .probe8  (tcp_close_req.data),
    .probe9  (tcp_rx_meta.valid),
    .probe10 (tcp_rx_meta.ready),
    .probe11 (tcp_rx_meta.data),
    .probe12 (tcp_notify.valid),
    .probe13 (tcp_notify.ready),
    .probe14 (tcp_notify.data),
    .probe15 (axis_tcp_recv.tvalid),
    .probe16 (axis_tcp_recv.tready),
    .probe17 (axis_tcp_recv.tdata),
    .probe18 (axis_tcp_recv.tlast),
    .probe19 (http_client_state),
    .probe20 (dbg_rx_ptr),
    .probe21 (dbg_rx_buf_0),
    .probe22 (dbg_rx_buf_1),
    .probe23 (tcp_tx_meta.valid),
    .probe24 (tcp_tx_meta.ready),
    .probe25 (tcp_tx_meta.data),
    .probe26 (tcp_tx_stat.valid),
    .probe27 (tcp_tx_stat.ready),
    .probe28 (tcp_tx_stat.data),
    .probe29 (axis_tcp_send.tvalid),
    .probe30 (axis_tcp_send.tready),
    .probe31 (axis_tcp_send.tdata),
    .probe32 (axis_tcp_send.tkeep),
    .probe33 (axis_tcp_send.tlast),
    .probe34 (dbg_tx_acc),
    .probe35 (dbg_tx_acc_cnt),
    .probe36 (dbg_tx_acc_last),
    .probe37 (dbg_http_len),
    .probe38 (dbg_builder_state),
    .probe39 (dbg_req_lo),
    .probe40 (dbg_req_hi),
    .probe41 (dbg_req_cnt)
);

//always_comb axi_out[BYPASS_ID].tie_off_m();
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
