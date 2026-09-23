`timescale 1ns / 1ps

import libstf::*;
import oasis::NUM_BF_LAST_INJECT_CONFIG_REGS;
import oasis::BF_LAST_INJECT_CONFIG_ID;

`include "libstf_macros.svh"
`include "config_macros.svh"

/**
 * Configures the inline TLAST injector on the Bloom filter's input stream (see vfpga_top.svh).
 * Software supplies the absolute AXI beat index where the build side's key chunks logically end
 * (first_beat) and where the probe side's key chunks logically end (second_beat), so multiple
 * decoded row-group chunks on either side can be concatenated into the two logical transfers the
 * Bloom filter core expects, regardless of how many chunks each side actually decodes into.
 * enable=0 (the reset default, and what software currently always configures) leaves every
 * chunk's own decoder-generated tlast untouched.
 */
module BFLastInjectorConfig (
    input logic clk,
    input logic rst_n,

    write_config_i.s write_config,
    read_config_i.s  read_config,

    output logic        enable,
    output logic [31:0] first_beat,
    output logic [31:0] second_beat
);

`RESET_RESYNC // Reset pipelining

// -- Read -----------------------------------------------------------------------------------------
logic[AXIL_DATA_BITS - 1:0] values[1];
assign values[0] = BF_LAST_INJECT_CONFIG_ID;

ConfigReadRegisterFile #(
    .NUM_REGS(1)
) inst_read_regs (
    .clk(clk),
    .rst_n(reset_synced),

    .in(read_config),
    .values(values)
);

// -- Write ----------------------------------------------------------------------------------------
ConfigWriteRegister #(0, logic)        inst_enable_reg      (clk, write_config, enable);
ConfigWriteRegister #(1, logic [31:0]) inst_first_beat_reg  (clk, write_config, first_beat);
ConfigWriteRegister #(2, logic [31:0]) inst_second_beat_reg (clk, write_config, second_beat);

endmodule
