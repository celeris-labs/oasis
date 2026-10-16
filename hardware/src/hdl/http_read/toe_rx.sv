`timescale 1ns / 1ps

import lynxTypes::*;

// =================================================================================================
// Receive side for N TCP sessions on a TOE that keeps a RECEIVE RING PER SESSION
// (TCP_STACK_RX_DDR_BYPASS_EN = 0, patches 0007/0008). Replaces rx_dispatch for handler_toe.
//
// WHAT CHANGED UNDERNEATH
// -----------------------
// rx_dispatch exists because the bypass TOE has ONE shared receive fifo: a readPkg pops its head
// whoever asked, so readPkgs had to go out in global arrival order and one slow lane held up every
// other (head-of-line watchdog, orphan announcements, the lot). With the bypass off the TOE writes
// each session's bytes into that session's own 1 MiB ring in card memory, announces them only once
// they have landed, and serves readPkg(sid, len) for ANY session in ANY order, returning exactly len
// bytes from that session's ring. The order constraint is gone; what is left is bookkeeping.
//
// THE CONTRACT THIS MODULE RELIES ON (the non-bypass TOE as fixed by hardware/patches/0007)
//   * Notification {sid, len, ip, port, closed, opened}: len bytes of sid are in its ring. A FIN
//     (len 0, closed) can OVERTAKE earlier data notifications (it bypasses the write-status
//     delay). Back-pressure on this interface stalls the TOE's rx engine for EVERY session.
//   * readPkg {len, sid}, any session, any order. The TOE answers in readPkg ISSUE ORDER with one
//     rx_meta {sid} and one data packet of exactly len bytes: ceil(len/64) 512-bit beats, keep
//     low-aligned, tlast on the last. len <= 65535.
//   * The TOE does NOT check len against what is there: an over-read corrupts the session. So the
//     one rule this module must never break is: per session, bytes requested <= bytes notified.
//
// SHAPE
// -----
//   notifications --> [slice] --> per lane: unread += len, closed |= closed   (bound sids only)
//
//   per lane: n = min(unread, RD_MAX); eligible when the lane is up, n > 0, its fifo has room for
//   ceil(n/64) beats and it has < RD_OUT readPkgs outstanding
//        --> round robin --> issue register --> readPkg      (unread -= n, fifo reserves the beats)
//                                     \--> order queue {lane, beats, sid}
//
//   rx data --> routed by the order queue's head --> [register] --> lane fifo (tcp_read)
//   rx meta --> checked against the order queue (order_err)
//
// Every TREADY this module drives towards the TOE is constant 1: notifications are only ever
// counted, and data is only ever asked for once the destination fifo has promised room for all of
// it (tcp_read RSV_EXACT), so no beat can be refused downstream.
//
// WHY THE GRANT USES REGISTERED VALUES, AND THE THREE-CYCLE BLOCK
// ---------------------------------------------------------------
// The eligibility of a lane (unread, its fifo's free count, its outstanding count) is registered
// (elig_q, n_q, need_q) so the arbiter starts from flops, and the reservation pulse to the lane's
// fifo is registered too (the fifo sits next to its decoder, possibly an SLR away). The price is
// staleness: a grant at cycle t shows up in unread at t+1 and in elig_q at t+2, but in the fifo's
// free count (pulse at t+1, reservation at t+2, registered free at t+3) only in elig_q at t+4.
// Every one of those values can only move AGAINST the lane between grants to it -- unread only
// grows (notifications), the free count only grows (the decoder drains), the outstanding count only
// falls -- except at a grant to that very lane. So a stale value is safe for every lane but the one
// just granted, and that lane is blocked for the three cycles after its grant (blk_q). A lane
// holds up to RD_MAX = 256 beats per readPkg, so three idle cycles cost nothing.
//
// The notification side never waits for anything, so a notification is always consumed in the
// cycle after it arrives, and evaluated against the bindings of THAT cycle: a stale one for a
// session released in between is dropped (its bytes stay in that ring, unread, which is harmless --
// the ring dies with the session).
// =================================================================================================
module toe_rx #(
    parameter int NUM_CONNS = 4,
    // Most bytes one readPkg asks for. 16 KiB = 256 beats.
    parameter int RD_MAX    = 16384,
    // readPkgs outstanding per lane (granted, last beat not yet handed to the lane).
    parameter int RD_OUT    = 4,
    // Width of the lanes' free-beat counts: tcp_read's $clog2(RX_FIFO_DEPTH+1).
    parameter int FREE_BITS = 12,
    // The TOE's receive ring per session, log2 bytes. Sizes `unread` and the budget check.
    parameter int RING_LOG2 = 20,
    localparam int CONN_BITS = (NUM_CONNS > 1) ? $clog2(NUM_CONNS) : 1,
    localparam int UNR_BITS  = RING_LOG2 + 1,
    localparam int N_BITS    = $clog2(RD_MAX + 1),
    localparam int BEAT_BITS = $clog2(RD_MAX / 64 + 2),
    localparam int OUT_BITS  = $clog2(RD_OUT + 1),
    // Order queue: one entry per readPkg outstanding anywhere, rounded up to a power of two.
    localparam int OQ_DEPTH  = 1 << $clog2(NUM_CONNS * RD_OUT),
    localparam int OQ_BITS   = $clog2(OQ_DEPTH)
) (
    input  logic clk,
    input  logic rst_n,

    // -- Notifications. TREADY is constant 1.
    input  logic                       s_axis_notifications_TVALID,
    output logic                       s_axis_notifications_TREADY,
    input  logic [TCP_NOTIFY_BITS-1:0] s_axis_notifications_TDATA,

    // -- Session binding, from the handler's bring-up FSM.
    input  logic                        bind_en,
    input  logic [CONN_BITS-1:0]        bind_conn,
    input  logic [TCP_SESSION_BITS-1:0] bind_sid,
    input  logic                        release_en,
    input  logic [CONN_BITS-1:0]        release_conn,

    // -- Per lane, from the handler: the connection is up and not fatal (may be read for).
    input  logic [NUM_CONNS-1:0]        lane_up,
    // -- Per lane, from its tcp_read (RSV_EXACT): beats a new readPkg may be promised. Registered.
    input  logic [FREE_BITS-1:0]        lane_free [NUM_CONNS],

    // -- readPkg out.
    output logic                            m_axis_read_package_TVALID,
    input  logic                            m_axis_read_package_TREADY,
    output logic [TCP_RD_PKG_REQ_BITS-1:0]  m_axis_read_package_TDATA,

    // -- rx metadata: one per readPkg, in issue order. TREADY is constant 1.
    input  logic                        s_axis_rx_metadata_TVALID,
    output logic                        s_axis_rx_metadata_TREADY,
    input  logic [TCP_RX_META_BITS-1:0] s_axis_rx_metadata_TDATA,

    // -- rx data: one packet per readPkg, in issue order. TREADY is constant 1.
    input  logic                       s_axis_rx_data_TVALID,
    output logic                       s_axis_rx_data_TREADY,
    input  logic [AXI_DATA_BITS-1:0]   s_axis_rx_data_TDATA,
    input  logic [AXI_DATA_BITS/8-1:0] s_axis_rx_data_TKEEP,
    input  logic                       s_axis_rx_data_TLAST,

    // -- To the lanes. The reservation (one cycle after the grant) and the routed beats, both
    //    from registers. conn_tready is expected to be 1 whenever conn_tvalid is (the reservation
    //    guarantees it); route_stall latches it if not.
    output logic [NUM_CONNS-1:0]       lane_pkg_issued,
    output logic [FREE_BITS-1:0]       lane_pkg_beats,
    output logic [NUM_CONNS-1:0]       conn_tvalid,
    input  logic [NUM_CONNS-1:0]       conn_tready,
    output logic [AXI_DATA_BITS-1:0]   conn_tdata,
    output logic [AXI_DATA_BITS/8-1:0] conn_tkeep,
    output logic                       conn_tlast,

    // -- Per lane state, for the handler.
    output logic [NUM_CONNS-1:0]       lane_closed,     // sticky: the peer FINed (raw, may overtake data)
    output logic [NUM_CONNS-1:0]       lane_unread,     // notified bytes not yet asked for
    output logic [NUM_CONNS-1:0]       lane_rd_busy,    // a readPkg of this lane is outstanding

    // -- Sticky errors. None can be true of a TOE that keeps the contract and a host that keeps
    //    the window rule.
    output logic                       order_err,   // rx_meta/data with nothing outstanding, or a meta naming the wrong sid
    output logic                       len_err,     // a packet's tlast not on its ceil(len/64)-th beat
    output logic                       budget_err,  // a lane's unread passed 2^RING_LOG2 - 64 KiB (window rule broken)
    output logic                       route_stall, // a lane refused a routed beat (reservation wrong)
    output logic [OQ_BITS:0]           dbg_oq_occ
);

    initial begin
        if (NUM_CONNS < 1 || NUM_CONNS > 8)
            $error("toe_rx: NUM_CONNS must be 1..8 (flat session compare)");
        if (RD_MAX < 64 || RD_MAX > 65535)
            $error("toe_rx: RD_MAX must be 64..65535 (readPkg length is 16 bits)");
        if (RD_OUT < 1)
            $error("toe_rx: RD_OUT must be >= 1");
    end

    // Packed appNotification: sessionID[15:0], length[31:16], ip[63:32], port[79:64], closed[80].
    localparam int CLOSED_BIT = TCP_SESSION_BITS + TCP_LEN_BITS + 32 + 16;
    localparam logic [UNR_BITS-1:0] BUDGET = UNR_BITS'((1 << RING_LOG2) - 65536);
    localparam int BLK = 3;   // cycles a lane is blocked after its grant (see the header)

    assign s_axis_notifications_TREADY = 1'b1;
    assign s_axis_rx_metadata_TREADY   = 1'b1;
    assign s_axis_rx_data_TREADY       = 1'b1;

    // =============================================================================================
    // Binding
    // =============================================================================================
    logic [NUM_CONNS-1:0]        bound_q;
    logic [TCP_SESSION_BITS-1:0] sid_q [NUM_CONNS];

    // =============================================================================================
    // Notifications: one register stage, then counted. The slice of 1419da6 degenerates to one
    // register here because its consumer never stalls (TREADY is constant 1).
    // =============================================================================================
    logic                        nt_v_q, nt_closed_q;
    logic [TCP_SESSION_BITS-1:0] nt_sid_q;
    logic [TCP_LEN_BITS-1:0]     nt_len_q;

    always_ff @(posedge clk) begin
        if (!rst_n) nt_v_q <= 1'b0;
        else        nt_v_q <= s_axis_notifications_TVALID;
    end
    always_ff @(posedge clk) begin
        if (s_axis_notifications_TVALID) begin
            nt_sid_q    <= s_axis_notifications_TDATA[TCP_SESSION_BITS-1:0];
            nt_len_q    <= s_axis_notifications_TDATA[TCP_SESSION_BITS +: TCP_LEN_BITS];
            nt_closed_q <= s_axis_notifications_TDATA[CLOSED_BIT];
        end
    end

    // The match, against the bindings of the cycle it is consumed in. A bind in this very cycle is
    // honoured too (nothing is announced for a session before its open completes, but the case
    // costs one comparator, and a notification dropped here would strand bytes the response needs).
    logic [NUM_CONNS-1:0] hit_w;
    logic                 hit_bind_w;
    always_comb begin
        for (int L = 0; L < NUM_CONNS; L++)
            hit_w[L] = nt_v_q && bound_q[L] && (sid_q[L] == nt_sid_q);
        hit_bind_w = nt_v_q && (bind_sid == nt_sid_q);
    end

    // =============================================================================================
    // Per-lane counters
    // =============================================================================================
    logic [UNR_BITS-1:0]  unread_q  [NUM_CONNS];
    logic [NUM_CONNS-1:0] closed_q;
    logic [OUT_BITS-1:0]  out_cnt_q [NUM_CONNS];
    logic [NUM_CONNS-1:0] budget_q;
    logic [BLK-1:0]       blk_q     [NUM_CONNS];

    // Registered eligibility (see the header).
    logic [NUM_CONNS-1:0] elig_q;
    logic [N_BITS-1:0]    n_q    [NUM_CONNS];
    logic [BEAT_BITS-1:0] need_q [NUM_CONNS];

    always_ff @(posedge clk) begin
        for (int L = 0; L < NUM_CONNS; L++) begin
            automatic logic                 big  = (unread_q[L] >= UNR_BITS'(RD_MAX));
            automatic logic [N_BITS-1:0]    n    = big ? N_BITS'(RD_MAX) : N_BITS'(unread_q[L]);
            automatic logic [BEAT_BITS-1:0] need = BEAT_BITS'((n + 63) >> 6);
            n_q[L]    <= n;
            need_q[L] <= need;
            elig_q[L] <= rst_n && lane_up[L] && bound_q[L] && (unread_q[L] != '0) &&
                         (FREE_BITS'(need) <= lane_free[L]) && (out_cnt_q[L] < OUT_BITS'(RD_OUT));
        end
    end

    // =============================================================================================
    // Grant -> issue register -> readPkg
    // =============================================================================================
    logic                        iss_v_q;
    logic [CONN_BITS-1:0]        iss_lane_q;
    logic [TCP_SESSION_BITS-1:0] iss_sid_q;
    logic [N_BITS-1:0]           iss_len_q;
    logic [BEAT_BITS-1:0]        iss_beats_q;
    logic                        iss_fire_w;

    assign m_axis_read_package_TVALID = iss_v_q;
    assign m_axis_read_package_TDATA  = {TCP_LEN_BITS'(iss_len_q), iss_sid_q};
    assign iss_fire_w = iss_v_q && m_axis_read_package_TREADY;

    // Order queue (declared here: the grant needs its room).
    logic [CONN_BITS-1:0]        oq_lane  [OQ_DEPTH];
    logic [BEAT_BITS-1:0]        oq_beats [OQ_DEPTH];
    logic [TCP_SESSION_BITS-1:0] oq_sid   [OQ_DEPTH];
    logic [OQ_BITS:0]            oq_tail_q, oq_head_q, oq_mptr_q;   // one wrap bit each
    logic [OQ_BITS:0]            occ_d_w, occ_m_w;
    logic                        oq_room_w;
    assign occ_d_w   = oq_tail_q - oq_head_q;
    assign occ_m_w   = oq_tail_q - oq_mptr_q;
    // Room for this grant's entry plus the one still in the issue register.
    assign oq_room_w = ((occ_d_w + (OQ_BITS+1)'(iss_v_q)) < (OQ_BITS+1)'(OQ_DEPTH)) &&
                       ((occ_m_w + (OQ_BITS+1)'(iss_v_q)) < (OQ_BITS+1)'(OQ_DEPTH));

    logic [NUM_CONNS-1:0] cand_w, grant_w;
    logic                 grant_any_w;
    logic [CONN_BITS-1:0] grant_lane_w, rr_q;

    always_comb begin
        for (int L = 0; L < NUM_CONNS; L++)
            cand_w[L] = elig_q[L] && (blk_q[L] == '0) && bound_q[L] && lane_up[L];
    end

    // Round robin from rr_q. The issue register takes a new readPkg when it is empty or its
    // current one leaves this cycle.
    always_comb begin
        grant_w      = '0;
        grant_any_w  = 1'b0;
        grant_lane_w = '0;
        if ((!iss_v_q || iss_fire_w) && oq_room_w) begin
            for (int k = 0; k < NUM_CONNS; k++) begin
                automatic int idx = int'(rr_q) + k;
                if (idx >= NUM_CONNS) idx = idx - NUM_CONNS;
                if (!grant_any_w && cand_w[idx]) begin
                    grant_any_w  = 1'b1;
                    grant_lane_w = CONN_BITS'(idx);
                end
            end
            if (grant_any_w) grant_w[grant_lane_w] = 1'b1;
        end
    end

    // =============================================================================================
    // Data routing: by the order queue's head, one register stage in front of the lane fifos
    // (b7ff974's idea: the lane fifos see a flop, not the shell's slice through a select).
    // =============================================================================================
    logic                        oq_has_d_w, oq_has_m_w;
    logic [CONN_BITS-1:0]        h_lane_w;
    logic [BEAT_BITS-1:0]        h_beats_w;
    logic [BEAT_BITS-1:0]        bcnt_q;
    logic                        h_cnt_end_w, beat_end_w;
    assign oq_has_d_w  = (oq_tail_q != oq_head_q);
    assign oq_has_m_w  = (oq_tail_q != oq_mptr_q);
    assign h_lane_w    = oq_lane [oq_head_q[OQ_BITS-1:0]];
    assign h_beats_w   = oq_beats[oq_head_q[OQ_BITS-1:0]];
    assign h_cnt_end_w = (bcnt_q == (h_beats_w - 1'b1));
    // A packet ends at its tlast or at its expected beat count, whichever comes first; a
    // disagreement is len_err either way.
    assign beat_end_w  = s_axis_rx_data_TLAST || h_cnt_end_w;

    logic [NUM_CONNS-1:0]       out_v_q;     // one-hot: the register holds a beat for this lane
    logic [NUM_CONNS-1:0]       out_end_q;   // ...and it ends that lane's readPkg
    logic [AXI_DATA_BITS-1:0]   out_data_q;
    logic [AXI_DATA_BITS/8-1:0] out_keep_q;
    logic                       out_last_q;

    assign conn_tvalid = out_v_q;
    assign conn_tdata  = out_data_q;
    assign conn_tkeep  = out_keep_q;
    assign conn_tlast  = out_last_q;

    // Reservation pulse, registered.
    logic [NUM_CONNS-1:0] pkg_v_q;
    logic [FREE_BITS-1:0] pkg_beats_q;
    assign lane_pkg_issued = pkg_v_q;
    assign lane_pkg_beats  = pkg_beats_q;

    logic order_err_q, len_err_q, route_stall_q;

    // =============================================================================================
    // Sequential
    // =============================================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            bound_q     <= '0;
            closed_q    <= '0;
            budget_q    <= '0;
            iss_v_q     <= 1'b0;
            rr_q        <= '0;
            oq_tail_q   <= '0;
            oq_head_q   <= '0;
            oq_mptr_q   <= '0;
            bcnt_q      <= '0;
            out_v_q     <= '0;
            out_end_q   <= '0;
            pkg_v_q     <= '0;
            order_err_q <= 1'b0;
            len_err_q   <= 1'b0;
            route_stall_q <= 1'b0;
            for (int L = 0; L < NUM_CONNS; L++) begin
                sid_q[L]     <= '0;
                unread_q[L]  <= '0;
                out_cnt_q[L] <= '0;
                blk_q[L]     <= '0;
            end
        end else begin
            // -- per lane: binding, unread, closed, outstanding, block ----------------------------
            for (int L = 0; L < NUM_CONNS; L++) begin
                automatic logic [UNR_BITS-1:0] add = hit_w[L]   ? UNR_BITS'(nt_len_q) : '0;
                automatic logic [UNR_BITS-1:0] sub = grant_w[L] ? UNR_BITS'(n_q[L])   : '0;
                automatic logic done_l = out_v_q[L] && out_end_q[L];

                if (bind_en && (bind_conn == CONN_BITS'(L))) begin
                    bound_q[L]  <= 1'b1;
                    sid_q[L]    <= bind_sid;
                    unread_q[L] <= hit_bind_w ? UNR_BITS'(nt_len_q) : '0;
                    closed_q[L] <= hit_bind_w && nt_closed_q;
                end else if (release_en && (release_conn == CONN_BITS'(L))) begin
                    // A notification for the session being let go in this very cycle is dropped
                    // with it; a readPkg granted in this cycle still goes out, and is outstanding
                    // until its data has been handed to the (now discarding) lane.
                    bound_q[L]  <= 1'b0;
                    unread_q[L] <= '0;
                    closed_q[L] <= 1'b0;
                end else begin
                    unread_q[L] <= unread_q[L] + add - sub;
                    if (hit_w[L] && nt_closed_q) closed_q[L] <= 1'b1;
                end

                case ({grant_w[L], done_l})
                    2'b10:   out_cnt_q[L] <= out_cnt_q[L] + 1'b1;
                    2'b01:   out_cnt_q[L] <= (out_cnt_q[L] == '0) ? '0 : out_cnt_q[L] - 1'b1;
                    default: ;
                endcase

                blk_q[L] <= {blk_q[L][BLK-2:0], grant_w[L]};

                if (unread_q[L] > BUDGET) budget_q[L] <= 1'b1;
            end

            // -- issue register ----------------------------------------------------------------
            if (grant_any_w) begin
                iss_v_q     <= 1'b1;
                iss_lane_q  <= grant_lane_w;
                iss_sid_q   <= sid_q[grant_lane_w];
                iss_len_q   <= n_q[grant_lane_w];
                iss_beats_q <= need_q[grant_lane_w];
                rr_q        <= (int'(grant_lane_w) == NUM_CONNS - 1) ? '0 : grant_lane_w + 1'b1;
            end else if (iss_fire_w) begin
                iss_v_q <= 1'b0;
            end

            // The reservation goes to the lane one cycle after its grant.
            pkg_v_q     <= grant_w;
            pkg_beats_q <= FREE_BITS'(need_q[grant_lane_w]);

            // -- order queue push at readPkg accept (the entry itself: see below) ---------------
            if (iss_fire_w) oq_tail_q <= oq_tail_q + 1'b1;

            // -- data: route by the head, count beats, pop at the end ----------------------------
            out_v_q   <= '0;
            out_end_q <= '0;
            if (s_axis_rx_data_TVALID) begin
                if (!oq_has_d_w) begin
                    order_err_q <= 1'b1;   // a beat nobody asked for: dropped
                end else begin
                    out_v_q[h_lane_w]   <= 1'b1;
                    out_end_q[h_lane_w] <= beat_end_w;
                    if (s_axis_rx_data_TLAST != h_cnt_end_w) len_err_q <= 1'b1;
                    if (beat_end_w) begin
                        oq_head_q <= oq_head_q + 1'b1;
                        bcnt_q    <= '0;
                    end else begin
                        bcnt_q    <= bcnt_q + 1'b1;
                    end
                end
            end

            // -- meta: checked, never waited for ------------------------------------------------
            if (s_axis_rx_metadata_TVALID) begin
                if (!oq_has_m_w) order_err_q <= 1'b1;
                else begin
                    if (oq_sid[oq_mptr_q[OQ_BITS-1:0]] != s_axis_rx_metadata_TDATA[TCP_SESSION_BITS-1:0])
                        order_err_q <= 1'b1;
                    oq_mptr_q <= oq_mptr_q + 1'b1;
                end
            end

            if (|(out_v_q & ~conn_tready)) route_stall_q <= 1'b1;
        end
    end

    // The order queue's entries: no reset (only read between head/mptr and tail), so they can be
    // distributed RAM.
    always_ff @(posedge clk) begin
        if (iss_fire_w) begin
            oq_lane [oq_tail_q[OQ_BITS-1:0]] <= iss_lane_q;
            oq_beats[oq_tail_q[OQ_BITS-1:0]] <= iss_beats_q;
            oq_sid  [oq_tail_q[OQ_BITS-1:0]] <= iss_sid_q;
        end
    end

    // Data registers: no reset, only read under their valid.
    always_ff @(posedge clk) begin
        if (s_axis_rx_data_TVALID) begin
            out_data_q <= s_axis_rx_data_TDATA;
            out_keep_q <= s_axis_rx_data_TKEEP;
            out_last_q <= s_axis_rx_data_TLAST;
        end
    end

    always_comb begin
        for (int L = 0; L < NUM_CONNS; L++) begin
            lane_unread[L]  = (unread_q[L] != '0);
            lane_rd_busy[L] = (out_cnt_q[L] != '0);
        end
    end
    assign lane_closed = closed_q;
    assign order_err   = order_err_q;
    assign len_err     = len_err_q;
    assign budget_err  = |budget_q;
    assign route_stall = route_stall_q;
    assign dbg_oq_occ  = occ_d_w;

endmodule
