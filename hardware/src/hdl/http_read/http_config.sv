`timescale 1ns / 1ps

import lynxTypes::*;
import libstf::*;
import http_types::*;

`include "libstf_macros.svh"
`include "config_macros.svh"

// The HTTP client's AXI-Lite registers, built from libstf's config blocks. Each write register
// latches one field of cfg, and a write to START emits cfg as one beat on start_cfg. START does not
// back-pressure: a START that lands before the previous beat was taken overwrites it, so the host
// polls LANE_READY before each START and uses LANE_OCC against QUEUE_DEPTH as its chunk credit.
//
// Write registers (mirrored in software/oasis/configuration.cpp; 42 registers, so
// HTTP_CONFIG_ADDR_SPACE in vfpga_top.svh is 64):
//   0     SERVER_IP        TCP target, big-endian in the low bytes
//   1     SERVER_PORT      TCP port in [15:0]
//   2..38 reserved         latched and echoed (read 3..9), read by no handler
//   39    START            any value; snapshots the live cfg, so write 40 and 41 first
//   40    REQ_TOTAL_BYTES  0: the beat is a chunk-length entry; else it arms the lane, and this
//                          many bytes of request text follow on the lane's host stream
//   41    REQ_CHUNK_BYTES  [31:0] bytes of one decoder stream (a column chunk), [35:32] its lane
//
// Read registers. INFLIGHT[31:24] is the CSR revision, 2; the host refuses any other. Addresses
// above 20 answer resp_error. Bits not listed read 0.
//   0     HTTP_CONFIG_ID   "HTT"
//   1     CLIENT_STATE     [3:0] lane 0's tcp_read state
//   2     STATUS           [7:4] tcp_init state, [11:8] lane 0's tcp_read state, [18] all lanes
//                          connected, [20] a lane fatal, [21] a TX reservation refused, [22] busy,
//                          [23] = STALL[24]
//   3..9  ECHO_*           write register echoes; 8 = {port, ip}, the others echo reserved ones
//   10    INFLIGHT         [7:0] most chunk entries queued on one lane, [15:8] QUEUE_DEPTH (both
//                          saturating), [16] an announcement queued in rx_dispatch, [17] a peer
//                          FIN, [18] all lanes connected, [19] req_ready of the lane the beat
//                          names, [23:20] lane count, [31:24] CSR revision
//   11    STALL            sticky, OR over the lanes: [0] open unanswered, [3] open refused, [4] TX
//                          reservation refused, [5] no Content-Length, [6] a lane fatal, [7] status
//                          not 200/206, [15:8] reconnects (saturating), [24] announcement dropped
//                          (never), [25] lane fifo lost a beat, [26] read watchdog expired,
//                          [27] body with no chunk length queued, [28] dispatcher lost a beat
//   12    RESP             [23:0] lane 0's status digits, [24] all statuses 200/206, [25] a
//                          response could not be framed, [26] a lane aborting dirty
//   13    BODY_REMAINING   lane 0's body bytes still to stream
//   14    CONTENT_LENGTH   lane 0's Content-Length of the last response, latched
//   15    QUEUE_DEPTH      chunk entries per lane, not saturated
// 16..20 are 64 bits with one field per lane at a fixed stride of 8 lanes; absent lanes read 0.
//   16    LANE_OCC         [8L+7:8L] chunk entries queued and not yet completed by a tlast
//   17    LANE_READY       [4L] ARM_READY, [4L+1] ENTRY_READY, [4L+2] CONN_UP, [4L+3] FATAL. Only a
//                          host write clears a ready bit, so a value read holds until the host
//                          writes. ARM_READY stays 0 on a fatal lane: check FATAL first.
//   18    LANE_STATE       [4L+3:4L] tcp_read state, [32+4L+3:32+4L] http_req_stream state
//   19    LANE_ERR         sticky since reset, [8L+n]: 0 LANE_DEAD (HOL watchdog), 1 DIRTY,
//                          2 INIT_ERR, 3 RESP_ERR, 4 STATUS_BAD, 5 TX_REFUSED, 6 READ_TIMEOUT,
//                          7 RX_FIFO_STALL
//   20    LANE_POLICY      [7:0] CSR revision, [15:8] NUM_CONNS, [31:16] QUEUE_DEPTH, [55:32] HOL
//                          watchdog cycles, saturating, [61:56] their log2
module HttpConfig #(
    parameter integer NUM_PARAM_REGS = 42,
    parameter integer START_ADDR     = 39
) (
    input  logic clk,
    input  logic rst_n,

    write_config_i.s write_config,
    read_config_i.s  read_config,

    // The live register values; start_cfg carries a snapshot of them.
    output http_config_t cfg,

    // One beat carrying cfg for each write to START.
    ready_valid_i.m  start_cfg,

    input  logic [3:0]  client_state,
    input  logic [31:0] total_word,
    input  logic [31:0] inflight_word,
    input  logic [31:0] queue_depth_word,
    input  logic [31:0] stall_word,
    input  logic [31:0] resp_word,
    input  logic [31:0] content_length_word,
    input  logic [31:0] body_remaining_word,

    input  logic [63:0] lane_occ_word,
    input  logic [63:0] lane_ready_word,
    input  logic [63:0] lane_state_word,
    input  logic [63:0] lane_err_word,
    input  logic [63:0] lane_policy_word
);

`RESET_RESYNC

localparam logic [AXIL_DATA_BITS - 1:0] HTTP_CONFIG_ID = 64'h0000_0000_0048_5454; // "HTT"

// The write map is fixed in the instantiations below. These checks keep START off every parameter
// register and the address space above the highest one.
localparam int LAST_PARAM_ADDR   = 38;   // highest contiguous parameter, below START
localparam int STREAM_PARAM_ADDR = 41;   // req_total_bytes at 40, req_chunk_bytes at 41
`ASSERT_ELAB(START_ADDR > LAST_PARAM_ADDR)
`ASSERT_ELAB(START_ADDR < STREAM_PARAM_ADDR)
`ASSERT_ELAB(NUM_PARAM_REGS > STREAM_PARAM_ADDR)

data64_t reg_server_ip;
data64_t reg_server_port;
data64_t reg_port_hex;
data64_t reg_ip_hex_len;
data64_t reg_ip_hex_w0;
data64_t reg_ip_hex_w1;
data64_t reg_ip_hex_w2;
data64_t reg_ip_hex_w3;
data64_t reg_file_len;
data64_t reg_file_w0;
data64_t reg_file_w1;
data64_t reg_file_w2;
data64_t reg_file_w3;
data64_t reg_file_w4;
data64_t reg_file_w5;
data64_t reg_file_w6;
data64_t reg_file_w7;
data64_t reg_file_w8;
data64_t reg_file_w9;
data64_t reg_file_w10;
data64_t reg_file_w11;
data64_t reg_file_w12;
data64_t reg_file_w13;
data64_t reg_file_w14;
data64_t reg_file_w15;
data64_t reg_req_flags;
data64_t reg_pkg_word_count;
data64_t reg_user_frequency;
data64_t reg_time_in_seconds;
data64_t reg_range_begin_len;
data64_t reg_range_begin_w0;
data64_t reg_range_begin_w1;
data64_t reg_range_begin_w2;
data64_t reg_range_begin_w3;
data64_t reg_range_end_len;
data64_t reg_req_total_bytes;
data64_t reg_req_chunk_bytes;
data64_t reg_range_end_w0;
data64_t reg_range_end_w1;
data64_t reg_range_end_w2;
data64_t reg_range_end_w3;

ConfigWriteRegister #(0,  data64_t) inst_reg_server_ip        (clk, write_config, reg_server_ip);
ConfigWriteRegister #(1,  data64_t) inst_reg_server_port      (clk, write_config, reg_server_port);
ConfigWriteRegister #(2,  data64_t) inst_reg_port_hex         (clk, write_config, reg_port_hex);
ConfigWriteRegister #(3,  data64_t) inst_reg_ip_hex_len       (clk, write_config, reg_ip_hex_len);
ConfigWriteRegister #(4,  data64_t) inst_reg_ip_hex_w0        (clk, write_config, reg_ip_hex_w0);
ConfigWriteRegister #(5,  data64_t) inst_reg_ip_hex_w1        (clk, write_config, reg_ip_hex_w1);
ConfigWriteRegister #(6,  data64_t) inst_reg_ip_hex_w2        (clk, write_config, reg_ip_hex_w2);
ConfigWriteRegister #(7,  data64_t) inst_reg_ip_hex_w3        (clk, write_config, reg_ip_hex_w3);
ConfigWriteRegister #(8,  data64_t) inst_reg_file_len         (clk, write_config, reg_file_len);
ConfigWriteRegister #(9,  data64_t) inst_reg_file_w0          (clk, write_config, reg_file_w0);
ConfigWriteRegister #(10, data64_t) inst_reg_file_w1          (clk, write_config, reg_file_w1);
ConfigWriteRegister #(11, data64_t) inst_reg_file_w2          (clk, write_config, reg_file_w2);
ConfigWriteRegister #(12, data64_t) inst_reg_file_w3          (clk, write_config, reg_file_w3);
ConfigWriteRegister #(13, data64_t) inst_reg_file_w4          (clk, write_config, reg_file_w4);
ConfigWriteRegister #(14, data64_t) inst_reg_file_w5          (clk, write_config, reg_file_w5);
ConfigWriteRegister #(15, data64_t) inst_reg_file_w6          (clk, write_config, reg_file_w6);
ConfigWriteRegister #(16, data64_t) inst_reg_file_w7          (clk, write_config, reg_file_w7);
ConfigWriteRegister #(17, data64_t) inst_reg_file_w8          (clk, write_config, reg_file_w8);
ConfigWriteRegister #(18, data64_t) inst_reg_file_w9          (clk, write_config, reg_file_w9);
ConfigWriteRegister #(19, data64_t) inst_reg_file_w10         (clk, write_config, reg_file_w10);
ConfigWriteRegister #(20, data64_t) inst_reg_file_w11         (clk, write_config, reg_file_w11);
ConfigWriteRegister #(21, data64_t) inst_reg_file_w12         (clk, write_config, reg_file_w12);
ConfigWriteRegister #(22, data64_t) inst_reg_file_w13         (clk, write_config, reg_file_w13);
ConfigWriteRegister #(23, data64_t) inst_reg_file_w14         (clk, write_config, reg_file_w14);
ConfigWriteRegister #(24, data64_t) inst_reg_file_w15         (clk, write_config, reg_file_w15);
ConfigWriteRegister #(25, data64_t) inst_reg_req_flags        (clk, write_config, reg_req_flags);
ConfigWriteRegister #(26, data64_t) inst_reg_pkg_word_count   (clk, write_config, reg_pkg_word_count);
ConfigWriteRegister #(27, data64_t) inst_reg_user_frequency   (clk, write_config, reg_user_frequency);
ConfigWriteRegister #(28, data64_t) inst_reg_time_in_seconds  (clk, write_config, reg_time_in_seconds);
// Above START: the trigger emits the live cfg, so the host writes 40 and 41 before 39.
ConfigWriteRegister #(40, data64_t) inst_reg_req_total_bytes (clk, write_config, reg_req_total_bytes);
ConfigWriteRegister #(41, data64_t) inst_reg_req_chunk_bytes (clk, write_config, reg_req_chunk_bytes);
ConfigWriteRegister #(29, data64_t) inst_reg_range_begin_len    (clk, write_config, reg_range_begin_len);
ConfigWriteRegister #(30, data64_t) inst_reg_range_begin_w0     (clk, write_config, reg_range_begin_w0);
ConfigWriteRegister #(31, data64_t) inst_reg_range_begin_w1     (clk, write_config, reg_range_begin_w1);
ConfigWriteRegister #(32, data64_t) inst_reg_range_begin_w2     (clk, write_config, reg_range_begin_w2);
ConfigWriteRegister #(33, data64_t) inst_reg_range_begin_w3     (clk, write_config, reg_range_begin_w3);
ConfigWriteRegister #(34, data64_t) inst_reg_range_end_len      (clk, write_config, reg_range_end_len);
ConfigWriteRegister #(35, data64_t) inst_reg_range_end_w0       (clk, write_config, reg_range_end_w0);
ConfigWriteRegister #(36, data64_t) inst_reg_range_end_w1       (clk, write_config, reg_range_end_w1);
ConfigWriteRegister #(37, data64_t) inst_reg_range_end_w2       (clk, write_config, reg_range_end_w2);
ConfigWriteRegister #(38, data64_t) inst_reg_range_end_w3       (clk, write_config, reg_range_end_w3);

always_comb begin
    cfg.server_ip       = reg_server_ip      [31:0];
    cfg.server_port     = reg_server_port    [31:0];
    cfg.port_hex        = reg_port_hex       [31:0];
    cfg.ip_hex_len      = reg_ip_hex_len     [7:0];
    cfg.ip_hex_w0       = reg_ip_hex_w0      [31:0];
    cfg.ip_hex_w1       = reg_ip_hex_w1      [31:0];
    cfg.ip_hex_w2       = reg_ip_hex_w2      [31:0];
    cfg.ip_hex_w3       = reg_ip_hex_w3      [31:0];
    cfg.file_len        = reg_file_len       [31:0];
    cfg.file_w0         = reg_file_w0        [31:0];
    cfg.file_w1         = reg_file_w1        [31:0];
    cfg.file_w2         = reg_file_w2        [31:0];
    cfg.file_w3         = reg_file_w3        [31:0];
    cfg.file_w4         = reg_file_w4        [31:0];
    cfg.file_w5         = reg_file_w5        [31:0];
    cfg.file_w6         = reg_file_w6        [31:0];
    cfg.file_w7         = reg_file_w7        [31:0];
    cfg.file_w8         = reg_file_w8        [31:0];
    cfg.file_w9         = reg_file_w9        [31:0];
    cfg.file_w10        = reg_file_w10       [31:0];
    cfg.file_w11        = reg_file_w11       [31:0];
    cfg.file_w12        = reg_file_w12       [31:0];
    cfg.file_w13        = reg_file_w13       [31:0];
    cfg.file_w14        = reg_file_w14       [31:0];
    cfg.file_w15        = reg_file_w15       [31:0];
    cfg.req_flags       = reg_req_flags      [15:0];
    cfg.pkg_word_count  = reg_pkg_word_count [31:0];
    cfg.user_frequency  = reg_user_frequency [31:0];
    cfg.time_in_seconds = reg_time_in_seconds[31:0];
    cfg.req_total_bytes = reg_req_total_bytes[31:0];
    cfg.req_chunk_bytes = reg_req_chunk_bytes[31:0];
    cfg.req_chunk_dest  = reg_req_chunk_bytes[35:32];
    cfg.range_begin_len = reg_range_begin_len[7:0];
    cfg.range_begin_w0  = reg_range_begin_w0 [31:0];
    cfg.range_begin_w1  = reg_range_begin_w1 [31:0];
    cfg.range_begin_w2  = reg_range_begin_w2 [31:0];
    cfg.range_begin_w3  = reg_range_begin_w3 [31:0];
    cfg.range_end_len   = reg_range_end_len  [7:0];
    cfg.range_end_w0    = reg_range_end_w0   [31:0];
    cfg.range_end_w1    = reg_range_end_w1   [31:0];
    cfg.range_end_w2    = reg_range_end_w2   [31:0];
    cfg.range_end_w3    = reg_range_end_w3   [31:0];
end

ready_valid_i #(data64_t) start_raw();

ConfigWriteReadyRegister #(START_ADDR, data64_t) inst_start_trigger (
    .clk         (clk),
    .rst_n       (reset_synced),
    .write_config(write_config),
    .data        (start_raw)
);

assign start_cfg.data  = cfg;
assign start_cfg.valid = start_raw.valid;
assign start_raw.ready = start_cfg.ready;

localparam int NUM_READ_REGS = 21;

logic [AXIL_DATA_BITS - 1:0] read_registers[NUM_READ_REGS];

assign read_registers[0] = HTTP_CONFIG_ID;
assign read_registers[1] = {60'b0, client_state};
assign read_registers[2] = {32'b0, total_word};
assign read_registers[3] = {32'b0, cfg.file_len};
assign read_registers[4] = {32'b0, cfg.file_w0};
assign read_registers[5] = {32'b0, cfg.file_w4};
assign read_registers[6] = {24'b0, cfg.range_begin_len, cfg.range_begin_w0};
assign read_registers[7] = {24'b0, cfg.range_end_len,   cfg.range_end_w0};
assign read_registers[8] = {16'b0, cfg.server_port[15:0], cfg.server_ip};
assign read_registers[9] = {32'b0, cfg.file_w8};
assign read_registers[10] = {32'b0, inflight_word};
assign read_registers[11] = {32'b0, stall_word};
assign read_registers[12] = {32'b0, resp_word};
assign read_registers[13] = {32'b0, body_remaining_word};
assign read_registers[14] = {32'b0, content_length_word};
assign read_registers[15] = {32'b0, queue_depth_word};

// Per-lane registers. Extend the map, never edit it: the CSR revision in INFLIGHT names it.
assign read_registers[16] = lane_occ_word;
assign read_registers[17] = lane_ready_word;
assign read_registers[18] = lane_state_word;
assign read_registers[19] = lane_err_word;
assign read_registers[20] = lane_policy_word;

// The read map shares HTTP_CONFIG_ADDR_SPACE with the write side and must not be the larger.
`ASSERT_ELAB(NUM_READ_REGS <= NUM_PARAM_REGS + 1)
`ASSERT_ELAB(AXIL_DATA_BITS >= 64)

// Read register file in two registered stages. libstf's ConfigReadRegisterFile decodes the address
// and muxes the words in the handshake cycle, which fails timing here, as the words come from
// across SLRs. This one registers every word each cycle and the decode in the handshake cycle, and
// answers one cycle later with the same values; the read splitter waits for resp_valid.
logic [AXIL_DATA_BITS - 1:0] read_words_q[NUM_READ_REGS];

always_ff @(posedge clk) begin
    for (int i = 0; i < NUM_READ_REGS; i++) read_words_q[i] <= read_registers[i];
end

typedef enum logic [1:0] {RD_WAIT, RD_SELECT, RD_RESPOND} rd_state_t;
rd_state_t                   rd_state_q;
logic [NUM_READ_REGS - 1:0]  rd_match_q;
logic [AXIL_DATA_BITS - 1:0] rd_data_w;

assign read_config.read_ready = (rd_state_q == RD_WAIT);

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        rd_state_q             <= RD_WAIT;
        read_config.resp_valid <= 1'b0;
    end else begin
        case (rd_state_q)
            RD_WAIT: begin
                if (read_config.read_valid) rd_state_q <= RD_SELECT;
            end
            RD_SELECT: begin
                read_config.resp_valid <= 1'b1;
                rd_state_q             <= RD_RESPOND;
            end
            default: begin // RD_RESPOND
                if (read_config.resp_ready) begin
                    read_config.resp_valid <= 1'b0;
                    rd_state_q             <= RD_WAIT;
                end
            end
        endcase
    end
end

always_ff @(posedge clk) begin
    if ((rd_state_q == RD_WAIT) && read_config.read_valid) begin
        for (int i = 0; i < NUM_READ_REGS; i++) rd_match_q[i] <= (read_config.read_addr == i);
    end
    if (rd_state_q == RD_SELECT) begin
        read_config.resp_data  <= rd_data_w;
        read_config.resp_error <= !(|rd_match_q);
    end
end

always_comb begin
    rd_data_w = '0;
    for (int i = 0; i < NUM_READ_REGS; i++) rd_data_w |= rd_match_q[i] ? read_words_q[i] : '0;
end

endmodule
