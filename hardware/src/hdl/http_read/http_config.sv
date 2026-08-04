`timescale 1ns / 1ps

import lynxTypes::*;
import libstf::*;
import http_types::*;

`include "libstf_macros.svh"
`include "config_macros.svh"

// =================================================================================================
// HttpConfig
//
// A libstf-style sub-configuration that:
//   * Latches all HTTP client parameters via per-field ConfigWriteRegister
//     blocks (addresses 0..(N_PARAM-1)).
//   * Exposes the latest snapshot of those fields on a packed http_config_t
//     bus, ready to be sampled when the START write arrives.
//   * Emits one ready/valid beat carrying the entire http_config_t struct
//     when the host writes the START register (ConfigWriteReadyRegister).
//   * Exposes a small ConfigReadRegisterFile so the host can poll status
//     (CLIENT_STATE, TOTAL_WORD) and identify the config (HTTP_CONFIG_ID).
//
// Register map (write side, addressed within this config's AXI-Lite space):
//   0  SERVER_IP        ([31:0])     -- TCP connect target, BE in low bytes
//   1  SERVER_PORT      ([31:0])     -- TCP port (uses [15:0])
//   2  PORT_HEX         ([31:0])     -- ASCII bytes of port (for HTTP Host:)
//   3  IP_HEX_LEN       ([7:0])      -- Length of ASCII IP string
//   4  IP_HEX_W0..7     ([31:0])     -- ASCII IP bytes packed little endian
//   5  IP_HEX_W1
//   6  IP_HEX_W2
//   7  IP_HEX_W3
//   8  FILE_LEN         ([31:0])     -- Length of GET path
//   9  FILE_W0          ([31:0])     -- Path bytes packed little endian
//   .. FILE_W1..W14                     (9 + n for word n)
//   24 FILE_W15
//   25 NUM_SESSIONS     ([15:0])
//   26 PKG_WORD_COUNT   ([31:0])
//   27 USER_FREQUENCY   ([31:0])
//   28 TIME_IN_SECONDS  ([31:0])
//   29 RANGE_BEGIN_LEN  ([7:0])
//   30 RANGE_BEGIN_W0   ([31:0])
//   31 RANGE_BEGIN_W1   ([31:0])
//   32 RANGE_BEGIN_W2   ([31:0])
//   33 RANGE_BEGIN_W3   ([31:0])
//   34 RANGE_END_LEN    ([7:0])
//   35 RANGE_END_W0     ([31:0])
//   36 RANGE_END_W1     ([31:0])
//   37 RANGE_END_W2     ([31:0])
//   38 RANGE_END_W3     ([31:0])
//   39 START            (ConfigWriteReadyRegister)  -- value ignored, write triggers
//
// The 16 FILE_W words carry a 64-character GET path. Widening from 8 words pushed the map past
// 32 registers, so HTTP_CONFIG_ADDR_SPACE in vfpga_top.svh is 64 and every address after FILE_W7
// shifted by +8. software/oasis/configuration.cpp mirrors this map exactly -- if the two ever
// disagree, every parameter after the path lands in the wrong register and the FPGA builds a
// garbage request out of whatever happened to be there.
//
// Register map (read side):
//   0  HTTP_CONFIG_ID
//   1  CLIENT_STATE     ([3:0])      -- handler.sv state_debug (aliased; prefer STATUS)
//   2  STATUS           ([31:0])     -- packed FSM status, see handler.sv totalWord
//   3  ECHO_FILE_LEN    ([31:0])
//   4  ECHO_FILE_W0     ([31:0])     -- path chars 0..3
//   5  ECHO_FILE_W4     ([31:0])     -- path chars 16..19
//   9  ECHO_FILE_W8     ([31:0])     -- path chars 32..35 (only meaningful for long paths)
//   6  ECHO_RANGE_BEGIN ([39:32] len, [31:0] first 4 ASCII digits)
//   7  ECHO_RANGE_END   ([39:32] len, [31:0] first 4 ASCII digits)
//   8  ECHO_SERVER      ([47:32] port, [31:0] ip)
//   10 INFLIGHT         ([7:0] slots occupied, [15:8] NUM_SLOTS, [23:16] pending bitmap,
//                        [31:24] closed bitmap) -- see handler.sv inflightWord
//   11 STALL            ([0] connect stalled, [1] send stalled, [2] read stalled, [3] init error,
//                        [4] send error, [15:8] connect slot, [23:16] read slot)
//
// INFLIGHT is not optional bookkeeping. ConfigWriteReadyRegister does NOT back-pressure: a START
// write that lands while the previous one is still unconsumed overwrites it, and the earlier request
// is lost without a trace. With the handler pipelined over several slots the host can legitimately
// have requests outstanding, so it needs to know how many before pushing another. The host reads
// this register and treats (NUM_SLOTS - occupied) as its credit.
// =================================================================================================
module HttpConfig #(
    parameter integer NUM_PARAM_REGS = 39,
    parameter integer START_ADDR     = 39
) (
    input  logic clk,
    input  logic rst_n,

    write_config_i.s write_config,
    read_config_i.s  read_config,

    // Live snapshot of the latched configuration. handler.sv can read these
    // directly; they are stable across runs as long as the host does not
    // overwrite the corresponding write registers.
    output http_config_t cfg,

    // Trigger: fires for one beat (until consumer raises ready) when the
    // host writes to the START register. data carries the cfg snapshot at
    // that moment.
    ready_valid_i.m  start_cfg,

    // Status read back to the host
    input  logic [3:0]  client_state,
    input  logic [31:0] total_word,
    input  logic [31:0] inflight_word,
    input  logic [31:0] stall_word
);

`RESET_RESYNC

localparam logic [AXIL_DATA_BITS - 1:0] HTTP_CONFIG_ID = 64'h0000_0000_0048_5454; // "HTT"

// The map below is hardcoded in the ConfigWriteRegister instantiations, so these parameters cannot
// move it -- they only place START and size the address space. An instantiation that leaves them at
// a stale value drops START on top of a parameter register, and a write to that parameter then fires
// the request mid-configuration: every register after it keeps its previous value while the read-side
// echo, which reads the LIVE cfg rather than the snapshot the handler took, still shows the correct
// values. build-88 shipped exactly that (START_ADDR=31, i.e. RANGE_BEGIN_W1). Catch it at elaboration
// rather than on the wire.
localparam int LAST_PARAM_ADDR = 38;
`ASSERT_ELAB(START_ADDR > LAST_PARAM_ADDR)
`ASSERT_ELAB(NUM_PARAM_REGS > LAST_PARAM_ADDR)

// -------------------------------------------------------------------------------------------------
// Per-field write registers. Each ConfigWriteRegister latches the AXI-Lite
// data into its output on a write to its assigned address.
// -------------------------------------------------------------------------------------------------
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
data64_t reg_num_sessions;
data64_t reg_pkg_word_count;
data64_t reg_user_frequency;
data64_t reg_time_in_seconds;
data64_t reg_range_begin_len;
data64_t reg_range_begin_w0;
data64_t reg_range_begin_w1;
data64_t reg_range_begin_w2;
data64_t reg_range_begin_w3;
data64_t reg_range_end_len;
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
ConfigWriteRegister #(25, data64_t) inst_reg_num_sessions     (clk, write_config, reg_num_sessions);
ConfigWriteRegister #(26, data64_t) inst_reg_pkg_word_count   (clk, write_config, reg_pkg_word_count);
ConfigWriteRegister #(27, data64_t) inst_reg_user_frequency   (clk, write_config, reg_user_frequency);
ConfigWriteRegister #(28, data64_t) inst_reg_time_in_seconds  (clk, write_config, reg_time_in_seconds);
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

// -------------------------------------------------------------------------------------------------
// Live snapshot bus. handler.sv samples whichever fields it needs from `cfg`.
// -------------------------------------------------------------------------------------------------
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
    cfg.num_sessions    = reg_num_sessions   [15:0];
    cfg.pkg_word_count  = reg_pkg_word_count [31:0];
    cfg.user_frequency  = reg_user_frequency [31:0];
    cfg.time_in_seconds = reg_time_in_seconds[31:0];
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

// -------------------------------------------------------------------------------------------------
// Start trigger. The host writes any value to START_ADDR and we emit one
// beat carrying the current cfg snapshot. ConfigWriteReadyRegister gives us
// a registered valid/data pair which we just rewire to carry the struct.
// -------------------------------------------------------------------------------------------------
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

// -------------------------------------------------------------------------------------------------
// Read register file: host can poll status here.
//
// Registers 3..8 echo back the latched request parameters. The write registers above are
// write-only, so without these there is no way for the host to tell whether the parameters it
// wrote actually reached the hardware before START sampled them -- which is exactly the blind spot
// that made the "request is one run behind" bug so hard to pin down. The echoed fields are the
// discriminating ones: file_w4 covers path characters 16..19, which is where ".../tpch-1/" and
// ".../tpch-10/" first differ, and the range words differ immediately between any two reads.
// -------------------------------------------------------------------------------------------------
localparam int NUM_READ_REGS = 12;

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
// Path chars 32..35. With 64-character paths the two prefixes under test can now agree all the way
// through file_w4, so w0/w4 alone no longer discriminate between two long paths.
assign read_registers[9] = {32'b0, cfg.file_w8};
// Request-ring occupancy. The host's credit before it may push another START. See the map above.
assign read_registers[10] = {32'b0, inflight_word};
// Which stage stalled, so a full ring can be told apart from a dead connect. See handler.sv.
assign read_registers[11] = {32'b0, stall_word};

`ASSERT_ELAB(NUM_READ_REGS <= NUM_PARAM_REGS + 1)

ConfigReadRegisterFile #(
    .NUM_REGS(NUM_READ_REGS)
) inst_read_reg_file (
    .clk   (clk),
    .rst_n (reset_synced),

    .in    (read_config),
    .values(read_registers)
);

endmodule
