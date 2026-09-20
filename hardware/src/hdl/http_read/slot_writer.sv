`timescale 1ns / 1ps

import lynxTypes::*;

// =================================================================================================
// Shared receive writer: every TCP segment rx_dispatch routes goes into its connection's slot in
// card memory (HBM), through one Coyote card-DMA write channel. ARCHITECTURE.md, ADR-5.
//
// WHAT IT REPLACES
// ----------------
// Today (build-119) each connection owns a 128 KiB BRAM fifo inside tcp_read. When one of them
// fills, `conn_space_ok` drops, the head of rx_dispatch's arrival-ordered queue blocks, and every
// other connection starves behind it -- measured, repeatedly: a FASTER origin is a net loss at 2+
// lanes, and 4.9 MiB GETs wedge at 2+ lanes (ADR-5's table). The fifo is the thing that is too
// small, and BRAM is the reason it cannot be made big enough: 24 connections x 4 MiB does not exist
// on this die, and 24 x 128 KiB does not fit either.
//
// So the buffer moves to HBM and the BRAM shrinks to a single shared elastic fifo whose only job is
// to absorb the latency of the DMA, not the size of a response. There is exactly ONE of them for
// all connections because there is exactly one card write channel, and one channel is enough: a
// segment is 4 KiB and the channel moves ~13 GB/s, two orders above what the TOE delivers.
//
// THE SHAPE
// ---------
//   rx_dispatch --routed beats--> [ axis_fifo, FIFO_DEPTH beats ] --> request + data --> card DMA
//                 |                                                       |
//                 +-- one descriptor {conn, off, len} per segment --------+
//
// Store and forward, per SEGMENT, deliberately. The DMA request has to name a length before its
// data, and the length of a TCP segment is only known at its tlast -- so the segment is buffered
// whole, its byte count is counted off tkeep on the way in, and only then is the request issued.
// The cost is one segment of latency (66 beats, 264 ns at 250 MHz); the alternative (guess the
// length, or issue per beat) either lies to the engine or spends a descriptor per 64 bytes.
//
// WHY conn_tready MAY NEVER FALL
// ------------------------------
// rx_dispatch accepts every beat of a packet it has issued a readPkg for, unconditionally -- that
// line is what keeps the TOE's single shared rx fifo draining for every other session. If we refuse
// a beat, the shared bus stalls for everyone, which is the exact failure this design exists to
// remove. So `conn_tready` is the fifo's tready and nothing else, the fifo is sized so it can never
// be reached while `conn_space_ok` is honoured, and if it ever IS reached, `route_stall` latches and
// stays latched. That bit is the gate for this work package.
//
// THE RESERVATION -- ONE COUNTER, SHARED
// --------------------------------------
// `conn_space_ok` cannot simply ask the fifo how full it is. A readPkg's bytes do not arrive when it
// is issued, so a "room for one MSS" check passes again the very next cycle and rx_dispatch can
// issue an unbounded run of readPkgs against the same single-segment reservation. That arithmetic
// was the build-116 over-commit bug (tcp_read.sv:267-323). The fix is identical here, with one
// difference: the fifo is shared, so there is ONE reservation counter for all connections rather
// than one per connection. `conn_pkg_issued` charges MSS_BEATS to it; a segment's tlast on the way
// into the fifo hands it back.
//
// `conn_space_ok` is REGISTERED, not combinational as in tcp_read. The compare feeds rx_dispatch's
// readPkg-issue decision and this design closes timing at 250 MHz with negative slack already. A
// registered check is one cycle stale, and rx_dispatch can issue one readPkg per cycle, so the
// margin is 3 x MSS_BEATS rather than 1 -- 198 of 1024 beats, which buys back a path for 12 KiB of
// elasticity we do not need.
//
// SLOT OVERFLOW
// -------------
// A segment whose bytes would run past the end of its 2^SLOT_LOG2 slot is discarded WHOLE -- its
// beats are drained out of the shared fifo and dropped, no request is issued, `slot_overflow[c]`
// latches, and every later segment of that connection is dropped too until the connection is
// released. Writing a partial segment, or wrapping, would corrupt the neighbouring slot; and a
// response with a hole in it is not repairable by anything short of the host reissuing, so once the
// connection is poisoned there is no value in writing the rest. The host's contract
// (GET <= SLOT_BYTES - 64 KiB) means this should never fire; the sticky bit says whether it did.
//
// DESIGN FOR SYNTHESIS
// --------------------
//   * the 48-bit vaddr adder is registered (O_IDLE -> O_REQ), and `(conn << SLOT_LOG2) | off` is a
//     concatenation, not a shift, so it is one adder and no barrel;
//   * `landed[]` is written only from the completion queue, never from a compare;
//   * there is no combinational path from `wr_ack` to `wr_req_valid`;
//   * the longest path is the descriptor computation at a segment's tlast:
//     popcount(tkeep) -> +(beats<<6) -> + cursor -> overflow compare -> descriptor register. The
//     32:1 cursor mux is only in series with that adder for a SINGLE-BEAT segment (otherwise the
//     offset comes from the registered `cur_off_q`). If WP3's timing watch flags it, the fix is a
//     one-deep register stage between tlast and the descriptor push, plus a write-forwarding mux on
//     the cursor read.
// =================================================================================================
module slot_writer #(
    parameter int N_CONNS    = 4,      // 1..32
    parameter int SLOT_LOG2  = 22,     // 4 MiB slots
    parameter int FIFO_DEPTH = 1024,   // shared elastic fifo, beats (x 64 B = 64 KiB)

    localparam int CONN_BITS = (N_CONNS > 1) ? $clog2(N_CONNS) : 1,
    localparam int OFF_BITS  = SLOT_LOG2 + 1,   // one bit above the slot, to see the overflow
    localparam int LEN_BITS_ = 16,              // a TCP segment is at most MSS
    localparam int KEEP_BITS = AXI_DATA_BITS/8
) (
    input  logic clk,
    input  logic rst_n,

    // -- routed receive stream from rx_dispatch. conn_tvalid is one-hot; tdata/tkeep/tlast shared.
    input  logic [N_CONNS-1:0]         conn_tvalid,
    output logic [N_CONNS-1:0]         conn_tready,
    input  logic [AXI_DATA_BITS-1:0]   conn_tdata,
    input  logic [KEEP_BITS-1:0]       conn_tkeep,
    input  logic                       conn_tlast,

    // -- one-hot pulse: rx_dispatch accepted a readPkg for this connection. Charges the reservation.
    input  logic [N_CONNS-1:0]         conn_pkg_issued,

    // -- room for one more MSS beyond everything already promised. Same value for every connection:
    //    the fifo is shared, so the answer is too.
    output logic [N_CONNS-1:0]         conn_space_ok,

    // -- base of the slot array in card memory (CSR).
    input  logic [VADDR_BITS-1:0]      slot_base,

    // -- from the readers: this connection's response has drained, reset its cursors.
    input  logic [N_CONNS-1:0]         conn_release,

    // -- card DMA write channel (wrapped into metaIntf/req_t{LOCAL_WRITE, STRM_CARD, dest 0} later)
    output logic                       wr_req_valid,
    input  logic                       wr_req_ready,
    output logic [VADDR_BITS-1:0]      wr_req_vaddr,
    output logic [LEN_BITS-1:0]        wr_req_len,
    output logic                       wr_req_last,

    output logic                       m_axis_tvalid,
    input  logic                       m_axis_tready,
    output logic [AXI_DATA_BITS-1:0]   m_axis_tdata,
    output logic [KEEP_BITS-1:0]       m_axis_tkeep,
    output logic                       m_axis_tlast,

    input  logic                       wr_ack,      // one per request, in issue order

    // -- bytes of connection c that are committed in its slot. The readers may read below this and
    //    nowhere else: it is the only thing that orders a read behind its write.
    output logic [N_CONNS-1:0][SLOT_LOG2:0] landed,

    // -- sticky diagnostics
    output logic [N_CONNS-1:0]         slot_overflow,
    output logic                       route_stall  // a routed beat was refused: see the note above
);

    // Space for one maximum segment, in beats. MSS is 4096 on this stack; at 512 bit that is 64
    // beats, +2 for the fifo's own registered output stage which is occupied but not in `level`.
    localparam int MSS_BEATS    = (4096 / (AXI_DATA_BITS/8)) + 2;   // 66
    localparam int SPACE_MARGIN = 3 * MSS_BEATS;                    // see the header
    localparam int DESC_DEPTH   = 64;                               // = rx_dispatch NOTIFY_DEPTH
    localparam int ACKQ_DEPTH   = 8;                                // = Coyote N_OUTSTANDING
    localparam int RSV_BITS     = $clog2(FIFO_DEPTH+1) + 2;
    localparam int LVL_BITS     = $clog2(FIFO_DEPTH+1);
    localparam int DPTR_BITS    = $clog2(DESC_DEPTH);
    localparam int DCNT_BITS    = $clog2(DESC_DEPTH+1);
    localparam int DSUM_BITS    = DCNT_BITS + 2;      // dq_cnt + dq_rsv + 2 must not wrap
    localparam int APTR_BITS    = $clog2(ACKQ_DEPTH);
    localparam int ACNT_BITS    = $clog2(ACKQ_DEPTH+1);
    localparam int BEAT_BITS    = 13;                               // beats in one segment

    typedef struct packed {
        logic [CONN_BITS-1:0] conn;
        logic [OFF_BITS-1:0]  off;
        logic [OFF_BITS-1:0]  end_off;
        logic [LEN_BITS_-1:0] len;
        logic                 drop;
    } desc_t;

    integer i;

    // ---------------------------------------------------------------------------------------------
    // Input side: one-hot decode, the shared fifo, and the never-refuse rule.
    // ---------------------------------------------------------------------------------------------
    logic                 in_tvalid_w;
    logic [CONN_BITS-1:0] in_conn_w;

    assign in_tvalid_w = |conn_tvalid;
    always_comb begin
        in_conn_w = '0;
        for (int c = 0; c < N_CONNS; c++) begin
            if (conn_tvalid[c]) in_conn_w = in_conn_w | CONN_BITS'(c);
        end
    end

    logic                     fifo_s_tready;
    logic                     fifo_m_tvalid, fifo_m_tready, fifo_m_tlast;
    logic [AXI_DATA_BITS-1:0] fifo_m_tdata;
    logic [KEEP_BITS-1:0]     fifo_m_tkeep;
    logic [LVL_BITS-1:0]      fifo_level;

    assign conn_tready = {N_CONNS{fifo_s_tready}};

    logic in_fire_w;
    assign in_fire_w = in_tvalid_w && fifo_s_tready;

    axis_fifo #(
        .DATA_BITS(AXI_DATA_BITS),
        .DEPTH(FIFO_DEPTH)
    ) inst_slot_fifo (
        .clk(clk),
        .rst_n(rst_n),
        // Never cleared: a release only resets cursors, and the sim assertion below proves nothing
        // of that connection is still in the fifo when it happens.
        .clear(1'b0),
        .s_axis_tvalid(in_tvalid_w),
        .s_axis_tready(fifo_s_tready),
        .s_axis_tdata(conn_tdata),
        .s_axis_tkeep(conn_tkeep),
        .s_axis_tlast(conn_tlast),
        .m_axis_tvalid(fifo_m_tvalid),
        .m_axis_tready(fifo_m_tready),
        .m_axis_tdata(fifo_m_tdata),
        .m_axis_tkeep(fifo_m_tkeep),
        .m_axis_tlast(fifo_m_tlast),
        .level(fifo_level),
        .overflow_stall()
    );

    // ---------------------------------------------------------------------------------------------
    // Per-connection state
    // ---------------------------------------------------------------------------------------------
    logic [OFF_BITS-1:0] wr_cursor_q [N_CONNS];   // next write offset inside slot c
    logic [OFF_BITS-1:0] landed_q    [N_CONNS];   // bytes committed (acked) in slot c
    logic [N_CONNS-1:0]  overflow_q;

    always_comb begin
        for (int c = 0; c < N_CONNS; c++) landed[c] = landed_q[c];
    end
    assign slot_overflow = overflow_q;

    // ---------------------------------------------------------------------------------------------
    // Segment accounting on the way in. A segment is full beats plus one partial last beat, so the
    // byte count is (beats so far << 6) + popcount of the last beat's tkeep -- no popcount adder
    // chain across the whole segment.
    // ---------------------------------------------------------------------------------------------
    logic                 seg_active_q;   // at least one beat of a segment accepted, no tlast yet
    logic [BEAT_BITS-1:0] seg_beats_q;    // beats accepted so far, NOT counting the current one
    logic [OFF_BITS-1:0]  cur_off_q;      // slot offset this segment starts at
    logic [CONN_BITS-1:0] seg_conn_q;

    logic [OFF_BITS-1:0]  cursor_mux_w;
    assign cursor_mux_w = wr_cursor_q[in_conn_w];

    logic [OFF_BITS-1:0]  off_sel_w;
    logic [CONN_BITS-1:0] conn_sel_w;
    logic [BEAT_BITS-1:0] prior_beats_w;
    assign off_sel_w     = seg_active_q ? cur_off_q  : cursor_mux_w;
    assign conn_sel_w    = seg_active_q ? seg_conn_q : in_conn_w;
    assign prior_beats_w = seg_active_q ? seg_beats_q : BEAT_BITS'(0);

    logic [6:0]           pop_w;
    logic [LEN_BITS_-1:0] seg_len_w;
    logic [OFF_BITS-1:0]  end_off_w;
    logic                 seg_ovf_w, seg_drop_w;

    assign pop_w     = 7'($countones(conn_tkeep));
    assign seg_len_w = LEN_BITS_'({prior_beats_w, 6'b0}) + LEN_BITS_'(pop_w);
    assign end_off_w = off_sel_w + OFF_BITS'(seg_len_w);
    // > 2^SLOT_LOG2 rather than >=: a segment that ends exactly on the slot boundary still fits.
    assign seg_ovf_w  = end_off_w[SLOT_LOG2] && (|end_off_w[SLOT_LOG2-1:0]);
    // Once a connection has lost a segment its response has a hole in it and nothing short of the
    // host reissuing repairs that, so everything else it sends is dropped until it is released.
    // A zero-length segment is dropped too: the DMA engine rejects len == 0.
    assign seg_drop_w = seg_ovf_w || overflow_q[conn_sel_w] || (seg_len_w == '0);

    logic desc_push_w;
    assign desc_push_w = in_fire_w && conn_tlast;

    // ---------------------------------------------------------------------------------------------
    // Descriptor fifo: one entry per segment, in arrival order. The data fifo carries no connection
    // id because it does not need one -- segments leave it in the order they entered.
    // ---------------------------------------------------------------------------------------------
    desc_t                 dq [DESC_DEPTH];
    logic [DPTR_BITS-1:0]  dq_head_q, dq_tail_q;
    logic [DCNT_BITS-1:0]  dq_cnt_q;
    logic [DCNT_BITS-1:0]  dq_rsv_q;

    logic dq_empty_w;
    assign dq_empty_w = (dq_cnt_q == '0);

    // ---------------------------------------------------------------------------------------------
    // Reservation and conn_space_ok. One counter for the shared fifo, plus room for the descriptor
    // the same readPkg will eventually produce.
    // ---------------------------------------------------------------------------------------------
    logic [RSV_BITS-1:0] rsv_beats_q;
    logic                pkg_issued_w;
    assign pkg_issued_w = |conn_pkg_issued;

    logic space_ok_q;
    assign conn_space_ok = {N_CONNS{space_ok_q}};

    // ---------------------------------------------------------------------------------------------
    // Output side
    // ---------------------------------------------------------------------------------------------
    localparam logic [1:0] O_IDLE = 2'd0, O_REQ = 2'd1, O_DATA = 2'd2, O_DISCARD = 2'd3;
    logic [1:0]            ost_q;
    logic [VADDR_BITS-1:0] req_vaddr_q;
    logic [LEN_BITS_-1:0]  req_len_q;
    logic [CONN_BITS-1:0]  req_conn_q;
    logic [OFF_BITS-1:0]   req_end_q;

    // Completion queue: {conn, end_cursor} per issued request, popped by wr_ack in issue order.
    logic [CONN_BITS-1:0] aq_conn [ACKQ_DEPTH];
    logic [OFF_BITS-1:0]  aq_end  [ACKQ_DEPTH];
    logic [APTR_BITS-1:0] aq_head_q, aq_tail_q;
    logic [ACNT_BITS-1:0] aq_cnt_q;

    logic aq_full_w;
    assign aq_full_w = (aq_cnt_q == ACNT_BITS'(ACKQ_DEPTH));

    assign wr_req_valid = (ost_q == O_REQ) && !aq_full_w;
    assign wr_req_vaddr = req_vaddr_q;
    assign wr_req_len   = LEN_BITS'(req_len_q);
    assign wr_req_last  = 1'b1;

    logic req_fire_w;
    assign req_fire_w = wr_req_valid && wr_req_ready;

    assign m_axis_tvalid = (ost_q == O_DATA) && fifo_m_tvalid;
    assign m_axis_tdata  = fifo_m_tdata;
    assign m_axis_tkeep  = fifo_m_tkeep;
    assign m_axis_tlast  = fifo_m_tlast;
    assign fifo_m_tready = (ost_q == O_DATA) ? m_axis_tready : (ost_q == O_DISCARD);

    logic out_beat_w, out_done_w;
    assign out_beat_w = fifo_m_tvalid && fifo_m_tready;
    assign out_done_w = out_beat_w && fifo_m_tlast;

    desc_t dq_head_w;
    assign dq_head_w = dq[dq_head_q];

    // ---------------------------------------------------------------------------------------------
    // Sequential
    // ---------------------------------------------------------------------------------------------
    logic route_stall_q;
    assign route_stall = route_stall_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            seg_active_q  <= 1'b0;
            seg_beats_q   <= '0;
            cur_off_q     <= '0;
            seg_conn_q    <= '0;
            dq_head_q     <= '0;
            dq_tail_q     <= '0;
            dq_cnt_q      <= '0;
            dq_rsv_q      <= '0;
            rsv_beats_q   <= '0;
            space_ok_q    <= 1'b0;
            ost_q         <= O_IDLE;
            req_vaddr_q   <= '0;
            req_len_q     <= '0;
            req_conn_q    <= '0;
            req_end_q     <= '0;
            aq_head_q     <= '0;
            aq_tail_q     <= '0;
            aq_cnt_q      <= '0;
            overflow_q    <= '0;
            route_stall_q <= 1'b0;
            for (i = 0; i < N_CONNS; i++) begin
                wr_cursor_q[i] <= '0;
                landed_q[i]    <= '0;
            end
        end else begin
            // -- the rule: a routed beat is never refused --------------------------------------
            if (in_tvalid_w && !fifo_s_tready) route_stall_q <= 1'b1;

            // -- segment accounting -------------------------------------------------------------
            if (in_fire_w) begin
                if (!seg_active_q) begin
                    cur_off_q  <= cursor_mux_w;
                    seg_conn_q <= in_conn_w;
                end
                seg_active_q <= !conn_tlast;
                seg_beats_q  <= conn_tlast ? BEAT_BITS'(0) : (prior_beats_w + BEAT_BITS'(1));
            end

            // -- descriptor push + cursor advance ------------------------------------------------
            if (desc_push_w) begin
                dq[dq_tail_q] <= '{conn:    conn_sel_w,
                                   off:     off_sel_w,
                                   end_off: end_off_w,
                                   len:     seg_len_w,
                                   drop:    seg_drop_w};
                dq_tail_q <= (dq_tail_q == DPTR_BITS'(DESC_DEPTH-1)) ? '0 : dq_tail_q + 1'b1;
                if (seg_ovf_w) overflow_q[conn_sel_w] <= 1'b1;
            end

            // -- per-connection cursors. A release wins over everything: by depth 1 there is
            //    nothing of that connection in flight, which the assertion below proves.
            for (i = 0; i < N_CONNS; i++) begin
                if (conn_release[i]) begin
                    wr_cursor_q[i] <= '0;
                    landed_q[i]    <= '0;
                end else begin
                    if (desc_push_w && !seg_drop_w && (conn_sel_w == CONN_BITS'(i)))
                        wr_cursor_q[i] <= end_off_w;
                    if (wr_ack && (aq_cnt_q != '0) && (aq_conn[aq_head_q] == CONN_BITS'(i)))
                        landed_q[i] <= aq_end[aq_head_q];
                end
            end

            // -- descriptor queue pointers -------------------------------------------------------
            case ({desc_push_w, (ost_q == O_IDLE) && !dq_empty_w})
                2'b10:   dq_cnt_q <= dq_cnt_q + 1'b1;
                2'b01:   dq_cnt_q <= dq_cnt_q - 1'b1;
                default: ;
            endcase
            if ((ost_q == O_IDLE) && !dq_empty_w) begin
                dq_head_q <= (dq_head_q == DPTR_BITS'(DESC_DEPTH-1)) ? '0 : dq_head_q + 1'b1;
            end

            // -- reservations. A readPkg promises one MSS of fifo and one descriptor slot; the
            //    segment's tlast on the way in hands both back.
            case ({pkg_issued_w, desc_push_w})
                2'b10:   rsv_beats_q <= (rsv_beats_q > RSV_BITS'(FIFO_DEPTH))
                                            ? rsv_beats_q : rsv_beats_q + RSV_BITS'(MSS_BEATS);
                2'b01:   rsv_beats_q <= (rsv_beats_q >= RSV_BITS'(MSS_BEATS))
                                            ? rsv_beats_q - RSV_BITS'(MSS_BEATS) : '0;
                default: ;
            endcase
            case ({pkg_issued_w, desc_push_w})
                2'b10:   dq_rsv_q <= (dq_rsv_q >= DCNT_BITS'(DESC_DEPTH))
                                        ? dq_rsv_q : dq_rsv_q + 1'b1;
                2'b01:   dq_rsv_q <= (dq_rsv_q != '0) ? dq_rsv_q - 1'b1 : '0;
                default: ;
            endcase

            // -- the registered space check. Written as an addition, never as a subtraction: level
            //    plus reserved may legitimately exceed the depth for a cycle and the subtraction
            //    would wrap to a huge unsigned "yes".
            space_ok_q <= ((RSV_BITS'(fifo_level) + rsv_beats_q + RSV_BITS'(SPACE_MARGIN))
                             < RSV_BITS'(FIFO_DEPTH))
                          && ((DSUM_BITS'(dq_cnt_q) + DSUM_BITS'(dq_rsv_q) + DSUM_BITS'(2))
                                <= DSUM_BITS'(DESC_DEPTH));

            // -- output fsm ----------------------------------------------------------------------
            case (ost_q)
                O_IDLE: begin
                    if (!dq_empty_w) begin
                        // The only 48-bit adder on this path, and it is registered here. Slot c
                        // starts at a multiple of 2^SLOT_LOG2, so (conn << SLOT_LOG2) | off is a
                        // concatenation -- no shifter, no second adder.
                        req_vaddr_q <= slot_base
                                     + VADDR_BITS'({dq_head_w.conn, dq_head_w.off[SLOT_LOG2-1:0]});
                        req_len_q   <= dq_head_w.len;
                        req_conn_q  <= dq_head_w.conn;
                        req_end_q   <= dq_head_w.end_off;
                        ost_q       <= dq_head_w.drop ? O_DISCARD : O_REQ;
                    end
                end
                O_REQ: begin
                    if (req_fire_w) ost_q <= O_DATA;
                end
                O_DATA: begin
                    if (out_done_w) ost_q <= O_IDLE;
                end
                O_DISCARD: begin
                    if (out_done_w) ost_q <= O_IDLE;
                end
                default: ost_q <= O_IDLE;
            endcase

            // -- completion queue ----------------------------------------------------------------
            if (req_fire_w) begin
                aq_conn[aq_tail_q] <= req_conn_q;
                aq_end[aq_tail_q]  <= req_end_q;
                aq_tail_q <= (aq_tail_q == APTR_BITS'(ACKQ_DEPTH-1)) ? '0 : aq_tail_q + 1'b1;
            end
            if (wr_ack && (aq_cnt_q != '0)) begin
                aq_head_q <= (aq_head_q == APTR_BITS'(ACKQ_DEPTH-1)) ? '0 : aq_head_q + 1'b1;
            end
            case ({req_fire_w, (wr_ack && (aq_cnt_q != '0))})
                2'b10:   aq_cnt_q <= aq_cnt_q + 1'b1;
                2'b01:   aq_cnt_q <= aq_cnt_q - 1'b1;
                default: ;
            endcase
        end
    end

    // =============================================================================================
    // Simulation-only checks. These are the invariants the rest of the design assumes and that a
    // waveform will not volunteer.
    // =============================================================================================
    // synthesis translate_off
    int unsigned sim_inflight [N_CONNS];   // descriptors of conn c not yet acked or discarded

    initial begin
        for (int c = 0; c < N_CONNS; c++) sim_inflight[c] = 0;
    end

    always @(posedge clk) begin
        if (rst_n) begin
            if ($countones(conn_tvalid) > 1)
                $display("slot_writer: FAIL t=%0t conn_tvalid %b is not one-hot", $time, conn_tvalid);
            if (in_fire_w && !conn_tlast && (conn_tkeep != {KEEP_BITS{1'b1}}))
                $display("slot_writer: FAIL t=%0t non-final segment beat tkeep %0h is not full",
                         $time, conn_tkeep);
            if (desc_push_w)                          sim_inflight[conn_sel_w]++;
            if (wr_ack && (aq_cnt_q != '0))           sim_inflight[aq_conn[aq_head_q]]--;
            if (out_done_w && (ost_q == O_DISCARD))   sim_inflight[req_conn_q]--;
            for (int c = 0; c < N_CONNS; c++) begin
                if (conn_release[c] && (sim_inflight[c] != 0))
                    $display("slot_writer: FAIL t=%0t release of conn %0d with %0d segment(s) in flight",
                             $time, c, sim_inflight[c]);
            end
        end
    end
    // synthesis translate_on

endmodule
