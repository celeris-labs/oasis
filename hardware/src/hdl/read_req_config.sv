`timescale 1ns / 1ps

import libstf::*;
import oasis::NUM_READ_REQ_CONFIG_REGS;
import oasis::READ_REQ_CONFIG_ID;
import oasis::read_req_t;

`include "libstf_macros.svh"
`include "config_macros.svh"

module ReadReqConfig #(
    parameter NUM_STREAMS
) (
    input logic clk,
    input logic rst_n,

    write_config_i.s write_config,
    read_config_i.s  read_config,

    ready_valid_i.m out[NUM_STREAMS]  // #(read_req_t)
);

localparam MAX_NUM_ENQUEUED_BUFFERS = 64;
localparam NUM_WRITE_REGS = NUM_READ_REQ_CONFIG_REGS;

`RESET_RESYNC // Reset pipelining

// -- Read -----------------------------------------------------------------------------------------
logic[AXIL_DATA_BITS - 1:0] values[2];
assign values[0] = READ_REQ_CONFIG_ID;
assign values[1] = NUM_STREAMS;

ConfigReadRegisterFile #(
    .NUM_REGS(2)
) inst_read_regs (
    .clk(clk),
    .rst_n(reset_synced),

    .in(read_config),
    .values(values)
);

// -- Write ----------------------------------------------------------------------------------------
for (genvar I = 0; I < NUM_STREAMS; I++) begin
    ready_valid_i #(vaddress_t) vaddr(clk, reset_synced);
    ConfigWriteFIFO #(I * NUM_WRITE_REGS + 0, MAX_NUM_ENQUEUED_BUFFERS, vaddress_t) inst_vaddr (clk, reset_synced, write_config, vaddr);

    ready_valid_i #(size_t) len(clk, reset_synced);
    ConfigWriteFIFO #(I * NUM_WRITE_REGS + 1, MAX_NUM_ENQUEUED_BUFFERS, size_t) inst_len (clk, reset_synced, write_config, len);

    `READY_COMBINE(vaddr, len, out[I])
end

endmodule
