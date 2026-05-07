`timescale 1ns / 1ps

import lynxTypes::*;
import libstf::data8_t;

// Fixes the last signal on CARD/RDMA streams, which is set high every 4KiB,
// and not on the actual last databeat.
module FixLast #(
    parameter NUM_ELEMENTS = AXI_DATA_BITS / 8
) (
    input logic clk,
    input logic rst_n,

    valid_i.s size,        // #(data64_t)
    output data64_t rem,

    ndata_i.s in,       // #(data8_t, NUM_ELEMENTS)
    ndata_i.m out       // #(data8_t, NUM_ELEMENTS)
);

data64_t remaining;

always_ff @(posedge clk) begin
    if (rst_n == 1'b0) begin
        remaining <= '0;
    end else begin
        if (size.valid) begin
            remaining <= size.data;
        end else if (out.ready && out.valid) begin
            remaining <= remaining - NUM_ELEMENTS;
        end
    end
end

logic[NUM_ELEMENTS - 1:0] last_keep;
assign last_keep = ~({NUM_ELEMENTS{1'b1}} >> remaining[$clog2(NUM_ELEMENTS) - 1:0]);

assign in.ready = out.ready;
assign out.valid = in.valid;
assign out.data = in.data;
assign out.keep = remaining < NUM_ELEMENTS ? last_keep : {NUM_ELEMENTS{1'b1}};
assign out.last = remaining <= NUM_ELEMENTS;

assign rem = remaining;

endmodule
