`timescale 1ns / 1ps

import lynxTypes::*;
import http_types::*;

// HTTP client with NUM_CONNS lanes, one TCP session and one decoder each. rx_dispatch splits the
// shared receive path over the lanes (tcp_read, axis_rewrite_last, a register slice), tx_arbiter
// shares the transmit path between their http_req_stream, and one tcp_init opens the sessions one
// lane at a time. Every config beat names its lane in req_chunk_dest: req_total_bytes == 0 pushes a
// chunk length, non-zero arms the lane, whose request text then follows on s_axis_req[lane].
//
// A lane whose read fails cleanly with nothing owed, or whose idle connection the server closed, is
// reconnected. Any other failure makes it fatal, since the hardware cannot replay request text and
// only the host can reissue the batch. A fatal lane's session is closed as well, so clear_framing
// flushes its fifo and the lane discards what it is still sent instead of blocking the other lanes.
module handler_multi #(
    parameter int NUM_CONNS = 4,
    // Column chunks queued ahead of the data, per lane.
    parameter int QUEUE_DEPTH = 64,
    // Receive fifo depth per lane in 64-byte beats: one MSS plus slack, not a whole response.
    parameter int RX_FIFO_DEPTH = 2048,
    parameter int TX_CHUNK_BYTES = 4096,
    parameter int STALL_CYCLES = 268435456,
    // Cycles one lane may block the shared receive path before rx_dispatch declares it dead.
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

    // -- per-lane readback, read registers 16..20 (see http_config.sv) ----------------------------
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

    // Config beat decode. Every beat names a lane in req_chunk_dest.
    logic [CONN_BITS-1:0] cfg_lane;
    assign cfg_lane = req_data.req_chunk_dest[CONN_BITS-1:0];

    logic cfg_is_arm_w, cfg_is_entry_w;
    assign cfg_is_arm_w   = req_valid && (req_data.req_total_bytes != 32'd0);
    assign cfg_is_entry_w = req_valid && (req_data.req_total_bytes == 32'd0);

    logic [NUM_CONNS-1:0] rwl_cfg_ready, rwl_busy, rwl_starved;
    logic [NUM_CONNS-1:0] stream_busy, stream_refused, stream_bus_req, stream_bus_grant;
    logic [NUM_CONNS-1:0] lane_occ_ok;

    // Admission per lane: an arm waits until the lane's previous text has gone out, an entry until
    // its chunk queue has room. Gating an arm on queue room would deadlock, as the arm drains the
    // queue. Only a host config beat clears either bit, so the host can poll, then write.
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

    // Connection bring-up: one tcp_init, sequenced across the lanes.
    logic [31:0] server_ip_q, server_port_q;
    logic        any_armed_q;

    localparam logic [2:0] BR_IDLE  = 3'd0;  // nothing wanted yet
    localparam logic [2:0] BR_OPEN  = 3'd1;  // tcp_init running for lane bring_lane_q
    localparam logic [2:0] BR_NEXT  = 3'd2;  // bind, advance to the next lane
    localparam logic [2:0] BR_DONE  = 3'd3;  // all lanes up; watching for reconnect requests
    localparam logic [2:0] BR_CLOSE = 3'd4;  // tearing bring_lane_q down before reopening it

    logic [2:0]           br_q, br_d;
    logic [CONN_BITS-1:0] bring_lane_q, bring_lane_d;
    // The initial walk over all lanes, as opposed to a single-lane reconnect.
    logic                 bringing_up_q;
    logic [NUM_CONNS-1:0] conn_up_q;
    logic [15:0]          conn_sid_q [NUM_CONNS];

    logic        init_done, init_error;
    logic [15:0] init_session_id;
    logic [3:0]  init_state_debug;

    localparam int RETRY_BITS = 16;
    logic [RETRY_BITS-1:0] retry_wait_q;
    // Reconnects since reset, saturating. A few are the server's idle timeout.
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

    logic [NUM_CONNS-1:0] lane_idle_w, lane_want_reconn_w, lane_must_die_w, lane_want_close_w;
    logic                 reconn_pending_w, close_pending_w;
    logic [CONN_BITS-1:0] reconn_lane_w, close_lane_w;
    // A close with no open behind it, for a fatal lane.
    logic                 close_only_q, close_only_d;

    // Receive: one dispatcher, N framing lanes.
    logic [NUM_CONNS-1:0]       conn_tvalid, conn_tready, conn_space_ok, conn_closed;
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

    // Transmit: N request streams share one TOE transmit path.
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

    assign m_axis_tx_meta_TVALID = tx_busy && lane_meta_valid[tx_sel];
    assign m_axis_tx_meta_TDATA  = lane_meta_data[tx_sel];
    assign m_axis_tx_data_TVALID = tx_busy && lane_data_valid[tx_sel];
    assign m_axis_tx_data_TDATA  = lane_data_data[tx_sel];
    assign m_axis_tx_data_TKEEP  = lane_data_keep[tx_sel];
    assign m_axis_tx_data_TLAST  = lane_data_last[tx_sel];
    assign s_axis_tx_status_TREADY = tx_busy && lane_stat_ready[tx_sel];

    // The lanes
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

    // tcp_read serves one response per start and leaves ST_DONE only when start falls; its cycle
    // in ST_ARM retires the response in strip_http. So read_run_q is cleared on done and set again
    // a cycle later while the lane owes bytes; a level would never fall with pipelined requests.
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
            .RX_FIFO_DEPTH    (RX_FIFO_DEPTH)
        ) inst_tcp_read (
            .clk(ap_clk), .rst_n(ap_rst_n),
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
            .rx_space_ok  (conn_space_ok[L]),
            .rx_pkg_issued(conn_pkg_issued[L]),
            .debug_rx_write_ptr(), .debug_rx_buffer_w0(), .debug_rx_buffer_w1(),
            .state_debug(lane_read_state[L])
        );

        // -- chunk boundaries by byte count -------------------------------------------------------
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
            .m_tvalid(rwl_tvalid), .m_tready(rwl_tready),
            .m_tdata (rwl_tdata),  .m_tkeep (rwl_tkeep),
            .m_tlast (rwl_tlast),
            .m_tdest (),
            .busy(rwl_busy[L]), .starved(rwl_starved[L]), .remaining_dbg()
        );

        // -- register slice on the body output ----------------------------------------------------
        // Ends the combinational cone from strip_http through axis_rewrite_last at a register, in
        // both directions. It sits here rather than in vfpga_top so that lane_occ_q, which counts
        // at this port, also starts from a register. It is empty whenever a lane is reconnectable.
        axis_skid #(.DATA_BITS(AXI_DATA_BITS)) inst_body_slice (
            .clk(ap_clk), .rst_n(ap_rst_n),
            .s_tvalid(rwl_tvalid), .s_tready(rwl_tready),
            .s_tdata (rwl_tdata),  .s_tkeep (rwl_tkeep), .s_tlast(rwl_tlast),
            .m_tvalid(m_axis_body_tvalid[L]), .m_tready(m_axis_body_tready[L]),
            .m_tdata (m_axis_body_tdata[L]),  .m_tkeep (m_axis_body_tkeep[L]),
            .m_tlast (m_axis_body_tlast[L])
        );

        assign lane_occ_ok[L] = (lane_occ_q[L] < 32'(QUEUE_DEPTH));

        assign lane_arm_ready_w[L]   = !stream_busy[L];
        assign lane_entry_ready_w[L] = rwl_cfg_ready[L] && lane_occ_ok[L];
    end

    // Reconnect only with nothing to replay: no chunk part-way, the transmit side idle, and a clean
    // failure.
    for (genvar L = 0; L < NUM_CONNS; L++) begin : gen_reconn_want
        assign lane_idle_w[L] = !rwl_busy[L] && !stream_busy[L] && (lane_occ_q[L] == '0);

        // A new connection after a clean read error, or a FIN while idle (server idle timeout).
        assign lane_want_reconn_w[L] = conn_up_q[L] && !lane_fatal_q[L] && lane_idle_w[L] &&
                                       ((lane_error[L] && !lane_error_dirty[L]) || conn_closed[L]);

        assign lane_must_die_w[L] = lane_error[L] && (lane_error_dirty[L] || !lane_idle_w[L]);

        // A fatal lane closes its session without waiting for idle: it may never become idle.
        assign lane_want_close_w[L] = conn_up_q[L] && lane_fatal_q[L];
    end

    // Lowest lane first; one tcp_init serves one reconnect at a time.
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
                // The first arm brings the server address; open every lane then, not on first use.
                if (any_armed_q && (retry_wait_q == '0)) begin
                    bring_lane_d = '0;
                    br_d         = BR_OPEN;
                end
            end
            BR_OPEN: begin
                if (init_done) begin
                    if (init_error) begin
                        // Nothing bound. During bring-up, back off and retry from lane 0; a refused
                        // reconnect leaves the lane down.
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

            // A fatal lane's teardown goes first: it needs no tcp_init and unblocks the shared
            // receive path, whereas a reconnect may first wait out retry_wait_q.
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

            // Release the session in rx_dispatch with the close, so its late notifications are
            // dropped. A fatal lane stays down here, which keeps clear_framing high.
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

    logic [NUM_CONNS-1:0] lane_init_err_q, lane_resp_err_q, lane_status_bad_q;
    // Latched here because the sources clear: the release after a fatal lane clears rx_dispatch's
    // dead bit, error_dirty lasts only in ST_ABORT, and read_timeout is reset on a reconnect.
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
            if (br_q == BR_NEXT && int'(bring_lane_q) == NUM_CONNS - 1) bringing_up_q <= 1'b0;

            if (cfg_fire && cfg_is_arm_w) begin
                server_ip_q   <= req_data.server_ip;
                server_port_q <= req_data.server_port;
                any_armed_q   <= 1'b1;
                lane_armed_q[cfg_lane] <= 1'b1;
            end

            if (release_en_w) begin
                conn_up_q[release_conn_w] <= 1'b0;
                if (!close_only_q && (reconn_cnt_q != 8'hFF)) reconn_cnt_q <= reconn_cnt_q + 8'd1;
            end
            // Bind after release, so a same-cycle pair could not leave the lane down.
            if (bind_en_w) begin
                conn_sid_q[bind_conn_w] <= bind_sid_w;
                conn_up_q[bind_conn_w]  <= 1'b1;
            end

            if (retry_wait_q != '0) retry_wait_q <= retry_wait_q - 1'b1;
            if ((br_q == BR_OPEN) && init_done && init_error) begin
                retry_wait_q               <= '1;
                lane_init_err_q[bring_lane_q] <= 1'b1;
            end

            for (int L = 0; L < NUM_CONNS; L++) begin
                automatic logic push = cfg_fire && cfg_is_entry_w && (cfg_lane == CONN_BITS'(L));
                automatic logic pop  = m_axis_body_tvalid[L] && m_axis_body_tready[L]
                                       && m_axis_body_tlast[L];
                case ({push, pop})
                    2'b10: lane_occ_q[L] <= lane_occ_q[L] + 1'b1;
                    2'b01: lane_occ_q[L] <= (lane_occ_q[L] == '0) ? '0 : lane_occ_q[L] - 1'b1;
                    default: ;
                endcase

                // Fatal when a reconnect cannot help: dirty, work outstanding, or declared dead by
                // rx_dispatch, which has already discarded bytes of a response.
                if (lane_must_die_w[L] || rxd_lane_dead[L]) lane_fatal_q[L] <= 1'b1;
                if (lane_resp_error[L]) lane_resp_err_q[L] <= 1'b1;

                if (rxd_lane_dead[L])   lane_dead_q[L]       <= 1'b1;
                if (lane_error_dirty[L])lane_dirty_q[L]      <= 1'b1;
                if (lane_timeout[L])    lane_timeout_q[L]    <= 1'b1;
                if (lane_fifo_stall[L]) lane_fifo_stall_q[L] <= 1'b1;

                if (read_run_q[L] && lane_done[L])
                    read_run_q[L] <= 1'b0;
                else if (conn_up_q[L] && rwl_busy[L] && !lane_fatal_q[L])
                    read_run_q[L] <= 1'b1;
                // Judge the status only while the connection is up: clear_framing resets the
                // framer, and a lane is released while its reader may still sit in ST_DONE.
                if (conn_up_q[L] && lane_done[L] && !lane_error[L] && !lane_status_ok[L])
                    lane_status_bad_q[L] <= 1'b1;
            end

            if (br_q == BR_OPEN) begin
                if (conn_cnt_q == STALL_BITS'(STALL_CYCLES)) conn_stall_q <= 1'b1;
                else                                          conn_cnt_q <= conn_cnt_q + 1'b1;
            end else conn_cnt_q <= '0;
        end
    end

    // Readback. The 32-bit words OR the lanes together; read registers 16..20 say which lane. The
    // bit layouts are in the read map in http_config.sv.
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

    // Each concatenation must add up to 32 bits: a short one is zero-extended on the left without a
    // compile error. The host refuses any CSR_REVISION but 2.
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

    // Per-lane readback at a fixed stride of 8 lanes, whatever NUM_CONNS is, so a host built for
    // one bitstream reads another correctly.
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
            // The transmit state shows a wedged transmit path: ST_IDLE with a transfer still armed.
            laneStateWord[4*L      +: 4] = lane_rd_nib[L];
            laneStateWord[32 + 4*L +: 4] = lane_tx_nib[L];
            laneErrWord  [8*L      +: 8] = lane_err_byte[L];
        end
    end

    // Fixed at elaboration, so the host can check its lanes, batch size and watchdog against it.
    assign lanePolicyWord = {2'd0, 6'(POLICY_STALL_LOG2), POLICY_STALL_CYC,
                             POLICY_QDEPTH, 8'(NUM_CONNS), CSR_REVISION};

endmodule
