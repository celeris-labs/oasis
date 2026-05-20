`timescale 1ns / 1ps

import oasis::*;
import parcore::*;
import libstf::*;
import common::*;

// -- Tie-off unused interfaces and signals --------------------------------------------------------
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
`else
always_comb sq_rd.tie_off_m();
always_comb cq_rd.tie_off_s();
`endif

localparam NUM_STREAMS   = N_STRM_AXI;
localparam DATABEAT_SIZE = AXI_DATA_BITS / 8;

`ifdef EN_RDMA
localparam NUM_CONFIGS     = 6;
`else
localparam NUM_CONFIGS     = 5;
`endif

localparam STREAM_CFG_REGS = 2;

// -- Fix clock and reset names --------------------------------------------------------------------
logic clk;
logic rst_n;

assign clk   = aclk;
assign rst_n = aresetn;

// -- Configuration --------------------------------------------------------------------------------
write_config_i                write_configs[NUM_CONFIGS](.*);
read_config_i                 read_configs [NUM_CONFIGS](.*);
mem_config_i                  mem_conf[NUM_STREAMS](.*);
`ifdef EN_RDMA
rdma_read_config_i            rdma_conf[NUM_STREAMS](.*);
`endif
column_chunk_decoder_config_i column_chunk_conf[NUM_STREAMS](.*);
page_decoder_config_i         page_conf[NUM_STREAMS](.*);
bloomfilter_config_i          bloomfilter_conf();
stream_config_i               bf_stream_conf[1](.*);

GlobalConfig #(
    .SYSTEM_ID(OASIS_SYSTEM_ID),
    .NUM_CONFIGS(NUM_CONFIGS),
    .ADDR_SPACE_SIZES({
        NUM_STREAMS + 1,
        COLUMN_CHUNK_DECODER_CONFIG_REGS * NUM_STREAMS,
        PAGE_DECODER_CONFIG_REGS * NUM_STREAMS,
        BLOOMFILTER_NUM_CONFIG_REGS,
        STREAM_CFG_REGS
`ifdef EN_RDMA
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
    .NUM_DECODERS(NUM_STREAMS)
) inst_column_chunk_decoder_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[1]),
    .read_config(read_configs[1]),

    .out(column_chunk_conf)
);

PageDecoderConfig #(
    .NUM_DECODERS(NUM_STREAMS)
) inst_page_decoder_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[2]),
    .read_config(read_configs[2]),

    .out(page_conf)
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

`ifdef EN_RDMA
RDMAReadConfig #(
    .NUM_STREAMS(NUM_STREAMS)
) inst_rdma_read_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[5]),
    .read_config(read_configs[5]),

    .out(rdma_conf)
);

// -- De-mux and arbiter the read send and completion queues ---------------------------------------
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
AXI4S decoded_axi[NUM_STREAMS](.aclk(clk), .aresetn(rst_n));
for (genvar I = 0; I < NUM_STREAMS; I++) begin
    AXI4S axi_in (.aclk(aclk), .aresetn(aresetn));
    ndata_i       #(data8_t, DATABEAT_SIZE) decoder_in();
    typed_ndata_i #(DATABEAT_SIZE)          typed_out();
    ndata_i       #(data8_t, DATABEAT_SIZE) out();

`ifdef EN_RDMA
    // AXI4SR to AXI4S
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
    // AXI4SR to AXI4S
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

    // Discard typed
    `DATA_ASSIGN(typed_out, out);

    NDataToAXI #(data8_t, DATABEAT_SIZE) inst_ndata_to_axi (
        .clk(clk),
        .rst_n(rst_n),

        .in(out),
        .out(decoded_axi[I])
    );
end

// -- Bloom filter on stream 0 (with bypass) -------------------------------------------------------
// The stream config's `select` chooses between the bloom-filtered path (0) and the bypass path (1)
// per column chunk, so chunks that do not need filtering skip the bloom filter entirely.
ready_valid_i #(select_t) bf_select();
ready_valid_i #(select_t) bf_demux_select();
ready_valid_i #(select_t) bf_mux_select();

`CONFIG_SIGNALS_TO_INTF(bf_stream_conf[0].select, bf_select)
assign bf_stream_conf[0].data_type_ready = 1'b1; // unused

`READY_DUPLICATE(2, bf_select, {bf_demux_select, bf_mux_select})

AXI4S axi_bf_in    (.aclk(clk), .aresetn(rst_n));
AXI4S axi_bf_out   (.aclk(clk), .aresetn(rst_n));
AXI4S axi_bf_bypass(.aclk(clk), .aresetn(rst_n));

AXIDemultiplexer #(
    .NUM_STREAMS(2)
) inst_bf_demux (
    .clk(clk),
    .rst_n(rst_n),

    .select(bf_demux_select),

    .in(decoded_axi[0]),
    .out({axi_bf_in, axi_bf_bypass})
);

data_i #(tuple_mask_t) bf_probe_mat();
assign bf_probe_mat.ready = 1'b1; // drain mask, the operator pipeline relies on it being consumed

BloomfilterOperator inst_bloomfilter_operator (
    .clk(clk),
    .rst_n(rst_n),

    .conf(bloomfilter_conf),
    .perf_counters(bf_perf_counters),

    .in(axi_bf_in),
    .raw_out(axi_bf_out),
    .probe_mat_out(bf_probe_mat)
);

AXIMultiplexer #(
    .NUM_STREAMS(2)
) inst_bf_mux (
    .clk(clk),
    .rst_n(rst_n),

    .select(bf_mux_select),

    .in({axi_bf_out, axi_bf_bypass}),
    .out(axi_out[0])
);

// -- Pass-through for remaining streams -----------------------------------------------------------
for (genvar I = 1; I < NUM_STREAMS; I++) begin
    `AXIS_ASSIGN(decoded_axi[I], axi_out[I])
end

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
