`timescale 1ns / 1ps

import libstf::*;
import oasis::RDMA_READ_CONFIG_REGS;
import oasis::RDMA_READ_CONFIG_ID;

`include "libstf_macros.svh"
`include "config_macros.svh"

module RDMAReadConfig #(
    parameter NUM_STREAMS
) (
    input logic clk,
    input logic rst_n,

    write_config_i.s write_config,
    read_config_i.s  read_config,

    rdma_read_config_i.m out[NUM_STREAMS]
);

localparam MAX_NUM_ENQUEUED_BUFFERS = 64;
localparam NUM_WRITE_REGS = RDMA_READ_CONFIG_REGS;

`RESET_RESYNC // Reset pipelining

// -- Read -----------------------------------------------------------------------------------------
logic[AXIL_DATA_BITS - 1:0] values[2];
assign values[0] = RDMA_READ_CONFIG_ID;
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
    ready_valid_i #(vaddress_t) vaddr ();
    ConfigWriteFIFO #(I*NUM_WRITE_REGS+0, MAX_NUM_ENQUEUED_BUFFERS, vaddress_t) inst_vaddr (clk, reset_synced, write_config, vaddr);

    ready_valid_i #(data32_t) size ();
    ConfigWriteFIFO #(I*NUM_WRITE_REGS+1, MAX_NUM_ENQUEUED_BUFFERS, data32_t) inst_size (clk, reset_synced, write_config, size);

    assign out[I].vaddr = vaddr.data;
    assign out[I].size = size.data;
    assign out[I].valid = vaddr.valid && size.valid;

    assign vaddr.ready = size.valid && out[I].ready;
    assign size.ready = vaddr.valid && out[I].ready;
end

endmodule
