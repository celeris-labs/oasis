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
//   9  FILE_W0..16      ([31:0])     -- Path bytes packed little endian
//   10 FILE_W1
//   11 FILE_W2
//   12 FILE_W3
//   13 FILE_W4
//   14 FILE_W5
//   15 FILE_W6
//   16 FILE_W7
//   17 NUM_SESSIONS     ([15:0])
//   18 PKG_WORD_COUNT   ([31:0])
//   19 USER_FREQUENCY   ([31:0])
//   20 TIME_IN_SECONDS  ([31:0])
//   21 RANGE_BEGIN_LEN  ([7:0])
//   22 RANGE_BEGIN_W0   ([31:0])
//   23 RANGE_BEGIN_W1   ([31:0])
//   24 RANGE_BEGIN_W2   ([31:0])
//   25 RANGE_BEGIN_W3   ([31:0])
//   26 RANGE_END_LEN    ([7:0])
//   27 RANGE_END_W0     ([31:0])
//   28 RANGE_END_W1     ([31:0])
//   29 RANGE_END_W2     ([31:0])
//   30 RANGE_END_W3     ([31:0])
//   31 START            (ConfigWriteReadyRegister)  -- value ignored, write triggers
//
// Register map (read side):
//   0  HTTP_CONFIG_ID
//   1  CLIENT_STATE
//   2  TOTAL_WORD
// =================================================================================================
module HttpConfig #(
    parameter integer NUM_PARAM_REGS = 31,
    parameter integer START_ADDR     = 31
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
    input  logic [31:0] total_word
);

`RESET_RESYNC

localparam logic [AXIL_DATA_BITS - 1:0] HTTP_CONFIG_ID = 64'h0000_0000_0048_5454; // "HTT"

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
ConfigWriteRegister #(17, data64_t) inst_reg_num_sessions     (clk, write_config, reg_num_sessions);
ConfigWriteRegister #(18, data64_t) inst_reg_pkg_word_count   (clk, write_config, reg_pkg_word_count);
ConfigWriteRegister #(19, data64_t) inst_reg_user_frequency   (clk, write_config, reg_user_frequency);
ConfigWriteRegister #(20, data64_t) inst_reg_time_in_seconds  (clk, write_config, reg_time_in_seconds);
ConfigWriteRegister #(21, data64_t) inst_reg_range_begin_len    (clk, write_config, reg_range_begin_len);
ConfigWriteRegister #(22, data64_t) inst_reg_range_begin_w0     (clk, write_config, reg_range_begin_w0);
ConfigWriteRegister #(23, data64_t) inst_reg_range_begin_w1     (clk, write_config, reg_range_begin_w1);
ConfigWriteRegister #(24, data64_t) inst_reg_range_begin_w2     (clk, write_config, reg_range_begin_w2);
ConfigWriteRegister #(25, data64_t) inst_reg_range_begin_w3     (clk, write_config, reg_range_begin_w3);
ConfigWriteRegister #(26, data64_t) inst_reg_range_end_len      (clk, write_config, reg_range_end_len);
ConfigWriteRegister #(27, data64_t) inst_reg_range_end_w0       (clk, write_config, reg_range_end_w0);
ConfigWriteRegister #(28, data64_t) inst_reg_range_end_w1       (clk, write_config, reg_range_end_w1);
ConfigWriteRegister #(29, data64_t) inst_reg_range_end_w2       (clk, write_config, reg_range_end_w2);
ConfigWriteRegister #(30, data64_t) inst_reg_range_end_w3       (clk, write_config, reg_range_end_w3);

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
// -------------------------------------------------------------------------------------------------
logic [AXIL_DATA_BITS - 1:0] read_registers[3];

assign read_registers[0] = HTTP_CONFIG_ID;
assign read_registers[1] = {60'b0, client_state};
assign read_registers[2] = {32'b0, total_word};

ConfigReadRegisterFile #(
    .NUM_REGS(3)
) inst_read_reg_file (
    .clk   (clk),
    .rst_n (reset_synced),

    .in    (read_config),
    .values(read_registers)
);

endmodule
