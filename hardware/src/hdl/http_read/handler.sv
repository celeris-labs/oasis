import lynxTypes::*;
import http_types::*;

// =================================================================================================
// HTTP client handler -- pipelined ranged GETs over ONE persistent TCP connection.
//
// WHAT CHANGED AND WHY
// --------------------
// Two designs preceded this one.
//
//   1. A single sequential FSM: connect, send, read, close, one request at a time. Every ranged GET
//      paid a three-way handshake, the request, the server's think time, the body and a teardown,
//      end to end with nothing overlapping.
//
//   2. A ring of NUM_SLOTS slots, each with its OWN TCP session, so the next connection was already
//      open and its GET already sent while the previous body streamed. That is correct against a
//      normal TCP stack and wrong against this one. Coyote builds the TOE with
//      TCP_STACK_RX_DDR_BYPASS_EN=1, where the receive side is a single shared packet FIFO with no
//      per-session buffering: rx_app_stream_if answers a readPkg with a bare token, and
//      rxAppMemDataRead pops the FIFO HEAD regardless of which session asked. The real contract is
//      "readPkg must be issued in global arrival order across all sessions", which nothing in a
//      request-ordered ring can honour. Builds 90/91/92 wedged on it.
//
// This design keeps the ring and deletes the concurrency that broke it. There is exactly ONE TCP
// connection, opened lazily on the first request and then held open across every request and every
// query. With one session, arrival order and request order are identical by construction, so the
// TOE's contract is satisfied for free -- and HTTP/1.1 pipelining over that single connection is
// legal and safe, which is what the ring is now for.
//
//     fill_ptr   host pushes a request descriptor into a free slot   (one cycle, no handshake)
//     send_ptr   SEND: tcp_send_http builds and transmits the GET on the shared session
//     read_ptr   READ: tcp_read streams exactly one response body out
//
//     read_ptr <= send_ptr <= fill_ptr (mod 2*NUM_SLOTS)
//
// Ordering is not incidental: the bodies are concatenated into one decoder stream, so they MUST come
// back in the order the host enqueued them. HTTP/1.1 guarantees responses in request order on one
// connection, so that holds without any per-slot bookkeeping on the receive side -- which is why
// tcp_session_table is instantiated with a single slot here. It owns the notification stream and
// queues the announcements for that one session in arrival order.
//
// WHAT KEEP-ALIVE BUYS
// --------------------
// The TOE hands out ephemeral ports from a pool of exactly TCP_STACK_MAX_SESSIONS = 512
// (32768..33279), allocated by a linear cursor, released with no quiet time, and cumulative since
// the bitstream was programmed. `Connection: close` meant the SERVER closed first, so Linux held
// each 4-tuple in TIME_WAIT for 60 s; wrapping the cursor inside that window lands on a tuple the
// peer still owns and the SYN is retried forever with no openStatus and nothing to report. A full
// benchmark run needed thousands of connections. It now needs one.
//
// RECONNECT AND REPLAY
// --------------------
// A persistent connection can still die -- MinIO closes an idle one on its own timeout. tcp_read
// reports that as `error`, and the recovery is in the ring: roll send_ptr back to read_ptr and every
// request that was sent but not answered is simply sent again on the new connection. Nothing else
// needs to be remembered.
//
// That is only safe while the failure is CLEAN, i.e. no body byte of the response being read has
// reached the decoder yet. tcp_read's `error_dirty` says otherwise: those bytes cannot be unsent, so
// replaying would duplicate them in the decoder stream. That case latches `fatal_q` and stalls
// visibly instead, which the host sees as a stalled read plus the dirty bit in the STALL CSR.
//
// ERROR HANDLING elsewhere is unchanged, which is to say minimal: init_error and send_error are
// surfaced in the status word but not acted on beyond retrying the connect. There is still no reset
// CSR; reprogramming clears a wedge.
// =================================================================================================
module handler #(
    // Requests in flight on the shared connection. Each costs one slot's worth of descriptor
    // storage. Unlike the previous design this does NOT cost a TCP session -- there is only ever
    // one -- so the knob now trades area for hidden round trips only. The host must not enqueue more
    // than this many outstanding requests; it reads the occupancy back through HttpConfig
    // (see http_config.sv, INFLIGHT register).
    parameter int NUM_SLOTS = 4,
    // Cycles a stage may sit in RUN before it is declared stalled. Reporting only -- nothing is
    // aborted or retried, because a skipped column chunk would corrupt the decoder stream. ~1.07 s
    // at 250 MHz, which is far beyond any legitimate connect, send or body transfer (8 MB at
    // 100 GbE is under a millisecond). Overridden small in simulation.
    parameter int STALL_CYCLES = 268435456
) (
    input  logic                                      ap_clk,
    input  logic                                      ap_rst_n,

    output logic                                      m_axis_open_connection_TVALID,
    input  logic                                      m_axis_open_connection_TREADY,
    output logic [TCP_OPEN_CONN_REQ_BITS-1:0]         m_axis_open_connection_TDATA,

    input  logic                                      s_axis_open_status_TVALID,
    output logic                                      s_axis_open_status_TREADY,
    input  logic [TCP_OPEN_CONN_RSP_BITS-1:0]         s_axis_open_status_TDATA,

    output logic                                      m_axis_close_connection_TVALID,
    input  logic                                      m_axis_close_connection_TREADY,
    output logic [TCP_CLOSE_CONN_REQ_BITS-1:0]        m_axis_close_connection_TDATA,

    input  logic                                      s_axis_notifications_TVALID,
    output logic                                      s_axis_notifications_TREADY,
    input  logic [TCP_NOTIFY_BITS-1:0]                s_axis_notifications_TDATA,

    output logic                                      m_axis_read_package_TVALID,
    input  logic                                      m_axis_read_package_TREADY,
    output logic [TCP_RD_PKG_REQ_BITS-1:0]            m_axis_read_package_TDATA,

    input  logic                                      s_axis_rx_metadata_TVALID,
    output logic                                      s_axis_rx_metadata_TREADY,
    input  logic [TCP_RX_META_BITS-1:0]               s_axis_rx_metadata_TDATA,

    input  logic                                      s_axis_rx_data_TVALID,
    output logic                                      s_axis_rx_data_TREADY,
    input  logic [AXI_DATA_BITS-1:0]                  s_axis_rx_data_TDATA,
    input  logic [AXI_DATA_BITS/8-1:0]                s_axis_rx_data_TKEEP,
    input  logic                                      s_axis_rx_data_TLAST,
    input  logic [AXI_DATA_BITS/8-1:0]                s_axis_rx_data_TSTRB,

    output logic                                      m_axis_tx_meta_TVALID,
    input  logic                                      m_axis_tx_meta_TREADY,
    output logic [TCP_TX_META_BITS-1:0]               m_axis_tx_meta_TDATA,

    output logic                                      m_axis_tx_data_TVALID,
    input  logic                                      m_axis_tx_data_TREADY,
    output logic [AXI_DATA_BITS-1:0]                  m_axis_tx_data_TDATA,
    output logic [AXI_DATA_BITS/8-1:0]                m_axis_tx_data_TKEEP,
    output logic                                      m_axis_tx_data_TLAST,

    input  logic                                      s_axis_tx_status_TVALID,
    output logic                                      s_axis_tx_status_TREADY,
    input  logic [TCP_TX_STAT_BITS-1:0]               s_axis_tx_status_TDATA,

    // Request input. One beat per ranged GET, carrying the whole descriptor. Accepted into a free
    // slot in a single cycle -- the slot ring IS the request queue, so no separate FIFO is needed.
    input  logic                                      req_valid,
    output logic                                      req_ready,
    input  http_config_t                              req_data,

    output logic                       m_axis_body_tvalid,
    input  logic                       m_axis_body_tready,
    output logic [AXI_DATA_BITS-1:0]   m_axis_body_tdata,
    output logic [AXI_DATA_BITS/8-1:0] m_axis_body_tkeep,
    output logic                                      m_axis_body_tlast,

    output logic [3:0]                                debug_rx_write_ptr,
    output logic [AXI_DATA_BITS-1:0]                  debug_rx_buffer_w0,
    output logic [AXI_DATA_BITS-1:0]                  debug_rx_buffer_w1,
    output logic [AXI_DATA_BITS-1:0]                  debug_tx_acc,
    output logic [6:0]                                debug_tx_acc_cnt,
    output logic                                      debug_tx_acc_last,
    output logic [15:0]                               debug_http_len,
    output logic [3:0]                                debug_builder_state,
    output logic [AXI_DATA_BITS-1:0]                  debug_req_lo,
    output logic [AXI_DATA_BITS-1:0]                  debug_req_hi,
    output logic [7:0]                                debug_req_cnt,
    output logic [31:0]                               totalWord,
    output logic [31:0]                               inflightWord,
    output logic [31:0]                               stallWord,
    output logic [31:0]                               respWord,
    output logic [31:0]                               contentLengthWord,
    output logic [31:0]                               bodyRemainingWord,
    output logic [3:0]                                state_debug
);

    localparam int PTR_BITS = $clog2(NUM_SLOTS) + 1; // one extra bit so full and empty differ
    // Clamped to 1 so NUM_SLOTS==1 -- pipelining off, the debugging fallback -- still elaborates;
    // $clog2(1) is 0 and would give [-1:0] index ports. At that width the pointer's low bit is not
    // a valid slot index, so the index is forced to 0 below.
    localparam int IDX_BITS = (NUM_SLOTS > 1) ? $clog2(NUM_SLOTS) : 1;

    // The pointers wrap at 2**PTR_BITS and the slot index is the low bits of the pointer, so
    // `occupancy = fill - read` is only correct when the ring size divides the pointer range --
    // i.e. for powers of two. 8 is the ceiling because the debug fields in inflightWord are one byte.
    if (NUM_SLOTS < 1 || NUM_SLOTS > 8)      $error("handler: NUM_SLOTS must be between 1 and 8");
    if (NUM_SLOTS & (NUM_SLOTS - 1))         $error("handler: NUM_SLOTS must be a power of two");

    // ---------------------------------------------------------------------------------------------
    // Slot ring. fill -> send -> read, each pointer owned by exactly one stage. There is no conn_ptr
    // any more: the connection is a property of the client, not of a request.
    // ---------------------------------------------------------------------------------------------
    http_config_t              slot_cfg_q [NUM_SLOTS];

    logic [PTR_BITS-1:0] fill_ptr_q, send_ptr_q, read_ptr_q;

    logic [IDX_BITS-1:0] fill_idx, send_idx, read_idx;
    assign fill_idx = (NUM_SLOTS > 1) ? fill_ptr_q[IDX_BITS-1:0] : '0;
    assign send_idx = (NUM_SLOTS > 1) ? send_ptr_q[IDX_BITS-1:0] : '0;
    assign read_idx = (NUM_SLOTS > 1) ? read_ptr_q[IDX_BITS-1:0] : '0;

    logic [PTR_BITS-1:0] occupancy;
    assign occupancy = fill_ptr_q - read_ptr_q;

    logic send_has_work, read_has_work;
    assign send_has_work = (send_ptr_q != fill_ptr_q);
    assign read_has_work = (read_ptr_q != send_ptr_q);

    // Accept a request whenever the ring has room. Purely combinational on occupancy, so the host's
    // START write is absorbed in one cycle and never has to wait behind a connection.
    assign req_ready = (occupancy < PTR_BITS'(NUM_SLOTS));
    logic req_fire;
    assign req_fire = req_valid && req_ready;

    // ---------------------------------------------------------------------------------------------
    // The one connection
    // ---------------------------------------------------------------------------------------------
    logic        conn_valid_q;
    logic [15:0] conn_sid_q;

    localparam logic [1:0] CS_DOWN  = 2'd0; // no connection
    localparam logic [1:0] CS_OPEN  = 2'd1; // tcp_init running
    localparam logic [1:0] CS_UP    = 2'd2; // connected, requests may flow
    localparam logic [1:0] CS_CLOSE = 2'd3; // tearing down before a reconnect

    logic [1:0] cs_q, cs_d;

    // Latched request to drop and reopen the connection, raised by a clean read failure.
    logic reconn_q, reconn_d;
    // A read failed after body bytes had already reached the decoder. Unrecoverable: replaying would
    // duplicate them, so stop and let the host's watchdog report it.
    logic fatal_q, fatal_d;
    // Reconnects since reset, saturating. A handful over a long session is MinIO's idle timeout
    // doing its job; a steadily climbing count means something is wrong with the connection.
    logic [7:0] reconn_cnt_q;

    // Backoff between a FAILED open and the next attempt. Without it a server that refuses the
    // connection turns into a tight retry loop that burns an ephemeral port per attempt -- 512 of
    // them, cumulative since the bitstream was programmed. ~262 us at 250 MHz: long enough not to
    // spin, short enough to be invisible next to a round trip. A reconnect after a clean FIN does
    // NOT wait; only an error does.
    localparam int RETRY_BITS = 16;
    logic [RETRY_BITS-1:0] retry_wait_q;

    // strip_http keeps its residue across responses, so it may only be cleared when the byte stream
    // it is framing goes away -- i.e. exactly while there is no connection.
    logic clear_framing;
    assign clear_framing = !conn_valid_q;

    // ---------------------------------------------------------------------------------------------
    // Sub-FSM handshakes
    // ---------------------------------------------------------------------------------------------
    logic init_done, init_error;
    logic [15:0] init_session_id;
    logic [3:0]  init_state_debug;

    logic send_done, send_error;
    logic [3:0]  send_state_debug;

    logic read_done, read_error, read_error_dirty;
    logic [3:0]  read_state_debug;
    logic        read_resp_error;
    logic [23:0] read_status_ascii;
    logic        read_status_ok;
    logic [31:0] read_content_length;
    logic [31:0] read_body_remaining;

    // Stage FSMs. Each sub-module latches `start` as a level and parks in its own DONE state until
    // start drops, so each stage needs an idle cycle between runs -- which the IDLE state provides.
    localparam logic ST_STAGE_IDLE = 1'b0;
    localparam logic ST_STAGE_RUN  = 1'b1;

    logic send_state_q, send_state_d;
    logic read_state_q, read_state_d;

    // ---------------------------------------------------------------------------------------------
    // Session table: owns the notification stream for the single session.
    // ---------------------------------------------------------------------------------------------
    logic                    bind_en;
    logic                    release_en;
    logic [TCP_LEN_BITS-1:0] tbl_req_len;
    logic                    tbl_closed;
    logic                    tbl_bound;
    logic                    tbl_take_en;
    logic                    tbl_dbg_has_pending;
    logic                    tbl_dbg_closed;
    logic                    tbl_dbg_overflow;

    tcp_session_table #(
        .NUM_SLOTS(1)
    ) inst_session_table (
        .clk  (ap_clk),
        .rst_n(ap_rst_n),

        .s_axis_notifications_TVALID(s_axis_notifications_TVALID),
        .s_axis_notifications_TREADY(s_axis_notifications_TREADY),
        .s_axis_notifications_TDATA (s_axis_notifications_TDATA),

        .bind_en     (bind_en),
        .bind_slot   (1'b0),
        .bind_sid    (init_session_id),
        .release_en  (release_en),
        .release_slot(1'b0),

        .q_slot   (1'b0),
        .q_pending(),
        .q_req_len(tbl_req_len),
        .q_closed (tbl_closed),
        .q_bound  (tbl_bound),

        .take_en (tbl_take_en),

        .dbg_has_pending(tbl_dbg_has_pending),
        .dbg_closed     (tbl_dbg_closed),
        .dbg_overflow   (tbl_dbg_overflow)
    );

    // ---------------------------------------------------------------------------------------------
    // Status word, surfaced on HttpConfig read register 2.
    //   [3:0]   coarse pipeline state (0 idle, 1 connecting, 2 sending, 3 reading, 4 reconnecting)
    //   [7:4]   tcp_init      state_debug
    //   [11:8]  tcp_send_http state_debug
    //   [15:12] tcp_read      state_debug
    //   [16]    init_done   [17] init_error
    //   [18]    send_done   [19] send_error
    //   [20]    read_done   [21] read_error
    //   [22]    busy (any slot occupied)  -- with pipelining this is the NORMAL state during a scan,
    //           not an error. The host must look at inflightWord for credit, not at this bit.
    //   [23]    req_ready (the ring has room)
    //   [31:24] session_id[7:0] of the shared connection
    // ---------------------------------------------------------------------------------------------
    logic [3:0] coarse_state;
    always_comb begin
        if (cs_q == CS_CLOSE || reconn_q) coarse_state = 4'd4;
        else if (read_has_work)           coarse_state = 4'd3;
        else if (send_has_work)           coarse_state = 4'd2;
        else if (cs_q == CS_OPEN)         coarse_state = 4'd1;
        else                              coarse_state = 4'd0;
    end

    assign totalWord = {conn_sid_q[7:0],
                        req_ready,
                        occupancy != 0,
                        read_error, read_done,
                        send_error, send_done,
                        init_error, init_done,
                        read_state_debug,
                        send_state_debug,
                        init_state_debug,
                        coarse_state};

    // Occupancy readback so the host can throttle: it must never have more than NUM_SLOTS requests
    // outstanding, because a START write that arrives with the ring full is silently swallowed by
    // ConfigWriteReadyRegister (it overwrites the pending beat rather than back-pressuring).
    //   [7:0]   slots occupied
    //   [15:8]  NUM_SLOTS (so the host can size its credit without a rebuild-order dependency)
    //   [16]    the session has an unread announcement
    //   [17]    the peer has FINed
    //   [18]    the connection is up
    assign inflightWord = {13'd0,
                           conn_valid_q,
                           tbl_dbg_closed,
                           tbl_dbg_has_pending,
                           8'(NUM_SLOTS),
                           8'(occupancy)};

    // ---------------------------------------------------------------------------------------------
    // Stage stall / error reporting.
    //
    // "The request ring is full" is a symptom, not a diagnosis -- it looks identical whether the
    // connect never completed, the GET never went out, or the body never arrived. These flags are
    // sticky and reporting-only: the decoder is configured per column chunk and expects that chunk's
    // bytes, so dropping a request would silently corrupt the stream rather than fail. Better to
    // stall visibly and let the host throw.
    //
    //   [0] connect stalled   [1] send stalled   [2] read stalled
    //   [3] tcp_init reported error   [4] tcp_send_http reported error
    //   [5] a response had no Content-Length (unframeable -- chunked, or not a real body)
    //   [6] fatal: a connection died after body bytes had already reached the decoder
    //   [7] a response carried a status other than 200/206
    //   [15:8]  reconnects since reset (saturating)
    //   [23:16] slot the read stage is on
    //   [24]    the announcement queue overflowed -- announced segments were dropped and that
    //           response is short forever
    // ---------------------------------------------------------------------------------------------
    localparam int STALL_BITS = $clog2(STALL_CYCLES) + 1;

    logic [STALL_BITS-1:0] conn_cnt_q, send_cnt_q, read_cnt_q;
    logic conn_stall_q, send_stall_q, read_stall_q;
    logic init_err_q, send_err_q, resp_err_q, status_bad_q;

    logic rx_fifo_stall_w;
    logic read_timeout_w;

    assign stallWord = {5'd0,
                        read_timeout_w,
                        rx_fifo_stall_w,
                        tbl_dbg_overflow,
                        8'(read_idx),
                        reconn_cnt_q,
                        status_bad_q, fatal_q, resp_err_q, send_err_q, init_err_q,
                        read_stall_q, send_stall_q, conn_stall_q};

    // Response framing readback (HttpConfig read register 12).
    //   [23:0]  the three status digits, ASCII
    //   [24]    status is 200 or 206
    //   [25]    the last response could not be framed (no Content-Length)
    //   [26]    the current response has already emitted body bytes
    assign respWord = {5'd0, read_error_dirty, read_resp_error, read_status_ok, read_status_ascii};
    // What the server SAID the body was, latched, next to what is left of it. The host knows what it
    // asked for, so these two being different is the difference between "the network is slow" and
    // "the server answered a different question".
    assign contentLengthWord = read_content_length;
    assign bodyRemainingWord = read_body_remaining;

    // ---------------------------------------------------------------------------------------------
    // CONNECT stage. Runs once per connection, not once per request.
    // ---------------------------------------------------------------------------------------------
    tcp_init inst_tcp_init (
        .clk(ap_clk),
        .rst_n(ap_rst_n),
        .start(cs_q == CS_OPEN),
        // Every request in the ring targets the same server; read_idx is filled whenever a connect
        // is wanted (we only open with occupancy != 0).
        .serverIpAddress(slot_cfg_q[read_idx].server_ip),
        .serverPort(slot_cfg_q[read_idx].server_port),
        .m_axis_open_connection_TVALID(m_axis_open_connection_TVALID),
        .m_axis_open_connection_TREADY(m_axis_open_connection_TREADY),
        .m_axis_open_connection_TDATA(m_axis_open_connection_TDATA),
        .s_axis_open_status_TVALID(s_axis_open_status_TVALID),
        .s_axis_open_status_TREADY(s_axis_open_status_TREADY),
        .s_axis_open_status_TDATA(s_axis_open_status_TDATA),
        .done(init_done),
        .error(init_error),
        .session_id(init_session_id),
        .state_debug(init_state_debug)
    );

    // ---------------------------------------------------------------------------------------------
    // SEND stage
    // ---------------------------------------------------------------------------------------------
    tcp_send_http inst_tcp_send_http (
        .clk(ap_clk),
        .rst_n(ap_rst_n),
        .start(send_state_q == ST_STAGE_RUN),
        .session_id(conn_sid_q),
        .ipHexLen(slot_cfg_q[send_idx].ip_hex_len),
        .ipHexWord0(slot_cfg_q[send_idx].ip_hex_w0),
        .ipHexWord1(slot_cfg_q[send_idx].ip_hex_w1),
        .ipHexWord2(slot_cfg_q[send_idx].ip_hex_w2),
        .ipHexWord3(slot_cfg_q[send_idx].ip_hex_w3),
        .portHexWord0(slot_cfg_q[send_idx].port_hex),
        .fileLen(slot_cfg_q[send_idx].file_len),
        .fileWord0(slot_cfg_q[send_idx].file_w0),
        .fileWord1(slot_cfg_q[send_idx].file_w1),
        .fileWord2(slot_cfg_q[send_idx].file_w2),
        .fileWord3(slot_cfg_q[send_idx].file_w3),
        .fileWord4(slot_cfg_q[send_idx].file_w4),
        .fileWord5(slot_cfg_q[send_idx].file_w5),
        .fileWord6(slot_cfg_q[send_idx].file_w6),
        .fileWord7(slot_cfg_q[send_idx].file_w7),
        .fileWord8(slot_cfg_q[send_idx].file_w8),
        .fileWord9(slot_cfg_q[send_idx].file_w9),
        .fileWord10(slot_cfg_q[send_idx].file_w10),
        .fileWord11(slot_cfg_q[send_idx].file_w11),
        .fileWord12(slot_cfg_q[send_idx].file_w12),
        .fileWord13(slot_cfg_q[send_idx].file_w13),
        .fileWord14(slot_cfg_q[send_idx].file_w14),
        .fileWord15(slot_cfg_q[send_idx].file_w15),
        .rangeBeginLen(slot_cfg_q[send_idx].range_begin_len),
        .rangeBeginW0(slot_cfg_q[send_idx].range_begin_w0),
        .rangeBeginW1(slot_cfg_q[send_idx].range_begin_w1),
        .rangeBeginW2(slot_cfg_q[send_idx].range_begin_w2),
        .rangeBeginW3(slot_cfg_q[send_idx].range_begin_w3),
        .rangeEndLen(slot_cfg_q[send_idx].range_end_len),
        .rangeEndW0(slot_cfg_q[send_idx].range_end_w0),
        .rangeEndW1(slot_cfg_q[send_idx].range_end_w1),
        .rangeEndW2(slot_cfg_q[send_idx].range_end_w2),
        .rangeEndW3(slot_cfg_q[send_idx].range_end_w3),
        .m_axis_tx_meta_TVALID(m_axis_tx_meta_TVALID),
        .m_axis_tx_meta_TREADY(m_axis_tx_meta_TREADY),
        .m_axis_tx_meta_TDATA(m_axis_tx_meta_TDATA),
        .m_axis_tx_data_TVALID(m_axis_tx_data_TVALID),
        .m_axis_tx_data_TREADY(m_axis_tx_data_TREADY),
        .m_axis_tx_data_TDATA(m_axis_tx_data_TDATA),
        .m_axis_tx_data_TKEEP(m_axis_tx_data_TKEEP),
        .m_axis_tx_data_TLAST(m_axis_tx_data_TLAST),
        .s_axis_tx_status_TVALID(s_axis_tx_status_TVALID),
        .s_axis_tx_status_TREADY(s_axis_tx_status_TREADY),
        .s_axis_tx_status_TDATA(s_axis_tx_status_TDATA),
        .done(send_done),
        .error(send_error),
        .debug_http_len(debug_http_len),
        .state_debug(send_state_debug),
        .debug_req_lo(debug_req_lo),
        .debug_req_hi(debug_req_hi),
        .debug_builder_len(debug_req_cnt),
        .debug_builder_state(debug_builder_state)
    );

    // ---------------------------------------------------------------------------------------------
    // READ stage. One activation per response; the connection outlives it.
    // ---------------------------------------------------------------------------------------------
    tcp_read inst_tcp_read (
        .clk(ap_clk),
        .rst_n(ap_rst_n),
        .start(read_state_q == ST_STAGE_RUN),
        .session_id(conn_sid_q),
        .body_last(slot_cfg_q[read_idx].req_flags[0]),
        .clear_framing(clear_framing),

        .rx_req_len (tbl_req_len),
        .rx_closed  (tbl_closed),
        .rx_take_en (tbl_take_en),

        .m_axis_read_package_TVALID(m_axis_read_package_TVALID),
        .m_axis_read_package_TREADY(m_axis_read_package_TREADY),
        .m_axis_read_package_TDATA(m_axis_read_package_TDATA),
        .s_axis_rx_metadata_TVALID(s_axis_rx_metadata_TVALID),
        .s_axis_rx_metadata_TREADY(s_axis_rx_metadata_TREADY),
        .s_axis_rx_metadata_TDATA(s_axis_rx_metadata_TDATA),
        .s_axis_rx_data_TVALID(s_axis_rx_data_TVALID),
        .s_axis_rx_data_TREADY(s_axis_rx_data_TREADY),
        .s_axis_rx_data_TDATA(s_axis_rx_data_TDATA),
        .s_axis_rx_data_TKEEP(s_axis_rx_data_TKEEP),
        .s_axis_rx_data_TLAST(s_axis_rx_data_TLAST),
        .m_axis_body_tvalid(m_axis_body_tvalid),
        .m_axis_body_tready(m_axis_body_tready),
        .m_axis_body_tdata(m_axis_body_tdata),
        .m_axis_body_tkeep(m_axis_body_tkeep),
        .m_axis_body_tlast(m_axis_body_tlast),
        .done(read_done),
        .error(read_error),
        .error_dirty(read_error_dirty),
        .resp_error(read_resp_error),
        .status_ascii(read_status_ascii),
        .status_ok(read_status_ok),
        .content_length(read_content_length),
        // Sticky: a read gave up waiting rather than failing outright. See WATCHDOG_BITS.
        .read_timeout(read_timeout_w),
        .body_remaining(read_body_remaining),
        // Sticky: the decoupling fifo refused the TCP stack at least once, i.e. back-pressure
        // reached the TOE anyway and RX_FIFO_DEPTH is too small for the traffic that showed up.
        // Surfaced as a CSR bit because it is the one thing that would silently undo the
        // decoupling, and nothing else on the host side would reveal it.
        .rx_fifo_level(),
        .rx_fifo_stall(rx_fifo_stall_w),
        .debug_rx_write_ptr(debug_rx_write_ptr),
        .debug_rx_buffer_w0(debug_rx_buffer_w0),
        .debug_rx_buffer_w1(debug_rx_buffer_w1),
        .state_debug(read_state_debug)
    );

    // debug_tx_acc* were tied off when the accumulator they described was removed; the ILA probes
    // still exist, so keep driving them rather than leaving the ports dangling.
    assign debug_tx_acc      = '0;
    assign debug_tx_acc_cnt  = '0;
    assign debug_tx_acc_last = 1'b0;

    // ---------------------------------------------------------------------------------------------
    // Stage sequencing
    // ---------------------------------------------------------------------------------------------
    logic send_advance, read_advance;
    logic conn_bind;

    always_comb begin
        cs_d         = cs_q;
        send_state_d = send_state_q;
        read_state_d = read_state_q;
        reconn_d     = reconn_q;
        fatal_d      = fatal_q;

        send_advance = 1'b0;
        read_advance = 1'b0;
        conn_bind    = 1'b0;

        bind_en    = 1'b0;
        release_en = 1'b0;

        m_axis_close_connection_TVALID = 1'b0;
        m_axis_close_connection_TDATA  = conn_sid_q[TCP_CLOSE_CONN_REQ_BITS-1:0];

        // -- CONNECTION -----------------------------------------------------------------------
        case (cs_q)
            CS_DOWN: begin
                // Open lazily: the first request in the ring is what asks for a connection.
                if ((occupancy != 0) && !fatal_q && (retry_wait_q == '0)) cs_d = CS_OPEN;
            end
            CS_OPEN: begin
                if (init_done) begin
                    if (init_error) begin
                        // Retry. A failed open leaves nothing bound and nothing sent, so there is
                        // no state to unwind; the sticky init_err_q and the watchdog report it.
                        cs_d = CS_DOWN;
                    end else begin
                        // Bind before anything can be sent, so the first notification for this
                        // session finds the queue. Nothing can answer yet -- no GET has gone out.
                        bind_en   = 1'b1;
                        conn_bind = 1'b1;
                        cs_d      = CS_UP;
                    end
                end
            end
            CS_UP: begin
                // Tear down only once both stages are parked, so send_ptr can be rolled back
                // without a transmission in progress.
                if (reconn_q && (send_state_q == ST_STAGE_IDLE) &&
                    (read_state_q == ST_STAGE_IDLE)) begin
                    cs_d = CS_CLOSE;
                end
            end
            CS_CLOSE: begin
                m_axis_close_connection_TVALID = 1'b1;
                if (m_axis_close_connection_TREADY) begin
                    release_en = 1'b1;
                    reconn_d   = 1'b0;
                    cs_d       = CS_DOWN;
                end
            end
        endcase

        // -- SEND -----------------------------------------------------------------------------
        case (send_state_q)
            ST_STAGE_IDLE: begin
                if (send_has_work && (cs_q == CS_UP) && !reconn_q && !fatal_q) begin
                    send_state_d = ST_STAGE_RUN;
                end
            end
            ST_STAGE_RUN: begin
                if (send_done) begin
                    send_advance = 1'b1;
                    send_state_d = ST_STAGE_IDLE;
                end
            end
        endcase

        // -- READ -----------------------------------------------------------------------------
        case (read_state_q)
            ST_STAGE_IDLE: begin
                if (read_has_work && (cs_q == CS_UP) && !reconn_q && !fatal_q) begin
                    read_state_d = ST_STAGE_RUN;
                end
            end
            ST_STAGE_RUN: begin
                if (read_done) begin
                    read_state_d = ST_STAGE_IDLE;
                    if (read_error) begin
                        // Do NOT advance read_ptr: this request has not been answered.
                        if (read_error_dirty) fatal_d  = 1'b1;
                        else                  reconn_d = 1'b1;
                    end else begin
                        read_advance = 1'b1;
                    end
                end
            end
        endcase
    end

    always_ff @(posedge ap_clk) begin
        if (!ap_rst_n) begin
            fill_ptr_q   <= '0;
            send_ptr_q   <= '0;
            read_ptr_q   <= '0;
            cs_q         <= CS_DOWN;
            send_state_q <= ST_STAGE_IDLE;
            read_state_q <= ST_STAGE_IDLE;
            conn_valid_q <= 1'b0;
            conn_sid_q   <= 16'd0;
            reconn_q     <= 1'b0;
            fatal_q      <= 1'b0;
            reconn_cnt_q <= '0;
            retry_wait_q <= '0;
        end else begin
            cs_q         <= cs_d;
            send_state_q <= send_state_d;
            read_state_q <= read_state_d;
            reconn_q     <= reconn_d;
            fatal_q      <= fatal_d;

            if (req_fire) begin
                slot_cfg_q[fill_idx] <= req_data;
                fill_ptr_q           <= fill_ptr_q + 1'b1;
            end
            if (send_advance) send_ptr_q <= send_ptr_q + 1'b1;
            if (read_advance) read_ptr_q <= read_ptr_q + 1'b1;

            if (retry_wait_q != '0) retry_wait_q <= retry_wait_q - 1'b1;
            if ((cs_q == CS_OPEN) && init_done && init_error) retry_wait_q <= '1;

            if (conn_bind) begin
                conn_sid_q   <= init_session_id;
                conn_valid_q <= 1'b1;
            end
            if (release_en) begin
                conn_valid_q <= 1'b0;
                // Replay: everything sent but not yet answered goes out again on the new
                // connection. The descriptors are still in their slots, so this is the whole fix.
                send_ptr_q   <= read_ptr_q;
                if (reconn_cnt_q != 8'hFF) reconn_cnt_q <= reconn_cnt_q + 8'd1;
            end
        end
    end

    // Stall watchdogs: count while a stage is running, clear when it hands its slot on. Sticky, so a
    // stall that later resolves is still visible to the host afterwards.
    always_ff @(posedge ap_clk) begin
        if (!ap_rst_n) begin
            conn_cnt_q   <= '0;
            send_cnt_q   <= '0;
            read_cnt_q   <= '0;
            conn_stall_q <= 1'b0;
            send_stall_q <= 1'b0;
            read_stall_q <= 1'b0;
            init_err_q   <= 1'b0;
            send_err_q   <= 1'b0;
            resp_err_q   <= 1'b0;
            status_bad_q <= 1'b0;
        end else begin
            if (cs_q != CS_OPEN)                             conn_cnt_q <= '0;
            else if (conn_cnt_q < STALL_BITS'(STALL_CYCLES)) conn_cnt_q <= conn_cnt_q + 1'b1;
            else                                             conn_stall_q <= 1'b1;

            if (send_advance || send_state_q == ST_STAGE_IDLE) send_cnt_q <= '0;
            else if (send_cnt_q < STALL_BITS'(STALL_CYCLES))   send_cnt_q <= send_cnt_q + 1'b1;
            else                                               send_stall_q <= 1'b1;

            if (read_advance || read_state_q == ST_STAGE_IDLE) read_cnt_q <= '0;
            else if (read_cnt_q < STALL_BITS'(STALL_CYCLES))   read_cnt_q <= read_cnt_q + 1'b1;
            else                                               read_stall_q <= 1'b1;

            // tcp_init raises `error` when openStatus comes back with success == 0. Note the
            // port-reuse failure does NOT set this: there, openStatus never arrives at all, so
            // conn_stall_q is the only signal. Keep-alive is what makes that failure rare.
            if ((cs_q == CS_OPEN) && init_done && init_error)            init_err_q   <= 1'b1;
            if ((send_state_q == ST_STAGE_RUN) && send_done && send_error) send_err_q <= 1'b1;
            if (read_resp_error)                                         resp_err_q   <= 1'b1;
            // Sample the status only once a response has been framed, so the reset value of
            // status_ascii is not mistaken for a bad status.
            if ((read_state_q == ST_STAGE_RUN) && read_done && !read_error && !read_status_ok)
                status_bad_q <= 1'b1;
        end
    end

    // Kept for the legacy 4-bit CLIENT_STATE CSR and the ILA. It multiplexes several sub-FSMs onto
    // one value and several codes alias; prefer totalWord.
    always_comb begin
        case (coarse_state)
            4'd1:    state_debug = init_state_debug;
            4'd2:    state_debug = send_state_debug;
            4'd3:    state_debug = read_state_debug;
            default: state_debug = 4'd0;
        endcase
    end

endmodule
