`timescale 1ns / 1ps

import lynxTypes::*;

`include "axi_macros.svh"
`include "lynx_macros.svh"
`include "libstf_macros.svh"

// =================================================================================================
// Card-DMA shell adapter for handler_slots.  ARCHITECTURE.md, ADR-5.
//
// WHY IT EXISTS
// -------------
// handler_slots deliberately carries NO Coyote types: its card side is flat
// {valid, ready, vaddr, len, last} plus raw AXI stream wires, so the whole handler elaborates in
// xsim against unit-tests/card_dma/card_dma_model.sv with nothing but a lynxTypes stub.  This
// module is the one place where that flat side meets Coyote's `metaIntf #(req_t)` descriptors and
// `AXI4SR` card streams, and it is the one place a descriptor field can be wrong.  Keeping it out
// of vfpga_top.svh keeps the ONLY difference between the build-119 wiring and the slot wiring
// inside a handful of `ifdef HTTP_SLOTS` blocks.
//
// THE DESCRIPTOR, FIELD BY FIELD, AND WHERE EACH VALUE COMES FROM
// ---------------------------------------------------------------
// `req_t` has fifteen fields and only four of them are obvious.  The rest are copied from libstf's
// StreamWriter (parcore/libstf/hardware/src/hdl/output/stream_writer.sv:217-240), the request
// builder that has been running on hardware in every OASIS build, and each was then checked
// against what the shell actually DOES with it:
//
//   opcode  LOCAL_WRITE / LOCAL_READ   lynx_pkg_tmplt.txt:201-202
//   strm    STRM_CARD                  lynx_pkg_tmplt.txt:207; picks the card leg of
//                                      req_mux_stream_1_2 (user_wrapper_tmplt.txt:834-849)
//   mode    0    RDMA only (skips the request splitter in dreq_rdma_parser_wr); StreamWriter
//                passes ~IS_LOCAL, i.e. 0, for a local transfer
//   rdma    0    same
//   remote  0    same -- a card transfer is local by definition
//   vfid    0    "rsrvd" in lynx_pkg.  tlb_fsm never reads the request's copy: it stamps the ACK's
//                vfid from its own ID_REG parameter (tlb_fsm.sv:1203)
//   pid     CARD_PID (0)  NOT reserved.  It is the Coyote thread id and it KEYS THE TLB LOOKUP --
//                `lTlb.pid = pid_C` / `sTlb.pid = pid_C` (tlb_fsm.sv:693,699).  A descriptor with
//                the wrong pid looks up a page table that does not hold the slot page and takes a
//                page fault on the datapath.  StreamWriter hardcodes 0 with the comment "We always
//                send to coyote thread id 0" (stream_writer.sv:226-227) and OASIS's output path has
//                worked on hardware on that assumption since build-93, so cpid 0 is what the one
//                cThread this design creates gets.  Parameterised rather than literal so the day a
//                second cThread appears this is a port to drive and not a bug to find.
//   dest    0 for the write, 1+d for reader d.  Selects the card AXI stream (mmu_top.sv:219 ->
//                the per-dest cdma engines, dynamic_top_tmplt.txt:369-385)
//   last    1 on writes, 0 on reads.  See THE last=0 CONTRACT below
//   vaddr   the slot cursor handler_slots computed.  Byte granular: build-119 already compiles the
//                unaligned engine cdma_u (cr_shell.tcl:93)
//   len     byte count, byte granular, never 0
//   actv    0    "rsrvd"; req_parser forwards it untouched (req_parser.sv:168), nothing reads it
//   host    0    NOT reserved in the ack.  tlb_fsm latches it from the request (tlb_fsm.sv:827) and
//                stamps it into the completion (tlb_fsm.sv:744,1200).  The host's own invokes set
//                it to 1 (cnfg_slave.sv:1195), so `host == 0` means "this completion belongs to a
//                request the vFPGA made", and the write-ack filter below tests it.  Without that
//                test a host-side LOCAL_WRITE to card dest 0 -- which cq_arb delivers into the user
//                region just the same (cq_arb.sv:35-37) -- would advance landed[] for a write we
//                never issued.
//   offs    0    "rsrvd"; req_parser overwrites it with 0 anyway (req_parser.sv:170)
//   rsrvd   0
//
// THE last=0 CONTRACT, VERIFIED AGAINST THE RTL
// ----------------------------------------------
// slot_reader issues `last = 0` reads and has no ack input at all; it counts bytes.  That rests on
// two claims, both checked in Coyote's RTL rather than in its comments:
//
//   1. NO COMPLETION.  tlb_fsm stores one ack-enable bit per DMA chunk, `!len_C && last_C`
//      (tlb_fsm.sv:745), and raises the completion only when that bit is set:
//      `card_done[i].valid = ddma_rsp[i].done && ack_buff_card_src_data[i][...+1+:1]`
//      (tlb_fsm.sv:1196).  With last = 0 the bit is 0 for every chunk, so no `cq_rd` beat is ever
//      produced.  The buffer is still POPPED on every DMA response (`ack_buff_card_src_ready[i] =
//      ddma_rsp[i].done`, tlb_fsm.sv:1193), so nothing leaks and nothing goes out of step.
//   2. NO tlast.  mmu_assign forces `last = 1` towards the engine and queues the user's bit
//      (mmu_assign.sv:50,56), and axis_last_rewriter ANDs the returning stream's tlast with it:
//      `m_axis.tlast = s_axis.tlast && s_fwd_last.data` (axis_last_rewriter.sv:48).  With last = 0
//      the user's stream carries no tlast, which is what strip_http wants -- it frames on
//      Content-Length and a spurious tlast would cut a response short.
//
// Consuming `cq_rd` anyway is free and is done regardless (ready tied high): if some future Coyote
// does complete a last=0 read, the beat is swallowed instead of wedging cq_arb's queue.
//
// THE COMPLETION FAN-OUT
// ----------------------
// `cq_wr` is one stream shared with OutputWriter, so vfpga_top duplicates it and both consumers
// filter.  Neither may ever stall the other: StreamWriter holds `cq_wr.ready = 1` unconditionally
// (stream_writer.sv:209) and so does this module.  meta_intf_dup2 at the bottom of this file is the
// metaIntf twin of libstf's ReadyValidDuplicator and tolerates one side being slow anyway.
//
// WHERE THE N_CARD_AXI = 2 FALLBACK WOULD GO
// -------------------------------------------
// The plan's fallback is one shared read stream with a dest-tagged mux instead of one per decoder.
// It lands ENTIRELY inside this module: the per-reader legs already exist, so the fallback makes
// RD_DEST_BASE + D collapse to a single dest, keeps the same MetaIntfArbiter, and adds an in-order
// {decoder, bytes} queue in front of a demux on the one `axis_card_recv[1]`.  handler_slots does
// not change, because it never learns which dest its bytes came from.
// =================================================================================================
module slot_dma_shell #(
    // Read channels, one per decoder.
    parameter int N_RD         = 4,
    // Card AXI streams the shell was built with; must be N_RD + 1.
    parameter int N_CARD       = 5,
    // Card stream carrying slot_writer's data, and the base of the readers'.
    parameter int WR_DEST      = 0,
    parameter int RD_DEST_BASE = 1,
    // Coyote thread id whose page table holds the slot page.  See the field table above.
    parameter int CARD_PID     = 0,
    // Register-slice depth towards the shell.  The HBM crossbar is physically far from the user
    // region and build-119 already closes at WNS -1.474 ns, so these are not optional.
    parameter int REG_STAGES   = 2
) (
    input  logic clk,
    input  logic rst_n,

    // -- flat side: slot_writer ------------------------------------------------------------------
    input  logic                       wr_req_valid,
    output logic                       wr_req_ready,
    input  logic [VADDR_BITS-1:0]      wr_req_vaddr,
    input  logic [LEN_BITS-1:0]        wr_req_len,
    input  logic                       wr_req_last,
    input  logic                       wr_tvalid,
    output logic                       wr_tready,
    input  logic [AXI_DATA_BITS-1:0]   wr_tdata,
    input  logic [AXI_DATA_BITS/8-1:0] wr_tkeep,
    input  logic                       wr_tlast,
    output logic                       wr_ack,

    // -- flat side: slot_reader[d] ---------------------------------------------------------------
    input  logic                       rd_req_valid [N_RD],
    output logic                       rd_req_ready [N_RD],
    input  logic [VADDR_BITS-1:0]      rd_req_vaddr [N_RD],
    input  logic [LEN_BITS-1:0]        rd_req_len   [N_RD],
    input  logic                       rd_req_last  [N_RD],
    output logic                       rd_tvalid [N_RD],
    input  logic                       rd_tready [N_RD],
    output logic [AXI_DATA_BITS-1:0]   rd_tdata  [N_RD],
    output logic [AXI_DATA_BITS/8-1:0] rd_tkeep  [N_RD],
    output logic                       rd_tlast  [N_RD],

    // -- Coyote side -----------------------------------------------------------------------------
    // This shell's leg of the sq_wr arbiter it shares with OutputWriter.
    metaIntf.m sq_wr,
    // A duplicate of the shared completion stream; filtered here, never back-pressured.
    metaIntf.s cq_wr,
    // The read submission queue, ours alone.
    metaIntf.m sq_rd,
    // Read completions.  See THE last=0 CONTRACT: none is expected, all are swallowed.
    metaIntf.s cq_rd,

    AXI4SR.m   axis_card_send [N_CARD],
    AXI4SR.s   axis_card_recv [N_CARD]
);

`ASSERT_ELAB(N_RD >= 1)
`ASSERT_ELAB(N_CARD == N_RD + 1)
`ASSERT_ELAB(RD_DEST_BASE + N_RD <= (1 << DEST_BITS))
`ASSERT_ELAB(WR_DEST < RD_DEST_BASE)

// =================================================================================================
// Write descriptors.  One leg of the shared sq_wr arbiter, registered on the way out.
// =================================================================================================
metaIntf #(.STYPE(req_t)) sq_wr_int (.aclk(clk), .aresetn(rst_n));

always_comb begin
    sq_wr_int.data        = '0;          // null every reserved field in one place
    sq_wr_int.data.opcode = LOCAL_WRITE;
    sq_wr_int.data.strm   = STRM_CARD;
    sq_wr_int.data.mode   = 1'b0;
    sq_wr_int.data.rdma   = 1'b0;
    sq_wr_int.data.remote = 1'b0;
    sq_wr_int.data.vfid   = '0;
    sq_wr_int.data.pid    = PID_BITS'(CARD_PID);
    sq_wr_int.data.dest   = DEST_BITS'(WR_DEST);
    sq_wr_int.data.last   = wr_req_last; // slot_writer holds this at 1: one cq_wr per segment
    sq_wr_int.data.vaddr  = wr_req_vaddr;
    sq_wr_int.data.len    = wr_req_len;
    sq_wr_int.data.actv   = 1'b0;
    sq_wr_int.data.host   = 1'b0;        // a vFPGA-issued request, see the field table
    sq_wr_int.data.offs   = '0;
    sq_wr_int.data.rsrvd  = '0;

    sq_wr_int.valid = wr_req_valid;
end
assign wr_req_ready = sq_wr_int.ready;

meta_reg_array #(
    .DATA_BITS($bits(req_t)),
    .N_STAGES (REG_STAGES)
) inst_sq_wr_reg (.aclk(clk), .aresetn(rst_n), .s_meta(sq_wr_int), .m_meta(sq_wr));

// -- Write completions ---------------------------------------------------------------------------
// One pulse per completed descriptor, in issue order -- slot_writer's landed[] depends on both
// properties.  The order comes from cdma_u's single status fifo per channel; the filter is what
// keeps OutputWriter's host completions, and any host-side card invoke, out of the count.
assign cq_wr.ready = 1'b1;
assign wr_ack = cq_wr.valid
             && (cq_wr.data.strm == STRM_BITS'(STRM_CARD))
             && (cq_wr.data.dest == DEST_BITS'(WR_DEST))
             && (cq_wr.data.host == 1'b0);

// =================================================================================================
// Read descriptors.  One leg per decoder, round-robin onto the single sq_rd, registered on the way
// out.  The arbiter is libstf's, the same one OutputWriter uses for its own sq_wr legs.
// =================================================================================================
metaIntf #(.STYPE(req_t)) sq_rd_leg [N_RD] (.aclk(clk), .aresetn(rst_n));
metaIntf #(.STYPE(req_t)) sq_rd_int (.aclk(clk), .aresetn(rst_n));

for (genvar D = 0; D < N_RD; D++) begin : gen_rd_req
    always_comb begin
        sq_rd_leg[D].data        = '0;
        sq_rd_leg[D].data.opcode = LOCAL_READ;
        sq_rd_leg[D].data.strm   = STRM_CARD;
        sq_rd_leg[D].data.mode   = 1'b0;
        sq_rd_leg[D].data.rdma   = 1'b0;
        sq_rd_leg[D].data.remote = 1'b0;
        sq_rd_leg[D].data.vfid   = '0;
        sq_rd_leg[D].data.pid    = PID_BITS'(CARD_PID);
        sq_rd_leg[D].data.dest   = DEST_BITS'(RD_DEST_BASE + D);
        sq_rd_leg[D].data.last   = rd_req_last[D];  // slot_reader holds this at 0
        sq_rd_leg[D].data.vaddr  = rd_req_vaddr[D];
        sq_rd_leg[D].data.len    = rd_req_len[D];
        sq_rd_leg[D].data.actv   = 1'b0;
        sq_rd_leg[D].data.host   = 1'b0;
        sq_rd_leg[D].data.offs   = '0;
        sq_rd_leg[D].data.rsrvd  = '0;

        sq_rd_leg[D].valid = rd_req_valid[D];
    end
    assign rd_req_ready[D] = sq_rd_leg[D].ready;
end

// MetaIntfArbiter computes $clog2(N_INTERFACES) and would build a [-1:0] select at N_RD == 1.
generate if (N_RD == 1) begin : gen_rd_single
    `META_ASSIGN(sq_rd_leg[0], sq_rd_int)
end else begin : gen_rd_arb
    MetaIntfArbiter #(
        .N_INTERFACES(N_RD),
        .STYPE(req_t)
    ) inst_sq_rd_arbiter (
        .clk(clk),
        .rst_n(rst_n),
        .intf_in(sq_rd_leg),
        .intf_out(sq_rd_int)
    );
end endgenerate

meta_reg_array #(
    .DATA_BITS($bits(req_t)),
    .N_STAGES (REG_STAGES)
) inst_sq_rd_reg (.aclk(clk), .aresetn(rst_n), .s_meta(sq_rd_int), .m_meta(sq_rd));

// Swallowed, see THE last=0 CONTRACT.  tie_off_s() on a metaIntf holds ready HIGH
// (lynx_intf.sv:50-52), which is consume-and-discard rather than block -- what is wanted here.
always_comb cq_rd.tie_off_s();

`ifndef SYNTHESIS
// If this ever prints, the last=0 finding above has been invalidated by a Coyote upgrade and
// slot_reader's "no ack, count bytes" assumption needs re-reading -- not because the beat hurts
// (it is swallowed) but because it would mean the completion semantics moved.
logic cq_rd_warned = 1'b0;
always_ff @(posedge clk) begin
    if (rst_n && cq_rd.valid && !cq_rd_warned) begin
        $display("slot_dma_shell: NOTE t=%0t a cq_rd arrived for a last=0 read (strm=%0d dest=%0d)",
                 $time, cq_rd.data.strm, cq_rd.data.dest);
        cq_rd_warned <= 1'b1;
    end
end
`endif

// =================================================================================================
// Card data streams.
//
// axis_card_send[WR_DEST] <- slot_writer, axis_card_recv[RD_DEST_BASE+d] -> slot_reader[d], every
// other stream tied off the way vfpga_top ties off the host streams it does not use.  The register
// slices sit here, i.e. immediately at the user-logic boundary, because that is the crossing the
// HBM shell is far from.
// =================================================================================================
AXI4S wr_axis_in  (.aclk(clk), .aresetn(rst_n));
AXI4S wr_axis_out (.aclk(clk), .aresetn(rst_n));

assign wr_axis_in.tdata  = wr_tdata;
assign wr_axis_in.tkeep  = wr_tkeep;
assign wr_axis_in.tlast  = wr_tlast;
assign wr_axis_in.tvalid = wr_tvalid;
assign wr_tready         = wr_axis_in.tready;

axis_reg_array #(
    .N_STAGES(REG_STAGES)
) inst_card_send_reg (.aclk(clk), .aresetn(rst_n), .s_axis(wr_axis_in), .m_axis(wr_axis_out));

assign axis_card_send[WR_DEST].tdata  = wr_axis_out.tdata;
assign axis_card_send[WR_DEST].tkeep  = wr_axis_out.tkeep;
assign axis_card_send[WR_DEST].tlast  = wr_axis_out.tlast;
assign axis_card_send[WR_DEST].tvalid = wr_axis_out.tvalid;
assign axis_card_send[WR_DEST].tid    = '0;   // StreamWriter does the same; the shell ignores it
assign wr_axis_out.tready             = axis_card_send[WR_DEST].tready;

// Nothing is read from card stream 0 and nothing is written to the read streams.
always_comb axis_card_recv[WR_DEST].tie_off_s();

for (genvar D = 0; D < N_RD; D++) begin : gen_rd_data
    AXI4S rd_axis_in  (.aclk(clk), .aresetn(rst_n));
    AXI4S rd_axis_out (.aclk(clk), .aresetn(rst_n));

    assign rd_axis_in.tdata  = axis_card_recv[RD_DEST_BASE + D].tdata;
    assign rd_axis_in.tkeep  = axis_card_recv[RD_DEST_BASE + D].tkeep;
    assign rd_axis_in.tlast  = axis_card_recv[RD_DEST_BASE + D].tlast;
    assign rd_axis_in.tvalid = axis_card_recv[RD_DEST_BASE + D].tvalid;
    assign axis_card_recv[RD_DEST_BASE + D].tready = rd_axis_in.tready;

    axis_reg_array #(
        .N_STAGES(REG_STAGES)
    ) inst_card_recv_reg (.aclk(clk), .aresetn(rst_n), .s_axis(rd_axis_in), .m_axis(rd_axis_out));

    assign rd_tvalid[D]       = rd_axis_out.tvalid;
    assign rd_tdata[D]        = rd_axis_out.tdata;
    assign rd_tkeep[D]        = rd_axis_out.tkeep;
    assign rd_tlast[D]        = rd_axis_out.tlast;
    assign rd_axis_out.tready = rd_tready[D];

    always_comb axis_card_send[RD_DEST_BASE + D].tie_off_m();
end

endmodule

// =================================================================================================
// Two-way fan-out of a metaIntf, for a completion stream both consumers must see.
//
// This is libstf's ReadyValidDuplicator (util/ready_valid_helpers.sv:7) transcribed onto metaIntf,
// which is a different interface type and cannot be handed to it.  The `seen` register is what
// makes it safe when the two sides are not ready in the same cycle: whoever took the beat first
// stops seeing it, and the input is only retired once everyone has.  In THIS design both consumers
// hold ready high for ever -- StreamWriter (stream_writer.sv:209) and slot_dma_shell above -- so
// the register never does anything; it is here so that a future consumer that DOES back-pressure
// cannot turn into a silently dropped completion.
// =================================================================================================
module meta_intf_dup2 #(
    parameter type STYPE = logic[63:0]
) (
    input  logic clk,
    input  logic rst_n,

    metaIntf.s in,
    metaIntf.m out_0,
    metaIntf.m out_1
);

logic [1:0] out_ready, seen, n_seen;

assign out_ready = {out_1.ready, out_0.ready};
assign in.ready  = &(seen | out_ready);

always_ff @(posedge clk) begin
    if (!rst_n) begin
        seen <= '0;
    end else begin
        seen <= n_seen;
    end
end

always_comb begin
    n_seen = seen;

    if (in.ready) begin
        n_seen = '0;
    end else if (in.valid) begin
        n_seen = seen | out_ready;
    end
end

assign out_0.data  = in.data;
assign out_0.valid = in.valid && !seen[0];
assign out_1.data  = in.data;
assign out_1.valid = in.valid && !seen[1];

endmodule
