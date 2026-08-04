import lynxTypes::*;
import http_types::*;

// =================================================================================================
// HTTP client handler -- pipelined over NUM_SLOTS concurrent TCP sessions.
//
// WHAT CHANGED AND WHY
// --------------------
// This used to be one sequential FSM:
//
//     ST_IDLE -> ST_TCP_INIT -> ST_TCP_SEND -> ST_TCP_READ -> ST_CLOSE -> ST_IDLE
//
// one request at a time, a fresh TCP connection per request, and `runTx` sampled only in ST_IDLE.
// Every ranged GET therefore paid, end to end and with nothing overlapping it: a three-way
// handshake, the request, the server's time-to-first-byte, the body, and a teardown. Measured
// against the decoder that consumes the body, the useful fraction of that is small -- a column
// chunk of a few hundred KB streams in tens of microseconds while the surrounding round trips cost
// hundreds. The decoder sat idle through nearly all of it.
//
// The fix is not a faster connection, it is more than one of them. The three stages are now
// independent FSMs running concurrently on a ring of slots:
//
//     fill_ptr   host pushes a request descriptor into a free slot   (one cycle, no handshake)
//     conn_ptr   CONNECT: tcp_init -> session id -> bind the slot in the session table
//     send_ptr   SEND:    tcp_send_http builds and transmits the GET
//     read_ptr   READ:    tcp_read streams the body out, then closes the session
//
// Slots are allocated, connected, sent and read strictly in order, so the ring needs no free list:
// four pointers into a circular array, each advanced by the stage that owns it, and the invariant
// read_ptr <= send_ptr <= conn_ptr <= fill_ptr (mod 2*NUM_SLOTS) falls out for free. Ordering is
// not incidental -- the bodies are concatenated into one decoder stream, so they MUST come back in
// the order the host enqueued them.
//
// The win: while slot k's body is streaming into the decoder, slot k+1 is already connected and its
// GET already sent, so the server's think-time overlaps the previous transfer instead of following
// it. With enough slots the gaps between bodies collapse to the readPkg latency.
//
// The three stages touch disjoint TOE interfaces -- open_connection, tx, rx -- so they need no
// arbitration between them. The one shared resource is the notification stream, and it is NOT
// arbitrated here: tcp_session_table owns it and records announcements per slot. That module is a
// hard prerequisite; see its header for why filtering notifications by session (what tcp_read used
// to do) silently breaks the moment a second connection is open.
//
// NOT DONE HERE: HTTP keep-alive. Every request still gets its own connection, because the response
// is delimited by the server's FIN -- strip_http finds \r\n\r\n and then streams until tlast, with
// no Content-Length parsing and no way to re-synchronise mid-beat on the next response's header.
// Sharing one connection means byte-exact reframing inside the module that is already the worst
// timing path in the design. Pipelining hides the connection cost instead of removing it, for a
// fraction of the risk. See docs and the README.
//
// ERROR HANDLING is unchanged, which is to say minimal: init_error and send_error are surfaced in
// the status word but not acted on. A connection that fails to open still advances the pipeline and
// its read will stall, which stalls everything behind it -- the same failure the single-session
// design had, not a new one. There is still no reset CSR; reprogramming clears a wedge.
// =================================================================================================
module handler #(
    // Requests in flight. Each costs one slot's worth of descriptor storage plus one concurrently
    // open TCP session, so this is the knob that trades area and TOE session-table pressure for
    // hidden latency. The host must not enqueue more than this many outstanding requests; it reads
    // the occupancy back through HttpConfig (see http_config.sv, INFLIGHT register).
    parameter int NUM_SLOTS = 4
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
    output logic [3:0]                                state_debug
);

    localparam int PTR_BITS = $clog2(NUM_SLOTS) + 1; // one extra bit so full and empty differ
    // Clamped to 1 so NUM_SLOTS==1 -- pipelining off, the debugging fallback -- still elaborates;
    // $clog2(1) is 0 and would give [-1:0] index ports. At that width the pointer's low bit is not
    // a valid slot index, so the index is forced to 0 below.
    localparam int IDX_BITS = (NUM_SLOTS > 1) ? $clog2(NUM_SLOTS) : 1;

    // The pointers wrap at 2**PTR_BITS and the slot index is the low bits of the pointer, so
    // `occupancy = fill - read` is only correct when the ring size divides the pointer range --
    // i.e. for powers of two. 8 is the ceiling because the per-slot debug bitmaps in inflightWord
    // are one byte each.
    if (NUM_SLOTS < 1 || NUM_SLOTS > 8)      $error("handler: NUM_SLOTS must be between 1 and 8");
    if (NUM_SLOTS & (NUM_SLOTS - 1))         $error("handler: NUM_SLOTS must be a power of two");

    // ---------------------------------------------------------------------------------------------
    // Slot ring. fill -> conn -> send -> read, each pointer owned by exactly one stage.
    // ---------------------------------------------------------------------------------------------
    http_config_t              slot_cfg_q [NUM_SLOTS];
    logic [15:0]               slot_sid_q [NUM_SLOTS];

    logic [PTR_BITS-1:0] fill_ptr_q, conn_ptr_q, send_ptr_q, read_ptr_q;

    logic [IDX_BITS-1:0] fill_idx, conn_idx, send_idx, read_idx;
    assign fill_idx = (NUM_SLOTS > 1) ? fill_ptr_q[IDX_BITS-1:0] : '0;
    assign conn_idx = (NUM_SLOTS > 1) ? conn_ptr_q[IDX_BITS-1:0] : '0;
    assign send_idx = (NUM_SLOTS > 1) ? send_ptr_q[IDX_BITS-1:0] : '0;
    assign read_idx = (NUM_SLOTS > 1) ? read_ptr_q[IDX_BITS-1:0] : '0;

    logic [PTR_BITS-1:0] occupancy;
    assign occupancy = fill_ptr_q - read_ptr_q;

    // A stage has work when its pointer trails the stage in front of it.
    logic conn_has_work, send_has_work, read_has_work;
    assign conn_has_work = (conn_ptr_q != fill_ptr_q);
    assign send_has_work = (send_ptr_q != conn_ptr_q);
    assign read_has_work = (read_ptr_q != send_ptr_q);

    // Accept a request whenever the ring has room. Purely combinational on occupancy, so the host's
    // START write is absorbed in one cycle and never has to wait behind a connection.
    assign req_ready = (occupancy < PTR_BITS'(NUM_SLOTS));
    logic req_fire;
    assign req_fire = req_valid && req_ready;

    // ---------------------------------------------------------------------------------------------
    // Sub-FSM handshakes
    // ---------------------------------------------------------------------------------------------
    logic init_done, init_error;
    logic [15:0] init_session_id;
    logic [3:0]  init_state_debug;

    logic send_done, send_error;
    logic [3:0]  send_state_debug;

    logic read_done, read_error;
    logic [3:0]  read_state_debug;

    // Stage FSMs. Each sub-module latches `start` as a level and parks in its own DONE state until
    // start drops, so each stage needs an idle cycle between runs -- which the IDLE state provides.
    localparam logic ST_STAGE_IDLE = 1'b0;
    localparam logic ST_STAGE_RUN  = 1'b1;

    logic conn_state_q, conn_state_d;
    logic send_state_q, send_state_d;
    logic [1:0] read_state_q, read_state_d;

    localparam logic [1:0] ST_READ_IDLE  = 2'd0;
    localparam logic [1:0] ST_READ_RUN   = 2'd1;
    localparam logic [1:0] ST_READ_CLOSE = 2'd2;

    // ---------------------------------------------------------------------------------------------
    // Session table: owns the notification stream, tracks per-slot pending bytes and FIN.
    // ---------------------------------------------------------------------------------------------
    logic                bind_en;
    logic [IDX_BITS-1:0] bind_slot;
    logic [15:0]         bind_sid;
    logic                release_en;
    logic [IDX_BITS-1:0] release_slot;

    logic [31:0]             tbl_pending;
    logic [TCP_LEN_BITS-1:0] tbl_req_len;
    logic                    tbl_closed;
    logic                    tbl_bound;
    logic                    tbl_take_en;
    logic [TCP_LEN_BITS-1:0] tbl_take_len;
    logic [NUM_SLOTS-1:0]    tbl_dbg_has_pending;
    logic [NUM_SLOTS-1:0]    tbl_dbg_closed;

    tcp_session_table #(
        .NUM_SLOTS(NUM_SLOTS)
    ) inst_session_table (
        .clk  (ap_clk),
        .rst_n(ap_rst_n),

        .s_axis_notifications_TVALID(s_axis_notifications_TVALID),
        .s_axis_notifications_TREADY(s_axis_notifications_TREADY),
        .s_axis_notifications_TDATA (s_axis_notifications_TDATA),

        .bind_en     (bind_en),
        .bind_slot   (bind_slot),
        .bind_sid    (bind_sid),
        .release_en  (release_en),
        .release_slot(release_slot),

        // The read stage is the only consumer, so the query port simply follows read_idx.
        .q_slot   (read_idx),
        .q_pending(tbl_pending),
        .q_req_len(tbl_req_len),
        .q_closed (tbl_closed),
        .q_bound  (tbl_bound),

        .take_en (tbl_take_en),
        .take_len(tbl_take_len),

        .dbg_has_pending(tbl_dbg_has_pending),
        .dbg_closed     (tbl_dbg_closed)
    );

    // ---------------------------------------------------------------------------------------------
    // Status word, surfaced on HttpConfig read register 2.
    //   [3:0]   coarse pipeline state (0 = idle, else the furthest-along active stage)
    //   [7:4]   tcp_init      state_debug
    //   [11:8]  tcp_send_http state_debug
    //   [15:12] tcp_read      state_debug
    //   [16]    init_done   [17] init_error
    //   [18]    send_done   [19] send_error
    //   [20]    read_done   [21] read_error
    //   [22]    busy (any slot occupied)  -- NOTE: with pipelining this is the NORMAL state during a
    //           scan, not an error. It no longer means "a new request would be dropped"; the host
    //           must look at inflightWord for that. The old software guard that refused to issue a
    //           request while this bit was set would now reject every pipelined request.
    //   [23]    req_ready (the ring has room)
    //   [31:24] session_id[7:0] of the slot being read
    // ---------------------------------------------------------------------------------------------
    logic [3:0] coarse_state;
    always_comb begin
        if (read_has_work)      coarse_state = 4'd3; // a body is streaming
        else if (send_has_work) coarse_state = 4'd2;
        else if (conn_has_work) coarse_state = 4'd1;
        else                    coarse_state = 4'd0;
    end

    assign totalWord = {slot_sid_q[read_idx][7:0],
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
    //   [23:16] per-slot "has pending bytes" bitmap
    //   [31:24] per-slot "peer closed" bitmap
    assign inflightWord = {8'(tbl_dbg_closed),
                           8'(tbl_dbg_has_pending),
                           8'(NUM_SLOTS),
                           8'(occupancy)};

    // ---------------------------------------------------------------------------------------------
    // CONNECT stage
    // ---------------------------------------------------------------------------------------------
    tcp_init inst_tcp_init (
        .clk(ap_clk),
        .rst_n(ap_rst_n),
        .start(conn_state_q == ST_STAGE_RUN),
        .serverIpAddress(slot_cfg_q[conn_idx].server_ip),
        .serverPort(slot_cfg_q[conn_idx].server_port),
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
        .session_id(slot_sid_q[send_idx]),
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
    // READ stage
    // ---------------------------------------------------------------------------------------------
    tcp_read inst_tcp_read (
        .clk(ap_clk),
        .rst_n(ap_rst_n),
        .start(read_state_q == ST_READ_RUN),
        .session_id(slot_sid_q[read_idx]),

        .rx_req_len (tbl_req_len),
        .rx_closed  (tbl_closed),
        .rx_take_en (tbl_take_en),
        .rx_take_len(tbl_take_len),

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
    logic conn_advance, send_advance, read_advance;

    always_comb begin
        conn_state_d = conn_state_q;
        send_state_d = send_state_q;
        read_state_d = read_state_q;

        conn_advance = 1'b0;
        send_advance = 1'b0;
        read_advance = 1'b0;

        bind_en      = 1'b0;
        bind_slot    = conn_idx;
        bind_sid     = init_session_id;
        release_en   = 1'b0;
        release_slot = read_idx;

        m_axis_close_connection_TVALID = 1'b0;
        m_axis_close_connection_TDATA  = slot_sid_q[read_idx][TCP_CLOSE_CONN_REQ_BITS-1:0];

        // -- CONNECT --------------------------------------------------------------------------
        case (conn_state_q)
            ST_STAGE_IDLE: begin
                if (conn_has_work) conn_state_d = ST_STAGE_RUN;
            end
            ST_STAGE_RUN: begin
                if (init_done) begin
                    // Bind before advancing: the session id must be recorded in the table before the
                    // GET goes out, or the first notification for it would find no slot and be
                    // dropped. Nothing can answer yet, since the request has not been sent.
                    bind_en      = 1'b1;
                    conn_advance = 1'b1;
                    conn_state_d = ST_STAGE_IDLE;
                end
            end
        endcase

        // -- SEND -----------------------------------------------------------------------------
        case (send_state_q)
            ST_STAGE_IDLE: begin
                if (send_has_work) send_state_d = ST_STAGE_RUN;
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
            ST_READ_IDLE: begin
                // The idle cycles here are also what pulses tcp_read's `clear` down to strip_http,
                // resetting the header search between responses.
                if (read_has_work) read_state_d = ST_READ_RUN;
            end
            ST_READ_RUN: begin
                if (read_done) read_state_d = ST_READ_CLOSE;
            end
            ST_READ_CLOSE: begin
                m_axis_close_connection_TVALID = 1'b1;
                if (m_axis_close_connection_TVALID && m_axis_close_connection_TREADY) begin
                    release_en   = 1'b1;
                    read_advance = 1'b1;
                    read_state_d = ST_READ_IDLE;
                end
            end
            default: read_state_d = ST_READ_IDLE;
        endcase
    end

    always_ff @(posedge ap_clk) begin
        if (!ap_rst_n) begin
            fill_ptr_q   <= '0;
            conn_ptr_q   <= '0;
            send_ptr_q   <= '0;
            read_ptr_q   <= '0;
            conn_state_q <= ST_STAGE_IDLE;
            send_state_q <= ST_STAGE_IDLE;
            read_state_q <= ST_READ_IDLE;
            for (int i = 0; i < NUM_SLOTS; i++) begin
                slot_sid_q[i] <= 16'd0;
            end
        end else begin
            conn_state_q <= conn_state_d;
            send_state_q <= send_state_d;
            read_state_q <= read_state_d;

            if (req_fire) begin
                slot_cfg_q[fill_idx] <= req_data;
                fill_ptr_q           <= fill_ptr_q + 1'b1;
            end
            if (conn_advance) begin
                slot_sid_q[conn_idx] <= init_session_id;
                conn_ptr_q           <= conn_ptr_q + 1'b1;
            end
            if (send_advance) send_ptr_q <= send_ptr_q + 1'b1;
            if (read_advance) read_ptr_q <= read_ptr_q + 1'b1;
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
