`timescale 1ns / 1ps

import oasis::*;
import parcore::*;
import http_types::*;
import lynxTypes::*;
import libstf::*;

`include "oasis_defines.svh"

// Decoder lanes on the HTTP path. With EN_TCP_MULTI each lane also owns its own TCP session and its
// own request stream; without it there is one session feeding all lanes through a shared framer.
localparam NUM_HTTP_LANES = N_STRM_AXI - 1;

// -- Tie-off unused interfaces and signals --------------------------------------------------------
`ifdef EN_TCP
always_comb sq_rd.tie_off_m();
always_comb cq_rd.tie_off_s();
always_comb rq_wr.tie_off_s();
// handler_stream.sv opens/closes TCP itself (legacy Coyote-http style).
//
// The ColumnChunkDecoder is fed by the HTTP stack rather than by host DMA, so the host-recv streams
// used to be unused. Stream 0 now carries the REQUEST TEXT: the host builds every GET of a query
// itself and DMAs the lot in, instead of writing a descriptor per request for the FPGA to rebuild
// the text from. That is what removes the queue-depth limit -- see handler_stream.sv.
//
// EN_TCP_MULTI takes one request stream PER LANE (handler_multi), so only the streams past the
// lane count are tied off. Sending a lane's text to a tied-off stream is silent data loss -- the
// tie-off holds tready high and discards, the DMA reports success, and the armed handler then waits
// for bytes that no longer exist. That exact mistake cost a 30 s timeout, a dirty_abort and a
// collapsed receive window; see the comment on req_dest in software/oasis/operator.cpp.
`ifdef EN_TCP_MULTI
for (genvar I = NUM_HTTP_LANES; I < N_STRM_AXI; I++) begin
    always_comb axis_host_recv[I].tie_off_s();
end
`else
for (genvar I = 1; I < N_STRM_AXI; I++) begin
    always_comb axis_host_recv[I].tie_off_s();
end
`endif
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
// HttpConfig: 39 param regs + START at 39, so 40 in use. The GET path takes 16 of them (64
// characters); with 8 words this fit in exactly 32. Rounded up to the next power of two.
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
// Requests in flight in the HTTP client. Each slot is one queued ranged GET, PIPELINED over the
// single persistent TCP connection the handler holds open -- so the GET and the server's think time
// for request k+1 overlap the body transfer of request k instead of following it. Slots no longer
// cost a TCP session: one connection serves all of them, which is what makes pipelining safe on a
// TOE whose receive path does not demultiplex sessions (see handler.sv). The host must not enqueue
// more than this many outstanding requests; it reads the ring occupancy back through HttpConfig's
// INFLIGHT register, and software/oasis mirrors this number.
// Responses that may be outstanding. One BIT each in handler_stream (body_last), not a 1160-bit
// descriptor, so this is no longer a resource decision -- 512 entries cost 512 bits.
// Column chunks queued ahead of the data, NOT requests. Alignment is a byte count per chunk
// (axis_rewrite_last), so this scales with columns in a row group -- a handful -- rather than with
// how finely each chunk is split into ranged GETs.
localparam int HTTP_QUEUE_DEPTH = 64;

// HttpConfig latches params; a START write emits one http_config_t beat, which the handler accepts
// straight into a free slot. The slot ring IS the request queue, so there is no separate FIFO and
// no runTx pulse any more -- the old one-cycle pulse was sampled only in ST_IDLE and was silently
// dropped if it arrived mid-transfer, which is exactly the wedge this replaces.
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
// Per-lane readback (CSR revision 2, read registers 16..20). 64 bits because eight lanes need eight
// bytes and the AXI-Lite data path is 64 wide; see the read map in http_config.sv.
logic [63:0]                   http_lane_occ_word;
logic [63:0]                   http_lane_ready_word;
logic [63:0]                   http_lane_state_word;
logic [63:0]                   http_lane_err_word;
logic [63:0]                   http_lane_policy_word;

// 39 param regs (0..38) with START at 39. These were left at 31/31 when the GET path widened from
// 8 to 16 words, which put START on top of RANGE_BEGIN_W1: writing that parameter fired the request
// mid-configuration, so registers 32..38 -- the rest of the Range begin and all of the Range end --
// never reached the snapshot and the FPGA sent "Range: bytes=<truncated>-" with no end at all.
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

// The streamed handler has no request BUILDER, so the probes that watched it building a GET have
// nothing to watch. Tied off rather than deleted: they are ILA probe indices, and renumbering an
// ILA invalidates every saved waveform layout and every note that refers to a probe by number.
always_comb begin
    dbg_rx_ptr        = '0;
    dbg_rx_buf_0      = '0;
    dbg_rx_buf_1      = '0;
    dbg_tx_acc        = '0;
    dbg_tx_acc_cnt    = '0;
    dbg_tx_acc_last   = 1'b0;
    dbg_http_len      = '0;
    dbg_builder_state = '0;
    dbg_req_lo        = '0;
    dbg_req_hi        = '0;
    dbg_req_cnt       = '0;
end

// Stripped HTTP body (unaligned keep) → DataNormalizer → OutputWriter bypass.
// ENABLE_COMPACTOR(0): barrel-shift + beat merge only (lighter than COMPACTOR=1).
`ifdef EN_TCP_MULTI
// -------------------------------------------------------------------------------------------------
// N TCP sessions, one per decoder lane.
//
// The single-session arrangement below demuxes AFTER the framer, on one shared body stream, so a
// lane busy on a large chunk back-pressures every other lane. handler_multi moves the demux up into
// the receive path (rx_dispatch): each lane owns a session, a decoupling fifo and a framer, and the
// dispatcher decides whether to ASK for a packet rather than whether to accept one. See
// hdl/http_read/handler_multi.sv and unit-tests/{http_multilane,handler_multi}.
//
// One connection is still the throughput ceiling being escaped here: measured against MinIO, one
// TCP session delivers ~0.46 GB/s however deeply pipelined and sixteen deliver 4.60, with the FPGA
// at 0.33.
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
    // Per lane, and it no longer has to hold a whole response -- rx_dispatch gates each lane on
    // room for one MSS, so this only absorbs decoder jitter. 2048 x 64 B = 128 KiB = 36 RAMB36,
    // so four lanes cost the 144 RAMB36 that the single-lane 8192-deep fifo used on its own.
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

`else
// The single-session HTTP path (handler_stream + tcp_session_table) is gone. It demuxed AFTER the
// framer on one shared body stream, so a lane busy on a large chunk back-pressured every other
// lane; and the measured ceiling of a single TCP connection -- ~0.46 GB/s however deeply pipelined,
// against 4.60 across sixteen -- made one session the wrong shape no matter how the demux behaved.
//
// ENABLE_HTTP_MULTI survives as a CMake option, so this branch is still reachable by configuration.
// Failing here, at elaboration, is the point: without it the build dies much later with an
// unresolved handler_stream module, which reads like a missing file rather than a retired mode.
if (1) $error("ENABLE_HTTP without ENABLE_HTTP_MULTI: the single-session HTTP path was removed -- reconfigure with -DENABLE_HTTP_MULTI=ON");

`endif

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

// Raw bypass removed — nothing flows to the bypass output slot now.
always_comb axi_out[BYPASS_ID].tie_off_m();



// Performance ILA. OFF by default -- see ENABLE_PERF_ILA in hardware/CMakeLists.txt.
//
// 42 probes, several of them 512 bits wide, costing ~13.2k LUTs and ~114.5 BRAM of pure debug logic
// in the user region. That is affordable at one or two decoder lanes and is not at four: build-110
// (4 lanes, ILA in) missed timing at WNS -7.43 ns, and the congested clusters were HBM shell nets
// and the decoder -- the HTTP logic never appeared in the failing paths. Freeing this area is the
// first lever for closing a 4-lane build, so the probes have to be opt-in rather than always paid.
//
// Turn it back on with `scripts/synthesize.sh --perf-ila` when a receive-path fault needs the wire
// view. The probe map is unchanged, so an existing .ltx still matches.
`ifdef EN_PERF_ILA
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
`endif // EN_PERF_ILA

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
