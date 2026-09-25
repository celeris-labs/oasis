`timescale 1ns / 1ps

import oasis::*;
import parcore::*;
import libstf::*;
import common::*;

// -- Tie-off unused interfaces and signals --------------------------------------------------------
always_comb cq_rd.tie_off_s();

`ifdef EN_RDMA
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
`endif

localparam NUM_STREAMS        = N_STRM_AXI;
localparam DATABEAT_SIZE      = AXI_DATA_BITS / 8;
// MemConfig write side needs NUM_STREAMS+1 regs, read side needs 3 (ID, num_streams, max_enqueued).
localparam MEM_CONFIG_NUM_REGS = (NUM_STREAMS + 1 > 3) ? NUM_STREAMS + 1 : 3;

localparam NUM_CONFIGS   = 6;
`ifdef EN_RDMA
localparam NUM_DECODERS  = NUM_STREAMS - 1;
`else
localparam NUM_DECODERS  = NUM_STREAMS;
`endif

// BFConfig (the Bloom filter's per-chunk materialization and input commands) + a 1-stream
// StreamConfig selecting per flow where decoder-stream 0's output goes (see the Bloom filter
// section below).
localparam STREAM_CFG_REGS = 2;

// -- Fix clock and reset names --------------------------------------------------------------------
logic clk;
logic rst_n;

assign clk   = aclk;
assign rst_n = aresetn;

// -- Configuration --------------------------------------------------------------------------------
write_config_i                       write_configs[NUM_CONFIGS](.*);
read_config_i                        read_configs [NUM_CONFIGS](.*);
mem_config_i                         mem_conf[NUM_STREAMS](.*);
ready_valid_i #(read_req_t)          read_conf[NUM_STREAMS](.*);
logic [PID_BITS-1:0]                 read_ctid[NUM_STREAMS];
ready_valid_i #(column_chunk_conf_t) column_chunk_conf[NUM_DECODERS](.*);
decoder_profile_i                    decoder_profiles[NUM_DECODERS]();
bloomfilter_config_i                 bloomfilter_conf();
stream_config_i                      bf_stream_conf[1](.*);

GlobalConfig #(
    .SYSTEM_ID(OASIS_SYSTEM_ID),
    .NUM_CONFIGS(NUM_CONFIGS),
    .ADDR_SPACE_SIZES({
        MEM_CONFIG_NUM_REGS,
        COLUMN_CHUNK_DECODER_READ_REGS(NUM_DECODERS),
        NUM_READ_REQ_CONFIG_REGS * NUM_STREAMS,
        BLOOMFILTER_NUM_CONFIG_REGS,
        STREAM_CFG_REGS,
        NUM_BF_LAST_INJECT_CONFIG_REGS
    }),
    .READ_CONFIG_SKID_DEPTH(2)
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

    .profile(decoder_profiles)
);

ReadReqConfig #(
    .NUM_STREAMS(NUM_STREAMS)
) inst_read_req_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[2]),
    .read_config(read_configs[2]),

    .out(read_conf),
    .ctid(read_ctid)
);

bloomfilter_perf_counters_t bf_perf_counters;
BFConfig inst_bf_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[3]),
    .read_config(read_configs[3]),

    .out(bloomfilter_conf),

    .perf_counters(bf_perf_counters)
);

StreamConfig #(
    .NUM_STREAMS(1)
) inst_bf_stream_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[4]),
    .read_config(read_configs[4]),

    .out(bf_stream_conf)
);

logic        bf_last_inject_enable;
logic [31:0] bf_last_inject_first_beat;
logic [31:0] bf_last_inject_second_beat;
BFLastInjectorConfig inst_bf_last_injector_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[5]),
    .read_config(read_configs[5]),

    .enable(bf_last_inject_enable),
    .first_beat(bf_last_inject_first_beat),
    .second_beat(bf_last_inject_second_beat)
);

// -- Arbiter the read send queue ------------------------------------------------------------------
metaIntf #(.STYPE(req_t)) sq_rd_strm [NUM_STREAMS](.aclk(clk), .aresetn(rst_n));

MetaIntfArbiter #(
    .N_INTERFACES(NUM_STREAMS),
    .STYPE(req_t)
) inst_sq_wr_arbiter (
    .clk(clk),
    .rst_n(rst_n),

    .intf_in(sq_rd_strm),
    .intf_out(sq_rd)
);

// -- Data path ------------------------------------------------------------------------------------
AXI4S axi_out[NUM_STREAMS](.aclk(clk), .aresetn(rst_n));
AXI4S decoded_axi[NUM_DECODERS](.aclk(clk), .aresetn(rst_n));
for (genvar I = 0; I < NUM_DECODERS; I++) begin : gen_decoders
    AXI4S axi_in (.aclk(aclk), .aresetn(aresetn));
    ndata_i       #(data8_t, DATABEAT_SIZE) decoder_in(.*);
    typed_ndata_i #(DATABEAT_SIZE)          typed_out(.*);
    ndata_i       #(data8_t, DATABEAT_SIZE) out(.*);

`ifdef EN_RDMA
    // AXI4SR to AXI4S
    `AXIS_ASSIGN(axis_rreq_recv[I], axi_in)

    RDMARead #(
        .AXI_STRM_ID(I),
        .DATABEAT_SIZE(DATABEAT_SIZE)
    ) inst_rdma_read (
        .clk(clk),
        .rst_n(rst_n),

        .conf(read_conf[I]),
        .ctid(read_ctid[I]),

        .sq_rd(sq_rd_strm[I]),

        .in(axi_in),
        .out(decoder_in)
    );
`else
    // AXI4SR to AXI4S
    `AXIS_ASSIGN(axis_host_recv[I], axi_in)

    LocalRead #(
        .AXI_STRM_ID(I),
        .DATABEAT_SIZE(DATABEAT_SIZE)
    ) inst_local_read (
        .clk(clk),
        .rst_n(rst_n),

        .conf(read_conf[I]),
        .sq_rd(sq_rd_strm[I]),

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

        .in(decoder_in),
        .out(typed_out),

        .profile(decoder_profiles[I])
    );

    // Discard typed
    `DATA_ASSIGN(typed_out, out);

    NDataToAXI #(data8_t, DATABEAT_SIZE) inst_ndata_to_axi (
        .clk(clk),
        .rst_n(rst_n),

        .in(out),
        .out(decoded_axi[I])
    );
end : gen_decoders

// -- Bloom filter on decoder-stream 0 -------------------------------------------------------------
// The stream config's `select` chooses, per flow, where decoder-stream 0's transfer goes. Pushed
// per flow by BloomFilterStreamSelectOperator (oasis_scan.cpp), not configured once here:
//   0 (FILTER): through the Bloom filter as a probe key chunk, yields its mask (axi_bf_mask)
//   1 (BYPASS): around the Bloom filter, yields decoded_axi[0] unchanged (axi_bf_bypass)
//   2 (BUILD):  through the Bloom filter as a build key chunk, yields a one-byte ack (axi_bf_ack)
//   3 (MATERIALIZE): into the Bloom filter's materializer as a column of 64-bit probe values,
//               yields the values of the rows its probe key chunk's mask kept (axi_bf_mat)
// FILTER and BUILD transfers look the same to the Bloom filter: the per-transfer input commands in
// its own config (CONTINUE/END/END_ONLY, pushed with the select) decide the phase. BUILD only
// exists because a build chunk has no output, while every flow needs one output transfer to
// complete (and the multiplexer needs one per select): the ack stands in for it.
// A probe key chunk is followed by the MATERIALIZE transfers of its columns (as many as its
// materialization command in the Bloom filter's config says), before the next probe key chunk.
localparam select_t BF_SELECT_FILTER      = 0;
localparam select_t BF_SELECT_BYPASS      = 1;
localparam select_t BF_SELECT_BUILD       = 2;
localparam select_t BF_SELECT_MATERIALIZE = 3;

// Demultiplexer outputs
localparam select_t BF_DEMUX_KEYS         = 0;
localparam select_t BF_DEMUX_BYPASS       = 1;
localparam select_t BF_DEMUX_PROBE_VALUES = 2;

ready_valid_i #(select_t) bf_select();
ready_valid_i #(select_t) bf_demux_select();
ready_valid_i #(select_t) bf_demux_select_mapped();
ready_valid_i #(select_t) bf_mux_select();

`CONFIG_SIGNALS_TO_INTF(bf_stream_conf[0].select, bf_select)
assign bf_stream_conf[0].data_type_ready = 1'b1; // unused

`READY_DUPLICATE(2, bf_select, {bf_demux_select, bf_mux_select})

// The demultiplexer only has three paths: BUILD goes into the Bloom filter like FILTER
always_comb begin
    case (bf_demux_select.data)
        BF_SELECT_FILTER, BF_SELECT_BUILD: bf_demux_select_mapped.data = BF_DEMUX_KEYS;
        BF_SELECT_MATERIALIZE:             bf_demux_select_mapped.data = BF_DEMUX_PROBE_VALUES;
        default:                           bf_demux_select_mapped.data = BF_DEMUX_BYPASS;
    endcase
end
assign bf_demux_select_mapped.valid = bf_demux_select.valid;
assign bf_demux_select.ready        = bf_demux_select_mapped.ready;

AXI4S axi_bf_in_raw(.aclk(clk), .aresetn(rst_n));
AXI4S axi_bf_in    (.aclk(clk), .aresetn(rst_n));
AXI4S axi_bf_out   (.aclk(clk), .aresetn(rst_n));
AXI4S axi_bf_bypass(.aclk(clk), .aresetn(rst_n));
AXI4S axi_bf_probe_values(.aclk(clk), .aresetn(rst_n));

AXIDemultiplexer #(
    .NUM_STREAMS(3)
) inst_bf_demux (
    .clk(clk),
    .rst_n(rst_n),

    .select(bf_demux_select_mapped),

    .in(decoded_axi[0]),
    .out({axi_bf_in_raw, axi_bf_bypass, axi_bf_probe_values}) // In BF_DEMUX_* order
);

// Build acks: one one-byte transfer (a single zero byte) per BUILD transfer, once its last beat went
// into the Bloom filter (an empty ack would work as well, see the output writer below). The
// demultiplexer takes a select for the whole next transfer, so the select it took last tells whether
// the transfer currently going into the filter is a build chunk.
// The multiplexer picks the acks up in select order, like every other output.
logic        bf_in_is_build;
logic [15:0] bf_pending_acks;
logic        bf_build_done, bf_ack_sent;

AXI4S axi_bf_ack(.aclk(clk), .aresetn(rst_n));
assign axi_bf_ack.tdata  = '0;
assign axi_bf_ack.tkeep  = 1; // One byte
assign axi_bf_ack.tlast  = 1'b1;
assign axi_bf_ack.tvalid = bf_pending_acks != 0;

assign bf_build_done = bf_in_is_build && axi_bf_in_raw.tvalid && axi_bf_in_raw.tready && axi_bf_in_raw.tlast;
assign bf_ack_sent   = axi_bf_ack.tvalid && axi_bf_ack.tready;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        bf_in_is_build  <= 1'b0;
        bf_pending_acks <= '0;
    end else begin
        if (bf_demux_select.valid && bf_demux_select.ready) begin
            bf_in_is_build <= bf_demux_select.data == BF_SELECT_BUILD;
        end
        bf_pending_acks <= bf_pending_acks + bf_build_done - bf_ack_sent;
    end
end

// Inline TLAST injector: software configures the absolute beat index where the build side's
// chunks end (first_beat) and where the probe side's chunks end (second_beat). Every other beat's
// decoder-generated tlast is suppressed here so the Bloom filter core sees exactly two logical
// transfers no matter how many row-group chunks it takes to build up each side. Disabled
// (bf_last_inject_enable=0) passes tlast through unchanged.
logic [31:0] bf_last_inject_beat_count;
logic        bf_last_inject_hit_first;
logic        bf_last_inject_hit_second;
logic        bf_last_inject_hit;

assign axi_bf_in_raw.tready = axi_bf_in.tready;

assign axi_bf_in.tdata  = axi_bf_in_raw.tdata;
assign axi_bf_in.tkeep  = axi_bf_in_raw.tkeep;
assign axi_bf_in.tvalid = axi_bf_in_raw.tvalid;

assign bf_last_inject_hit_first =
    bf_last_inject_enable &&
    axi_bf_in_raw.tvalid &&
    axi_bf_in_raw.tready &&
    (bf_last_inject_beat_count == bf_last_inject_first_beat);

assign bf_last_inject_hit_second =
    bf_last_inject_enable &&
    axi_bf_in_raw.tvalid &&
    axi_bf_in_raw.tready &&
    (bf_last_inject_beat_count == bf_last_inject_second_beat);

assign bf_last_inject_hit =
    bf_last_inject_hit_first || bf_last_inject_hit_second;

assign axi_bf_in.tlast =
    axi_bf_in_raw.tlast || bf_last_inject_hit;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        bf_last_inject_beat_count <= 32'd0;
    end else if (!bf_last_inject_enable) begin
        bf_last_inject_beat_count <= 32'd0;
    end else if (axi_bf_in_raw.tvalid && axi_bf_in_raw.tready) begin
        if (bf_last_inject_hit_second) begin
            bf_last_inject_beat_count <= 32'd0;
        end else begin
            bf_last_inject_beat_count <= bf_last_inject_beat_count + 32'd1;
        end
    end
end

// Probe values to materialize (MATERIALIZE), 64 bits each
ndata_i #(data64_t, CELERIS_NUM_TUPLES) bf_probe_values_in();
AXIToNData #(
    .data_t(data64_t),
    .NUM_ELEMENTS(CELERIS_NUM_TUPLES)
) inst_bf_probe_values_to_data (
    .clk(clk),
    .rst_n(rst_n),

    .in(axi_bf_probe_values),
    .out(bf_probe_values_in)
);

data_i #(tuple_mask_t) bf_mask_out();

ndata_i #(data64_t, CELERIS_NUM_TUPLES) bf_probe_mat_out();

BloomfilterOperator inst_bloomfilter_operator (
    .clk(clk),
    .rst_n(rst_n),

    .conf(bloomfilter_conf),
    .perf_counters(bf_perf_counters),

    .in(axi_bf_in),
    .probe_values_in(bf_probe_values_in),

    .raw_out(axi_bf_out),
    .mask_out(bf_mask_out),
    .probe_mat_out(bf_probe_mat_out)
);

// raw_out is the Bloomfilter core's compacted (DataNormalizer/ENABLE_COMPACTOR) surviving-key
// stream: fewer elements than went in, and not aligned with the original row positions, so it
// can't feed a fixed-cc.num_values sink. We don't use it -- drain it unconditionally. The surviving
// keys are materialized like any other probe column instead.
assign axi_bf_out.tready = 1'b1;

// The materialized probe values: one transfer per MATERIALIZE transfer, with only the kept rows
AXI4S axi_bf_mat(.aclk(clk), .aresetn(rst_n));
NDataToAXI #(
    .data_t(data64_t),
    .NUM_ELEMENTS(CELERIS_NUM_TUPLES),
    .AXI_WIDTH(AXI_DATA_BITS),
    .NUM_AXI_ELEMENTS(8)
) inst_bf_mat_to_axi (
    .clk(clk),
    .rst_n(rst_n),

    .in(bf_probe_mat_out),
    .out(axi_bf_mat)
);

// mask_out is a tuple_mask_t (CELERIS_NUM_TUPLES = 8 bits = 1 byte) keep-bit-per-row mask, one
// per decoded beat of axi_bf_in, emitted *before* raw_out's compaction -- so unlike raw_out it
// stays positionally aligned 1:1 with the probe key column's rows. The mask bytes are packed into
// full beats (the output writer only takes normalized streams: every beat full but the last), so a
// probe chunk of n rows yields ceil(n / 8) bytes. There is one mask transfer per probe key chunk (the
// Bloom filter frames its mask per input transfer). Software submits the probe key column chunk
// with FILTER for this mask, and then its 64-bit columns (the key column included) with
// MATERIALIZE for their kept rows -- see PrefetchGroup in oasis_scan.cpp.
ndata_i #(tuple_mask_t, 1) bf_mask_ndata(clk, rst_n);
`DATA_ASSIGN(bf_mask_out, bf_mask_ndata)

localparam BF_MASK_WORDS = AXI_DATA_BITS / $bits(tuple_mask_t);
ndata_i #(tuple_mask_t, BF_MASK_WORDS) bf_mask_packed(clk, rst_n);
NDataWidthConverter #(
    .data_t(tuple_mask_t)
) inst_bf_mask_pack (
    .clk(clk),
    .rst_n(rst_n),

    .in(bf_mask_ndata),
    .out(bf_mask_packed)
);

AXI4S axi_bf_mask(.aclk(clk), .aresetn(rst_n));
NDataToAXI #(
    .data_t(tuple_mask_t),
    .NUM_ELEMENTS(BF_MASK_WORDS),
    .AXI_WIDTH(AXI_DATA_BITS)
) inst_bf_mask_to_axi (
    .clk(clk),
    .rst_n(rst_n),

    .in(bf_mask_packed),
    .out(axi_bf_mask)
);

AXIMultiplexer #(
    .NUM_STREAMS(4)
) inst_bf_mux (
    .clk(clk),
    .rst_n(rst_n),

    .select(bf_mux_select),

    .in({axi_bf_mask, axi_bf_bypass, axi_bf_ack, axi_bf_mat}), // In select order: FILTER, BYPASS, BUILD, MATERIALIZE
    .out(axi_out[0])
);

// -- Pass-through for remaining decoder streams -----------------------------------------------------
for (genvar I = 1; I < NUM_DECODERS; I++) begin : gen_bf_passthrough
    `AXIS_ASSIGN(decoded_axi[I], axi_out[I])
end : gen_bf_passthrough

// -- RDMA bypass stream (last stream slot, no decoder) --------------------------------------------
`ifdef EN_RDMA
localparam BYPASS_ID = NUM_STREAMS - 1;

AXI4S axi_in (.aclk(aclk), .aresetn(aresetn));
ndata_i #(data8_t, DATABEAT_SIZE) bypass_ndata();

// AXI4SR to AXI4S
`AXIS_ASSIGN(axis_rreq_recv[BYPASS_ID], axi_in)

RDMARead #(
    .AXI_STRM_ID(BYPASS_ID),
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_rdma_read_bypass (
    .clk(clk),
    .rst_n(rst_n),

    .conf(read_conf[BYPASS_ID]),
    .ctid(read_ctid[BYPASS_ID]),

    .sq_rd(sq_rd_strm[BYPASS_ID]),

    .in(axi_in),
    .out(bypass_ndata)
);

NDataToAXI #(data8_t, DATABEAT_SIZE) inst_ndata_to_axi_bypass (
    .clk(clk),
    .rst_n(rst_n),

    .in(bypass_ndata),
    .out(axi_out[BYPASS_ID])
);
`endif

// -- Output writer --------------------------------------------------------------------------------
// The scheduler (software/oasis/scheduler.cpp) enqueues one output buffer per flow ahead of time and
// matches the n-th interrupt of a stream with its n-th buffer. So a flow with an empty output (e.g.
// a materialized column of which the Bloom filter kept no row) has to use up its buffer too.
OutputWriter #(
    .EMPTY_TRANSFER_TAKES_BUFFER(1)
) inst_output_writer (
    .clk(clk),
    .rst_n(rst_n),

    .sq_wr(sq_wr),
    .cq_wr(cq_wr),
    .notify(notify),

    .mem_config(mem_conf),

    .data_in(axi_out),
    .data_out(axis_host_send)
);
