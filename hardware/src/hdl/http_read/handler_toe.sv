`timescale 1ns / 1ps

import lynxTypes::*;
import http_types::*;

// =================================================================================================
// HTTP client handler for the TOE with a RECEIVE RING PER SESSION (TCP_STACK_RX_DDR_BYPASS_EN = 0,
// patches 0007/0008; `synthesize.sh --toe-buffer`). Stage 1: one TCP session per decoder lane.
//
// WHAT THIS IS
// ------------
// A copy of handler_multi (the sealed build-119/125 handler, which stays untouched as the control
// arm) with its receive dispatcher swapped. handler_multi's rx_dispatch exists because the bypass
// TOE has ONE shared receive fifo for all sessions, so readPkgs had to follow global arrival order
// and a slow lane held every other lane up (head-of-line watchdog, orphan announcements, dead
// lanes). With the bypass off the TOE keeps each session's bytes in its own 1 MiB ring in card
// memory and serves readPkg(sid, len) for any session in any order. toe_rx does the receive side
// instead: it counts notified-but-unread bytes per lane and asks for them once the lane's fifo has
// promised room (tcp_read RSV_EXACT). A decoder that stops leaves its bytes in its ring; no other
// lane notices, and nothing is ever thrown away.
//
// THE SHAPE (per lane as in handler_multi)
//
//   notifications --> toe_rx --+-- tcp_read[0] -> slice -> rewrite_last[0] -> slice -> decoder 0
//   readPkg       <--  (count, |-- tcp_read[1] -> ...
//   rx meta/data  -->  route)  +-- ...
//
//   host text[L] --> http_req_stream[L] --> tx_arbiter --> ONE TOE transmit path
//
// WHAT IS DIFFERENT FROM handler_multi, AND WHY
// ---------------------------------------------
//   * toe_rx replaces rx_dispatch; tcp_read reserves exactly (RSV_EXACT). No head-of-line
//     watchdog, no dead lanes: LANE_ERR bit 0 reads 0, and a stalled decoder is never fatal.
//   * THE WINDOW RULE. The TOE never sends a window update when the application reads, and a
//     session whose window reaches 0 can deadlock. So per session, response bytes requested but
//     not yet read out of the ring (headers included) must stay <= 1 MiB - 16 - 4 KiB. The host
//     keeps it with ONE GET PER ARM (revision 6) and at most GET_CREDIT GETs outstanding per lane,
//     each capped (stage-1 host: 236 KiB + 4 KiB header, x 4 = 960 KiB); the hardware enforces the
//     credit: an arm is admitted only while fewer than GET_CREDIT responses of that lane are
//     unfinished (gets_out). toe_rx raises a sticky budget error if a lane's unread bytes ever pass
//     2^RING_LOG2 - 64 KiB (an origin ignoring Range, or a host breaking the rule).
//   * A FIN CAN OVERTAKE DATA. The TOE sends a FIN notification without waiting for the
//     write-status delay that data notifications wait for, so `closed` can arrive before the last
//     bytes are announced. A lane's peer counts as closed (tcp_read's rx_closed, and the idle
//     reconnect) only once the FIN has been seen AND nothing is unread AND no readPkg is out AND
//     that has held for CLOSE_SETTLE cycles. tcp_read's own 200-cycle DRAIN_SETTLE then runs
//     behind it as before.
//   * BR_DRAIN. After BR_CLOSE releases a session, the bring-up FSM waits until the lane has no
//     readPkg outstanding before it opens a new one: the old session's bytes still on their way
//     must land in the (discarding) lane while it is down, never be spliced into a rebound session
//     -- even one that got the same session id.
//   * Timing slices: a two-deep slice between the framer and the chunk
//     counter (61ad533) with the chunk-length push registered (CFG_REG), and the decoder's tready
//     kept out of the chunk-occupancy counter (741295a). toe_rx registers notifications (1419da6)
//     and the routed beats (b7ff974) itself.
//
// Everything else -- the config protocol per lane, the sequenced bring-up, reconnect-only-when-
// nothing-is-owed, fatal-closes-the-session, the read stage, the readback layout -- is
// handler_multi's, and so are most of the comments below. Readback: revision 6 in INFLIGHT[31:24]
// and LANE_POLICY[7:0]; LANE_POLICY[55:32] = GET_CREDIT, [61:56] = RING_LOG2 (the revision-2 meaning,
// the head-of-line watchdog, is gone with rx_dispatch). The HttpConfig register map is revision 2's.
// =================================================================================================
module handler_toe #(
    // Lanes. One TCP session, one framer, one chunk-length queue and one decoder each.
    parameter int NUM_CONNS = 4,
    // Column chunks queued ahead of the data, PER LANE.
    parameter int QUEUE_DEPTH = 64,
    // Receive decoupling fifo depth per lane, in 64-byte beats. It must hold one whole readPkg
    // (RD_MAX / 64 beats) plus axis_fifo's 4-beat slack, or a lane with RD_MAX unread could never
    // be granted.
    parameter int RX_FIFO_DEPTH = 2048,
    parameter int TX_CHUNK_BYTES = 4096,
    parameter int STALL_CYCLES = 268435456,
    // toe_rx: most bytes one readPkg asks for, and readPkgs outstanding per lane.
    parameter int RD_MAX = 16384,
    parameter int RD_OUT = 4,
    // GETs (= arms, one GET each on revision 6) whose responses may be unfinished per lane.
    parameter int GET_CREDIT = 4,
    // The TOE's receive ring per session, log2 bytes (1 MiB).
    parameter int RING_LOG2 = 20,
    // Quiet cycles after a FIN with nothing unread and nothing outstanding before the lane's peer
    // counts as closed (a FIN notification can overtake data notifications).
    parameter int CLOSE_SETTLE = 4096,
    // INFLIGHT[31:24] / LANE_POLICY[7:0].
    parameter int CSR_REV = 6,
    // 1: the two-deep slice between the framer and the chunk counter (61ad533, a timing fix for a
    // framer an SLR away from its counter). It costs a 2:1 mux and two 577-bit registers
    // per lane; 0 wires the framer straight into the counter as handler_multi does.
    parameter bit FRAMER_SLICE = 1'b1,
    localparam int CONN_BITS = (NUM_CONNS > 1) ? $clog2(NUM_CONNS) : 1
) (
    input  logic ap_clk,
    input  logic ap_rst_n,

    // -- TCP connection management (shared; opens are sequenced) ----------------------------------
    output logic                              m_axis_open_connection_TVALID,
    input  logic                              m_axis_open_connection_TREADY,
    output logic [TCP_OPEN_CONN_REQ_BITS-1:0] m_axis_open_connection_TDATA,
    input  logic                              s_axis_open_status_TVALID,
    output logic                              s_axis_open_status_TREADY,
    input  logic [TCP_OPEN_CONN_RSP_BITS-1:0] s_axis_open_status_TDATA,
    output logic                              m_axis_close_connection_TVALID,
    input  logic                              m_axis_close_connection_TREADY,
    output logic [TCP_CLOSE_CONN_REQ_BITS-1:0] m_axis_close_connection_TDATA,

    // -- TCP receive (shared; toe_rx counts, asks and routes) ---------------------------------------
    input  logic                       s_axis_notifications_TVALID,
    output logic                       s_axis_notifications_TREADY,
    input  logic [TCP_NOTIFY_BITS-1:0] s_axis_notifications_TDATA,
    output logic                           m_axis_read_package_TVALID,
    input  logic                           m_axis_read_package_TREADY,
    output logic [TCP_RD_PKG_REQ_BITS-1:0] m_axis_read_package_TDATA,
    input  logic                        s_axis_rx_metadata_TVALID,
    output logic                        s_axis_rx_metadata_TREADY,
    input  logic [TCP_RX_META_BITS-1:0] s_axis_rx_metadata_TDATA,
    input  logic                       s_axis_rx_data_TVALID,
    output logic                       s_axis_rx_data_TREADY,
    input  logic [AXI_DATA_BITS-1:0]   s_axis_rx_data_TDATA,
    input  logic [AXI_DATA_BITS/8-1:0] s_axis_rx_data_TKEEP,
    input  logic                       s_axis_rx_data_TLAST,

    // -- TCP transmit (shared, arbitrated) --------------------------------------------------------
    output logic                        m_axis_tx_meta_TVALID,
    input  logic                        m_axis_tx_meta_TREADY,
    output logic [TCP_TX_META_BITS-1:0] m_axis_tx_meta_TDATA,
    output logic                        m_axis_tx_data_TVALID,
    input  logic                        m_axis_tx_data_TREADY,
    output logic [AXI_DATA_BITS-1:0]    m_axis_tx_data_TDATA,
    output logic [AXI_DATA_BITS/8-1:0]  m_axis_tx_data_TKEEP,
    output logic                        m_axis_tx_data_TLAST,
    input  logic                        s_axis_tx_status_TVALID,
    output logic                        s_axis_tx_status_TREADY,
    input  logic [TCP_TX_STAT_BITS-1:0] s_axis_tx_status_TDATA,

    // -- config -----------------------------------------------------------------------------------
    input  logic         req_valid,
    output logic         req_ready,
    input  http_config_t req_data,

    // -- per-lane request text from the host ------------------------------------------------------
    input  logic [NUM_CONNS-1:0]       s_axis_req_TVALID,
    output logic [NUM_CONNS-1:0]       s_axis_req_TREADY,
    input  logic [AXI_DATA_BITS-1:0]   s_axis_req_TDATA  [NUM_CONNS],
    input  logic [AXI_DATA_BITS/8-1:0] s_axis_req_TKEEP  [NUM_CONNS],
    input  logic [NUM_CONNS-1:0]       s_axis_req_TLAST,

    // -- per-lane framed body out -----------------------------------------------------------------
    output logic [NUM_CONNS-1:0]       m_axis_body_tvalid,
    input  logic [NUM_CONNS-1:0]       m_axis_body_tready,
    output logic [AXI_DATA_BITS-1:0]   m_axis_body_tdata [NUM_CONNS],
    output logic [AXI_DATA_BITS/8-1:0] m_axis_body_tkeep [NUM_CONNS],
    output logic [NUM_CONNS-1:0]       m_axis_body_tlast,

    // -- readback ---------------------------------------------------------------------------------
    output logic [31:0] totalWord,
    output logic [31:0] inflightWord,
    output logic [31:0] queueDepthWord,
    output logic [31:0] stallWord,
    output logic [31:0] respWord,
    output logic [31:0] contentLengthWord,
    output logic [31:0] bodyRemainingWord,
    output logic [3:0]  state_debug,

    // -- PER-LANE readback (CSR revision 2) --------------------------------------------------------
    //
    // Everything above folds N lanes into one 32-bit window with OR, which answers "is anything
    // wrong" and nothing else. These five say WHICH LANE. They are 64 bits wide because eight lanes
    // need eight bytes, and the AXI-Lite read path is 64 bits (AXIL_DATA_BITS); read register 6
    // already carries a field at [39:32] and the host already decodes it, so the upper half is not
    // new ground. See http_config.sv for the register numbers and the field tables.
    output logic [63:0] laneOccWord,
    output logic [63:0] laneReadyWord,
    output logic [63:0] laneStateWord,
    output logic [63:0] laneErrWord,
    output logic [63:0] lanePolicyWord
);

    initial begin
        if (NUM_CONNS < 1 || NUM_CONNS > 8)
            $error("handler_toe: NUM_CONNS must be 1..8 (toe_rx uses a flat session compare)");
        if ((RD_MAX + 63) / 64 > RX_FIFO_DEPTH - 4)
            $error("handler_toe: RX_FIFO_DEPTH must hold one RD_MAX readPkg plus 4 beats");
        if (GET_CREDIT < 1 || GET_CREDIT > 255)
            $error("handler_toe: GET_CREDIT must be 1..255");
    end

    // =============================================================================================
    // Config beat decode. Every beat names a lane in req_chunk_dest.
    // =============================================================================================
    logic [CONN_BITS-1:0] cfg_lane;
    assign cfg_lane = req_data.req_chunk_dest[CONN_BITS-1:0];

    logic cfg_is_arm_w, cfg_is_entry_w;
    assign cfg_is_arm_w   = req_valid && (req_data.req_total_bytes != 32'd0);
    assign cfg_is_entry_w = req_valid && (req_data.req_total_bytes == 32'd0);

    logic [NUM_CONNS-1:0] rwl_cfg_ready, rwl_busy, rwl_starved;
    logic [NUM_CONNS-1:0] stream_busy, stream_refused, stream_bus_req, stream_bus_grant;
    logic [NUM_CONNS-1:0] lane_occ_ok;

    // THE TWO ADMISSION CONDITIONS, PER LANE.
    //
    // req_ready answers about the lane this beat names, exactly as the single-lane version answers
    // about the only lane there is. An ARM waits for that lane's previous text to have gone out; an
    // ENTRY waits for that lane's chunk queue to have room. Conflating them deadlocks -- the arm is
    // what drains the queue, so gating it on queue room means a batch that exactly fills the queue
    // can never begin.
    //
    // They are named here rather than inlined into req_ready because the host now reads them back
    // per lane (laneReadyWord). Both are MONOTONE IN THE HOST'S FAVOUR: nothing but a config beat
    // from the host can clear either one, so "poll, then write" is race-free and needs no retry.
    // stream_busy only rises on an ARM this module accepted; rwl_cfg_ready and lane_occ_ok only fall
    // on an ENTRY it accepted. Assigned in gen_lane below, with the signals they read.
    logic [NUM_CONNS-1:0] lane_arm_ready_w, lane_entry_ready_w;

    always_comb begin
        req_ready = 1'b0;
        for (int L = 0; L < NUM_CONNS; L++) begin
            if (cfg_lane == CONN_BITS'(L)) begin
                req_ready = (req_data.req_total_bytes != 32'd0) ? lane_arm_ready_w[L]
                                                                : lane_entry_ready_w[L];
            end
        end
    end

    logic cfg_fire;
    assign cfg_fire = req_valid && req_ready;

    // =============================================================================================
    // Connection bring-up. ONE tcp_init, sequenced across lanes.
    //
    // N concurrent opens would need N tcp_inits and an arbiter on open_connection/open_status, for
    // an event that happens once per query on a ~1 ms path. Sequencing costs N round trips at
    // startup and nothing thereafter, and it makes the session-to-lane binding trivially ordered.
    // =============================================================================================
    logic [31:0] server_ip_q, server_port_q;
    logic        any_armed_q;

    localparam logic [2:0] BR_IDLE  = 3'd0;  // nothing wanted yet
    localparam logic [2:0] BR_OPEN  = 3'd1;  // tcp_init running for lane bring_lane_q
    localparam logic [2:0] BR_NEXT  = 3'd2;  // bind, advance to the next lane
    localparam logic [2:0] BR_DONE  = 3'd3;  // all lanes up; watching for reconnect requests
    localparam logic [2:0] BR_CLOSE = 3'd4;  // tearing bring_lane_q down before reopening it
    localparam logic [2:0] BR_DRAIN = 3'd5;  // released; waiting for its readPkgs to have landed

    logic [2:0]           br_q, br_d;
    logic [CONN_BITS-1:0] bring_lane_q, bring_lane_d;
    // Distinguishes the initial walk across all lanes from a later single-lane reconnect, so
    // BR_OPEN knows where to return to.
    logic                 bringing_up_q;
    logic [NUM_CONNS-1:0] conn_up_q;
    logic [15:0]          conn_sid_q [NUM_CONNS];

    logic        init_done, init_error;
    logic [15:0] init_session_id;
    logic [3:0]  init_state_debug;

    localparam int RETRY_BITS = 16;
    logic [RETRY_BITS-1:0] retry_wait_q;
    // Reconnects since reset, saturating. A handful over a long session is MinIO's idle timeout
    // doing its job; a steadily climbing count means something is wrong with the connection.
    logic [7:0]            reconn_cnt_q;

    tcp_init inst_tcp_init (
        .clk(ap_clk), .rst_n(ap_rst_n),
        .start(br_q == BR_OPEN),
        .serverIpAddress(server_ip_q),
        .serverPort(server_port_q),
        .m_axis_open_connection_TVALID(m_axis_open_connection_TVALID),
        .m_axis_open_connection_TREADY(m_axis_open_connection_TREADY),
        .m_axis_open_connection_TDATA (m_axis_open_connection_TDATA),
        .s_axis_open_status_TVALID(s_axis_open_status_TVALID),
        .s_axis_open_status_TREADY(s_axis_open_status_TREADY),
        .s_axis_open_status_TDATA (s_axis_open_status_TDATA),
        .done(init_done), .error(init_error),
        .session_id(init_session_id), .state_debug(init_state_debug)
    );

    logic bind_en_w;
    logic [CONN_BITS-1:0] bind_conn_w;
    logic [15:0]          bind_sid_w;

    logic release_en_w;
    logic [CONN_BITS-1:0] release_conn_w;

    // Reconnect decision wires. The logic is below, after the per-lane signals it reads are
    // declared; only the declarations can live up here, where the bring-up FSM needs them.
    logic [NUM_CONNS-1:0] lane_idle_w, lane_want_reconn_w, lane_must_die_w, lane_want_close_w;
    logic                 reconn_pending_w, close_pending_w;
    logic [CONN_BITS-1:0] reconn_lane_w, close_lane_w;
    // A close with no open behind it. Same teardown as a reconnect, stopping one state early.
    logic                 close_only_q, close_only_d;

    // =============================================================================================
    // Receive: toe_rx, N framing lanes.
    // =============================================================================================
    localparam int FREE_BITS = $clog2(RX_FIFO_DEPTH + 1);

    logic [NUM_CONNS-1:0]       conn_tvalid, conn_tready, conn_closed;
    logic [AXI_DATA_BITS-1:0]   conn_tdata;
    logic [AXI_DATA_BITS/8-1:0] conn_tkeep;
    logic                       conn_tlast;
    // The reservation: toe_rx charges a lane's fifo one cycle after each grant.
    logic [NUM_CONNS-1:0]       conn_pkg_issued;
    logic [FREE_BITS-1:0]       conn_pkg_beats;
    logic [FREE_BITS-1:0]       conn_free [NUM_CONNS];
    // toe_rx's per-lane view: FIN seen (raw), notified bytes not yet asked for, a readPkg out.
    logic [NUM_CONNS-1:0]       rxt_closed, rxt_unread, rxt_rd_busy;
    logic                       rxt_order_err, rxt_len_err, rxt_budget_err, rxt_route_stall;
    logic                       rxt_overflow;
    // lane_fatal_q is declared with the lanes; toe_rx reads only live, non-fatal lanes.
    logic [NUM_CONNS-1:0]       lane_fatal_q;

    toe_rx #(
        .NUM_CONNS(NUM_CONNS),
        .RD_MAX   (RD_MAX),
        .RD_OUT   (RD_OUT),
        .FREE_BITS(FREE_BITS),
        .RING_LOG2(RING_LOG2)
    ) inst_toe_rx (
        .clk(ap_clk), .rst_n(ap_rst_n),
        .s_axis_notifications_TVALID(s_axis_notifications_TVALID),
        .s_axis_notifications_TREADY(s_axis_notifications_TREADY),
        .s_axis_notifications_TDATA (s_axis_notifications_TDATA),
        .bind_en(bind_en_w), .bind_conn(bind_conn_w), .bind_sid(bind_sid_w),
        .release_en(release_en_w), .release_conn(release_conn_w),
        .lane_up  (conn_up_q & ~lane_fatal_q),
        .lane_free(conn_free),
        .m_axis_read_package_TVALID(m_axis_read_package_TVALID),
        .m_axis_read_package_TREADY(m_axis_read_package_TREADY),
        .m_axis_read_package_TDATA (m_axis_read_package_TDATA),
        .s_axis_rx_metadata_TVALID(s_axis_rx_metadata_TVALID),
        .s_axis_rx_metadata_TREADY(s_axis_rx_metadata_TREADY),
        .s_axis_rx_metadata_TDATA (s_axis_rx_metadata_TDATA),
        .s_axis_rx_data_TVALID(s_axis_rx_data_TVALID),
        .s_axis_rx_data_TREADY(s_axis_rx_data_TREADY),
        .s_axis_rx_data_TDATA (s_axis_rx_data_TDATA),
        .s_axis_rx_data_TKEEP (s_axis_rx_data_TKEEP),
        .s_axis_rx_data_TLAST (s_axis_rx_data_TLAST),
        .lane_pkg_issued(conn_pkg_issued), .lane_pkg_beats(conn_pkg_beats),
        .conn_tvalid(conn_tvalid), .conn_tready(conn_tready),
        .conn_tdata (conn_tdata),  .conn_tkeep (conn_tkeep), .conn_tlast(conn_tlast),
        .lane_closed (rxt_closed),
        .lane_unread (rxt_unread),
        .lane_rd_busy(rxt_rd_busy),
        .order_err  (rxt_order_err),
        .len_err    (rxt_len_err),
        .budget_err (rxt_budget_err),
        .route_stall(rxt_route_stall),
        .dbg_oq_occ ()
    );

    // The one "something is broken underneath" bit the readback has room for (totalWord[23],
    // stallWord[24], where revision 2 had rxd_overflow): the TOE broke its contract (order_err,
    // len_err) or a lane's ring passed the window budget (budget_err).
    assign rxt_overflow = rxt_order_err | rxt_len_err | rxt_budget_err;

    // THE FIN, SETTLED. toe_rx's closed bit is raw: a FIN notification overtakes the data
    // notifications still waiting for their write status, so the last bytes of a response can be
    // announced AFTER it. A lane's peer counts as closed -- for tcp_read's ST_DRAIN and for the idle
    // reconnect -- only once nothing is unread, no readPkg is out, and that has held with the FIN
    // seen for CLOSE_SETTLE cycles. Any announcement or read restarts it. tcp_read's DRAIN_SETTLE
    // (the parser going quiet) then runs behind this as before.
    localparam int CS_BITS = $clog2(CLOSE_SETTLE + 1);
    logic [CS_BITS-1:0]   close_cnt_q [NUM_CONNS];
    logic [NUM_CONNS-1:0] close_quiet_w;

    always_comb begin
        for (int L = 0; L < NUM_CONNS; L++) begin
            close_quiet_w[L] = rxt_closed[L] && !rxt_unread[L] && !rxt_rd_busy[L];
            conn_closed[L]   = close_quiet_w[L] && (close_cnt_q[L] == '0);
        end
    end

    always_ff @(posedge ap_clk) begin
        for (int L = 0; L < NUM_CONNS; L++) begin
            if (!ap_rst_n || !close_quiet_w[L]) close_cnt_q[L] <= CS_BITS'(CLOSE_SETTLE);
            else if (close_cnt_q[L] != '0)      close_cnt_q[L] <= close_cnt_q[L] - 1'b1;
        end
    end

    // =============================================================================================
    // Transmit arbitration: N request streams, one TOE transmit path.
    // =============================================================================================
    logic [CONN_BITS-1:0] tx_sel;
    logic                 tx_busy;

    tx_arbiter #(.N(NUM_CONNS)) inst_tx_arbiter (
        .clk(ap_clk), .rst_n(ap_rst_n),
        .req(stream_bus_req), .grant(stream_bus_grant),
        .sel(tx_sel), .busy(tx_busy)
    );

    logic [NUM_CONNS-1:0]       lane_meta_valid, lane_data_valid, lane_data_last, lane_stat_ready;
    logic [TCP_TX_META_BITS-1:0] lane_meta_data [NUM_CONNS];
    logic [AXI_DATA_BITS-1:0]    lane_data_data [NUM_CONNS];
    logic [AXI_DATA_BITS/8-1:0]  lane_data_keep [NUM_CONNS];

    // Only the holder reaches the wire; everyone else sees TREADY low and stalls harmlessly.
    assign m_axis_tx_meta_TVALID = tx_busy && lane_meta_valid[tx_sel];
    assign m_axis_tx_meta_TDATA  = lane_meta_data[tx_sel];
    assign m_axis_tx_data_TVALID = tx_busy && lane_data_valid[tx_sel];
    assign m_axis_tx_data_TDATA  = lane_data_data[tx_sel];
    assign m_axis_tx_data_TKEEP  = lane_data_keep[tx_sel];
    assign m_axis_tx_data_TLAST  = lane_data_last[tx_sel];
    assign s_axis_tx_status_TREADY = tx_busy && lane_stat_ready[tx_sel];

    // =============================================================================================
    // The lanes
    // =============================================================================================
    logic [NUM_CONNS-1:0]     lane_error, lane_error_dirty;   // lane_fatal_q: with toe_rx above
    logic [NUM_CONNS-1:0]     lane_done, lane_status_ok, lane_resp_error;
    logic [NUM_CONNS-1:0]     lane_fifo_stall, lane_timeout;
    logic [3:0]               lane_read_state [NUM_CONNS];
    logic [3:0]               lane_tx_state   [NUM_CONNS];
    logic [23:0]              lane_status_ascii [NUM_CONNS];
    logic [31:0]              lane_content_len [NUM_CONNS];
    logic [31:0]              lane_body_remain [NUM_CONNS];
    logic [NUM_CONNS-1:0]     lane_armed_q;
    logic [31:0]              lane_occ_q [NUM_CONNS];
    // Responses of this lane's GETs not yet finished (revision 6: one GET per arm). +1 per arm,
    // -1 per finished read activation (done or abort), 0 at the session's release.
    logic [7:0]               gets_out_q [NUM_CONNS];
    // A chunk's last beat left for the decoder, one cycle late (741295a): the decoder's tready is a
    // long cone inside parcore and stays out of lane_occ_q's 32-bit counter. The count reads one
    // entry high for one cycle -- an entry for a full queue is admitted a cycle later, and a lane
    // becomes reconnectable a cycle later. Nothing else reads it.
    logic [NUM_CONNS-1:0]     body_pop_q;

    // THE READ STAGE. One bit per lane, and the only thing that drives tcp_read's `start`.
    //
    // tcp_read serves exactly ONE response per activation: it ends in ST_DONE (or ST_ABORT) and
    // leaves only when `start` FALLS. That falling edge is not cosmetic -- the single cycle the
    // reader then spends in ST_ARM is what asserts resp_ack, which is what retires strip_http's
    // resp_done and unblocks the parser at the next header block. So `start` is an EDGE protocol,
    // not a level.
    //
    // It used to be driven with the level `conn_up && rwl_busy && !fatal`. rwl_busy is high while
    // ANY chunk entry is queued in axis_rewrite_last, so with two or more requests outstanding on a
    // lane -- which is the whole point of pipelining, and what the board actually runs -- it never
    // fell. The reader framed the first response, parked in ST_DONE, and the lane went silent while
    // the wire kept delivering. The old handler had this stage (a 2-state FSM around the same
    // condition) and it was lost in the port to N lanes; lane_drain p1/p4/p5/a2/a10 are what found
    // it missing.
    //
    // Set on the same condition as before, cleared when the reader reports this activation
    // finished. lane_done covers ST_DONE and ST_ABORT, so an aborted activation releases the stage
    // too rather than leaving it latched on a reader that has already given up. The clear wins over
    // the set, so a lane with more work re-arms one cycle later -- exactly one cycle of `start` low,
    // which is all the reader needs.
    //
    // The set condition still requires rwl_busy, so this cannot re-arm into a pending reconnect:
    // lane_want_reconn_w demands lane_idle_w, which demands !rwl_busy.
    logic [NUM_CONNS-1:0]     read_run_q;

    for (genvar L = 0; L < NUM_CONNS; L++) begin : gen_lane
        logic                       raw_tvalid, raw_tready;
        logic [AXI_DATA_BITS-1:0]   raw_tdata;
        logic [AXI_DATA_BITS/8-1:0] raw_tkeep;

        // -- request text out ---------------------------------------------------------------------
        http_req_stream #(.CHUNK_BYTES(TX_CHUNK_BYTES)) inst_req_stream (
            .clk(ap_clk), .rst_n(ap_rst_n),
            .conn_up   (conn_up_q[L] && !lane_fatal_q[L]),
            .session_id(conn_sid_q[L]),
            .req_total_bytes(req_data.req_total_bytes),
            .req_start      (cfg_fire && cfg_is_arm_w && (cfg_lane == CONN_BITS'(L))),

            .s_axis_req_TVALID(s_axis_req_TVALID[L]),
            .s_axis_req_TREADY(s_axis_req_TREADY[L]),
            .s_axis_req_TDATA (s_axis_req_TDATA[L]),
            .s_axis_req_TKEEP (s_axis_req_TKEEP[L]),
            .s_axis_req_TLAST (s_axis_req_TLAST[L]),

            .m_axis_tx_meta_TVALID(lane_meta_valid[L]),
            .m_axis_tx_meta_TREADY(m_axis_tx_meta_TREADY && tx_busy && (tx_sel == CONN_BITS'(L))),
            .m_axis_tx_meta_TDATA (lane_meta_data[L]),
            .m_axis_tx_data_TVALID(lane_data_valid[L]),
            .m_axis_tx_data_TREADY(m_axis_tx_data_TREADY && tx_busy && (tx_sel == CONN_BITS'(L))),
            .m_axis_tx_data_TDATA (lane_data_data[L]),
            .m_axis_tx_data_TKEEP (lane_data_keep[L]),
            .m_axis_tx_data_TLAST (lane_data_last[L]),
            .s_axis_tx_status_TVALID(s_axis_tx_status_TVALID && tx_busy && (tx_sel == CONN_BITS'(L))),
            .s_axis_tx_status_TREADY(lane_stat_ready[L]),
            .s_axis_tx_status_TDATA (s_axis_tx_status_TDATA),

            .bus_req(stream_bus_req[L]), .bus_grant(stream_bus_grant[L]),
            .busy(stream_busy[L]), .refused_sticky(stream_refused[L]),
            .tx_space(), .state_debug(lane_tx_state[L])
        );

        // -- receive and framing ------------------------------------------------------------------
        tcp_read #(
            .RX_FIFO_DEPTH    (RX_FIFO_DEPTH),
            .RSV_EXACT        (1)
        ) inst_tcp_read (
            .clk(ap_clk), .rst_n(ap_rst_n),
            // One activation per response. See read_run_q: the reader needs `start` to FALL between
            // responses, and "up and still owing bytes" is a level that does not.
            .start        (read_run_q[L]),
            .body_last    (1'b0),   // tlast comes from axis_rewrite_last, by byte count
            .clear_framing(!conn_up_q[L]),

            .rx_closed(conn_closed[L]),

            .s_axis_rx_data_TVALID(conn_tvalid[L]),
            .s_axis_rx_data_TREADY(conn_tready[L]),
            .s_axis_rx_data_TDATA (conn_tdata),
            .s_axis_rx_data_TKEEP (conn_tkeep),
            .s_axis_rx_data_TLAST (conn_tlast),

            .m_axis_body_tvalid(raw_tvalid),
            .m_axis_body_tready(raw_tready),
            .m_axis_body_tdata (raw_tdata),
            .m_axis_body_tkeep (raw_tkeep),
            .m_axis_body_tlast (),

            .done(lane_done[L]), .error(lane_error[L]), .error_dirty(lane_error_dirty[L]),
            .resp_error(lane_resp_error[L]),
            .status_ascii(lane_status_ascii[L]), .status_ok(lane_status_ok[L]),
            .content_length(lane_content_len[L]), .body_remaining(lane_body_remain[L]),
            .read_timeout(lane_timeout[L]),
            .rx_fifo_level(), .rx_fifo_stall(lane_fifo_stall[L]),
            .rx_space_ok  (),
            .rx_pkg_issued(conn_pkg_issued[L]),
            .rx_pkg_beats (conn_pkg_beats),
            .rx_free_beats(conn_free[L]),
            .debug_rx_write_ptr(), .debug_rx_buffer_w0(), .debug_rx_buffer_w1(),
            .state_debug(lane_read_state[L])
        );

        // -- register slice between the framer and the chunk counter (61ad533) --------------------
        //
        // strip_http's output skid went straight into axis_rewrite_last's popcount of tkeep and its
        // 32-bit remaining compare, and the counter's ready straight back into the skid's clock
        // enables (build-133: -2.02 ns when the framer and the counter sat in different SLRs). Both
        // ends of this slice are flops. It is downstream of the framer and clear_framing does not
        // empty it: a beat in here belongs to a response that is complete in the framer, exactly as
        // a beat in the body slice below does. One cycle of body latency; order and rate unchanged.
        logic                       rl_tvalid, rl_tready;
        logic [AXI_DATA_BITS-1:0]   rl_tdata;
        logic [AXI_DATA_BITS/8-1:0] rl_tkeep;

        if (FRAMER_SLICE) begin : gen_framer_slice
            axis_skid #(.DATA_BITS(AXI_DATA_BITS)) inst_framer_slice (
                .clk(ap_clk), .rst_n(ap_rst_n),
                .s_tvalid(raw_tvalid), .s_tready(raw_tready),
                .s_tdata (raw_tdata),  .s_tkeep (raw_tkeep), .s_tlast(1'b0),
                .m_tvalid(rl_tvalid),  .m_tready(rl_tready),
                .m_tdata (rl_tdata),   .m_tkeep (rl_tkeep),  .m_tlast()
            );
        end else begin : gen_framer_direct
            assign rl_tvalid  = raw_tvalid;
            assign raw_tready = rl_tready;
            assign rl_tdata   = raw_tdata;
            assign rl_tkeep   = raw_tkeep;
        end

        // -- chunk boundaries by byte count -------------------------------------------------------
        //
        // NUM_DEST is 1 per lane: the lane IS the destination. CFG_REG (61ad533): the entry
        // admission reaches the length queue through a register instead of straight into its write
        // enable, and cfg_ready / busy count the length still in that register; the body data
        // reaches the counter one cycle later too (the slice above), so the two keep their timing.
        logic                       rwl_tvalid, rwl_tready, rwl_tlast;
        logic [AXI_DATA_BITS-1:0]   rwl_tdata;
        logic [AXI_DATA_BITS/8-1:0] rwl_tkeep;

        axis_rewrite_last #(
            .CFG_DEPTH(QUEUE_DEPTH), .NUM_DEST(1), .DEST_BITS(1), .CFG_REG(1'b1)
        ) inst_rewrite_last (
            .clk(ap_clk), .rst_n(ap_rst_n),
            .cfg_valid(cfg_fire && cfg_is_entry_w && (cfg_lane == CONN_BITS'(L))),
            .cfg_ready(rwl_cfg_ready[L]),
            .cfg_len  (req_data.req_chunk_bytes),
            .cfg_dest (1'b0),
            .s_tvalid(rl_tvalid), .s_tready(rl_tready),
            .s_tdata (rl_tdata),  .s_tkeep (rl_tkeep),
            .m_tvalid(rwl_tvalid), .m_tready(rwl_tready),
            .m_tdata (rwl_tdata),  .m_tkeep (rwl_tkeep),
            .m_tlast (rwl_tlast),
            .m_tdest (),
            .busy(rwl_busy[L]), .starved(rwl_starved[L]), .remaining_dbg()
        );

        // -- register slice on the body output ----------------------------------------------------
        //
        // strip_http's skid register -> axis_rewrite_last -> out used to be ONE combinational cone:
        // rewrite_last derives tlast from $countones(tkeep) against a 32-bit remaining count
        // (axis_rewrite_last.sv:98-115), straight off strip_http's skid_keep_q. build-117 (3 lanes,
        // WNS -0.849 ns) has two clusters of violations starting at skid_keep_q_reg and running
        // through exactly that popcount + compare (10 logic levels, CARRY8 x2):
        //   * 45 paths into THIS module's lane_occ_q_reg/CE, worst -0.766 ns -- the chunk-retire
        //     pop below reads m_axis_body_tlast;
        //   * 24 paths out through vfpga_top, AXIToNData and into the DataNormalizer's
        //     offset_reg/R (its "tlast resets the offset"), worst -0.727 ns.
        // And the decoder's tready came back the same way into strip_http's skid clock enables.
        //
        // WHY HERE AND NOT IN vfpga_top. A slice between hm_body and AXIToNData would cut the 24
        // and leave the 45: lane_occ_q's pop is inside this module and would still see the
        // unregistered tlast. Here the cone ends at the slice's input register, and everything
        // that reads the body output -- lane_occ_q below, the port, the normalizer beyond it --
        // starts from the slice's registers instead. lane_occ_q still counts at the PORT
        // handshake, so a chunk is retired when the decoder side takes its tlast, as before.
        //
        // What the slice may hold -- at most two beats -- is past the framer, so clear_framing does
        // not flush it, exactly like a beat the decoder has already taken. It never holds anything
        // when a lane is reconnectable: lane_idle_w needs lane_occ_q == 0, i.e. the last tlast has
        // left through the port, and nothing of a later chunk can be behind it while rwl_busy is 0.
        axis_skid #(.DATA_BITS(AXI_DATA_BITS)) inst_body_slice (
            .clk(ap_clk), .rst_n(ap_rst_n),
            .s_tvalid(rwl_tvalid), .s_tready(rwl_tready),
            .s_tdata (rwl_tdata),  .s_tkeep (rwl_tkeep), .s_tlast(rwl_tlast),
            .m_tvalid(m_axis_body_tvalid[L]), .m_tready(m_axis_body_tready[L]),
            .m_tdata (m_axis_body_tdata[L]),  .m_tkeep (m_axis_body_tkeep[L]),
            .m_tlast (m_axis_body_tlast[L])
        );

        assign lane_occ_ok[L] = (lane_occ_q[L] < 32'(QUEUE_DEPTH));

        // The two admission conditions, per lane. See the declaration above for why they are named.
        // The ARM additionally waits for the lane's GET credit (revision 6: one GET per arm, at most
        // GET_CREDIT unfinished -- the hardware half of the window rule). Still monotone in the
        // host's favour: gets_out only rises on an arm this module accepted.
        assign lane_arm_ready_w[L]   = !stream_busy[L] && (gets_out_q[L] < 8'(GET_CREDIT));
        assign lane_entry_ready_w[L] = rwl_cfg_ready[L] && lane_occ_ok[L];
    end

    // A lane may be reconnected only when there is NOTHING TO REPLAY.
    //
    // The old handler learned this the expensive way: streamed request text is consumed as it is
    // sent and the hardware cannot reproduce it, so reopening a session with requests outstanding
    // gives a connection nobody will ever ask anything on. The read errors again, reconnects again,
    // and each iteration burns one of the TOE's 512 ephemeral ports -- observed as SYN/FIN on
    // 32769, 32770, 32771 ... with no data on any of them.
    //
    // So "nothing owed" is the whole precondition: the alignment counter is idle (no chunk is
    // part-way through), the transmit side is idle, and the failure was clean rather than dirty.
    // Anything else is fatal and the HOST retries, because only the host still holds the text.
    for (genvar L = 0; L < NUM_CONNS; L++) begin : gen_reconn_want
        assign lane_idle_w[L] = !rwl_busy[L] && !stream_busy[L] && (lane_occ_q[L] == '0);

        // Two ways a healthy lane wants a new connection:
        //   - its read failed cleanly with nothing owed
        //   - the peer FINed while the lane was idle. MinIO closes an idle connection after ~30 s
        //     and a lane can easily sit idle that long while other lanes work, so this is the
        //     normal case rather than a fault. Catching it here turns it into a reconnect nobody
        //     notices; catching it later, mid-batch, would be fatal.
        assign lane_want_reconn_w[L] = conn_up_q[L] && !lane_fatal_q[L] && lane_idle_w[L] &&
                                       ((lane_error[L] && !lane_error_dirty[L]) || conn_closed[L]);

        assign lane_must_die_w[L] = lane_error[L] && (lane_error_dirty[L] || !lane_idle_w[L]);

        // A fatal lane that still holds a session. There is no precondition to wait for: a lane
        // goes fatal on a failure it cannot replay (there is no head-of-line watchdog here any more),
        // and the host reissues either way. What teardown can lose is a beat strip_http was holding
        // out to a sink that never took it; everything the sink DID take is already past the framer
        // and untouched by clear_framing.
        assign lane_want_close_w[L] = conn_up_q[L] && lane_fatal_q[L];
    end

    // First lane asking, lowest index. Reconnects are rare and one at a time is plenty -- the
    // connect resource is a single sequenced tcp_init either way.
    always_comb begin
        reconn_pending_w = 1'b0;
        reconn_lane_w    = '0;
        close_pending_w  = 1'b0;
        close_lane_w     = '0;
        for (int i = NUM_CONNS - 1; i >= 0; i--) begin
            if (lane_want_reconn_w[i]) begin
                reconn_pending_w = 1'b1;
                reconn_lane_w    = CONN_BITS'(i);
            end
            if (lane_want_close_w[i]) begin
                close_pending_w = 1'b1;
                close_lane_w    = CONN_BITS'(i);
            end
        end
    end

    always_comb begin
        br_d         = br_q;
        bring_lane_d = bring_lane_q;
        close_only_d = close_only_q;
        bind_en_w    = 1'b0;
        bind_conn_w  = bring_lane_q;
        bind_sid_w   = init_session_id;
        release_en_w = 1'b0;
        release_conn_w = bring_lane_q;

        m_axis_close_connection_TVALID = 1'b0;
        m_axis_close_connection_TDATA  = conn_sid_q[bring_lane_q][TCP_CLOSE_CONN_REQ_BITS-1:0];

        case (br_q)
            BR_IDLE: begin
                // The first arm is what says a server address exists. Open every lane then, not
                // lazily per lane: a lane whose connection is opened only when it is first used
                // pays a handshake in the middle of a query instead of before it.
                if (any_armed_q && (retry_wait_q == '0)) begin
                    bring_lane_d = '0;
                    br_d         = BR_OPEN;
                end
            end
            BR_OPEN: begin
                if (init_done) begin
                    if (init_error) begin
                        // Back off and retry this same lane. A failed open leaves nothing bound,
                        // so there is no state to unwind -- but DO come back to where we were:
                        // during bring-up that is the start, after a reconnect it is BR_DONE.
                        br_d = bringing_up_q ? BR_IDLE : BR_DONE;
                    end else begin
                        bind_en_w = 1'b1;
                        br_d      = bringing_up_q ? BR_NEXT : BR_DONE;
                    end
                end
            end
            BR_NEXT: begin
                if (int'(bring_lane_q) == NUM_CONNS - 1) br_d = BR_DONE;
                else begin
                    bring_lane_d = bring_lane_q + 1'b1;
                    br_d         = BR_OPEN;
                end
            end

            // All lanes up. The connect resource is free, so this is where a lane that wants a new
            // connection gets one -- one at a time, because there is only one tcp_init.
            //
            // A fatal lane's teardown goes FIRST. It needs no tcp_init and it is what unblocks the
            // shared receive path, so making it wait behind a reconnect -- which does need the
            // tcp_init, and can be held off by retry_wait_q for 65535 cycles after a failed open --
            // would leave every other lane starving for the whole of that backoff.
            BR_DONE: begin
                if (close_pending_w) begin
                    bring_lane_d = close_lane_w;
                    close_only_d = 1'b1;
                    br_d         = BR_CLOSE;
                end else if (reconn_pending_w && (retry_wait_q == '0)) begin
                    bring_lane_d = reconn_lane_w;
                    close_only_d = 1'b0;
                    br_d         = BR_CLOSE;
                end
            end

            // Drop the session. The release reaches toe_rx in the same breath: an unbound session
            // id stops matching, so a late notification for the dead connection is dropped (its
            // bytes stay in that session's ring, which dies with it) and no further readPkg is
            // issued for it.
            BR_CLOSE: begin
                m_axis_close_connection_TVALID = 1'b1;
                if (m_axis_close_connection_TREADY) begin
                    release_en_w   = 1'b1;
                    release_conn_w = bring_lane_q;
                    br_d           = BR_DRAIN;
                end
            end

            // A readPkg granted up to the release cycle still goes out and its bytes still come
            // back; they are routed to this lane, which discards them while it is down
            // (clear_framing). Only once none is outstanding may the lane be bound again -- else the
            // old session's tail would be spliced onto the front of the new one, even when the TOE
            // hands out the same session id. Then either open a fresh session (a reconnect) or stop
            // here (a fatal lane: it stays down, which holds clear_framing high, which makes it
            // discard instead of block). rxt_rd_busy is registered and already counts a grant made
            // in the release cycle; no grant can follow it (toe_rx reads bound lanes only).
            BR_DRAIN: begin
                if (!rxt_rd_busy[bring_lane_q]) br_d = close_only_q ? BR_DONE : BR_OPEN;
            end

            default: br_d = BR_IDLE;
        endcase
    end

    // The invariant BR_DRAIN exists for, checked in simulation: a lane is never bound while a
    // readPkg of its previous session is outstanding.
    // synthesis translate_off
    always @(posedge ap_clk) begin
        if (ap_rst_n && bind_en_w && rxt_rd_busy[bind_conn_w])
            $error("handler_toe: lane %0d bound to session %0d with a readPkg of its old session outstanding",
                   bind_conn_w, bind_sid_w);
    end
    // synthesis translate_on

    // =============================================================================================
    // State
    // =============================================================================================
    logic [NUM_CONNS-1:0] lane_init_err_q, lane_resp_err_q, lane_status_bad_q;
    // WHY THESE FOUR ARE LATCHED HERE RATHER THAN READ WHERE THEY ARE PRODUCED.
    //
    // (handler_multi latches a fourth, lane_dead_q, the head-of-line watchdog's verdict; there is
    // no watchdog here and LANE_ERR bit 0 reads 0.) These three are transients: error_dirty is only
    // asserted while tcp_read sits in ST_ABORT, read_timeout is reset with the framer on a
    // reconnect, and rx_fifo_stall is a level from the decoupling fifo. The OR-folded copies in
    // stallWord say some lane saw them; these say which, and still say it afterwards.
    logic [NUM_CONNS-1:0] lane_dirty_q, lane_timeout_q, lane_fifo_stall_q;
    logic                 conn_stall_q;
    localparam int STALL_BITS = $clog2(STALL_CYCLES) + 1;
    logic [STALL_BITS-1:0] conn_cnt_q;

    always_ff @(posedge ap_clk) begin
        if (!ap_rst_n) begin
            br_q          <= BR_IDLE;
            bring_lane_q  <= '0;
            close_only_q  <= 1'b0;
            bringing_up_q <= 1'b1;
            conn_up_q     <= '0;
            reconn_cnt_q  <= '0;
            any_armed_q   <= 1'b0;
            server_ip_q   <= '0;
            server_port_q <= '0;
            retry_wait_q  <= '0;
            lane_fatal_q  <= '0;
            lane_armed_q  <= '0;
            read_run_q    <= '0;
            lane_init_err_q   <= '0;
            lane_resp_err_q   <= '0;
            lane_status_bad_q <= '0;
            lane_dirty_q      <= '0;
            body_pop_q        <= '0;
            lane_timeout_q    <= '0;
            lane_fifo_stall_q <= '0;
            conn_stall_q  <= 1'b0;
            conn_cnt_q    <= '0;
            for (int L = 0; L < NUM_CONNS; L++) begin
                conn_sid_q[L] <= 16'd0;
                lane_occ_q[L] <= '0;
                gets_out_q[L] <= '0;
            end
        end else begin
            br_q         <= br_d;
            bring_lane_q <= bring_lane_d;
            close_only_q <= close_only_d;
            // The initial walk ends the first time every lane is up.
            if (br_q == BR_NEXT && int'(bring_lane_q) == NUM_CONNS - 1) bringing_up_q <= 1'b0;

            if (cfg_fire && cfg_is_arm_w) begin
                server_ip_q   <= req_data.server_ip;
                server_port_q <= req_data.server_port;
                any_armed_q   <= 1'b1;
                lane_armed_q[cfg_lane] <= 1'b1;
            end

            if (release_en_w) begin
                conn_up_q[release_conn_w] <= 1'b0;
                // Only a release that a new session follows is a reconnect. Counting a fatal
                // lane's teardown here would report a recovery that never happened.
                if (!close_only_q && (reconn_cnt_q != 8'hFF)) reconn_cnt_q <= reconn_cnt_q + 8'd1;
            end
            // Bind after release in source order so a same-cycle pair cannot leave the lane down;
            // they never coincide (BR_CLOSE and BR_OPEN are different states), but the ordering
            // makes that independent of the FSM rather than a fact you have to go and check.
            if (bind_en_w) begin
                conn_sid_q[bind_conn_w] <= bind_sid_w;
                conn_up_q[bind_conn_w]  <= 1'b1;
            end

            if (retry_wait_q != '0) retry_wait_q <= retry_wait_q - 1'b1;
            if ((br_q == BR_OPEN) && init_done && init_error) begin
                retry_wait_q               <= '1;
                lane_init_err_q[bring_lane_q] <= 1'b1;
            end

            // Per-lane chunk accounting, for the readback and the entry admission test. The pop is
            // the registered one (body_pop_q, see its declaration).
            for (int L = 0; L < NUM_CONNS; L++) begin
                automatic logic push = cfg_fire && cfg_is_entry_w && (cfg_lane == CONN_BITS'(L));
                automatic logic pop  = body_pop_q[L];
                automatic logic arm  = cfg_fire && cfg_is_arm_w && (cfg_lane == CONN_BITS'(L));
                automatic logic fin  = read_run_q[L] && lane_done[L];   // one pulse per activation
                body_pop_q[L] <= m_axis_body_tvalid[L] && m_axis_body_tready[L] && m_axis_body_tlast[L];

                // The GET credit. A release forgets the lane's GETs: their responses died with the
                // session (a reconnect happens only with nothing owed; a fatal lane stays down).
                if (release_en_w && (release_conn_w == CONN_BITS'(L))) gets_out_q[L] <= '0;
                else case ({arm, fin})
                    2'b10:   gets_out_q[L] <= gets_out_q[L] + 8'd1;
                    2'b01:   gets_out_q[L] <= (gets_out_q[L] == '0) ? '0 : gets_out_q[L] - 8'd1;
                    default: ;
                endcase

                case ({push, pop})
                    2'b10: lane_occ_q[L] <= lane_occ_q[L] + 1'b1;
                    2'b01: lane_occ_q[L] <= (lane_occ_q[L] == '0) ? '0 : lane_occ_q[L] - 1'b1;
                    default: ;
                endcase

                // A lane that fails stops. It cannot recover on its own: streamed request text is
                // consumed as it is sent and the hardware cannot reproduce it, so reconnecting
                // would reopen a session with nothing to ask for -- which is the SYN/FIN-per-port
                // loop that burned the TOE's ephemeral pool in the single-lane design. The host
                // still holds the text and reissues.
                // Fatal ONLY when a reconnect could not fix it -- dirty (body bytes already
                // reached the decoder, so replay would duplicate them) or with work outstanding
                // (the request text is gone and only the host can reissue it). A clean error on an
                // idle lane is a reconnect, handled by the bring-up FSM. (handler_multi's third way
                // in, the head-of-line watchdog, does not exist here: a stalled decoder's bytes wait
                // in its ring.)
                if (lane_must_die_w[L]) lane_fatal_q[L] <= 1'b1;
                if (lane_resp_error[L]) lane_resp_err_q[L] <= 1'b1;

                // Per-lane causes, latched where they are true. See the declarations.
                if (lane_error_dirty[L])lane_dirty_q[L]      <= 1'b1;
                if (lane_timeout[L])    lane_timeout_q[L]    <= 1'b1;
                if (lane_fifo_stall[L]) lane_fifo_stall_q[L] <= 1'b1;

                // The read stage. Clear beats set, so a lane that still owes bytes drops `start`
                // for exactly one cycle and the reader walks ST_DONE -> ST_IDLE -> ST_ARM, which
                // is where resp_ack retires the response just framed.
                if (read_run_q[L] && lane_done[L])
                    read_run_q[L] <= 1'b0;
                else if (conn_up_q[L] && rwl_busy[L] && !lane_fatal_q[L])
                    read_run_q[L] <= 1'b1;
                // Status is only meaningful while the framer that produced it still exists.
                // clear_framing is !conn_up_q, and it resets strip_http -- status included -- so a
                // lane sampled with its connection down reads 0, which is not 200 or 206, and a run
                // of perfect 206s raises the sticky bad-status bit.
                //
                // That window is not hypothetical, it is the COMMON case on a reconnect. A lane
                // becomes reconnectable the instant its last chunk retires (lane_idle_w), which is
                // the same instant the reader is finishing that response: the bring-up FSM closes
                // and releases the session two or three cycles later, while the reader is still
                // sitting in ST_DONE waiting for `start` to fall. lane_drain c, f and s_f all set
                // bit 7 that way, on runs where every byte of every response was correct.
                //
                // Requiring conn_up_q is sufficient as well as necessary: the framer can only have
                // been reset if clear_framing was high last cycle, i.e. if conn_up_q was low last
                // cycle, and a lane cannot be back up and still parked in ST_DONE -- the read stage
                // drops `start` one cycle after `done`, long before an open handshake completes.
                if (conn_up_q[L] && lane_done[L] && !lane_error[L] && !lane_status_ok[L])
                    lane_status_bad_q[L] <= 1'b1;
            end

            if (br_q == BR_OPEN) begin
                if (conn_cnt_q == STALL_BITS'(STALL_CYCLES)) conn_stall_q <= 1'b1;
                else                                          conn_cnt_q <= conn_cnt_q + 1'b1;
            end else conn_cnt_q <= '0;
        end
    end

    // =============================================================================================
    // Readback. Same field positions as the old handler wherever a field still means the same,
    // so an existing host reads something sensible; the per-lane bits are folded with OR because a
    // 32-bit window cannot carry N lanes' worth and "any lane is stalled" is what the host acts on.
    // =============================================================================================
    logic [7:0] occ_sat, depth_sat;
    always_comb begin
        automatic logic [31:0] occ_max = '0;
        for (int L = 0; L < NUM_CONNS; L++) if (lane_occ_q[L] > occ_max) occ_max = lane_occ_q[L];
        occ_sat = (occ_max > 32'd255) ? 8'd255 : 8'(occ_max);
    end
    assign depth_sat = (QUEUE_DEPTH > 255) ? 8'd255 : 8'(QUEUE_DEPTH);

    assign totalWord = {8'd0,
                        rxt_overflow,
                        (|rwl_busy) || tx_busy,
                        |stream_refused, |lane_fatal_q, 1'b0, (&conn_up_q),
                        6'd0,
                        lane_read_state[0], init_state_debug, 4'd0};

    // EXACTLY 32 BITS. The first draft packed 30 and relied on the lvalue width, which zero-extends
    // on the LEFT -- so every field still landed where it should but the lane count was
    // CONN_BITS'(NUM_CONNS), i.e. 4 truncated into 2 bits, reading back as 0. A concat that does
    // not add up is not a compile error, it is a host that decodes the wrong bits.
    //   [7:0] occupancy (max over lanes, saturating)  [15:8] queue depth
    //   [16] any lane has an unread announcement      [17] any peer FINed
    //   [18] every lane is connected                  [19] req_ready for the lane last addressed
    //   [23:20] LANE COUNT -- how many sessions this bitstream has, which is what the host sizes
    //           its per-lane batches from
    //   [31:24] CSR REVISION. 6 here: the revision-2 register map and fields, with ONE GET PER
    //           ARM and the GET credit (see the header); a revision-2 host must not drive it.
    //   [16] here: some lane has notified bytes it has not asked for yet (toe_rx's unread).
    //   [17] here: some lane's FIN has settled (conn_closed).
    localparam logic [7:0] CSR_REVISION = 8'(CSR_REV);

    assign inflightWord = {CSR_REVISION, 4'(NUM_CONNS), req_ready, (&conn_up_q),
                           |conn_closed, |rxt_unread,
                           depth_sat, occ_sat};

    // [28] route_stall: a lane refused a beat toe_rx had routed (the reservation is wrong).
    // [24] the "overflow" bit: order_err | len_err | budget_err (see rxt_overflow).
    assign stallWord = {3'd0, rxt_route_stall,
                        |rwl_starved, |lane_timeout, |lane_fifo_stall, rxt_overflow,
                        8'd0, reconn_cnt_q,
                        |lane_status_bad_q, |lane_fatal_q, |lane_resp_err_q,
                        |stream_refused, |lane_init_err_q,
                        1'b0, 1'b0, conn_stall_q};

    assign queueDepthWord    = 32'(QUEUE_DEPTH);
    assign respWord          = {5'd0, |lane_error_dirty, |lane_resp_error, (&lane_status_ok),
                                lane_status_ascii[0]};
    assign contentLengthWord = lane_content_len[0];
    assign bodyRemainingWord = lane_body_remain[0];
    assign state_debug       = lane_read_state[0];

    // =============================================================================================
    // PER-LANE READBACK -- CSR revision 2
    //
    // The words above answer "is anything wrong". With N lanes that is no longer a useful question:
    // one dead lane sets |lane_fatal_q and the host learns that SOMETHING failed, then has to guess
    // which lane to reissue. Everything below is indexed by lane, at a fixed stride, so software
    // reads one register and shifts.
    //
    // SLOT WIDTH IS FIXED AT 8 LANES, not NUM_CONNS. A host compiled against one bitstream reads
    // another; a stride that moved with the lane count would silently reinterpret every field the
    // moment a 2-lane bitstream was swapped for a 4-lane one. Lanes this bitstream does not have
    // read 0, and inflightWord[23:20] says how many are real.
    //
    // ATOMICITY. A lane's two admission bits sit in the SAME register (laneReadyWord), one AXI-Lite
    // read, because that is what makes poll-then-write safe: both conditions are monotone in the
    // host's favour (nothing but the host's own config beat can clear either), so a value read is
    // still true when the write lands. Splitting them across two registers would not break that --
    // monotonicity is per bit -- but it would make the host's check two round trips on a path it
    // takes once per column chunk.
    // =============================================================================================
    localparam logic [15:0] POLICY_QDEPTH    =
        (QUEUE_DEPTH > 16'hFFFF) ? 16'hFFFF : 16'(QUEUE_DEPTH);

    logic [7:0] lane_occ_byte  [8];
    logic [3:0] lane_ready_nib [8];
    logic [3:0] lane_rd_nib    [8];
    logic [3:0] lane_tx_nib    [8];
    logic [7:0] lane_err_byte  [8];

    always_comb begin
        for (int L = 0; L < 8; L++) begin
            lane_occ_byte[L]  = 8'd0;
            lane_ready_nib[L] = 4'd0;
            lane_rd_nib[L]    = 4'd0;
            lane_tx_nib[L]    = 4'd0;
            lane_err_byte[L]  = 8'd0;
        end
        for (int L = 0; L < NUM_CONNS; L++) begin
            // Chunk entries queued and not yet retired by a tlast. This is the count the host's
            // admission test is about; it saturates at 255 where QUEUE_DEPTH does not, and
            // queueDepthWord (read register 15) carries the untruncated depth.
            lane_occ_byte[L]  = (lane_occ_q[L] > 32'd255) ? 8'd255 : 8'(lane_occ_q[L]);
            lane_ready_nib[L] = {lane_fatal_q[L], conn_up_q[L],
                                 lane_entry_ready_w[L], lane_arm_ready_w[L]};
            lane_rd_nib[L]    = lane_read_state[L];
            lane_tx_nib[L]    = lane_tx_state[L];
            lane_err_byte[L]  = {lane_fifo_stall_q[L], lane_timeout_q[L], stream_refused[L],
                                 lane_status_bad_q[L], lane_resp_err_q[L], lane_init_err_q[L],
                                 lane_dirty_q[L], 1'b0};   // bit 0: no dead lanes here
        end
    end

    always_comb begin
        laneOccWord   = '0;
        laneReadyWord = '0;
        laneStateWord = '0;
        laneErrWord   = '0;
        for (int L = 0; L < 8; L++) begin
            laneOccWord  [8*L      +: 8] = lane_occ_byte[L];
            laneReadyWord[4*L      +: 4] = lane_ready_nib[L];
            // Reader state in the low half, request-stream state in the high half, same nibble
            // index. The transmit FSM is here because a lane parked in ST_IDLE with a transfer
            // still armed is exactly the shape of a wedged transmit path, and nothing else exports
            // it -- see the bus_req/conn_up interlock in http_req_stream.sv.
            laneStateWord[4*L      +: 4] = lane_rd_nib[L];
            laneStateWord[32 + 4*L +: 4] = lane_tx_nib[L];
            laneErrWord  [8*L      +: 8] = lane_err_byte[L];
        end
    end

    // Fixed at elaboration. The host cannot infer any of it and every one of them is something a
    // mismatched host gets silently wrong: too many lanes addressed, a batch larger than the queue
    // can hold, or a software watchdog shorter than the hardware's, which would report a lane dead
    // that the hardware is still waiting on.
    //   [7:0]   CSR revision -- 6, the same value as inflightWord[31:24]
    //   [15:8]  NUM_CONNS
    //   [31:16] QUEUE_DEPTH, chunk entries PER LANE, saturating at 65535
    //   [55:32] GET_CREDIT: GETs (arms) per lane whose responses may be unfinished
    //   [61:56] RING_LOG2: the TOE's receive ring per session (20 = 1 MiB), which the host's window
    //           budget is computed from
    //   [63:62] zero
    assign lanePolicyWord = {2'd0, 6'(RING_LOG2), 24'(GET_CREDIT),
                             POLICY_QDEPTH, 8'(NUM_CONNS), CSR_REVISION};

endmodule
