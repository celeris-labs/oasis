`timescale 1ns / 1ps

import lynxTypes::*;

// Receive dispatcher for NUM_CONNS TCP connections. With the TOE's DDR bypass every session shares
// one receive fifo, and a readPkg pops its head whatever session it names, so readPkgs go out
// strictly in arrival order from one queue, one per notification. Back-pressure applies only to
// the decision to issue: a readPkg goes out once the destination fifo has room for a segment, and
// its beats are then accepted unconditionally. A connection that blocks the head for
// HOL_STALL_CYCLES is declared dead; its packets, and those of sessions nobody holds, are read and
// discarded, since an announcement that is never read strands its bytes in the shared fifo.
module rx_dispatch #(
    parameter int NUM_CONNS    = 4,
    // Announcements outstanding across all connections; the notification port is held when full.
    parameter int NOTIFY_DEPTH = 64,
    // About 262 us at 250 MHz, longer than a healthy lane takes to drain its whole fifo.
    parameter int HOL_STALL_CYCLES = 65536,
    // 1: notifications pass a two-deep register slice first, so TREADY is a flop. handler_multi: 0.
    parameter bit  NOTE_REG     = 1'b0,
    localparam int CONN_BITS   = (NUM_CONNS > 1) ? $clog2(NUM_CONNS) : 1,
    localparam int PTR_BITS    = $clog2(NOTIFY_DEPTH),
    localparam int CNT_BITS    = $clog2(NOTIFY_DEPTH + 1),
    localparam int HOL_BITS    = $clog2(HOL_STALL_CYCLES + 1)
) (
    input  logic clk,
    input  logic rst_n,

    // TREADY falls only when an announcement needs a queue slot and there is none.
    input  logic                       s_axis_notifications_TVALID,
    output logic                       s_axis_notifications_TREADY,
    input  logic [TCP_NOTIFY_BITS-1:0] s_axis_notifications_TDATA,

    input  logic                        bind_en,
    input  logic [CONN_BITS-1:0]        bind_conn,
    input  logic [TCP_SESSION_BITS-1:0] bind_sid,
    input  logic                        release_en,
    input  logic [CONN_BITS-1:0]        release_conn,

    output logic                            m_axis_read_package_TVALID,
    input  logic                            m_axis_read_package_TREADY,
    output logic [TCP_RD_PKG_REQ_BITS-1:0]  m_axis_read_package_TDATA,

    input  logic                        s_axis_rx_metadata_TVALID,
    output logic                        s_axis_rx_metadata_TREADY,
    input  logic [TCP_RX_META_BITS-1:0] s_axis_rx_metadata_TDATA,

    input  logic                       s_axis_rx_data_TVALID,
    output logic                       s_axis_rx_data_TREADY,
    input  logic [AXI_DATA_BITS-1:0]   s_axis_rx_data_TDATA,
    input  logic [AXI_DATA_BITS/8-1:0] s_axis_rx_data_TKEEP,
    input  logic                       s_axis_rx_data_TLAST,

    // One port per connection. tready should always be high, since the fifo reserved room; a
    // refused beat is lost and sets route_stall.
    output logic [NUM_CONNS-1:0]       conn_tvalid,
    input  logic [NUM_CONNS-1:0]       conn_tready,
    output logic [AXI_DATA_BITS-1:0]   conn_tdata,
    output logic [AXI_DATA_BITS/8-1:0] conn_tkeep,
    output logic                       conn_tlast,

    // Must mean room for a whole MSS: a readPkg for connection i is issued only while it is high.
    input  logic [NUM_CONNS-1:0]       conn_space_ok,

    // One-hot pulse per issued readPkg, so the fifo can reserve a segment for the bytes in flight.
    output logic [NUM_CONNS-1:0]       conn_pkg_issued,

    output logic [NUM_CONNS-1:0]       conn_closed,

    output logic [NUM_CONNS-1:0]       dbg_has_pending,
    output logic                       dbg_overflow,   // sticky: an announcement was dropped (never)
    output logic                       dbg_route_stall,// sticky: a consumer refused a beat
    // Sticky per connection: declared dead by the head-of-line watchdog; the lane goes fatal.
    output logic [NUM_CONNS-1:0]       dbg_lane_dead
);

    // Packed appNotification layout (Coyote's tcp_notify_t):
    //   sessionID[15:0], length[31:16], ipAddress[63:32], dstPort[79:64], closed[80], opened[81]
    localparam int CLOSED_BIT = TCP_SESSION_BITS + TCP_LEN_BITS + 32 + 16;

    logic                        bound_q [NUM_CONNS];
    logic [TCP_SESSION_BITS-1:0] sid_q   [NUM_CONNS];
    logic                        closed_q[NUM_CONNS];

    function automatic logic [CONN_BITS-1:0] conn_of(input logic [TCP_SESSION_BITS-1:0] sid);
        conn_of = '0;
        for (int i = 0; i < NUM_CONNS; i++) begin
            if (bound_q[i] && (sid_q[i] == sid)) conn_of = CONN_BITS'(i);
        end
    endfunction

    function automatic logic has_conn(input logic [TCP_SESSION_BITS-1:0] sid);
        has_conn = 1'b0;
        for (int i = 0; i < NUM_CONNS; i++) begin
            if (bound_q[i] && (sid_q[i] == sid)) has_conn = 1'b1;
        end
    endfunction

    // One announcement queue for all connections, in arrival order.
    logic [TCP_SESSION_BITS-1:0] nq_sid [NOTIFY_DEPTH];
    logic [TCP_LEN_BITS-1:0]     nq_len [NOTIFY_DEPTH];
    // Recorded at enqueue: after a release, conn_of() of the sid would fall through to lane 0.
    logic [CONN_BITS-1:0]        nq_conn[NOTIFY_DEPTH];
    // For a session nobody holds: still read in arrival order, then discarded.
    logic                        nq_orphan[NOTIFY_DEPTH];
    logic [PTR_BITS-1:0]         nq_head_q, nq_tail_q;
    logic [CNT_BITS-1:0]         nq_cnt_q;
    logic                        ovf_q, route_stall_q;
    logic [NUM_CONNS-1:0]        dead_q;

    logic [CNT_BITS-1:0]         pend_q [NUM_CONNS];

    logic nq_empty_w, nq_full_w;
    assign nq_empty_w = (nq_cnt_q == '0);
    assign nq_full_w  = (nq_cnt_q == CNT_BITS'(NOTIFY_DEPTH));

    // Optional two-deep slice (NOTE_REG); without it nt_* are the port itself.
    logic                       nt_valid_w, nt_ready_w;
    logic [TCP_NOTIFY_BITS-1:0] nt_data_w;

    if (NOTE_REG) begin : gen_note_reg
        logic                       nr_v_q,  nr2_v_q;
        logic [TCP_NOTIFY_BITS-1:0] nr_d_q,  nr2_d_q;

        assign s_axis_notifications_TREADY = !nr2_v_q;

        always_ff @(posedge clk) begin
            if (!rst_n) begin
                nr_v_q  <= 1'b0;
                nr2_v_q <= 1'b0;
            end else if (nt_ready_w || !nr_v_q) begin
                if (nr2_v_q) begin
                    nr_v_q  <= 1'b1;
                    nr2_v_q <= 1'b0;
                end else begin
                    nr_v_q  <= s_axis_notifications_TVALID;
                end
            end else if (s_axis_notifications_TVALID && !nr2_v_q) begin
                nr2_v_q <= 1'b1;
            end
        end

        always_ff @(posedge clk) begin
            if (nt_ready_w || !nr_v_q) begin
                nr_d_q <= nr2_v_q ? nr2_d_q : s_axis_notifications_TDATA;
            end else if (s_axis_notifications_TVALID && !nr2_v_q) begin
                nr2_d_q <= s_axis_notifications_TDATA;
            end
        end

        assign nt_valid_w = nr_v_q;
        assign nt_data_w  = nr_d_q;
    end else begin : gen_note_direct
        assign s_axis_notifications_TREADY = nt_ready_w;
        assign nt_valid_w = s_axis_notifications_TVALID;
        assign nt_data_w  = s_axis_notifications_TDATA;
    end

    logic [TCP_SESSION_BITS-1:0] note_sid_w;
    logic [TCP_LEN_BITS-1:0]     note_len_w;
    logic                        note_closed_w, note_fire_w;
    assign note_sid_w    = nt_data_w[TCP_SESSION_BITS-1:0];
    assign note_len_w    = nt_data_w[TCP_SESSION_BITS +: TCP_LEN_BITS];
    assign note_closed_w = nt_data_w[CLOSED_BIT];

    // A bare FIN (length 0) needs no slot; a readPkg of length 0 would hang the TOE.
    logic note_needs_slot_w;
    assign note_needs_slot_w = (note_len_w != '0);

    assign nt_ready_w    = !(note_needs_slot_w && nq_full_w);
    assign note_fire_w   = nt_valid_w && nt_ready_w;

    logic note_keep_w;
    assign note_keep_w = note_fire_w && note_needs_slot_w;

    // always_comb, not assign, where conn_of()/has_conn() are called: xsim re-evaluates an assign
    // only when the function arguments change, not when bound_q or sid_q do.
    logic                 enq_fire_w;
    logic [CONN_BITS-1:0] enq_conn_w;
    logic                 enq_orphan_w;
    assign enq_fire_w = note_keep_w && !nq_full_w;
    always_comb enq_conn_w   = conn_of(note_sid_w);
    always_comb enq_orphan_w = !has_conn(note_sid_w);

    logic [TCP_SESSION_BITS-1:0] head_sid_w;
    logic [TCP_LEN_BITS-1:0]     head_len_w;
    logic [CONN_BITS-1:0]        head_conn_w;
    assign head_sid_w  = nq_sid[nq_head_q];
    assign head_len_w  = nq_len[nq_head_q];
    // An empty queue has no head; reading the unwritten slot would put X into the watchdog.
    assign head_conn_w = nq_empty_w ? CONN_BITS'(0) : nq_conn[nq_head_q];
    logic  head_orphan_w;
    assign head_orphan_w = !nq_empty_w && nq_orphan[nq_head_q];

    logic issue_ok_w;
    assign issue_ok_w = !nq_empty_w && (head_orphan_w || conn_space_ok[head_conn_w] || dead_q[head_conn_w]);

    assign m_axis_read_package_TVALID = issue_ok_w;
    assign m_axis_read_package_TDATA  = {head_len_w, head_sid_w};

    logic issue_fire_w;
    assign issue_fire_w = m_axis_read_package_TVALID && m_axis_read_package_TREADY;

    always_comb begin
        conn_pkg_issued = '0;
        if (issue_fire_w && !head_orphan_w) conn_pkg_issued[head_conn_w] = 1'b1;
    end

    // Head-of-line watchdog. One counter is enough: only the head's connection is waited on.
    logic                 hol_blocked_w;
    logic [HOL_BITS-1:0]  hol_cnt_q;
    logic [CONN_BITS-1:0] hol_conn_q;
    assign hol_blocked_w = !nq_empty_w && !head_orphan_w && !conn_space_ok[head_conn_w] && !dead_q[head_conn_w];

    logic                 pkt_active_q;
    logic [CONN_BITS-1:0] pkt_conn_q;
    // Nobody owns this packet's bytes any more (session released, or connection dead): drop it.
    logic                 pkt_drop_q;

    logic meta_fire_w;
    assign s_axis_rx_metadata_TREADY = !pkt_active_q;
    assign meta_fire_w = s_axis_rx_metadata_TVALID && s_axis_rx_metadata_TREADY;

    // Never gate this: it keeps the shared receive fifo draining for every other session.
    assign s_axis_rx_data_TREADY = pkt_active_q;

    logic data_fire_w;
    assign data_fire_w = s_axis_rx_data_TVALID && s_axis_rx_data_TREADY;

    always_comb begin
        conn_tvalid = '0;
        if (pkt_active_q && !pkt_drop_q) conn_tvalid[pkt_conn_q] = s_axis_rx_data_TVALID;
    end
    assign conn_tdata = s_axis_rx_data_TDATA;
    assign conn_tkeep = s_axis_rx_data_TKEEP;
    assign conn_tlast = s_axis_rx_data_TLAST;

    integer i;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            nq_head_q     <= '0;
            nq_tail_q     <= '0;
            nq_cnt_q      <= '0;
            ovf_q         <= 1'b0;
            route_stall_q <= 1'b0;
            pkt_active_q  <= 1'b0;
            pkt_conn_q    <= '0;
            pkt_drop_q    <= 1'b0;
            dead_q        <= '0;
            hol_cnt_q     <= '0;
            hol_conn_q    <= '0;
            for (i = 0; i < NUM_CONNS; i++) begin
                bound_q[i]  <= 1'b0;
                sid_q[i]    <= '0;
                closed_q[i] <= 1'b0;
                pend_q[i]   <= '0;
            end
        end else begin
            if (bind_en) begin
                bound_q[bind_conn]  <= 1'b1;
                sid_q[bind_conn]    <= bind_sid;
                closed_q[bind_conn] <= 1'b0;
                dead_q[bind_conn]   <= 1'b0;
            end
            if (release_en) begin
                bound_q[release_conn]  <= 1'b0;
                closed_q[release_conn] <= 1'b0;
                dead_q[release_conn]   <= 1'b0;
            end

            if (note_fire_w && note_closed_w && has_conn(note_sid_w)) begin
                closed_q[conn_of(note_sid_w)] <= 1'b1;
            end

            if (enq_fire_w) begin
                nq_sid[nq_tail_q]  <= note_sid_w;
                nq_len[nq_tail_q]  <= note_len_w;
                nq_conn[nq_tail_q] <= enq_conn_w;
                nq_orphan[nq_tail_q] <= enq_orphan_w;
                nq_tail_q <= (nq_tail_q == PTR_BITS'(NOTIFY_DEPTH-1)) ? '0 : nq_tail_q + 1'b1;
            end
            // Unreachable, since TREADY falls first; if set, announcements are being lost.
            if (note_keep_w && nq_full_w) ovf_q <= 1'b1;

            if (issue_fire_w) begin
                nq_head_q <= (nq_head_q == PTR_BITS'(NOTIFY_DEPTH-1)) ? '0 : nq_head_q + 1'b1;
            end

            case ({enq_fire_w, issue_fire_w})
                2'b10:   nq_cnt_q <= nq_cnt_q + 1'b1;
                2'b01:   nq_cnt_q <= nq_cnt_q - 1'b1;
                default: ;
            endcase

            // A release forgets the connection's pending count. The decrement is guarded so a stale
            // head cannot underflow it.
            for (i = 0; i < NUM_CONNS; i++) begin
                if (release_en && (release_conn == CONN_BITS'(i))) begin
                    pend_q[i] <= '0;
                end else begin
                    case ({enq_fire_w   && !enq_orphan_w  && (enq_conn_w  == CONN_BITS'(i)),
                           issue_fire_w && !head_orphan_w && (head_conn_w == CONN_BITS'(i)) && (pend_q[i] != '0)})
                        2'b10:   pend_q[i] <= pend_q[i] + 1'b1;
                        2'b01:   pend_q[i] <= pend_q[i] - 1'b1;
                        default: ;
                    endcase
                end
            end

            // The metadata names the session actually delivered; an unbound one is dropped, not
            // routed to lane 0.
            if (meta_fire_w) begin
                pkt_active_q <= 1'b1;
                pkt_conn_q   <= conn_of(s_axis_rx_metadata_TDATA[TCP_SESSION_BITS-1:0]);
                pkt_drop_q   <= !has_conn(s_axis_rx_metadata_TDATA[TCP_SESSION_BITS-1:0]) ||
                                 dead_q[conn_of(s_axis_rx_metadata_TDATA[TCP_SESSION_BITS-1:0])];
            end else if (data_fire_w && s_axis_rx_data_TLAST) begin
                pkt_active_q <= 1'b0;
            end

            if (pkt_active_q && !pkt_drop_q && s_axis_rx_data_TVALID && !conn_tready[pkt_conn_q]) begin
                route_stall_q <= 1'b1;
            end

            if (!hol_blocked_w || (head_conn_w != hol_conn_q)) begin
                hol_conn_q <= head_conn_w;
                hol_cnt_q  <= '0;
            end else if (hol_cnt_q == HOL_BITS'(HOL_STALL_CYCLES)) begin
                dead_q[hol_conn_q] <= 1'b1;
            end else begin
                hol_cnt_q <= hol_cnt_q + 1'b1;
            end
        end
    end

    always_comb begin
        for (int j = 0; j < NUM_CONNS; j++) dbg_has_pending[j] = (pend_q[j] != '0);
    end

    always_comb begin
        for (int k = 0; k < NUM_CONNS; k++) conn_closed[k] = closed_q[k];
    end

    assign dbg_overflow    = ovf_q;
    assign dbg_route_stall = route_stall_q;
    assign dbg_lane_dead   = dead_q;

endmodule
