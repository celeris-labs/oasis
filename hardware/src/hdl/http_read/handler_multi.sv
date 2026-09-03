`timescale 1ns / 1ps

import lynxTypes::*;
import http_types::*;

// =================================================================================================
// HTTP client handler, N-connection variant. One TCP session per decoder lane.
//
// WHAT THIS CHANGES, AND WHY IT IS A NEW MODULE RATHER THAN AN EDIT
// -----------------------------------------------------------------
// handler_stream holds ONE connection. Everything a query fetches is serialised onto it, and
// measurement says that connection is the ceiling: one TCP session to MinIO delivers ~0.46 GB/s
// however deeply pipelined, sixteen sessions deliver 4.60, and the FPGA sits at 0.33. So the gap
// worth chasing is not inside the decoder -- it is the session count.
//
// handler_stream is left untouched. It is what current bitstreams are built from and what the
// working software drives; a receive path that has produced this many deadlocks is not a good place
// for an in-place rewrite. This module is the N-lane arrangement built beside it.
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
// strip_http measures 2492 LUTs in build-108, against 84200 for one ColumnChunkDecoder.
//
// The cost that IS real is the decoupling fifo -- 144 RAMB36 per lane at RX_FIFO_DEPTH=8192. That
// depth exists because a single lane must absorb everything; with rx_dispatch gating per lane on
// conn_space_ok, a lane needs room for one MSS plus decoder jitter, not for a whole response. Size
// it accordingly and N lanes cost what one used to.
//
// HOW THE HOST DRIVES IT
// ----------------------
// As handler_stream, plus a lane on every beat (req_chunk_dest, already carried in the spare upper
// bits of the chunk-length register):
//
//   1. per column chunk: cfg beat, req_total_bytes == 0, {req_chunk_bytes, req_chunk_dest}
//        -> pushes a chunk-length entry into LANE req_chunk_dest
//   2. per lane batch:   cfg beat, req_total_bytes != 0, req_chunk_dest = lane
//        -> latches the server and ARMS that lane's transfer
//   3. the request text for that lane, DMA'd into s_axis_req[lane]
//
// Ordering within a lane is exactly the single-lane protocol, and for the same reason:
// ConfigWriteReadyRegister does not back-pressure, so the host must write every parameter, then
// poll req_ready, then pulse START. req_ready here answers about the lane named in the beat.
//
// RECONNECT
// ---------
// Per lane, and only when there is NOTHING TO REPLAY. Streamed request text is consumed as it is
// sent and the hardware cannot reproduce it, so a lane is reconnectable exactly when its alignment
// counter is idle, its transmit side is idle and its chunk queue is empty -- and the failure was
// clean rather than dirty. Then the bring-up FSM closes that session, releases it in rx_dispatch
// (so a late notification for the dead id is dropped instead of becoming a readPkg the TOE cannot
// answer) and opens a fresh one, one lane at a time because there is one tcp_init.
//
// The common case is not a fault at all: MinIO closes an idle connection after ~30 s, and with N
// lanes a lane can easily sit idle that long while its neighbours work. Catching the FIN while the
// lane is idle turns that into a reconnect nobody notices.
//
// Everything else is fatal for that lane -- dirty, or failing with work outstanding. The host holds
// the request text and reissues the batch; that is the only place a retry can come from.
// =================================================================================================
module handler_multi #(
    // Lanes. One TCP session, one framer, one chunk-length queue and one decoder each.
    parameter int NUM_CONNS = 4,
    // Column chunks queued ahead of the data, PER LANE.
    parameter int QUEUE_DEPTH = 64,
    // Receive decoupling fifo depth per lane, in 64-byte beats. See the note above: this no longer
    // has to hold a whole response, only one MSS plus slack.
    parameter int RX_FIFO_DEPTH = 2048,
    parameter int TX_CHUNK_BYTES = 4096,
    parameter int STALL_CYCLES = 268435456,
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
    output logic [3:0]  state_debug
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

    // req_ready answers about the lane this beat names, exactly as the single-lane version answers
    // about the only lane there is. An ARM waits for that lane's previous text to have gone out; an
    // ENTRY waits for that lane's chunk queue to have room. Conflating them deadlocks -- the arm is
    // what drains the queue, so gating it on queue room means a batch that exactly fills the queue
    // can never begin.
    always_comb begin
        req_ready = 1'b0;
        for (int L = 0; L < NUM_CONNS; L++) begin
            if (cfg_lane == CONN_BITS'(L)) begin
                req_ready = (req_data.req_total_bytes != 32'd0) ? !stream_busy[L]
                                                                : (rwl_cfg_ready[L] && lane_occ_ok[L]);
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
    logic [NUM_CONNS-1:0] lane_idle_w, lane_want_reconn_w, lane_must_die_w;
    logic                 reconn_pending_w;
    logic [CONN_BITS-1:0] reconn_lane_w;

    // =============================================================================================
    // Receive: one dispatcher, N framing lanes.
    // =============================================================================================
    logic [NUM_CONNS-1:0]       conn_tvalid, conn_tready, conn_space_ok, conn_closed;
    logic [AXI_DATA_BITS-1:0]   conn_tdata;
    logic [AXI_DATA_BITS/8-1:0] conn_tkeep;
    logic                       conn_tlast;
    logic [NUM_CONNS-1:0]       rxd_has_pending;
    logic                       rxd_overflow, rxd_route_stall;

    rx_dispatch #(
        .NUM_CONNS   (NUM_CONNS),
        .NOTIFY_DEPTH(64)
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
        .dbg_has_pending(rxd_has_pending),
        .dbg_overflow   (rxd_overflow),
        .dbg_route_stall(rxd_route_stall)
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
    // It used to be driven with the level `conn_up && rwl_busy && !fatal`. rwl_busy is high while
    // ANY chunk entry is queued in axis_rewrite_last, so with two or more requests outstanding on a
    // lane -- which is the whole point of pipelining, and what the board actually runs -- it never
    // fell. The reader framed the first response, parked in ST_DONE, and the lane went silent while
    // the wire kept delivering. handler_stream had this stage (a 2-state FSM around the same
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
            .tx_space(), .state_debug()
        );

        // -- receive and framing ------------------------------------------------------------------
        tcp_read #(
            .RX_FIFO_DEPTH    (RX_FIFO_DEPTH),
            .EXTERNAL_DISPATCH(1)
        ) inst_tcp_read (
            .clk(ap_clk), .rst_n(ap_rst_n),
            // One activation per response. See read_run_q: the reader needs `start` to FALL between
            // responses, and "up and still owing bytes" is a level that does not.
            .start        (read_run_q[L]),
            .session_id   (conn_sid_q[L]),
            .body_last    (1'b0),   // tlast comes from axis_rewrite_last, by byte count
            .clear_framing(!conn_up_q[L]),

            .rx_req_len('0), .rx_closed(conn_closed[L]), .rx_take_en(),
            .m_axis_read_package_TVALID(), .m_axis_read_package_TREADY(1'b0),
            .m_axis_read_package_TDATA (),
            .s_axis_rx_metadata_TVALID (1'b0), .s_axis_rx_metadata_TREADY(),
            .s_axis_rx_metadata_TDATA  ('0),

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
            .rx_space_ok  (conn_space_ok[L]),
            .debug_rx_write_ptr(), .debug_rx_buffer_w0(), .debug_rx_buffer_w1(),
            .state_debug(lane_read_state[L])
        );

        // -- chunk boundaries by byte count -------------------------------------------------------
        //
        // NUM_DEST is 1 per lane: the lane IS the destination now. The old design had one
        // rewrite_last with an N-way dest because one body stream fed N decoders; here each lane
        // has its own stream and its own decoder, so there is nothing left to select.
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
            .m_tvalid(m_axis_body_tvalid[L]), .m_tready(m_axis_body_tready[L]),
            .m_tdata (m_axis_body_tdata[L]),  .m_tkeep (m_axis_body_tkeep[L]),
            .m_tlast (m_axis_body_tlast[L]),
            .m_tdest (),
            .busy(rwl_busy[L]), .starved(rwl_starved[L]), .remaining_dbg()
        );

        assign lane_occ_ok[L] = (lane_occ_q[L] < 32'(QUEUE_DEPTH));
    end

    // A lane may be reconnected only when there is NOTHING TO REPLAY.
    //
    // handler_stream learned this the expensive way: streamed request text is consumed as it is
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
    end

    // First lane asking, lowest index. Reconnects are rare and one at a time is plenty -- the
    // connect resource is a single sequenced tcp_init either way.
    always_comb begin
        reconn_pending_w = 1'b0;
        reconn_lane_w    = '0;
        for (int i = NUM_CONNS - 1; i >= 0; i--) begin
            if (lane_want_reconn_w[i]) begin
                reconn_pending_w = 1'b1;
                reconn_lane_w    = CONN_BITS'(i);
            end
        end
    end

    always_comb begin
        br_d         = br_q;
        bring_lane_d = bring_lane_q;
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
            BR_DONE: begin
                if (reconn_pending_w && (retry_wait_q == '0)) begin
                    bring_lane_d = reconn_lane_w;
                    br_d         = BR_CLOSE;
                end
            end

            // Drop the old session before asking for a new one. The release must reach rx_dispatch
            // in the same breath: an unbound session id stops matching, so a late notification for
            // the dead connection is dropped rather than turned into a readPkg for a session the
            // TOE has forgotten -- which would desynchronise the shared fifo for every other lane.
            BR_CLOSE: begin
                m_axis_close_connection_TVALID = 1'b1;
                if (m_axis_close_connection_TREADY) begin
                    release_en_w   = 1'b1;
                    release_conn_w = bring_lane_q;
                    br_d           = BR_OPEN;
                end
            end
        endcase
    end

    // =============================================================================================
    // State
    // =============================================================================================
    logic [NUM_CONNS-1:0] lane_init_err_q, lane_resp_err_q, lane_status_bad_q;
    logic                 conn_stall_q;
    localparam int STALL_BITS = $clog2(STALL_CYCLES) + 1;
    logic [STALL_BITS-1:0] conn_cnt_q;

    always_ff @(posedge ap_clk) begin
        if (!ap_rst_n) begin
            br_q          <= BR_IDLE;
            bring_lane_q  <= '0;
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
            conn_stall_q  <= 1'b0;
            conn_cnt_q    <= '0;
            for (int L = 0; L < NUM_CONNS; L++) begin
                conn_sid_q[L] <= 16'd0;
                lane_occ_q[L] <= '0;
            end
        end else begin
            br_q         <= br_d;
            bring_lane_q <= bring_lane_d;
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
                if (reconn_cnt_q != 8'hFF) reconn_cnt_q <= reconn_cnt_q + 8'd1;
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
                // would reopen a session with nothing to ask for -- which is the SYN/FIN-per-port
                // loop that burned the TOE's ephemeral pool in the single-lane design. The host
                // still holds the text and reissues.
                // Fatal ONLY when a reconnect could not fix it -- dirty (body bytes already
                // reached the decoder, so replay would duplicate them) or with work outstanding
                // (the request text is gone and only the host can reissue it). A clean error on an
                // idle lane is a reconnect, handled by the bring-up FSM.
                if (lane_must_die_w[L]) lane_fatal_q[L] <= 1'b1;
                if (lane_resp_error[L]) lane_resp_err_q[L] <= 1'b1;

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
    // Readback. Same field positions as handler_stream wherever a field still means the same thing,
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
                        rxd_overflow,
                        (|rwl_busy) || tx_busy,
                        |stream_refused, |lane_fatal_q, 1'b0, (&conn_up_q),
                        6'd0,
                        lane_read_state[0], init_state_debug, 4'd0};

    // EXACTLY 32 BITS. The first draft packed 30 and relied on the lvalue width, which zero-extends
    // on the LEFT -- so every field still landed where it should but the lane count was
    // CONN_BITS'(NUM_CONNS), i.e. 4 truncated into 2 bits, reading back as 0. handler_stream carries
    // the same warning for the same reason: a concat that does not add up is not a compile error,
    // it is a host that decodes the wrong bits.
    //   [7:0] occupancy (max over lanes, saturating)  [15:8] queue depth
    //   [16] any lane has an unread announcement      [17] any peer FINed
    //   [18] every lane is connected                  [19] req_ready for the lane last addressed
    //   [23:20] LANE COUNT -- how many sessions this bitstream has, which is what the host sizes
    //           its per-lane batches from
    //   [31:24] zero
    assign inflightWord = {8'd0, 4'(NUM_CONNS), req_ready, (&conn_up_q),
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

endmodule
