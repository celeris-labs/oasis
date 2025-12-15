`timescale 1ns / 1ps

`include "axi_macros.svh"
`include "parcore_types.svh"

import libstf::data8_t;
import parcore::*;

module RDMARead #(
    parameter AXI_DATA_BITS = 512,
    parameter AXI_STRM_ID = 0,
    parameter DATABEAT_SIZE = AXI_DATA_BITS / 8
) (
    input logic clk,
    input logic rst_n,

    metaIntf.m sq_rd,    // #(.STYPE(req_t))
    metaIntf.s cq_rd,    // #(.STYPE(ack_t))
    AXI4S.s rdma_in,     // #(AXI_DATA_BITS)
                         // NOTE: This must be axis_rreq_recv[AXI_STRM_ID]

    ready_valid_i.s in,  // #(rdma_buffer_t)

    ndata_i.m out        // #(data8_t, DATABEAT_SIZE)
);

localparam RDMA_READ = 12;
localparam STRM = STRM_RDMA;
localparam OPCODE = RDMA_READ;

typedef enum logic {
    ST_IDLE,
    ST_READING
} state_t;

// ------- State machine state -----------------------------------------------
state_t state;
logic keep_ack, keep_last;

// ------- Combinatorial state -----------------------------------------------
logic ack, last;

// ------- State machine logic  ----------------------------------------------
logic request_sent, received_ack, received_last;
assign request_sent = sq_rd.ready && sq_rd.valid;
assign received_ack = cq_rd.ready && cq_rd.valid && cq_rd.data.strm == STRM && cq_rd.data.dest == AXI_STRM_ID && cq_rd.data.opcode == OPCODE;
assign received_last = out.ready && out.valid && out.last;

task reset();
    state <= ST_IDLE;
    keep_ack <= 0;
    keep_last <= 0;
endtask

always_ff @(posedge clk) begin
    if (rst_n == 1'b0) begin
        reset();
    end else begin
        if (received_ack) begin
          keep_ack <= 1;
        end

        if (received_last) begin
          keep_last <= 1;
        end

        case (state)
            ST_IDLE: begin
                if (request_sent) begin
                    state <= ST_READING;
                end
            end

            ST_READING: begin
                if (ack && last) begin
                    reset();
                end
            end
        endcase
    end
end

assign ack = keep_ack || received_ack;
assign last = keep_last || received_last;

ndata_i #(data8_t, DATABEAT_SIZE) out_inner ();
AXIToNData #(
  .data_t(data8_t),
  .NUM_ELEMENTS(DATABEAT_SIZE)
) inst_axi_to_ndata(
    .clk(clk),
    .rst_n(rst_n),

    .in(rdma_in),
    .out(out_inner)
);

valid_i #(data64_t) size ();
assign size.valid = request_sent;
assign size.data = buffer.size;

FixLast #(.DATABEAT_SIZE(DATABEAT_SIZE)) inst_fix_last (
    .clk(clk),
    .rst_n(rst_n),

    .size(size),

    .in(out_inner),
    .out(out)
);

rdma_buffer_t buffer;
assign buffer = in.data;

always_comb begin
    sq_rd.data = '0; // Null everything else

    sq_rd.data.opcode = OPCODE;
    sq_rd.data.strm   = STRM;
    sq_rd.data.mode   = 1;
    sq_rd.data.rdma   = 1;
    sq_rd.data.remote = 1;
  
    // Note: We always send to coyote thread id 0.
    sq_rd.data.pid  = 0;
    sq_rd.data.dest = AXI_STRM_ID;

    sq_rd.data.len = buffer.size;
    sq_rd.data.vaddr = buffer.vaddr;
   
    // We always mark the transfer as last so we get
    // one acknowledgement per transfer!
    sq_rd.data.last = 1;

    sq_rd.valid = (state == ST_IDLE) && in.valid && in.ready;
end

// Accept acks when we haven't received one for the current transaction.
assign cq_rd.ready = ~keep_ack;
// We can take in another input buffer to kick-off a read when we're not
// already waiting for an in-progress read.
assign in.ready = (state == ST_IDLE) && sq_rd.ready;

`ifdef SYNTHESIS
ila_rdma_read inst_ila_rdma_read (
    .clk(clk),
    .probe0(rst_n),

    .probe1(sq_rd.ready),
    .probe2(sq_rd.valid),
    .probe3(sq_rd.data),
    .probe4(sq_rd.data.vaddr),
    .probe5(sq_rd.data.len),

    .probe6(cq_rd.ready),
    .probe7(cq_rd.valid),
    .probe8(cq_rd.data),

    .probe9(rdma_in.tready),
    .probe10(rdma_in.tvalid),

    .probe11(in.ready),
    .probe12(in.valid),

    .probe13(out.ready),
    .probe14(out.valid),
    .probe15(out.last),

    .probe16(out_inner.ready),
    .probe17(out_inner.valid),
    .probe18(out_inner.last),

    .probe19(state),
    .probe20(ack),
    .probe21(last)
);
`endif

endmodule
