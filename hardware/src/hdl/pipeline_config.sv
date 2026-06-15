`timescale 1ns / 1ps

import libstf::*;
import oasis::*;

`include "libstf_macros.svh"

module PipelineConfig (
    input logic clk,
    input logic rst_n,

    write_config_i.s write_config,
    read_config_i.s  read_config,

    output logic filter_enabled
);

`RESET_RESYNC

data64_t values[PIPELINE_CONFIG_REGS];
assign values[0] = PIPELINE_CONFIG_ID;
assign values[1] = filter_enabled;

ConfigReadRegisterFile #(
    .NUM_REGS(PIPELINE_CONFIG_REGS)
) inst_read_regs (
    .clk(clk),
    .rst_n(reset_synced),
    .in(read_config),
    .values(values)
);

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        filter_enabled <= 1'b0;
    end else if (write_config.valid && write_config.addr == 0) begin
        filter_enabled <= write_config.data[0];
    end
end

endmodule
