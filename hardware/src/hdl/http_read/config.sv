`timescale 1ns / 1ps

`include "axi_macros.svh"
`include "libstf_macros.svh"

import libstf::data8_t;
import libstf::data32_t;
import libstf::data64_t;
import lynxTypes::AXI_DATA_BITS;
import http_types::NUM_HTTP_READ_CONFIG_REGS;
import http_types::HTTP_READ_CONFIG_ID;
import http_types::*;

module HTTPReadConfig #(
    parameter NUM_STREAMS = 1
) (
    input logic clk,
    input logic rst_n,

    write_config_i.s write_config,
    read_config_i.s  read_config,

    http_read_config_i.m out[NUM_STREAMS]
);

localparam NUM_WRITE_REGS = NUM_HTTP_READ_CONFIG_REGS;

`RESET_RESYNC

// values[2] is a debug status word: the live HTTP/TCP FSM state of the bypass
// stream's HTTPRead instance. The bypass stream is always the last one.
logic [AXIL_DATA_BITS - 1:0] values[3];
assign values[0] = HTTP_READ_CONFIG_ID;
assign values[1] = NUM_STREAMS;
assign values[2] = {{(AXIL_DATA_BITS-32){1'b0}}, out[NUM_STREAMS-1].status};

ConfigReadRegisterFile #(
    .NUM_REGS(3)
) inst_read_regs (
    .clk(clk),
    .rst_n(reset_synced),
    .in(read_config),
    .values(values)
);

for (genvar I = 0; I < NUM_STREAMS; I++) begin : gen_streams
    data64_t reg_server_ip;
    data64_t reg_server_port;
    data64_t reg_file_len;
    data64_t reg_file_w0;
    data64_t reg_file_w1;
    data64_t reg_file_w2;
    data64_t reg_file_w3;
    data64_t reg_file_w4;
    data64_t reg_file_w5;
    data64_t reg_file_w6;
    data64_t reg_file_w7;
    data64_t reg_range_begin;
    data64_t reg_range_end;
    data64_t reg_size;
    data64_t reg_session_id;

    localparam int BASE = I * NUM_WRITE_REGS;

    ConfigWriteRegister #(BASE + 0,  data64_t) inst_server_ip   (clk, write_config, reg_server_ip);
    ConfigWriteRegister #(BASE + 1,  data64_t) inst_server_port (clk, write_config, reg_server_port);
    ConfigWriteRegister #(BASE + 2,  data64_t) inst_file_len    (clk, write_config, reg_file_len);
    ConfigWriteRegister #(BASE + 3,  data64_t) inst_file_w0     (clk, write_config, reg_file_w0);
    ConfigWriteRegister #(BASE + 4,  data64_t) inst_file_w1     (clk, write_config, reg_file_w1);
    ConfigWriteRegister #(BASE + 5,  data64_t) inst_file_w2     (clk, write_config, reg_file_w2);
    ConfigWriteRegister #(BASE + 6,  data64_t) inst_file_w3     (clk, write_config, reg_file_w3);
    ConfigWriteRegister #(BASE + 7,  data64_t) inst_file_w4     (clk, write_config, reg_file_w4);
    ConfigWriteRegister #(BASE + 8,  data64_t) inst_file_w5     (clk, write_config, reg_file_w5);
    ConfigWriteRegister #(BASE + 9,  data64_t) inst_file_w6     (clk, write_config, reg_file_w6);
    ConfigWriteRegister #(BASE + 10, data64_t) inst_file_w7     (clk, write_config, reg_file_w7);
    ConfigWriteRegister #(BASE + 11, data64_t) inst_range_begin (clk, write_config, reg_range_begin);
    ConfigWriteRegister #(BASE + 12, data64_t) inst_range_end   (clk, write_config, reg_range_end);
    ConfigWriteRegister #(BASE + 13, data64_t) inst_size        (clk, write_config, reg_size);
    ConfigWriteRegister #(BASE + 14, data64_t) inst_session_id  (clk, write_config, reg_session_id);

    ready_valid_i #(data64_t) start_raw();
    ConfigWriteReadyRegister #(BASE + 15, data64_t) inst_start (
        .clk         (clk),
        .rst_n       (reset_synced),
        .write_config(write_config),
        .data        (start_raw)
    );

    http_config_t cfg_live;
    always_comb begin
        cfg_live.server_ip   = reg_server_ip[31:0];
        cfg_live.server_port = reg_server_port[31:0];
        cfg_live.file_len    = reg_file_len[31:0];
        cfg_live.file_w0     = reg_file_w0[31:0];
        cfg_live.file_w1     = reg_file_w1[31:0];
        cfg_live.file_w2     = reg_file_w2[31:0];
        cfg_live.file_w3     = reg_file_w3[31:0];
        cfg_live.file_w4     = reg_file_w4[31:0];
        cfg_live.file_w5     = reg_file_w5[31:0];
        cfg_live.file_w6     = reg_file_w6[31:0];
        cfg_live.file_w7     = reg_file_w7[31:0];
        cfg_live.range_begin = reg_range_begin;
        cfg_live.range_end   = reg_range_end;
        cfg_live.session_id  = reg_session_id[15:0];
    end

    assign out[I].cfg        = cfg_live;
    assign out[I].size       = reg_size[31:0];
    assign out[I].valid      = start_raw.valid;
    assign start_raw.ready   = out[I].ready;
end : gen_streams

endmodule
