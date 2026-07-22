`timescale 1ns / 1ps

`include "axi_macros.svh"
`include "libstf_macros.svh"

import libstf::data8_t;
import lynxTypes::AXI_DATA_BITS;
import lynxTypes::LOCAL_READ;
import oasis::read_req_t;

/*
 * Issues local (host-memory) reads from a configured (vaddr, len) and streams the returned data
 * out as an ndata stream. The data arrives on the corresponding axis_host_recv stream.
 *
 * The host read path can only issue reads for DATABEAT_SIZE-aligned addresses, so ReadReqGenerator
 * rounds the address down and extends the length to cover the leading `head = vaddr % DATABEAT_SIZE`
 * bytes. We mask those `head` bytes off the first beat and re-pack the stream with a barrel shifter
 * + cross-beat merge.
 */
module LocalRead #(
    parameter AXI_STRM_ID = 0,
    parameter DATABEAT_SIZE = AXI_DATA_BITS / 8
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s conf,  // #(read_req_t)
    metaIntf.m      sq_rd, // #(.STYPE(req_t))

    AXI4S.s in,   // #(AXI_DATA_BITS)
                  // NOTE: This must be axis_host_recv[AXI_STRM_ID]
    ndata_i.m out // #(data8_t, DATABEAT_SIZE)
);

`RESET_RESYNC

localparam int OFFSET_WIDTH = $clog2(DATABEAT_SIZE);

// -- Request generation ---------------------------------------------------------------------------
ready_valid_i #(read_req_t) req (clk, reset_synced);

ReadReqGenerator #(
    .OPCODE(LOCAL_READ),
    .DEST(AXI_STRM_ID),
    .ALIGN_VADDR_TO(DATABEAT_SIZE)
) inst_req_gen (
    .clk(clk),
    .rst_n(reset_synced),
    
    .ctid('0), // Local reads always use the host process' Coyote thread (ID 0).

    .conf(conf),
    .sq_rd(sq_rd),
    .req(req)
);

// -- AXI -> ndata ---------------------------------------------------------------------------------
ndata_i #(data8_t, DATABEAT_SIZE) ndata (clk, reset_synced);

AXIToNData #(
    .data_t(data8_t),
    .NUM_ELEMENTS(DATABEAT_SIZE)
) inst_axi_to_ndata (
    .clk(clk),
    .rst_n(reset_synced),

    .in(in),
    .out(ndata)
);

// -- Head stripping -------------------------------------------------------------------------------
logic [OFFSET_WIDTH - 1:0] head;
logic [OFFSET_WIDTH - 1:0] shift_offset;
assign head         = req.data.vaddr[OFFSET_WIDTH - 1:0];
assign shift_offset = (DATABEAT_SIZE - head) & (DATABEAT_SIZE - 1);

logic in_transfer;
logic first_beat;
assign first_beat = !in_transfer;
always_ff @(posedge clk) begin
    if (!reset_synced) begin
        in_transfer <= 1'b0;
    end else if (ndata.valid && ndata.ready) begin
        in_transfer <= !ndata.last;
    end
end

assign req.ready = ndata.valid && ndata.ready && ndata.last;

ndata_i #(data8_t, DATABEAT_SIZE) masked (clk, reset_synced);
logic [DATABEAT_SIZE - 1:0] head_keep_mask;
assign head_keep_mask = {DATABEAT_SIZE{1'b1}} << head;

assign masked.data  = ndata.data;
assign masked.keep  = first_beat ? (ndata.keep & head_keep_mask) : ndata.keep;
assign masked.last  = ndata.last;
assign masked.valid = ndata.valid;
assign ndata.ready  = masked.ready;

// -- Barrel shifter -------------------------------------------------------------------------------
ndata_i #(data8_t, DATABEAT_SIZE) shifted (clk, reset_synced);
BarrelShifter #(
    .data_t(data8_t),
    .NUM_ELEMENTS(DATABEAT_SIZE),
    .REGISTER_LEVELS(1)
) inst_barrel_shifter (
    .clk(clk),
    .rst_n(reset_synced),

    .offset(shift_offset),

    .in(masked),
    .out(shifted)
);

// -- Cross-beat merge (output register) -----------------------------------------------------------
ndata_i #(data8_t, DATABEAT_SIZE) merged (clk, reset_synced);
DataBeatMerge #(
    .data_t(data8_t),
    .NUM_ELEMENTS(DATABEAT_SIZE)
) inst_merge (
    .clk(clk),
    .rst_n(reset_synced),

    .in(shifted),
    .out(merged)
);

NDataSkidBuffer #(
    .data_t(data8_t),
    .NUM_ELEMENTS(DATABEAT_SIZE)
) inst_out_skid (
    .clk(clk),
    .rst_n(reset_synced),

    .in(merged),
    .out(out)
);

`ifdef SYNTHESIS
ila_read inst_ila_local_read (
    .clk(clk),
    .probe0(reset_synced),

    .probe1(sq_rd.data),
    .probe2(sq_rd.valid),
    .probe3(sq_rd.ready),

    .probe4(conf.data),
    .probe5(conf.valid),
    .probe6(conf.ready),

    .probe7(req.data),
    .probe8(req.valid),
    .probe9(req.ready),

    .probe10(in.tkeep),
    .probe11(in.tlast),
    .probe12(in.tvalid),
    .probe13(in.tready),

    .probe14(out.keep),
    .probe15(out.last),
    .probe16(out.valid),
    .probe17(out.ready)
);
`endif

endmodule
