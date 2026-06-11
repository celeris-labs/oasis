`timescale 1ns / 1ps

import oasis::*;
import parcore::*;
import libstf::*;
import common::*;

initial begin
    $display("%0t [OASIS_SIM] vfpga_top debug compiled", $time);
end

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
always_comb sq_wr.tie_off_m();
always_comb cq_wr.tie_off_s();
`endif

localparam NUM_STREAMS   = N_STRM_AXI;
localparam DATABEAT_SIZE = AXI_DATA_BITS / 8;

`ifdef EN_RDMA
localparam NUM_CONFIGS     = 6;
`else
localparam NUM_CONFIGS     = 4;
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
ready_valid_i #(column_chunk_conf_t) column_chunk_conf[NUM_STREAMS](clk, rst_n);
decoder_profile_t              column_chunk_profile[NUM_STREAMS];
bloomfilter_config_i          bloomfilter_conf();
stream_config_i               bf_stream_conf[1](.*);

GlobalConfig #(
    .SYSTEM_ID(OASIS_SYSTEM_ID),
    .NUM_CONFIGS(NUM_CONFIGS),
    .ADDR_SPACE_SIZES({
        NUM_STREAMS + 1,
        COLUMN_CHUNK_DECODER_CONFIG_REGS * NUM_STREAMS,
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

    .out(column_chunk_conf),
    .profile(column_chunk_profile)
);

bloomfilter_perf_counters_t bf_perf_counters;
BFConfig inst_bf_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[2]),
    .read_config(read_configs[2]),

    .out(bloomfilter_conf),

    .perf_counters(bf_perf_counters)
);

StreamConfig #(
    .NUM_STREAMS(1)
) inst_bf_stream_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[3]),
    .read_config(read_configs[3]),

    .out(bf_stream_conf)
);

`ifdef EN_RDMA
RDMAReadConfig #(
    .NUM_STREAMS(NUM_STREAMS)
) inst_rdma_read_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[3]),
    .read_config(read_configs[3]),

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

        .conf(column_chunk_conf[I]),

        .in(decoder_in),
        .out(typed_out),
        .profile(column_chunk_profile[I])
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
// The stream config's `select` chooses between the bloom-filtered path (0)
// and the bypass path (1) per column chunk.
//
// The Bloomfilter is asymmetric:
//   BUILD input  -> no output
//   PROBE input  -> output
//
// Therefore:
//   BF BUILD: select=0 -> demux select only
//   BF PROBE: select=0 -> demux select + mux select
//   BYPASS:   select=1 -> demux select + mux select
//
// Important:
//   For output-producing phases, demux and mux selects are offered in parallel.
//   We must not wait for the mux select before releasing the demux select,
//   otherwise the mux may wait for data that can never arrive.
ready_valid_i #(select_t) bf_conf_select();

ready_valid_i #(select_t) bf_demux_select();
ready_valid_i #(select_t) bf_mux_select();

`CONFIG_SIGNALS_TO_INTF(bf_stream_conf[0].select, bf_conf_select)
assign bf_stream_conf[0].data_type_ready = 1'b1; // unused

typedef enum logic {
    BF_PHASE_BUILD,
    BF_PHASE_PROBE
} bf_phase_t;

logic      bf_route_active;
bf_phase_t bf_phase;

select_t bf_route_select;
logic    bf_route_is_bf;
logic    bf_route_has_output;

logic bf_demux_done;
logic bf_mux_done;

wire bf_conf_is_bf =
    bf_conf_select.data == '0;

wire bf_conf_has_output =
    !bf_conf_is_bf || (bf_phase == BF_PHASE_PROBE);

assign bf_conf_select.ready =
    !bf_route_active;

assign bf_demux_select.data =
    bf_route_select;

assign bf_demux_select.valid =
    bf_route_active && !bf_demux_done;

assign bf_mux_select.data =
    bf_route_select;

assign bf_mux_select.valid =
    bf_route_active && bf_route_has_output && !bf_mux_done;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        bf_route_active     <= 1'b0;
        bf_phase            <= BF_PHASE_BUILD;

        bf_route_select     <= '0;
        bf_route_is_bf      <= 1'b0;
        bf_route_has_output <= 1'b0;

        bf_demux_done       <= 1'b0;
        bf_mux_done         <= 1'b0;
    end else begin
        if (!bf_route_active) begin
            if (bf_conf_select.valid && bf_conf_select.ready) begin
                bf_route_active     <= 1'b1;

                bf_route_select     <= bf_conf_select.data;
                bf_route_is_bf      <= bf_conf_is_bf;
                bf_route_has_output <= bf_conf_has_output;

                bf_demux_done       <= 1'b0;
                bf_mux_done         <= !bf_conf_has_output;
            end
        end else begin
            if (bf_demux_select.valid && bf_demux_select.ready) begin
                bf_demux_done <= 1'b1;
            end

            if (bf_mux_select.valid && bf_mux_select.ready) begin
                bf_mux_done <= 1'b1;
            end

            if ((bf_demux_done || (bf_demux_select.valid && bf_demux_select.ready)) &&
                (bf_mux_done   || (bf_mux_select.valid   && bf_mux_select.ready))) begin

                // Only Bloomfilter input chunks advance the BUILD/PROBE phase.
                // Bypass chunks do not affect Bloomfilter phase state.
                if (bf_route_is_bf) begin
                    if (bf_phase == BF_PHASE_BUILD) begin
                        bf_phase <= BF_PHASE_PROBE;
                    end else begin
                        bf_phase <= BF_PHASE_BUILD;
                    end
                end

                bf_route_active <= 1'b0;
            end
        end
    end
end

AXI4S axi_bf_in_raw(.aclk(clk), .aresetn(rst_n));
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
    .out({axi_bf_in_raw, axi_bf_bypass})
);

// Inline TLAST injector for the Bloomfilter input stream.
// Software configures absolute beat indices for BUILD end and PROBE end.
logic [31:0] bf_last_inject_beat_count;
logic        bf_last_inject_hit_first;
logic        bf_last_inject_hit_second;
logic        bf_last_inject_hit;

assign axi_bf_in_raw.tready = axi_bf_in.tready;

assign axi_bf_in.tdata  = axi_bf_in_raw.tdata;
assign axi_bf_in.tkeep  = axi_bf_in_raw.tkeep;
assign axi_bf_in.tvalid = axi_bf_in_raw.tvalid;

assign bf_last_inject_hit_first =
    bloomfilter_conf.last_inject_enable &&
    axi_bf_in_raw.tvalid &&
    axi_bf_in_raw.tready &&
    (bf_last_inject_beat_count == bloomfilter_conf.last_inject_first_beat);

assign bf_last_inject_hit_second =
    bloomfilter_conf.last_inject_enable &&
    axi_bf_in_raw.tvalid &&
    axi_bf_in_raw.tready &&
    (bf_last_inject_beat_count == bloomfilter_conf.last_inject_second_beat);

assign bf_last_inject_hit =
    bf_last_inject_hit_first || bf_last_inject_hit_second;

assign axi_bf_in.tlast =
    axi_bf_in_raw.tlast || bf_last_inject_hit;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        bf_last_inject_beat_count <= 32'd0;
    end else if (!bloomfilter_conf.last_inject_enable) begin
        bf_last_inject_beat_count <= 32'd0;
    end else if (axi_bf_in_raw.tvalid && axi_bf_in_raw.tready) begin
        if (bf_last_inject_hit_second) begin
            bf_last_inject_beat_count <= 32'd0;
        end else begin
            bf_last_inject_beat_count <= bf_last_inject_beat_count + 32'd1;
        end
    end
end

// SIM DEBUG: Bloom input/output progress
always_ff @(posedge clk) begin
    if (rst_n) begin
        if (axi_bf_in_raw.tvalid && axi_bf_in_raw.tready) begin
            $display("%0t [OASIS_SIM] BF_IN_RAW beat=%0d raw_last=%0b injected_last=%0b",
                     $time, bf_last_inject_beat_count, axi_bf_in_raw.tlast, axi_bf_in.tlast);
        end
        if (bf_last_inject_hit_first) begin
            $display("%0t [OASIS_SIM] BF_TLAST_FIRST beat=%0d", $time, bf_last_inject_beat_count);
        end
        if (bf_last_inject_hit_second) begin
            $display("%0t [OASIS_SIM] BF_TLAST_SECOND beat=%0d", $time, bf_last_inject_beat_count);
        end
        if (axi_bf_out.tvalid && axi_bf_out.tready) begin
            $display("%0t [OASIS_SIM] BF_OUT beat last=%0b", $time, axi_bf_out.tlast);
        end
    end
end

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