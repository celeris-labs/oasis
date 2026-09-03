`timescale 1ns / 1ps

import lynxTypes::*;

// =================================================================================================
// Arrival-order receive dispatcher for N concurrent TCP connections.
//
// Replaces tcp_session_table's per-slot announcement queues. See ARCHITECTURE.md, ADR-1 and ADR-3.
//
// THE CONTRACT
// ------------
// The TOE is built with TCP_STACK_RX_DDR_BYPASS_EN=1, so there is no per-session receive buffer:
// every session shares one axis_data_fifo_512_d1024 (tcp_stack.sv:681, 1024 x 64 B = 64 KB) and
// toe.cpp's rxAppMemDataRead() pops the HEAD of it regardless of which session asked. The session id
// in a readPkg is not an address -- it is only used to advance that session's app read pointer
// (rx_app_stream_if.cpp: rxSarAppd(sessionID, appd + readLength)). So:
//
//     readPkg must be issued in GLOBAL ARRIVAL ORDER across all sessions,
//     and the drain must never stop.
//
// tcp_session_table queued announcements per slot and let the reader take them in REQUEST order.
// That reorders, and reordering hands one session's bytes to another session's reader -- builds
// 90/91/92. Coyote's own full-throughput receiver satisfies the contract by never buffering at all
// (examples/13_perf_tcp/.../tcp_perf_server.cpp): read a notification, issue the readPkg, consume to
// `last`, at II=1. This module is that shape, with two additions it needs and the benchmark does
// not -- it has to route bytes to the right consumer, and it has to survive a consumer that is
// slower than the wire.
//
// WHERE THE BACK-PRESSURE GOES
// ----------------------------
// Exactly one place: the DECISION TO ISSUE a readPkg. A packet is only requested once the target
// connection's fifo can certainly hold it. Once requested, every beat is accepted unconditionally.
//
// That distinction is the whole design. Gating the data stream instead would stall the shared fifo
// for every other session at once -- including sessions whose consumers are keeping up -- which is
// the failure mode ADR-2 was about, multiplied by N.
//
// ONE readPkg PER NOTIFICATION
// ----------------------------
// A readPkg returns exactly ONE announced segment however many bytes it names, because on the
// bypass path rxAppMemDataRead forwards words until currWord.last. Naming a larger length does not
// coalesce segments; it only runs the receive window ahead of what was really consumed. That cost
// build-90 a day, so the length here is always passed through from the notification unchanged.
// =================================================================================================
module rx_dispatch #(
    parameter int NUM_CONNS    = 4,
    // Announcements that may be outstanding across ALL connections. Global now, not per slot: the
    // TOE announces one segment at a time and the shared fifo holds 64 KB, so at MSS 4096 there can
    // never be more than 16 unread announcements in existence. 64 is comfortable.
    parameter int NOTIFY_DEPTH = 64,
    localparam int CONN_BITS   = (NUM_CONNS > 1) ? $clog2(NUM_CONNS) : 1,
    localparam int PTR_BITS    = $clog2(NOTIFY_DEPTH),
    localparam int CNT_BITS    = $clog2(NOTIFY_DEPTH + 1)
) (
    input  logic clk,
    input  logic rst_n,

    // -- Notification sink. TREADY is hardwired high: back-pressuring this interface stalls every
    //    session simultaneously, including ones that are perfectly healthy.
    input  logic                       s_axis_notifications_TVALID,
    output logic                       s_axis_notifications_TREADY,
    input  logic [TCP_NOTIFY_BITS-1:0] s_axis_notifications_TDATA,

    // -- Connection binding, driven by the handler's connect stage.
    input  logic                        bind_en,
    input  logic [CONN_BITS-1:0]        bind_conn,
    input  logic [TCP_SESSION_BITS-1:0] bind_sid,
    input  logic                        release_en,
    input  logic [CONN_BITS-1:0]        release_conn,

    // -- readPkg request out.
    output logic                            m_axis_read_package_TVALID,
    input  logic                            m_axis_read_package_TREADY,
    output logic [TCP_RD_PKG_REQ_BITS-1:0]  m_axis_read_package_TDATA,

    // -- rx metadata: one beat per readPkg, naming the session the following data belongs to.
    input  logic                        s_axis_rx_metadata_TVALID,
    output logic                        s_axis_rx_metadata_TREADY,
    input  logic [TCP_RX_META_BITS-1:0] s_axis_rx_metadata_TDATA,

    // -- rx data: accepted unconditionally while a packet is in progress.
    input  logic                       s_axis_rx_data_TVALID,
    output logic                       s_axis_rx_data_TREADY,
    input  logic [AXI_DATA_BITS-1:0]   s_axis_rx_data_TDATA,
    input  logic [AXI_DATA_BITS/8-1:0] s_axis_rx_data_TKEEP,
    input  logic                       s_axis_rx_data_TLAST,

    // -- Demultiplexed output, one port per connection. tready is expected to be high (these feed
    //    the per-connection fifos); if it ever falls the shared fifo is being stalled again, which
    //    route_stall latches.
    output logic [NUM_CONNS-1:0]       conn_tvalid,
    input  logic [NUM_CONNS-1:0]       conn_tready,
    output logic [AXI_DATA_BITS-1:0]   conn_tdata,
    output logic [AXI_DATA_BITS/8-1:0] conn_tkeep,
    output logic                       conn_tlast,

    // -- Per-connection fifo space, from the fifos. A readPkg for connection i is only issued while
    //    conn_space_ok[i] is high, so it must mean "room for a whole MSS", not "room for one beat".
    input  logic [NUM_CONNS-1:0]       conn_space_ok,

    // -- Per-connection sticky FIN.
    output logic [NUM_CONNS-1:0]       conn_closed,

    output logic [NUM_CONNS-1:0]       dbg_has_pending,
    output logic                       dbg_overflow,   // sticky: an announcement was dropped
    output logic                       dbg_route_stall // sticky: a consumer refused a beat
);

    // Packed appNotification layout (mirrors tcp_read.sv / tcp_session_table.sv):
    //   sessionID[15:0], length[31:16], ipAddress[63:32], dstPort[79:64], closed[80], opened[81]
    localparam int CLOSED_BIT = TCP_SESSION_BITS + TCP_LEN_BITS + 32 + 16; // = 80

    // ---------------------------------------------------------------------------------------------
    // Session -> connection binding
    // ---------------------------------------------------------------------------------------------
    logic                        bound_q [NUM_CONNS];
    logic [TCP_SESSION_BITS-1:0] sid_q   [NUM_CONNS];
    logic                        closed_q[NUM_CONNS];

    // Combinational lookup. NUM_CONNS is small (<= 8) so a flat compare is cheaper and shallower
    // than any encoded scheme, and it keeps the mapping visible in one place.
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

    // ---------------------------------------------------------------------------------------------
    // The announcement queue. ONE queue, in arrival order, for every connection together -- that
    // ordering IS the contract, so there is deliberately no per-connection structure here.
    // ---------------------------------------------------------------------------------------------
    logic [TCP_SESSION_BITS-1:0] nq_sid [NOTIFY_DEPTH];
    logic [TCP_LEN_BITS-1:0]     nq_len [NOTIFY_DEPTH];
    logic [PTR_BITS-1:0]         nq_head_q, nq_tail_q;
    logic [CNT_BITS-1:0]         nq_cnt_q;
    logic                        ovf_q, route_stall_q;

    // Announcements queued per connection, maintained incrementally.
    //
    // This replaces a combinational sweep of all NOTIFY_DEPTH entries that computed a rotated index
    // (nq_head_q + j) % NOTIFY_DEPTH and called has_conn()/conn_of() on every one of them -- a
    // NOTIFY_DEPTH-way barrel rotate over the whole sid array plus 2*NUM_CONNS*NOTIFY_DEPTH session
    // comparators, 8603 LUTs against 1158 FFs in build-110. It existed only to drive
    // dbg_has_pending, whose single consumer OR-reduces it into a debug word; and by reading every
    // queue entry combinationally it also kept nq_sid/nq_len out of RAM. Counters cost NUM_CONNS
    // registers and say the same thing more exactly.
    logic [CNT_BITS-1:0]         pend_q [NUM_CONNS];

    logic nq_empty_w, nq_full_w;
    assign nq_empty_w = (nq_cnt_q == '0);
    assign nq_full_w  = (nq_cnt_q == CNT_BITS'(NOTIFY_DEPTH));

    // Incoming notification, unpacked.
    logic [TCP_SESSION_BITS-1:0] note_sid_w;
    logic [TCP_LEN_BITS-1:0]     note_len_w;
    logic                        note_closed_w, note_fire_w;
    assign note_sid_w    = s_axis_notifications_TDATA[TCP_SESSION_BITS-1:0];
    assign note_len_w    = s_axis_notifications_TDATA[TCP_SESSION_BITS +: TCP_LEN_BITS];
    assign note_closed_w = s_axis_notifications_TDATA[CLOSED_BIT];
    assign s_axis_notifications_TREADY = 1'b1;
    assign note_fire_w   = s_axis_notifications_TVALID;

    // A notification for a session we do not have bound is not an error we can act on -- it belongs
    // to a connection torn down between the announcement and now. Dropping it is correct; queueing
    // it would issue a readPkg for a dead session and desynchronise the shared fifo for everyone.
    logic note_keep_w;
    assign note_keep_w = note_fire_w && (note_len_w != '0) && has_conn(note_sid_w);

    // The enqueue condition, named once. Used by the queue pointers, by the count, and by the
    // per-connection pending counters below.
    logic                 enq_fire_w;
    logic [CONN_BITS-1:0] enq_conn_w;
    assign enq_fire_w = note_keep_w && !nq_full_w;
    assign enq_conn_w = conn_of(note_sid_w);

    // ---------------------------------------------------------------------------------------------
    // readPkg issue. Head of the queue, gated ONLY on the destination having room.
    // ---------------------------------------------------------------------------------------------
    logic [TCP_SESSION_BITS-1:0] head_sid_w;
    logic [TCP_LEN_BITS-1:0]     head_len_w;
    logic [CONN_BITS-1:0]        head_conn_w;
    assign head_sid_w  = nq_sid[nq_head_q];
    assign head_len_w  = nq_len[nq_head_q];
    assign head_conn_w = conn_of(head_sid_w);

    logic issue_ok_w;
    assign issue_ok_w = !nq_empty_w && conn_space_ok[head_conn_w];

    assign m_axis_read_package_TVALID = issue_ok_w;
    assign m_axis_read_package_TDATA  = {head_len_w, head_sid_w};

    logic issue_fire_w;
    assign issue_fire_w = m_axis_read_package_TVALID && m_axis_read_package_TREADY;

    // ---------------------------------------------------------------------------------------------
    // Data routing. rx_meta names the session of the packet about to arrive; hold that until tlast.
    // ---------------------------------------------------------------------------------------------
    logic                 pkt_active_q;
    logic [CONN_BITS-1:0] pkt_conn_q;

    logic meta_fire_w;
    assign s_axis_rx_metadata_TREADY = !pkt_active_q;
    assign meta_fire_w = s_axis_rx_metadata_TVALID && s_axis_rx_metadata_TREADY;

    // Unconditional acceptance while a packet is in progress. This is the line that must never gain
    // a term: it is what keeps the shared 64 KB fifo draining for every other session.
    assign s_axis_rx_data_TREADY = pkt_active_q;

    logic data_fire_w;
    assign data_fire_w = s_axis_rx_data_TVALID && s_axis_rx_data_TREADY;

    always_comb begin
        conn_tvalid = '0;
        if (pkt_active_q) conn_tvalid[pkt_conn_q] = s_axis_rx_data_TVALID;
    end
    assign conn_tdata = s_axis_rx_data_TDATA;
    assign conn_tkeep = s_axis_rx_data_TKEEP;
    assign conn_tlast = s_axis_rx_data_TLAST;

    // ---------------------------------------------------------------------------------------------
    // Sequential
    // ---------------------------------------------------------------------------------------------
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
            for (i = 0; i < NUM_CONNS; i++) begin
                bound_q[i]  <= 1'b0;
                sid_q[i]    <= '0;
                closed_q[i] <= 1'b0;
                pend_q[i]   <= '0;
            end
        end else begin
            // -- binding
            if (bind_en) begin
                bound_q[bind_conn]  <= 1'b1;
                sid_q[bind_conn]    <= bind_sid;
                closed_q[bind_conn] <= 1'b0;
            end
            if (release_en) begin
                bound_q[release_conn]  <= 1'b0;
                closed_q[release_conn] <= 1'b0;
            end

            // -- sticky FIN, recorded even for a zero-length notification
            if (note_fire_w && note_closed_w && has_conn(note_sid_w)) begin
                closed_q[conn_of(note_sid_w)] <= 1'b1;
            end

            // -- enqueue / dequeue. Both can happen in the same cycle.
            if (enq_fire_w) begin
                nq_sid[nq_tail_q] <= note_sid_w;
                nq_len[nq_tail_q] <= note_len_w;
                nq_tail_q <= (nq_tail_q == PTR_BITS'(NOTIFY_DEPTH-1)) ? '0 : nq_tail_q + 1'b1;
            end
            if (note_keep_w && nq_full_w) ovf_q <= 1'b1;

            if (issue_fire_w) begin
                nq_head_q <= (nq_head_q == PTR_BITS'(NOTIFY_DEPTH-1)) ? '0 : nq_head_q + 1'b1;
            end

            case ({enq_fire_w, issue_fire_w})
                2'b10:   nq_cnt_q <= nq_cnt_q + 1'b1;
                2'b01:   nq_cnt_q <= nq_cnt_q - 1'b1;
                default: ;
            endcase

            // -- per-connection pending count. A release drops the accounting for that connection:
            //    its queued entries are already unroutable (conn_of returns 0 for an unbound sid),
            //    so counting them against the new binding would be worse than forgetting them. The
            //    decrement is guarded so a stale head cannot underflow a lane back to all-ones.
            for (i = 0; i < NUM_CONNS; i++) begin
                if (release_en && (release_conn == CONN_BITS'(i))) begin
                    pend_q[i] <= '0;
                end else begin
                    case ({enq_fire_w   && (enq_conn_w  == CONN_BITS'(i)),
                           issue_fire_w && (head_conn_w == CONN_BITS'(i)) && (pend_q[i] != '0)})
                        2'b10:   pend_q[i] <= pend_q[i] + 1'b1;
                        2'b01:   pend_q[i] <= pend_q[i] - 1'b1;
                        default: ;
                    endcase
                end
            end

            // -- packet routing window
            if (meta_fire_w) begin
                pkt_active_q <= 1'b1;
                pkt_conn_q   <= conn_of(s_axis_rx_metadata_TDATA[TCP_SESSION_BITS-1:0]);
            end else if (data_fire_w && s_axis_rx_data_TLAST) begin
                pkt_active_q <= 1'b0;
            end

            // A consumer that refuses a beat means its fifo filled despite conn_space_ok, i.e. the
            // space check is wrong or the fifo is undersized. Either way the shared fifo is being
            // stalled again and the whole point of this module is lost.
            if (pkt_active_q && s_axis_rx_data_TVALID && !conn_tready[pkt_conn_q]) begin
                route_stall_q <= 1'b1;
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

endmodule
