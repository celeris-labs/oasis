`timescale 1ns / 1ps

import libstf::*;
import oasis::RDMA_READ_CONFIG_NUM_REGS;
import oasis::RDMA_READ_CONFIG_ID;

`include "libstf_macros.svh"
`include "config_macros.svh"

module RDMAReadConfig (
    input logic clk,
    input logic rst_n,

    write_config_i.s write_config,
    read_config_i.s  read_config,

    rdma_read_config_i.m out
);

`RESET_RESYNC // Reset pipelining

// -- Read -----------------------------------------------------------------------------------------
logic[AXIL_DATA_BITS - 1:0] values[RDMA_READ_CONFIG_NUM_REGS];
assign values[0] = RDMA_READ_CONFIG_ID;
generate
for (genvar I = 1; I < RDMA_READ_CONFIG_NUM_REGS; I++) begin
    assign values[I] = '0;
end
endgenerate

ConfigReadRegisterFile #(
    .NUM_REGS(RDMA_READ_CONFIG_NUM_REGS)
) inst_read_regs (
    .clk(clk),
    .rst_n(reset_synced),

    .in(read_config),
    .values(values)
);

// -- Write ----------------------------------------------------------------------------------------
ready_valid_i #(vaddress_t) vaddr ();
ConfigWriteFIFO #(0, 16, vaddress_t) inst_vaddr (clk, reset_synced, write_config, vaddr);

ready_valid_i #(data32_t) size ();
ConfigWriteFIFO #(1, 16, data32_t) inst_size (clk, reset_synced, write_config, size);

assign out.vaddr = vaddr.data;
assign out.size = size.data;
assign out.valid = vaddr.valid && size.valid;

assign vaddr.ready = size.valid && out.ready;
assign size.ready = vaddr.valid && out.ready;

endmodule
