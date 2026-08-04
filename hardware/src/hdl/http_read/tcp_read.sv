import lynxTypes::*;

// TCP receive path for one HTTP ranged-GET response.
//
// A TCP byte stream has no message boundaries and the TOE surfaces it INCREMENTALLY: it emits an
// appNotification whenever more bytes have landed (length = bytes available *right now*, typically
// one segment), and a separate notification with `closed=1, length=0` when the peer FINs. The
// server sends `Connection: close`, so it transmits the whole response and then closes.
//
// The correct way to receive the full body is therefore a LOOP, exactly like a software
// `while (recv() > 0)`: keep asking for whatever has arrived for THIS session, issue a readPkg for
// it, and stop when the peer has FINed and the balance is empty. Reading a single notification and
// quitting (the original behaviour) returned only whatever had arrived by the first read -- a
// timing-dependent fragment -- which was the "requested N, got 690/367" truncation.
//
// WHERE THE NOTIFICATIONS WENT
// ----------------------------
// This module used to pop the notification stream itself and discard everything that was not for
// its own session. That silently breaks as soon as a second connection is open: the announcement
// for the other session is consumed and thrown away, and when the reader turns to it, it blocks
// forever on news that already came and went. Since pipelining exists precisely to have the next
// response in flight while this one drains, notifications are now owned by tcp_session_table, which
// records them per slot. This module just reads the balance for its slot and tells the table how
// much of it was requested. See tcp_session_table.sv.
//
// strip_http and the downstream DataNormalizer expect ONE continuous stream terminated by a single
// tlast (the normalizer accumulates a running byte offset and only resets on tlast). But each
// readPkg from the TOE ends in its own tlast. So a 1-beat-delay "concatenator" sits between the TOE
// rx_data and strip_http: it holds the most recent beat and only emits it once it knows whether
// another beat follows -- with tlast=0 when the next readPkg's first beat arrives, or with tlast=1
// when the FSM has seen `closed` and flushes the held beat as the final one. This masks every
// per-readPkg tlast and produces the single-tlast stream the rest of the pipeline was built for.
module tcp_read (
    input  logic                                      clk,
    input  logic                                      rst_n,
    input  logic                                      start,
    input  logic [15:0]                               session_id,

    // Receive accounting for THIS response's slot, from tcp_session_table.
    input  logic [TCP_LEN_BITS-1:0]                   rx_req_len, // min(balance, MAX_READ_BYTES)
    input  logic                                      rx_closed,  // peer has FINed (sticky)
    output logic                                      rx_take_en, // we just requested rx_take_len
    output logic [TCP_LEN_BITS-1:0]                   rx_take_len,

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

    output logic                       m_axis_body_tvalid,
    input  logic                       m_axis_body_tready,
    output logic [AXI_DATA_BITS-1:0]   m_axis_body_tdata,
    output logic [AXI_DATA_BITS/8-1:0] m_axis_body_tkeep,
    output logic                       m_axis_body_tlast,

    output logic                                      done,
    output logic                                      error,
    output logic [3:0]                                debug_rx_write_ptr,
    output logic [AXI_DATA_BITS-1:0]                  debug_rx_buffer_w0,
    output logic [AXI_DATA_BITS-1:0]                  debug_rx_buffer_w1,
    output logic [3:0]                                state_debug
);

    localparam logic [3:0] ST_IDLE          = 4'd0;
    localparam logic [3:0] ST_WAIT_NOTIFY   = 4'd7;
    localparam logic [3:0] ST_REQ_PKG       = 4'd8;
    localparam logic [3:0] ST_RECV_DATA     = 4'd9;
    localparam logic [3:0] ST_FINISH        = 4'd10;
    localparam logic [3:0] ST_DONE          = 4'd15;

    logic [3:0] state_q, state_d;
    logic rx_meta_received_q, rx_meta_received_d;
    // Length of the readPkg currently being issued / received.
    logic [TCP_LEN_BITS-1:0] req_len_q, req_len_d;

    // ---------------------------------------------------------------
    // 1-beat-delay concatenator (holds the most recent rx beat)
    // ---------------------------------------------------------------
    logic [AXI_DATA_BITS-1:0]   hold_data_q, hold_data_d;
    logic [AXI_DATA_BITS/8-1:0] hold_keep_q, hold_keep_d;
    logic                       hold_valid_q, hold_valid_d;

    logic emit_last;  // ST_FINISH: the held beat is the final beat of the whole body

    // strip_http slave-side stream, driven by the concatenator (not rx_data directly)
    logic                       sh_s_tvalid;
    logic [AXI_DATA_BITS-1:0]   sh_s_tdata;
    logic [AXI_DATA_BITS/8-1:0] sh_s_tkeep;
    logic                       sh_s_tlast;
    logic                       sh_s_tready;

    logic payload_done;
    logic [AXI_DATA_BITS-1:0] payload_w0;
    logic [AXI_DATA_BITS-1:0] payload_w1;
    logic payload_w0_valid;
    logic payload_w1_valid;

    logic in_fire, out_fire;

    // Present the held beat to strip_http only once its tlast status is known: either a new rx beat
    // is available (held is NOT last -> tlast=0) or the FSM is flushing (held IS last -> tlast=1).
    assign sh_s_tvalid = hold_valid_q && (s_axis_rx_data_TVALID || emit_last);
    assign sh_s_tdata  = hold_data_q;
    assign sh_s_tkeep  = hold_keep_q;
    assign sh_s_tlast  = emit_last;
    assign out_fire    = sh_s_tvalid && sh_s_tready;

    // Accept a new rx beat only while receiving a readPkg; there is room when the hold slot is empty
    // or is being emitted this cycle.
    assign s_axis_rx_data_TREADY = (state_q == ST_RECV_DATA) && (!hold_valid_q || out_fire);
    assign in_fire               = s_axis_rx_data_TVALID && s_axis_rx_data_TREADY;

    always_comb begin
        hold_data_d  = hold_data_q;
        hold_keep_d  = hold_keep_q;
        hold_valid_d = hold_valid_q;
        if (in_fire) begin
            hold_data_d  = s_axis_rx_data_TDATA;
            hold_keep_d  = s_axis_rx_data_TKEEP;
            hold_valid_d = 1'b1;
        end else if (out_fire) begin
            hold_valid_d = 1'b0;
        end
    end

    strip_http inst_strip_http (
        .clk(clk),
        .rst_n(rst_n),
        // Reset the header search only while idle; keep it live across the whole (multi-readPkg)
        // body so the header is stripped exactly once and the body streams continuously.
        .clear(state_q == ST_IDLE),
        .enable(state_q != ST_IDLE && state_q != ST_DONE),
        .s_axis_tvalid(sh_s_tvalid),
        .s_axis_tdata(sh_s_tdata),
        .s_axis_tkeep(sh_s_tkeep),
        .s_axis_tlast(sh_s_tlast),
        .s_axis_tready(sh_s_tready),
        .m_axis_tvalid(m_axis_body_tvalid),
        .m_axis_tdata(m_axis_body_tdata),
        .m_axis_tkeep(m_axis_body_tkeep),
        .m_axis_tlast(m_axis_body_tlast),
        .m_axis_tready(m_axis_body_tready),
        .out_w0(payload_w0),
        .out_w1(payload_w1),
        .out_w0_valid(payload_w0_valid),
        .out_w1_valid(payload_w1_valid),
        .done(payload_done),
        .out_payload_idx()
    );

    always_comb begin
        state_d             = state_q;
        rx_meta_received_d  = rx_meta_received_q;
        req_len_d           = req_len_q;

        m_axis_read_package_TVALID  = 1'b0;
        m_axis_read_package_TDATA   = {req_len_q, session_id};
        s_axis_rx_metadata_TREADY   = 1'b0;
        emit_last                   = 1'b0;
        rx_take_en                  = 1'b0;
        rx_take_len                 = rx_req_len;

        case (state_q)
            ST_IDLE: begin
                if (start) begin
                    rx_meta_received_d = 1'b0;
                    state_d            = ST_WAIT_NOTIFY;
                end
            end

            ST_WAIT_NOTIFY: begin
                // Take whatever the session table has recorded for us. Order matters: drain the
                // balance first and only treat `closed` as end-of-body once nothing is left, because
                // one notification can carry both the final segment and the FIN.
                if (rx_req_len != 0) begin
                    rx_take_en = 1'b1;
                    req_len_d  = rx_req_len;
                    state_d    = ST_REQ_PKG;
                end else if (rx_closed) begin
                    state_d = ST_FINISH;
                end
            end

            ST_REQ_PKG: begin
                m_axis_read_package_TVALID = 1'b1;
                if (m_axis_read_package_TVALID && m_axis_read_package_TREADY) begin
                    rx_meta_received_d = 1'b0;
                    state_d            = ST_RECV_DATA;
                end
            end

            ST_RECV_DATA: begin
                // One rx metadata beat per readPkg.
                if (s_axis_rx_metadata_TVALID && s_axis_rx_metadata_TREADY) begin
                    rx_meta_received_d = 1'b1;
                end
                if (!rx_meta_received_q) begin
                    s_axis_rx_metadata_TREADY = 1'b1;
                end

                // rx_data flows into the concatenator (see combinational block above). This readPkg
                // ends on its rx tlast; the last beat is now held. Go back and look for more -- the
                // balance may already hold the next segment, and `closed` is only honoured there.
                if (in_fire && s_axis_rx_data_TLAST) begin
                    state_d = ST_WAIT_NOTIFY;
                end
            end

            ST_FINISH: begin
                // Flush the held (final) beat with tlast=1, then wait for strip_http (and its skid
                // buffer) to fully drain the body downstream.
                emit_last = 1'b1;
                if (payload_done) begin
                    state_d = ST_DONE;
                end
            end

            ST_DONE: begin
                if (!start) begin
                    state_d = ST_IDLE;
                end
            end

            default: state_d = ST_IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q            <= ST_IDLE;
            rx_meta_received_q <= 1'b0;
            req_len_q          <= '0;
            hold_data_q        <= '0;
            hold_keep_q        <= '0;
            hold_valid_q       <= 1'b0;
        end else begin
            state_q            <= state_d;
            rx_meta_received_q <= rx_meta_received_d;
            req_len_q          <= req_len_d;
            hold_data_q        <= hold_data_d;
            hold_keep_q        <= hold_keep_d;
            hold_valid_q       <= hold_valid_d;
        end
    end

    assign done               = (state_q == ST_DONE);
    assign error              = 1'b0;
    assign debug_rx_write_ptr = payload_w1_valid ? 4'd2 : payload_w0_valid ? 4'd1 : 4'd0;
    assign debug_rx_buffer_w0 = payload_w0;
    assign debug_rx_buffer_w1 = payload_w1;

    assign state_debug        = (state_q == ST_DONE) ? 4'd9 : state_q;

endmodule
