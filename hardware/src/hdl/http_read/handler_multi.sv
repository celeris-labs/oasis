`timescale 1ns / 1ps

import lynxTypes::*;
import http_types::*;

// =================================================================================================
// HTTP client handler, N-connection variant. One TCP session per decoder lane.
//
// WHY N CONNECTIONS
// -----------------
// One TCP session to MinIO is a throughput ceiling however deeply its GETs are pipelined, well
// below what the decoders take; several sessions together deliver many times more. So each decoder
// lane gets its own session.
//
// THE SHAPE
// ---------
//                                       +-- tcp_read[0] --> rewrite_last[0] --> decoder 0
//   notifications --> rx_dispatch ------+-- tcp_read[1] --> rewrite_last[1] --> decoder 1
//   rx data       -->   (demux)         +-- ...
//                                       +-- tcp_read[N-1] -> rewrite_last[N-1] -> decoder N-1
//
//   host text[L] --> http_req_stream[L] --+
//                                          +--> tx_arbiter --> ONE TOE transmit path
//
// Session L is statically bound to lane L at connect time. That binding is the whole routing
// mechanism -- rx_dispatch compares an arriving notification's session id against N latched ids
// (16 bits each) and selects a lane. There is no dynamic table and no per-session buffering,
// because the TOE has none to offer.
//
// WHY EACH LANE GETS ITS OWN strip_http (INSIDE tcp_read)
// -------------------------------------------------------
// Not for throughput -- for state. strip_http carries residue across beats: a partially parsed
// header, a Content-Length countdown, a barrel-shift alignment. That is why clear_framing is only
// legal on a NEW CONNECTION; between responses the residue holds the first bytes of the next
// header. A single shared framer would have to save and restore all of it at every packet boundary,
// which is N copies of the state plus a mux plus a new class of bug. It is also not worth avoiding:
// strip_http is a few thousand LUTs, against ~84k for one ColumnChunkDecoder.
//
// The cost that IS real is the decoupling fifo per lane. With rx_dispatch gating each lane on
// conn_space_ok, a lane needs room for one MSS plus decoder jitter, not for a whole response:
// RX_FIFO_DEPTH = 2048 is 36 RAMB36 per lane.
//
// HOW THE HOST DRIVES IT
// ----------------------
// Per lane, with the lane named on every beat (req_chunk_dest, in the spare upper bits of the
// chunk-length register):
//
//   1. per column chunk: cfg beat, req_total_bytes == 0, {req_chunk_bytes, req_chunk_dest}
//        -> pushes a chunk-length entry into LANE req_chunk_dest
//   2. per lane batch:   cfg beat, req_total_bytes != 0, req_chunk_dest = lane
//        -> latches the server and ARMS that lane's transfer
//   3. the request text for that lane, DMA'd into s_axis_req[lane]
//
// ConfigWriteReadyRegister does not back-pressure, so the host must write every parameter, then
// poll req_ready, then pulse START. req_ready answers about the lane named in the beat.
//
// RECONNECT
// ---------
// Per lane, and only when there is NOTHING TO REPLAY. Streamed request text is consumed as it is
// sent and the hardware cannot reproduce it, so a lane is reconnectable exactly when its alignment
// counter is idle, its transmit side is idle and its chunk queue is empty -- and the failure was
// clean rather than dirty. Then the bring-up FSM closes that session, releases it in rx_dispatch
// (so a late notification for the dead id is dropped instead of becoming a readPkg the TOE cannot
// answer) and opens a fresh one, one lane at a time because there is one tcp_init. If the TOE
// refuses that open the lane goes fatal: it has no session, and nothing but the host reopens it.
//
// The common case is not a fault at all: MinIO closes an idle connection after ~30 s, and with N
// lanes a lane can easily sit idle that long while its neighbours work. Catching the FIN while the
// lane is idle turns that into a reconnect nobody notices.
//
// Everything else is fatal for that lane -- dirty, or failing with work outstanding. The host holds
// the request text and reissues the batch; that is the only place a retry can come from.
//
// FATAL MEANS THE CONNECTION GOES DOWN
// ------------------------------------
// A fatal lane is excluded from reconnect but not from TEARDOWN. With its session kept, conn_up_q
// would stay high, so clear_framing (which is !conn_up_q) would never rise and the lane's decoupling
// fifo would never be flushed. A lane that has stopped consuming would go on refusing space for the
// rest of time, and rx_dispatch's queue is in arrival order -- so the dead lane would hold the head
// and every other lane would starve behind it.
//
// So fatal closes the session. Not to reopen it: the lane stays down and only the host can restart
// it. What the teardown buys is that a lane which is out of the game stops PRETENDING to be in it --
// clear_framing resets the framer, empties the fifo, and turns the lane into something that accepts
// and discards whatever the dispatcher still routes to it. That is what lets everyone else carry on.
//
// It is also what makes a later host-driven restart safe: the fifo is held empty and the framer
// held in reset for as long as the lane is down, so there is no residue of the dead session left to
// be spliced onto the front of a new one.
// =================================================================================================
module handler_multi #(
    // Lanes. One TCP session, one framer, one chunk-length queue and one decoder each.
    parameter int NUM_CONNS = 4,
    // Column chunks queued ahead of the data, PER LANE.
    parameter int QUEUE_DEPTH = 64,
    // Receive decoupling fifo depth per lane, in 64-byte beats. See the note above: this holds one
    // MSS plus slack, not a whole response.
    parameter int RX_FIFO_DEPTH = 2048,
    parameter int TX_CHUNK_BYTES = 4096,
    parameter int STALL_CYCLES = 268435456,
    // How long one lane may hold up the shared receive path before it is declared dead. See
    // rx_dispatch, which does the timing and the discarding; this module only decides what a dead
    // lane means, which is: fatal, and the session goes.
    parameter int LANE_STALL_CYCLES = 65536,
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

    // -- TCP receive (shared, demultiplexed by rx_dispatch) ---------------------------------------
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

    // -- PER-LANE readback -------------------------------------------------------------------------
    //
    // Everything above folds N lanes into one 32-bit window with OR, which answers "is anything
    // wrong" and nothing else. These five say WHICH LANE. They are 64 bits wide because eight lanes
    // need eight bytes, and the AXI-Lite read path is 64 bits (AXIL_DATA_BITS). See http_config.sv
    // for the register numbers and the field tables.
    output logic [63:0] laneOccWord,
    output logic [63:0] laneReadyWord,
    output logic [63:0] laneStateWord,
    output logic [63:0] laneErrWord,
    output logic [63:0] lanePolicyWord
);

    initial begin
        if (NUM_CONNS < 1 || NUM_CONNS > 8)
            $error("handler_multi: NUM_CONNS must be 1..8 (rx_dispatch uses a flat session compare)");
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
    // req_ready answers about the lane this beat names. An ARM waits for that lane's previous text
    // to have gone out; an ENTRY waits for that lane's chunk queue to have room. Conflating them
    // deadlocks -- the arm is what drains the queue, so gating it on queue room means a batch that
    // exactly fills the queue can never begin.
    //
    // They are named here rather than inlined into req_ready because the host reads them back per
    // lane (laneReadyWord). Both are MONOTONE IN THE HOST'S FAVOUR: nothing but a config beat
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
    // Receive: one dispatcher, N framing lanes.
    // =============================================================================================
    logic [NUM_CONNS-1:0]       conn_tvalid, conn_tready, conn_space_ok, conn_closed;
    // One-hot: rx_dispatch issued a readPkg for this lane. Feeds that lane's fifo reservation.
    logic [NUM_CONNS-1:0]       conn_pkg_issued;
    logic [AXI_DATA_BITS-1:0]   conn_tdata;
    logic [AXI_DATA_BITS/8-1:0] conn_tkeep;
    logic                       conn_tlast;
    logic [NUM_CONNS-1:0]       rxd_has_pending, rxd_lane_dead;
    logic                       rxd_overflow, rxd_route_stall;

    rx_dispatch #(
        .NUM_CONNS       (NUM_CONNS),
        .NOTIFY_DEPTH    (64),
        .HOL_STALL_CYCLES(LANE_STALL_CYCLES)
    ) inst_rx_dispatch (
        .clk(ap_clk), .rst_n(ap_rst_n),
        .s_axis_notifications_TVALID(s_axis_notifications_TVALID),
        .s_axis_notifications_TREADY(s_axis_notifications_TREADY),
        .s_axis_notifications_TDATA (s_axis_notifications_TDATA),
        .bind_en(bind_en_w), .bind_conn(bind_conn_w), .bind_sid(bind_sid_w),
        .release_en(release_en_w), .release_conn(release_conn_w),
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
        .conn_tvalid(conn_tvalid), .conn_tready(conn_tready),
        .conn_tdata (conn_tdata),  .conn_tkeep(conn_tkeep), .conn_tlast(conn_tlast),
        .conn_space_ok(conn_space_ok), .conn_closed(conn_closed),
        .conn_pkg_issued(conn_pkg_issued),
        .dbg_has_pending(rxd_has_pending),
        .dbg_overflow   (rxd_overflow),
        .dbg_route_stall(rxd_route_stall),
        .dbg_lane_dead  (rxd_lane_dead)
    );

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
    logic [NUM_CONNS-1:0]     lane_error, lane_error_dirty, lane_fatal_q;
    logic [NUM_CONNS-1:0]     lane_done, lane_status_ok, lane_resp_error;
    logic [NUM_CONNS-1:0]     lane_fifo_stall, lane_timeout;
    logic [3:0]               lane_read_state [NUM_CONNS];
    logic [3:0]               lane_tx_state   [NUM_CONNS];
    logic [23:0]              lane_status_ascii [NUM_CONNS];
    logic [31:0]              lane_content_len [NUM_CONNS];
    logic [31:0]              lane_body_remain [NUM_CONNS];
    logic [NUM_CONNS-1:0]     lane_armed_q;
    logic [31:0]              lane_occ_q [NUM_CONNS];

    // THE READ STAGE. One bit per lane, and the only thing that drives tcp_read's `start`.
    //
    // tcp_read serves exactly ONE response per activation: it ends in ST_DONE (or ST_ABORT) and
    // leaves only when `start` FALLS. That falling edge is not cosmetic -- the single cycle the
    // reader then spends in ST_ARM is what asserts resp_ack, which is what retires strip_http's
    // resp_done and unblocks the parser at the next header block. So `start` is an EDGE protocol,
    // not a level.
    //
    // The level `conn_up && rwl_busy && !fatal` would not do: rwl_busy is high while ANY chunk entry
    // is queued in axis_rewrite_last, so with two or more requests outstanding on a lane -- which is
    // the whole point of pipelining -- it never falls. The reader would frame the first response,
    // park in ST_DONE, and the lane would go silent while the wire kept delivering (lane_drain
    // p1/p4/p5/a2/a10).
    //
    // Set on that condition, cleared when the reader reports this activation finished. lane_done
    // covers ST_DONE and ST_ABORT, so an aborted activation releases the stage too rather than
    // leaving it latched on a reader that has already given up. The clear wins over the set, so a
    // lane with more work re-arms one cycle later -- exactly one cycle of `start` low, which is all
    // the reader needs.
    //
    // The set condition still requires rwl_busy, so this cannot re-arm into a pending reconnect:
    // lane_want_reconn_w demands lane_idle_w, which demands !rwl_busy.
    logic [NUM_CONNS-1:0]     read_run_q;

    for (genvar L = 0; L < NUM_CONNS; L++) begin : gen_lane
        logic                       raw_tvalid, raw_tready;
        logic [AXI_DATA_BITS-1:0]   raw_tdata;
        logic [AXI_DATA_BITS/8-1:0] raw_tkeep;
        logic [$clog2(AXI_DATA_BITS/8):0] raw_tbytes;

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
            .RX_FIFO_DEPTH    (RX_FIFO_DEPTH)
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
            .m_axis_body_tbytes(raw_tbytes),

            .done(lane_done[L]), .error(lane_error[L]), .error_dirty(lane_error_dirty[L]),
            .resp_error(lane_resp_error[L]),
            .status_ascii(lane_status_ascii[L]), .status_ok(lane_status_ok[L]),
            .content_length(lane_content_len[L]), .body_remaining(lane_body_remain[L]),
            .read_timeout(lane_timeout[L]),
            .rx_fifo_level(), .rx_fifo_stall(lane_fifo_stall[L]),
            .rx_space_ok  (conn_space_ok[L]),
            .rx_pkg_issued(conn_pkg_issued[L]),
            .debug_rx_write_ptr(), .debug_rx_buffer_w0(), .debug_rx_buffer_w1(),
            .state_debug(lane_read_state[L])
        );

        // -- chunk boundaries by byte count -------------------------------------------------------
        //
        // NUM_DEST is 1 per lane: each lane has its own stream and its own decoder, so there is
        // nothing to select.
        logic                       rwl_tvalid, rwl_tready, rwl_tlast;
        logic [AXI_DATA_BITS-1:0]   rwl_tdata;
        logic [AXI_DATA_BITS/8-1:0] rwl_tkeep;

        axis_rewrite_last #(
            .CFG_DEPTH(QUEUE_DEPTH), .NUM_DEST(1), .DEST_BITS(1)
        ) inst_rewrite_last (
            .clk(ap_clk), .rst_n(ap_rst_n),
            .cfg_valid(cfg_fire && cfg_is_entry_w && (cfg_lane == CONN_BITS'(L))),
            .cfg_ready(rwl_cfg_ready[L]),
            .cfg_len  (req_data.req_chunk_bytes),
            .cfg_dest (1'b0),
            .s_tvalid(raw_tvalid), .s_tready(raw_tready),
            .s_tdata (raw_tdata),  .s_tkeep (raw_tkeep),
            .s_tbytes(raw_tbytes),
            .m_tvalid(rwl_tvalid), .m_tready(rwl_tready),
            .m_tdata (rwl_tdata),  .m_tkeep (rwl_tkeep),
            .m_tlast (rwl_tlast),
            .m_tdest (),
            .busy(rwl_busy[L]), .starved(rwl_starved[L]), .remaining_dbg()
        );

        // -- register slice on the body output ----------------------------------------------------
        //
        // Without it, strip_http's skid register -> axis_rewrite_last -> out is ONE combinational
        // cone: rewrite_last derives tlast from the byte count against a 32-bit remaining count,
        // straight off strip_http's skid register. That cone runs into this module's lane_occ_q
        // (the chunk-retire pop below reads m_axis_body_tlast) and out through vfpga_top and
        // AXIToNData into the DataNormalizer's offset register (its "tlast resets the offset"), and
        // it is where timing fails; the decoder's tready comes back the same way into strip_http's
        // skid clock enables.
        //
        // WHY HERE AND NOT IN vfpga_top. A slice between hm_body and AXIToNData would cut the paths
        // into the normalizer and leave the ones into lane_occ_q, whose pop is inside this module.
        // Here the cone ends at the slice's input register, and everything that reads the body
        // output -- lane_occ_q below, the port, the normalizer beyond it -- starts from the slice's
        // registers instead. lane_occ_q still counts at the PORT handshake, so a chunk is retired
        // when the decoder side takes its tlast.
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
        assign lane_arm_ready_w[L]   = !stream_busy[L];
        assign lane_entry_ready_w[L] = rwl_cfg_ready[L] && lane_occ_ok[L];
    end

    // A lane may be reconnected only when there is NOTHING TO REPLAY.
    //
    // Streamed request text is consumed as it is sent and the hardware cannot reproduce it, so
    // reopening a session with requests outstanding gives a connection nobody will ever ask anything
    // on. The read errors again, reconnects again, and each iteration burns one of the TOE's
    // ephemeral ports: SYN/FIN on one port after another with no data on any of them.
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

        // A fatal lane that still holds a session. There is no precondition to wait for and
        // deliberately so: the reasons a lane goes fatal are a failure it cannot replay, or a
        // consumer that has taken nothing for LANE_STALL_CYCLES -- and in the second case waiting
        // for the lane to be idle, or for its body output to be quiet, would wait for the very
        // thing that is not going to happen. What teardown can lose is a beat strip_http was
        // holding out to a sink that never took it; everything the sink DID take is already past
        // the framer and untouched by clear_framing. The lane owes the host a reissue either way.
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
                // pays a handshake in the middle of a query instead of before it. The walk starts
                // at lane 0 (reset); after a refused open it resumes at the lane that was refused,
                // because the lanes before it are up.
                if (any_armed_q && (retry_wait_q == '0)) begin
                    br_d = BR_OPEN;
                end
            end
            BR_OPEN: begin
                if (init_done) begin
                    if (init_error) begin
                        // A refused open leaves nothing bound, so there is nothing to unwind.
                        // During bring-up, back off in BR_IDLE and retry this same lane. After a
                        // reconnect the lane is left without a session and goes fatal (below);
                        // the others carry on from BR_DONE.
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

            // Drop the session. The release must reach rx_dispatch in the same breath: an unbound
            // session id stops matching, so a late notification for the dead connection is dropped
            // rather than turned into a readPkg for a session the TOE has forgotten -- which would
            // desynchronise the shared fifo for every other lane.
            //
            // Then either open a fresh session (a reconnect) or stop here (a fatal lane). Stopping
            // is the whole difference: the lane stays down, which is what holds clear_framing high,
            // which is what makes it discard instead of block.
            BR_CLOSE: begin
                m_axis_close_connection_TVALID = 1'b1;
                if (m_axis_close_connection_TREADY) begin
                    release_en_w   = 1'b1;
                    release_conn_w = bring_lane_q;
                    br_d           = close_only_q ? BR_DONE : BR_OPEN;
                end
            end
        endcase
    end

    // =============================================================================================
    // State
    // =============================================================================================
    logic [NUM_CONNS-1:0] lane_init_err_q, lane_resp_err_q, lane_status_bad_q;
    // WHY THESE FOUR ARE LATCHED HERE RATHER THAN READ WHERE THEY ARE PRODUCED.
    //
    // lane_dead_q is the important one. rx_dispatch's dead_q is cleared when the session is BOUND OR
    // RELEASED -- and releasing the session is precisely what handler_multi does to a lane it has
    // declared fatal (lane_want_close_w -> BR_CLOSE). So by the time the host polls, dbg_lane_dead
    // has already gone back to 0 while lane_fatal_q stays 1, and "killed by the head-of-line
    // watchdog" is indistinguishable from "failed a read it could not replay". They call for
    // different things from the host -- the first means bytes were thrown away out of the middle of
    // a response and the whole batch must be reissued on a new lane, the second is a retry -- so the
    // cause has to be latched at the moment it is true.
    //
    // Two of the other three are transients: error_dirty is only asserted while tcp_read sits in
    // ST_ABORT, and read_timeout is reset with the framer on a reconnect. rx_fifo_stall is latched
    // with them so every cause reads from one place. The OR-folded copies in stallWord say some lane
    // saw them; these say which, and still say it afterwards.
    logic [NUM_CONNS-1:0] lane_dead_q, lane_dirty_q, lane_timeout_q, lane_fifo_stall_q;
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
            lane_dead_q       <= '0;
            lane_dirty_q      <= '0;
            lane_timeout_q    <= '0;
            lane_fifo_stall_q <= '0;
            conn_stall_q  <= 1'b0;
            conn_cnt_q    <= '0;
            for (int L = 0; L < NUM_CONNS; L++) begin
                conn_sid_q[L] <= 16'd0;
                lane_occ_q[L] <= '0;
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
                // A refused reconnect: the lane has no session, nothing reopens it, and it owes
                // the host a reissue. Fatal, so the host sees it and routes around it.
                if (!bringing_up_q) lane_fatal_q[bring_lane_q] <= 1'b1;
            end

            // Per-lane chunk accounting, for the readback and the entry admission test.
            for (int L = 0; L < NUM_CONNS; L++) begin
                automatic logic push = cfg_fire && cfg_is_entry_w && (cfg_lane == CONN_BITS'(L));
                automatic logic pop  = m_axis_body_tvalid[L] && m_axis_body_tready[L]
                                       && m_axis_body_tlast[L];
                case ({push, pop})
                    2'b10: lane_occ_q[L] <= lane_occ_q[L] + 1'b1;
                    2'b01: lane_occ_q[L] <= (lane_occ_q[L] == '0) ? '0 : lane_occ_q[L] - 1'b1;
                    default: ;
                endcase

                // A lane that fails stops. It cannot recover on its own: streamed request text is
                // consumed as it is sent and the hardware cannot reproduce it, so reconnecting
                // would reopen a session with nothing to ask for -- the SYN/FIN-per-port loop that
                // burns the TOE's ephemeral pool. The host still holds the text and reissues.
                // Fatal ONLY when a reconnect could not fix it -- dirty (body bytes already
                // reached the decoder, so replay would duplicate them) or with work outstanding
                // (the request text is gone and only the host can reissue it). A clean error on an
                // idle lane is a reconnect, handled by the bring-up FSM.
                //
                // The third way in is not a read failure at all. rx_dispatch declares a connection
                // dead once it has held the head of the announcement queue for LANE_STALL_CYCLES
                // while accepting nothing, and from then on it reads that connection's packets and
                // throws them away to keep the shared drain moving. Bytes have been lost out of the
                // middle of a response by the time we see this, so the lane is fatal in the
                // strongest sense -- there is nothing left to reconnect to, only a batch for the
                // host to reissue.
                if (lane_must_die_w[L] || rxd_lane_dead[L]) lane_fatal_q[L] <= 1'b1;
                if (lane_resp_error[L]) lane_resp_err_q[L] <= 1'b1;

                // Per-lane causes, latched where they are true. See the declarations.
                if (rxd_lane_dead[L])   lane_dead_q[L]       <= 1'b1;
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
                // sitting in ST_DONE waiting for `start` to fall (lane_drain c, f and s_f reach
                // exactly that window, with every byte of every response correct).
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
    // Readback. The per-lane bits are folded with OR because a 32-bit window cannot carry N lanes'
    // worth and "any lane is stalled" is what the host acts on; the per-lane registers below say
    // which lane.
    // =============================================================================================
    logic [7:0] occ_sat, depth_sat;
    always_comb begin
        automatic logic [31:0] occ_max = '0;
        for (int L = 0; L < NUM_CONNS; L++) if (lane_occ_q[L] > occ_max) occ_max = lane_occ_q[L];
        occ_sat = (occ_max > 32'd255) ? 8'd255 : 8'(occ_max);
    end
    assign depth_sat = (QUEUE_DEPTH > 255) ? 8'd255 : 8'(QUEUE_DEPTH);

    // totalWord (read register 2):
    //   [3:0] 0                      [7:4] tcp_init state          [11:8] lane 0's tcp_read state
    //   [17:12] 0                    [18] every lane is connected  [19] 0
    //   [20] some lane is fatal      [21] some lane's TX reservation was refused
    //   [22] busy (a chunk queued or the transmit path held)       [23] rxd_overflow (reads 0)
    //   [31:24] 0
    assign totalWord = {8'd0,
                        rxd_overflow,
                        (|rwl_busy) || tx_busy,
                        |stream_refused, |lane_fatal_q, 1'b0, (&conn_up_q),
                        6'd0,
                        lane_read_state[0], init_state_debug, 4'd0};

    // EXACTLY 32 BITS. A concat that does not add up is not a compile error: the lvalue width
    // zero-extends it on the LEFT, and the host decodes the wrong bits.
    //   [7:0] occupancy (max over lanes, saturating)  [15:8] queue depth
    //   [16] any lane has an unread announcement      [17] any peer FINed
    //   [18] every lane is connected                  [19] req_ready for the lane last addressed
    //   [23:20] LANE COUNT -- how many sessions this bitstream has, which is what the host sizes
    //           its per-lane batches from
    //   [31:24] CSR REVISION, 2. The host reads it first and refuses any other value.
    localparam logic [7:0] CSR_REVISION = 8'd2;

    assign inflightWord = {CSR_REVISION, 4'(NUM_CONNS), req_ready, (&conn_up_q),
                           |conn_closed, |rxd_has_pending,
                           depth_sat, occ_sat};

    assign stallWord = {3'd0, rxd_route_stall,
                        |rwl_starved, |lane_timeout, |lane_fifo_stall, rxd_overflow,
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
    // PER-LANE READBACK
    //
    // The words above answer "is anything wrong". With N lanes that is not a useful question:
    // one dead lane sets |lane_fatal_q and the host learns that SOMETHING failed, then has to guess
    // which lane to reissue. Everything below is indexed by lane, at a fixed stride, so software
    // reads one register and shifts.
    //
    // FIELD STRIDE IS FIXED AT 8 LANES, not NUM_CONNS. A host compiled against one bitstream reads
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
    localparam int         POLICY_STALL_LOG2 = $clog2(LANE_STALL_CYCLES);
    localparam logic [23:0] POLICY_STALL_CYC =
        (LANE_STALL_CYCLES > 24'hFF_FFFF) ? 24'hFF_FFFF : 24'(LANE_STALL_CYCLES);
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
                                 lane_dirty_q[L], lane_dead_q[L]};
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
    //   [7:0]   CSR revision -- 2, the same value as inflightWord[31:24]
    //   [15:8]  NUM_CONNS
    //   [31:16] QUEUE_DEPTH, chunk entries PER LANE, saturating at 65535
    //   [55:32] LANE_STALL_CYCLES, the head-of-line watchdog threshold, saturating at 2^24-1
    //   [61:56] $clog2(LANE_STALL_CYCLES) -- still exact when the 24-bit field saturates
    //   [63:62] zero
    assign lanePolicyWord = {2'd0, 6'(POLICY_STALL_LOG2), POLICY_STALL_CYC,
                             POLICY_QDEPTH, 8'(NUM_CONNS), CSR_REVISION};

endmodule
