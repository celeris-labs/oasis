`timescale 1ns / 1ps

import lynxTypes::OPCODE_BITS;
import lynxTypes::LOCAL_READ;
import lynxTypes::STRM_HOST;
import lynxTypes::STRM_RDMA;
import lynxTypes::N_OUTSTANDING;
import oasis::read_req_t;

/*
 * Fires off read requests on sq_rd and pushes the issued requests into a FIFO. The FIFO output side
 * exposes the currently outstanding request on the req ready/valid interface so the consumer can
 * pop it once the corresponding read has completed.
 */
module ReadReqGenerator #(
    parameter [OPCODE_BITS-1:0] OPCODE, // LOCAL_READ or RDMA_READ
    parameter                   DEST,
    parameter                   FIFO_DEPTH = N_OUTSTANDING
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s conf, // #(read_req_t)
    metaIntf.m sq_rd,     // #(.STYPE(req_t))

    ready_valid_i.m req // #(read_req_t) Currently outstanding request
);

localparam IS_LOCAL = (OPCODE == LOCAL_READ);
localparam STRM     = IS_LOCAL ? STRM_HOST : STRM_RDMA;
localparam MODE     = IS_LOCAL ? 1'b0 : 1'b1;
localparam RDMA     = IS_LOCAL ? 1'b0 : 1'b1;
localparam REMOTE   = IS_LOCAL ? 1'b0 : 1'b1;

logic fifo_in_ready;
logic issued;
assign issued = conf.valid && sq_rd.ready;

always_comb begin
    sq_rd.data = '0; // Null everything else

    sq_rd.data.opcode = OPCODE;
    sq_rd.data.strm   = STRM;
    sq_rd.data.mode   = MODE;
    sq_rd.data.rdma   = RDMA;
    sq_rd.data.remote = REMOTE;

    // Note: We always send to coyote thread id 0.
    sq_rd.data.pid  = 0;
    sq_rd.data.dest = DEST;

    sq_rd.data.len   = conf.data.len;
    sq_rd.data.vaddr = conf.data.vaddr;

    // Note: We always mark the transfer as last so we get one acknowledgement per transfer.
    sq_rd.data.last = 1;

    sq_rd.valid = conf.valid && fifo_in_ready;
end

assign conf.ready = sq_rd.ready && fifo_in_ready;

// The issued request is pushed into the FIFO and exposed on the output side as the outstanding
// request. The consumer pops it (asserts req.ready) once the read has completed.
FIFO #(FIFO_DEPTH, $bits(read_req_t)) inst_fifo (
    .i_clk(clk),
    .i_rst_n(rst_n),

    .i_data(conf.data),
    .i_valid(issued),
    .i_ready(fifo_in_ready),

    .o_data(req.data),
    .o_valid(req.valid),
    .o_ready(req.ready),

    .o_filling_level()
);

endmodule
