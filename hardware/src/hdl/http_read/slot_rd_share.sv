`timescale 1ns / 1ps

import lynxTypes::*;

// =================================================================================================
// One card read channel, N decoders. ARCHITECTURE.md, ADR-5 (2026-09-22 addendum).
//
// WHY IT EXISTS
// -------------
// ADR-5 was built with one card AXI stream per decoder, so each slot_reader owned a read engine and
// nobody could be delayed by anybody else. build-123 proved that unaffordable: every card AXI stream
// costs ~25k LUT / ~42k FF / ~32 RAMB36 of Coyote SHELL (a cdma, an HBM path_i, a 3-stage 577-bit
// register array each way, mmu queues, card credits), 79% of that growth placed in SLR0 next to the
// HBM controller, SLR0 reached 99.55% CLB occupancy and route_design failed with 34,111 unroutable
// signals. (oasis-debug/2026-09-22/build-123-postmortem/deltas.txt.) The user logic was innocent:
// handler_slots is 22.2k LUT against handler_multi's 21.3k and it FREES 112 RAMB36.
//
// So there is now ONE read channel for every decoder, and this module is the thing that makes that
// safe. Sharing a channel naively would reintroduce, inside the card path, the exact fault ADR-5
// exists to remove: read data comes back in REQUEST order on one AXI stream, so if decoder 0 is
// slow and its bytes are at the head, back-pressuring the stream starves decoders 1..3 --
// head-of-line coupling, measured fatal on hardware at 3 lanes on the old design.
//
// THE RULE THAT REMOVES IT
// ------------------------
// The shared stream is NEVER back-pressured. `ch_tready` is a literal 1'b1 (not a mux of fifo
// readys, not a level compare -- a constant, so that no future edit can make a slow decoder reach
// it). What makes that safe is a reservation, not luck:
//
//   * every decoder has its own receive fifo of FIFO_DEPTH = 2 x RD_MAX bytes;
//   * a read request from decoder d is only ever handed to the channel when d's fifo has room for
//     RD_MAX bytes BEYOND everything already reserved by its outstanding requests and everything
//     already sitting in the fifo (`committed_q[d]`);
//   * so every beat the channel returns has a home the instant it arrives.
//
// `committed_q[d]` counts beats from the moment the request is taken from the reader -- not from
// when the channel accepts it -- because at most one request sits in the issue register uncounted
// otherwise, and that one request is exactly enough to overrun the fifo by RD_MAX. Counting at the
// grant makes the credit compare EXACT rather than nearly right.
//
// It is decremented when a beat leaves the fifo towards the reader, i.e. when the decoder has
// genuinely consumed it. A stalled decoder therefore stops getting credit, which is the whole
// point: it stops asking for data it cannot take, and the channel keeps running for everybody else.
//
// WHAT THIS DOES NOT BUY BACK
// ---------------------------
// One channel is one channel: 512 bits at 250 MHz, 16 GB/s, shared. A decoder draining at line rate
// can no longer have the whole channel while another decoder is also draining -- that is arithmetic,
// not coupling, and it is why RD_MAX dropped from 64 KiB to 16 KiB in the same change (the channel
// is handed back to the arbiter four times as often, so the worst-case wait for a decoder whose turn
// is behind somebody else's read is 256 beats, ~1 us, instead of 1024). Measured decoder intake is
// 0.53-1.8 GB/s each (ADR-5), so four decoders want ~25% of the channel and the sharing is free at
// the real operating point. unit-tests/slot_reader `rslow`/`rsolo` report both: at a realistic sink
// rate a slow decoder costs the fast one NOTHING, and at an unrealistic flat-out sink rate it costs
// exactly the bandwidth the slow decoder itself used.
//
// IN-ORDER RETURN, AND WHY A QUEUE IS ENOUGH
// ------------------------------------------
// A last=0 read draws no completion (slot_dma_shell's last=0 contract) and carries no tlast, so
// there is no marker in the data saying where one read's bytes end. What says it is arithmetic:
// exactly ceil(len/64) beats come back per request, the last of them partial, in the order the
// requests were accepted -- one channel, one cdma read engine, one status fifo. So an in-order
// queue of {decoder, beats} pushed at the grant and popped as the beats are counted off is the
// whole demux. `order_err` latches if a beat arrives with the queue empty or the queue would
// overflow; either would mean that premise is wrong, and no silent mis-steering is possible because
// the beat is dropped rather than guessed at.
//
// DESIGN FOR SYNTHESIS (build-119 closes at WNS -1.474 ns; this adds no depth to a shared path)
// ---------------------------------------------------------------------------------------------
//   * the credit compare is REGISTERED: committed_q -> add/subtract -> compare -> credit_ok_q, and
//     the arbiter reads credit_ok_q. Nothing walks from a beat handshake into rd_req_ready.
//   * the arbiter's decision is captured in a one-deep issue register before it reaches the
//     channel, so the longest request path is (rd_req_valid & credit_ok_q) -> round-robin priority
//     -> N:1 mux of a 48-bit vaddr -> register.
//   * the receive demux steers off `hd_sel_q`, a REGISTER holding the head of the order queue, not
//     off a mux over the queue memory. The beat path is register -> 1-of-N decode -> fifo write.
// =================================================================================================
module slot_rd_share #(
    // Readers sharing the channel. One per decoder.
    parameter int N_RD     = 4,
    // The most one read may ask for, in bytes. Must match the readers' RD_MAX: it sizes both the
    // fifos and the credit, and a longer request would overrun them.
    parameter int RD_MAX   = 16384,
    // Requests accepted by the channel and not yet fully returned. Coyote's cdma allows 8
    // (N_OUTSTANDING) and the readers allow 2 each, so this is margin, not a limit.
    parameter int OQ_DEPTH = 16,

    localparam int BYTES     = AXI_DATA_BITS/8,
    localparam int LBYTES    = $clog2(AXI_DATA_BITS/8),
    localparam int MAXBEATS  = (RD_MAX + BYTES - 1) / BYTES,
    // 2 x RD_MAX per decoder: exactly the two outstanding reads slot_reader allows, so the credit
    // never costs throughput. 512 x 577 bits = one BRAM row, ~9 RAMB36 each; the redesign freed 112.
    localparam int FIFO_DEPTH= 2 * MAXBEATS,
    localparam int BCNT_BITS = $clog2(MAXBEATS + 1),
    // Enough bits for any length a reader may legally ask for, and no more; see gen_nbeats.
    localparam int LEN_W     = $clog2(RD_MAX + 1),
    localparam int OCC_BITS  = $clog2(FIFO_DEPTH + 1),
    localparam int SEL_BITS  = (N_RD > 1) ? $clog2(N_RD) : 1,
    localparam int OQP_BITS  = $clog2(OQ_DEPTH),
    localparam int OQC_BITS  = $clog2(OQ_DEPTH + 1)
) (
    input  logic clk,
    input  logic rst_n,

    // -- reader side: requests, exactly as slot_reader presents them -------------------------------
    input  logic                       rd_req_valid [N_RD],
    output logic                       rd_req_ready [N_RD],
    input  logic [VADDR_BITS-1:0]      rd_req_vaddr [N_RD],
    input  logic [LEN_BITS-1:0]        rd_req_len   [N_RD],
    input  logic                       rd_req_last  [N_RD],

    // -- reader side: data ------------------------------------------------------------------------
    output logic                       rd_tvalid [N_RD],
    input  logic                       rd_tready [N_RD],
    output logic [AXI_DATA_BITS-1:0]   rd_tdata  [N_RD],
    output logic [BYTES-1:0]           rd_tkeep  [N_RD],
    output logic                       rd_tlast  [N_RD],

    // -- channel side: ONE request port and ONE stream ---------------------------------------------
    output logic                       ch_req_valid,
    input  logic                       ch_req_ready,
    output logic [VADDR_BITS-1:0]      ch_req_vaddr,
    output logic [LEN_BITS-1:0]        ch_req_len,
    output logic                       ch_req_last,

    input  logic                       ch_tvalid,
    output logic                       ch_tready,
    input  logic [AXI_DATA_BITS-1:0]   ch_tdata,
    input  logic [BYTES-1:0]           ch_tkeep,
    input  logic                       ch_tlast,

    // -- visibility --------------------------------------------------------------------------------
    // Sticky. order_err: a beat arrived with nothing outstanding, or the order queue would have
    // overflowed -- the in-order premise above is broken. fifo_err: a receive fifo refused a beat,
    // which the credit is supposed to make impossible. len_err: a request longer than RD_MAX, which
    // the beat count cannot represent. None of them can be true of a correct configuration; they
    // exist so that a wrong one says so instead of corrupting a body.
    output logic                       order_err,
    output logic                       fifo_err,
    output logic                       len_err,
    // Level. credit_ok[d] low means d is holding station because its fifo is full, which is the
    // design working, not a fault. The benches watch it to prove the credit ever bound.
    output logic [N_RD-1:0]            credit_ok,
    output logic [OQC_BITS-1:0]        oq_occ
);

    // ---------------------------------------------------------------------------------------------
    // Beats per request. slot_reader clamps len to RD_MAX, so the count fits BCNT_BITS; len_err
    // latches if it ever does not, because the truncation would silently mis-frame the demux.
    // ---------------------------------------------------------------------------------------------
    logic [BCNT_BITS-1:0] nbeats_w [N_RD];
    logic [N_RD-1:0]      overlong_w;

    for (genvar D = 0; D < N_RD; D++) begin : gen_nbeats
        // Only the bits a legal length can use. The rounding add is the longest carry chain in the
        // request path -- it feeds the credit compare -- and doing it on all LEN_BITS (28) of a
        // field that can never exceed RD_MAX would nearly double it for nothing. `overlong_w`
        // keeps the assumption honest on the full width.
        logic [LEN_W-1:0] len_up_w;
        assign len_up_w      = rd_req_len[D][LEN_W-1:0] + LEN_W'(BYTES - 1);
        assign nbeats_w[D]   = BCNT_BITS'(len_up_w >> LBYTES);
        assign overlong_w[D] = rd_req_valid[D] && (rd_req_len[D] > LEN_BITS'(RD_MAX));
    end

    // ---------------------------------------------------------------------------------------------
    // Credit. committed_q[d] = beats this decoder has reserved: asked for and not yet delivered,
    // plus delivered and not yet taken out of its fifo.
    // ---------------------------------------------------------------------------------------------
    logic [OCC_BITS-1:0] committed_q [N_RD];
    logic [N_RD-1:0]     credit_ok_q;
    logic [N_RD-1:0]     grant_oh_w;      // one-hot: this reader's request is taken this cycle
    logic [N_RD-1:0]     fifo_pop_w;      // a beat left this reader's fifo

    assign credit_ok = credit_ok_q;

    // ---------------------------------------------------------------------------------------------
    // Round-robin over the readers that have a request AND the room to receive its answer.
    //
    // Written as two descending passes rather than a modulo so it stays a static priority network:
    // the wrapped group (below the pointer) is resolved first and the group at or above the pointer
    // overwrites it, and within each group the last assignment wins, which puts rr_ptr_q on top.
    // ---------------------------------------------------------------------------------------------
    logic [N_RD-1:0]     req_elig_w;
    logic [SEL_BITS-1:0] rr_ptr_q;
    logic                grant_valid_w;
    logic [SEL_BITS-1:0] grant_sel_w;

    for (genvar D = 0; D < N_RD; D++) begin : gen_elig
        assign req_elig_w[D] = rd_req_valid[D] && credit_ok_q[D];
    end

    always_comb begin
        grant_valid_w = 1'b0;
        grant_sel_w   = '0;
        for (int d = N_RD-1; d >= 0; d--) begin
            if ((d < int'(rr_ptr_q)) && req_elig_w[d]) begin
                grant_valid_w = 1'b1;
                grant_sel_w   = SEL_BITS'(d);
            end
        end
        for (int d = N_RD-1; d >= 0; d--) begin
            if ((d >= int'(rr_ptr_q)) && req_elig_w[d]) begin
                grant_valid_w = 1'b1;
                grant_sel_w   = SEL_BITS'(d);
            end
        end
    end

    // ---------------------------------------------------------------------------------------------
    // Issue register: the one place a granted request waits for the channel.
    // ---------------------------------------------------------------------------------------------
    logic                  iss_valid_q;
    logic [SEL_BITS-1:0]   iss_sel_q;
    logic [VADDR_BITS-1:0] iss_vaddr_q;
    logic [LEN_BITS-1:0]   iss_len_q;
    logic                  iss_last_q;
    logic [BCNT_BITS-1:0]  iss_beats_q;

    assign ch_req_valid = iss_valid_q;
    assign ch_req_vaddr = iss_vaddr_q;
    assign ch_req_len   = iss_len_q;
    assign ch_req_last  = iss_last_q;

    logic [OQC_BITS-1:0] oq_cnt_q;
    logic                oq_room_w;
    // Two slots of head-room rather than one: the issue register may still be holding a request
    // that has not been pushed yet, and a full queue must never be the thing that stalls a grant.
    assign oq_room_w = (oq_cnt_q < OQC_BITS'(OQ_DEPTH - 2));

    logic iss_fire_w, load_en_w;
    assign iss_fire_w = iss_valid_q && ch_req_ready;
    assign load_en_w  = (!iss_valid_q || ch_req_ready) && oq_room_w;

    for (genvar D = 0; D < N_RD; D++) begin : gen_gnt
        assign grant_oh_w[D]   = load_en_w && grant_valid_w && (grant_sel_w == SEL_BITS'(D));
        assign rd_req_ready[D] = grant_oh_w[D];
    end

    // ---------------------------------------------------------------------------------------------
    // Order queue: {decoder, beats}, pushed when a request is handed to the channel, popped into the
    // head registers as its beats are counted off.
    // ---------------------------------------------------------------------------------------------
    logic [SEL_BITS-1:0]  oq_sel   [OQ_DEPTH];
    logic [BCNT_BITS-1:0] oq_beats [OQ_DEPTH];
    logic [OQP_BITS-1:0]  oq_head_q, oq_tail_q;

    assign oq_occ = oq_cnt_q;

    logic                 hd_valid_q;
    logic [SEL_BITS-1:0]  hd_sel_q;
    logic [BCNT_BITS-1:0] hd_rem_q;

    logic beat_w;
    assign ch_tready = 1'b1;                // never, under any condition. See the header.
    assign beat_w    = ch_tvalid && ch_tready;

    logic hd_last_w, ld_from_q_w, ld_avail_w, hd_load_w;
    assign hd_last_w   = hd_valid_q && beat_w && (hd_rem_q == BCNT_BITS'(1));
    assign ld_from_q_w = (oq_cnt_q != '0);
    // The bypass: a request pushed this cycle can be taken straight into the head registers when the
    // queue is empty. It cannot matter on hardware (the data is many cycles behind the descriptor)
    // and it costs nothing, but it removes the one cycle in which a beat could arrive unowned.
    assign ld_avail_w  = ld_from_q_w || iss_fire_w;
    assign hd_load_w   = (!hd_valid_q || hd_last_w) && ld_avail_w;

    logic [SEL_BITS-1:0]  hd_sel_n_w;
    logic [BCNT_BITS-1:0] hd_rem_n_w;
    assign hd_sel_n_w = ld_from_q_w ? oq_sel[oq_head_q]   : iss_sel_q;
    assign hd_rem_n_w = ld_from_q_w ? oq_beats[oq_head_q] : iss_beats_q;

    // ---------------------------------------------------------------------------------------------
    // Receive fifos, one per decoder. `clear` is tied off: a torn-down connection is drained by
    // slot_reader, which holds its input tready high and swallows while handler_slots flushes it,
    // so the bytes leave through the front door and the credit is returned with them.
    // ---------------------------------------------------------------------------------------------
    logic [N_RD-1:0] fifo_we_w, fifo_ovf_w;

    for (genvar D = 0; D < N_RD; D++) begin : gen_fifo
        assign fifo_we_w[D] = beat_w && hd_valid_q && (hd_sel_q == SEL_BITS'(D));

        axis_fifo #(
            .DATA_BITS(AXI_DATA_BITS),
            .DEPTH    (FIFO_DEPTH),
            // 0, not the default 4. The default slack exists because the TOE's tready is a long
            // combinational path; here the producer is the registered demux above and the credit
            // already guarantees the room, so a slack would only shrink the reservation the credit
            // is sized against. `overflow_stall` below is the proof that it is never needed.
            .ALMOST_FULL_SLACK(0)
        ) inst_rx_fifo (
            .clk(clk), .rst_n(rst_n), .clear(1'b0),
            .s_axis_tvalid(fifo_we_w[D]), .s_axis_tready(),
            .s_axis_tdata (ch_tdata), .s_axis_tkeep(ch_tkeep), .s_axis_tlast(ch_tlast),
            .m_axis_tvalid(rd_tvalid[D]), .m_axis_tready(rd_tready[D]),
            .m_axis_tdata (rd_tdata[D]),  .m_axis_tkeep (rd_tkeep[D]),
            .m_axis_tlast (rd_tlast[D]),
            .level(), .overflow_stall(fifo_ovf_w[D])
        );

        assign fifo_pop_w[D] = rd_tvalid[D] && rd_tready[D];
    end

    assign fifo_err = |fifo_ovf_w;

    // ---------------------------------------------------------------------------------------------
    // Sequential
    // ---------------------------------------------------------------------------------------------
    logic order_err_q, len_err_q;
    assign order_err = order_err_q;
    assign len_err   = len_err_q;

    logic [OCC_BITS-1:0] committed_n;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rr_ptr_q    <= '0;
            iss_valid_q <= 1'b0;
            iss_sel_q   <= '0;
            iss_vaddr_q <= '0;
            iss_len_q   <= '0;
            iss_last_q  <= 1'b0;
            iss_beats_q <= '0;
            oq_head_q   <= '0;
            oq_tail_q   <= '0;
            oq_cnt_q    <= '0;
            hd_valid_q  <= 1'b0;
            hd_sel_q    <= '0;
            hd_rem_q    <= '0;
            order_err_q <= 1'b0;
            len_err_q   <= 1'b0;
            for (int d = 0; d < N_RD; d++) begin
                committed_q[d] <= '0;
                credit_ok_q[d] <= 1'b1;
            end
        end else begin
            // -- credit ---------------------------------------------------------------------------
            // Reserved at the GRANT, released when the beat leaves the fifo. credit_ok_q is computed
            // from the NEXT value, so the arbiter never sees a stale one and the compare is exact:
            // a grant needs room for a whole RD_MAX on top of everything already reserved.
            for (int d = 0; d < N_RD; d++) begin
                committed_n = committed_q[d]
                            + (grant_oh_w[d] ? OCC_BITS'(nbeats_w[d]) : OCC_BITS'(0))
                            - (fifo_pop_w[d] ? OCC_BITS'(1)           : OCC_BITS'(0));
                committed_q[d] <= committed_n;
                credit_ok_q[d] <= (committed_n <= OCC_BITS'(FIFO_DEPTH - MAXBEATS));
            end

            // -- issue register --------------------------------------------------------------------
            if (iss_fire_w) iss_valid_q <= 1'b0;
            if (load_en_w && grant_valid_w) begin
                iss_valid_q <= 1'b1;
                iss_sel_q   <= grant_sel_w;
                iss_vaddr_q <= rd_req_vaddr[grant_sel_w];
                iss_len_q   <= rd_req_len[grant_sel_w];
                iss_last_q  <= rd_req_last[grant_sel_w];
                iss_beats_q <= nbeats_w[grant_sel_w];
                rr_ptr_q    <= (grant_sel_w == SEL_BITS'(N_RD-1)) ? '0
                                                                  : SEL_BITS'(grant_sel_w + 1'b1);
            end

            // -- order queue -----------------------------------------------------------------------
            if (iss_fire_w) begin
                oq_sel[oq_tail_q]   <= iss_sel_q;
                oq_beats[oq_tail_q] <= iss_beats_q;
                oq_tail_q           <= (oq_tail_q == OQP_BITS'(OQ_DEPTH-1)) ? '0 : oq_tail_q + 1'b1;
            end
            // An entry leaves the queue when it is loaded into the head registers -- what is being
            // served is not queued any more -- so the head pointer and the count move on EVERY
            // load, bypass included. In the bypass the same cycle pushes and pops: oq_head_q equals
            // oq_tail_q there, both step over the entry the push just wrote, and the count is
            // unchanged. (Counting the bypass as a push only was the bug that made a served entry
            // look queued and the head reload itself from an empty slot.)
            if (hd_load_w) begin
                oq_head_q <= (oq_head_q == OQP_BITS'(OQ_DEPTH-1)) ? '0 : oq_head_q + 1'b1;
            end
            case ({iss_fire_w, hd_load_w})
                2'b10:   oq_cnt_q <= oq_cnt_q + 1'b1;
                2'b01:   oq_cnt_q <= oq_cnt_q - 1'b1;
                default: ;
            endcase

            // -- head registers / beat accounting --------------------------------------------------
            if (hd_load_w) begin
                hd_valid_q <= 1'b1;
                hd_sel_q   <= hd_sel_n_w;
                hd_rem_q   <= hd_rem_n_w;
            end else if (hd_last_w) begin
                hd_valid_q <= 1'b0;
            end else if (beat_w && hd_valid_q) begin
                hd_rem_q <= hd_rem_q - 1'b1;
            end

            // -- the three things that must never happen -------------------------------------------
            if (beat_w && !hd_valid_q)                    order_err_q <= 1'b1;
            if (iss_fire_w && (oq_cnt_q == OQC_BITS'(OQ_DEPTH))) order_err_q <= 1'b1;
            if (|overlong_w)                              len_err_q   <= 1'b1;
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (RD_MAX % BYTES != 0)
            $display("slot_rd_share: NOTE RD_MAX %0d is not a multiple of %0d (legal; the last beat of a full-size read is then partial)", RD_MAX, BYTES);
        if (OQ_DEPTH < 12)
            $display("slot_rd_share: NOTE OQ_DEPTH %0d is below Coyote's 8 outstanding plus margin", OQ_DEPTH);
    end
    always_ff @(posedge clk) begin
        if (rst_n) begin
            if (beat_w && !hd_valid_q)
                $display("slot_rd_share: FAIL t=%0t a read beat arrived with nothing outstanding",
                         $time);
            if (|fifo_ovf_w && !fifo_err)
                $display("slot_rd_share: FAIL t=%0t a receive fifo refused a beat (credit is wrong)",
                         $time);
            if (|overlong_w && !len_err_q)
                $display("slot_rd_share: FAIL t=%0t a read request is longer than RD_MAX %0d",
                         $time, RD_MAX);
        end
    end
`endif

endmodule
