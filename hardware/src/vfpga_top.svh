`timescale 1ns / 1ps

import oasis::*;
import parcore::*;
import http_types::*;
import lynxTypes::*;
import libstf::*;

// Decoder lanes on the HTTP path. Each lane owns its own TCP session and its own request stream.
localparam NUM_HTTP_LANES = N_STRM_AXI - 1;

// -- Tie-off unused interfaces and signals --------------------------------------------------------
`ifdef EN_TCP
always_comb sq_rd.tie_off_m();
always_comb cq_rd.tie_off_s();
always_comb rq_wr.tie_off_s();
// The ColumnChunkDecoders are fed by the HTTP stack rather than by host DMA, so the host-recv
// streams carry the REQUEST TEXT instead: the host builds every GET of a query itself and DMAs the
// lot in, instead of writing a descriptor per request for the FPGA to rebuild the text from.
//
// One request stream PER LANE, so only the streams past the lane count are tied off. Sending a
// lane's text to a tied-off stream is silent data loss -- the tie-off holds tready high and
// discards, the DMA reports success, and the armed handler then waits for bytes that no longer
// exist.
for (genvar I = NUM_HTTP_LANES; I < N_STRM_AXI; I++) begin
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
// HttpConfig: parameters 0..38, 40 and 41 with START at 39, 42 registers. Rounded up to the next
// power of two.
localparam HTTP_CONFIG_ADDR_SPACE = 64;
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
// Column chunks queued ahead of the data PER LANE, NOT requests. Alignment is a byte count per
// chunk (axis_rewrite_last), so this scales with columns in a row group -- a handful -- rather than
// with how finely each chunk is split into ranged GETs. The GETs themselves are pipelined over the
// lane's persistent TCP connection, so the GET and the server's think time for request k+1 overlap
// the body transfer of request k. The host reads the depth back through HttpConfig's QUEUE_DEPTH
// register.
localparam int HTTP_QUEUE_DEPTH = 64;

// HttpConfig latches params; a START write emits one http_config_t beat, which the handler takes
// as a per-lane chunk entry or a transfer arm (see http_types.sv). ConfigWriteReadyRegister does not
// back-pressure, so the host polls the lane's admission bits before it writes START.
http_config_t                  http_cfg_live;
ready_valid_i #(http_config_t) http_start();
logic [3:0]                    http_client_state;
logic [31:0]                   http_total_word;
logic [31:0]                   http_inflight_word;
logic [31:0]                   http_queue_depth_word;
logic [31:0]                   http_stall_word;
logic [31:0]                   http_resp_word;
logic [31:0]                   http_content_length_word;
logic [31:0]                   http_body_remaining_word;
// Per-lane readback (read registers 16..20). 64 bits because eight lanes need eight bytes and the
// AXI-Lite data path is 64 wide; see the read map in http_config.sv.
logic [63:0]                   http_lane_occ_word;
logic [63:0]                   http_lane_ready_word;
logic [63:0]                   http_lane_state_word;
logic [63:0]                   http_lane_err_word;
logic [63:0]                   http_lane_policy_word;

// Parameters 0..38, 40 and 41; START at 39 (see http_config.sv).
HttpConfig #(
    .NUM_PARAM_REGS(42),
    .START_ADDR    (39)
) inst_http_config (
    .clk         (clk),
    .rst_n       (rst_n),
    .write_config(write_configs[2]),
    .read_config (read_configs[2]),
    .cfg          (http_cfg_live),
    .start_cfg    (http_start),
    .client_state (http_client_state),
    .total_word   (http_total_word),
    .inflight_word(http_inflight_word),
    .queue_depth_word(http_queue_depth_word),
    .stall_word   (http_stall_word),
    .resp_word           (http_resp_word),
    .content_length_word (http_content_length_word),
    .body_remaining_word (http_body_remaining_word),
    .lane_occ_word       (http_lane_occ_word),
    .lane_ready_word     (http_lane_ready_word),
    .lane_state_word     (http_lane_state_word),
    .lane_err_word       (http_lane_err_word),
    .lane_policy_word    (http_lane_policy_word)
);
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
// EN_TCP feeds its NUM_DECODERS ColumnChunkDecoders from the HTTP lanes below, so this host-DMA /
// RDMA-fed decoder loop is only built for the non-TCP modes.
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

// -- Bypass stream (last stream, no decoder) ------------------------------------------------------
localparam BYPASS_ID = NUM_STREAMS - 1;

`ifdef EN_TCP
// Listen is unused; open/close are driven by the handler.
always_comb tcp_listen_req.tie_off_m();
always_comb tcp_listen_rsp.tie_off_s();

// Stripped HTTP body (unaligned keep) → DataNormalizer → ColumnChunkDecoder, per lane.
// ENABLE_COMPACTOR(0): barrel-shift + beat merge only (lighter than COMPACTOR=1).
// -------------------------------------------------------------------------------------------------
// N TCP sessions, one per decoder lane.
//
// The demux sits in the receive path (rx_dispatch), not after one shared framer: each lane owns a
// session, a decoupling fifo and a framer, and the dispatcher decides whether to ASK for a packet
// rather than whether to accept one, so a lane busy on a large chunk does not back-pressure the
// others. See hdl/http_read/handler_multi.sv and unit-tests/{lane_drain,handler_multi}.
//
// One TCP connection to MinIO is a throughput ceiling however deeply its GETs are pipelined; the
// sessions together are what reach the decoders' rate.
// -------------------------------------------------------------------------------------------------
logic [NUM_DECODERS-1:0]       hm_body_tvalid, hm_body_tready, hm_body_tlast;
logic [AXI_DATA_BITS-1:0]      hm_body_tdata [NUM_DECODERS];
logic [AXI_DATA_BITS/8-1:0]    hm_body_tkeep [NUM_DECODERS];

logic [NUM_DECODERS-1:0]       hm_req_tvalid, hm_req_tready, hm_req_tlast;
logic [AXI_DATA_BITS-1:0]      hm_req_tdata [NUM_DECODERS];
logic [AXI_DATA_BITS/8-1:0]    hm_req_tkeep [NUM_DECODERS];

for (genvar L = 0; L < NUM_DECODERS; L++) begin : gen_hm_req
    assign hm_req_tvalid[L]        = axis_host_recv[L].tvalid;
    assign axis_host_recv[L].tready = hm_req_tready[L];
    assign hm_req_tdata[L]         = axis_host_recv[L].tdata;
    assign hm_req_tkeep[L]         = axis_host_recv[L].tkeep;
    assign hm_req_tlast[L]         = axis_host_recv[L].tlast;
end

handler_multi #(
    .NUM_CONNS    (NUM_DECODERS),
    .QUEUE_DEPTH  (HTTP_QUEUE_DEPTH),
    // Per lane. rx_dispatch gates each lane on room for one MSS, so this only absorbs decoder
    // jitter, not a whole response. 2048 x 64 B = 128 KiB = 36 RAMB36.
    .RX_FIFO_DEPTH(2048)
) inst_handler (
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

    .s_axis_notifications_TVALID(tcp_notify.valid),
    .s_axis_notifications_TREADY(tcp_notify.ready),
    .s_axis_notifications_TDATA (tcp_notify.data),
    .m_axis_read_package_TVALID (tcp_rd_pkg.valid),
    .m_axis_read_package_TREADY (tcp_rd_pkg.ready),
    .m_axis_read_package_TDATA  (tcp_rd_pkg.data),
    .s_axis_rx_metadata_TVALID  (tcp_rx_meta.valid),
    .s_axis_rx_metadata_TREADY  (tcp_rx_meta.ready),
    .s_axis_rx_metadata_TDATA   (tcp_rx_meta.data[TCP_RX_META_BITS-1:0]),
    .s_axis_rx_data_TVALID      (axis_tcp_recv.tvalid),
    .s_axis_rx_data_TREADY      (axis_tcp_recv.tready),
    .s_axis_rx_data_TDATA       (axis_tcp_recv.tdata),
    .s_axis_rx_data_TKEEP       (axis_tcp_recv.tkeep),
    .s_axis_rx_data_TLAST       (axis_tcp_recv.tlast),

    .m_axis_tx_meta_TVALID  (tcp_tx_meta.valid),
    .m_axis_tx_meta_TREADY  (tcp_tx_meta.ready),
    .m_axis_tx_meta_TDATA   (tcp_tx_meta.data),
    .m_axis_tx_data_TVALID  (axis_tcp_send.tvalid),
    .m_axis_tx_data_TREADY  (axis_tcp_send.tready),
    .m_axis_tx_data_TDATA   (axis_tcp_send.tdata),
    .m_axis_tx_data_TKEEP   (axis_tcp_send.tkeep),
    .m_axis_tx_data_TLAST   (axis_tcp_send.tlast),
    .s_axis_tx_status_TVALID(tcp_tx_stat.valid),
    .s_axis_tx_status_TREADY(tcp_tx_stat.ready),
    .s_axis_tx_status_TDATA (tcp_tx_stat.data),

    .req_valid(http_start.valid),
    .req_ready(http_start.ready),
    .req_data (http_start.data),

    .s_axis_req_TVALID(hm_req_tvalid), .s_axis_req_TREADY(hm_req_tready),
    .s_axis_req_TDATA (hm_req_tdata),  .s_axis_req_TKEEP (hm_req_tkeep),
    .s_axis_req_TLAST (hm_req_tlast),

    .m_axis_body_tvalid(hm_body_tvalid), .m_axis_body_tready(hm_body_tready),
    .m_axis_body_tdata (hm_body_tdata),  .m_axis_body_tkeep (hm_body_tkeep),
    .m_axis_body_tlast (hm_body_tlast),

    .totalWord        (http_total_word),
    .inflightWord     (http_inflight_word),
    .queueDepthWord   (http_queue_depth_word),
    .stallWord        (http_stall_word),
    .respWord         (http_resp_word),
    .contentLengthWord(http_content_length_word),
    .bodyRemainingWord(http_body_remaining_word),
    .state_debug      (http_client_state),

    .laneOccWord      (http_lane_occ_word),
    .laneReadyWord    (http_lane_ready_word),
    .laneStateWord    (http_lane_state_word),
    .laneErrWord      (http_lane_err_word),
    .lanePolicyWord   (http_lane_policy_word)
);

// Each lane is already its own stream -- there is nothing left to select.
AXI4S axi_http_lane [NUM_DECODERS] (.aclk(clk), .aresetn(rst_n));

for (genvar L = 0; L < NUM_DECODERS; L++) begin : gen_hm_lane
    assign axi_http_lane[L].tvalid = hm_body_tvalid[L];
    assign axi_http_lane[L].tdata  = hm_body_tdata[L];
    assign axi_http_lane[L].tkeep  = hm_body_tkeep[L];
    assign axi_http_lane[L].tlast  = hm_body_tlast[L];
    assign hm_body_tready[L]       = axi_http_lane[L].tready;
end

for (genvar L = 0; L < NUM_DECODERS; L++) begin : gen_http_decoders
    ndata_i       #(data8_t, DATABEAT_SIZE) lane_ndata();
    ndata_i       #(data8_t, DATABEAT_SIZE) lane_norm();
    typed_ndata_i #(DATABEAT_SIZE)          lane_typed();
    ndata_i       #(data8_t, DATABEAT_SIZE) lane_decoded();

    AXIToNData #(data8_t, DATABEAT_SIZE) inst_axi_to_ndata (
        .clk(clk), .rst_n(rst_n), .in(axi_http_lane[L]), .out(lane_ndata)
    );

    DataNormalizer #(
        .data_t(data8_t), .NUM_ELEMENTS(DATABEAT_SIZE), .ENABLE_COMPACTOR(0)
    ) inst_normalizer (
        .clk(clk), .rst_n(rst_n), .in(lane_ndata), .out(lane_norm)
    );

    ColumnChunkDecoder #(
        .DATABEAT_SIZE(DATABEAT_SIZE)
    ) inst_decoder (
        .clk(clk), .rst_n(rst_n),
        .conf(column_chunk_conf[L]), .profile(profile[L]),
        .in(lane_norm), .out(lane_typed)
    );

    `DATA_ASSIGN(lane_typed, lane_decoded);

    NDataToAXI #(data8_t, DATABEAT_SIZE) inst_ndata_to_axi (
        .clk(clk), .rst_n(rst_n), .in(lane_decoded), .out(axi_out[L])
    );
end

// No traffic on the bypass output stream in HTTP mode.
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
