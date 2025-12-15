`timescale 1ns / 1ps

`include "axi_macros.svh"
`include "parcore_types.svh"

import libstf::data8_t;

// Fixes the last signal on CARD/RDMA streams, which is set high every 4KiB,
// and not on the actual last databeat.
module FixLast #(
    parameter DATABEAT_SIZE = AXI_DATA_BITS / 8
) (
    input logic clk,
    input logic rst_n,

    valid_i.s size,        // #(data64_t)

    ndata_i.m in,       // #(data8_t, DATABEAT_SIZE)
    ndata_i.m out       // #(data8_t, DATABEAT_SIZE)
);

valid_i #(data64_t) remaining ();
logic actual_last;

always_ff @(posedge clk) begin
    if (rst_n == 1'b0) begin
        remaining.valid <= 0;
    end else begin
        if (size.valid) begin
            remaining.valid <= 1;
            remaining.data <= size.data;
        end

        if (out.ready && out.valid) begin
            remaining.data <= remaining.data - DATABEAT_SIZE;

            if (actual_last) begin
                remaining.valid <= 0;
            end
        end
    end
end

assign actual_last = remaining.valid && remaining.data <= DATABEAT_SIZE;

assign in.ready = out.ready;
assign out.valid = in.valid;
assign out.data = in.data;
assign out.keep = in.keep;
assign out.last = actual_last;

endmodule
