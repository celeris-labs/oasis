import lynxTypes::*;

// =================================================================================================
// TCP receive path for ONE HTTP response on a persistent connection.
//
// A TCP byte stream has no message boundaries and the TOE surfaces it INCREMENTALLY: it emits an
// appNotification whenever more bytes have landed (length = the bytes available right now, typically
// one segment), and a separate notification with `closed=1, length=0` when the peer FINs. So
// receiving is a LOOP, exactly like a software `while (recv() > 0)`: take the oldest announcement
// recorded for this session, issue a readPkg naming exactly its length, repeat.
//
// WHAT CHANGED FOR KEEP-ALIVE
// ---------------------------
// The end of a response used to be the FIN, and this module ran until `closed` with an empty queue.
// The connection is now persistent, so the FIN is not a frame marker any more: strip_http delimits
// each body by Content-Length and raises `resp_done` when it has drained. This module therefore
// serves exactly ONE response per activation and leaves the connection open; the handler advances
// its slot ring and starts us again for the next one.
//
// Two consequences worth spelling out:
//
//   * The 1-beat-delay concatenator is GONE. It existed to mask the per-readPkg tlast so the
//     downstream normalizer saw one continuous stream, which meant holding every beat back until
//     the next one arrived. strip_http now ignores the input tlast entirely and produces the single
//     tlast itself from the byte count, so rx_data feeds it directly -- one less register stage and
//     one less place for a seam byte to go wrong.
//
//   * A response can end in the MIDDLE of a readPkg, because a TCP segment may carry the tail of
//     body k and the head of response k+1. When that happens we stop with the packet half-consumed
//     and remember it in pkg_active_q; the next activation re-enters ST_RECV_DATA rather than
//     issuing a fresh readPkg. Backing out and re-reading is not an option -- the TOE has already
//     advanced its app read pointer for this packet.
//
// FAILURE REPORTING
// -----------------
// `error` means this activation ended without a complete response: the peer FINed with nothing left
// to read (an idle-timeout close, or a lost pipelined request), or strip_http could not frame the
// response at all. `error_dirty` says body bytes of THIS response already reached the decoder, so
// the stream is corrupt and the handler must not silently reconnect and replay. See handler.sv.
// =================================================================================================
module tcp_read (
    input  logic                                      clk,
    input  logic                                      rst_n,
    input  logic                                      start,
    input  logic [15:0]                               session_id,

    // Does this response end the decoder stream? 0 when the host split one column chunk across
    // several ranged GETs and this is not the last of them.
    input  logic                                      body_last,
    // Reset the response framer. ONLY on a new connection -- between responses it would discard the
    // residue, which holds the bytes of the next header.
    input  logic                                      clear_framing,

    // Receive accounting for this session, from tcp_session_table.
    input  logic [TCP_LEN_BITS-1:0]                   rx_req_len, // oldest unread announcement
    input  logic                                      rx_closed,  // peer has FINed (sticky)
    output logic                                      rx_take_en, // retire that announcement

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
    output logic                                      error_dirty,

    // Response framing status, surfaced to the host through HttpConfig.
    output logic                                      resp_error,
    output logic [23:0]                               status_ascii,
    output logic                                      status_ok,
    output logic [31:0]                               body_remaining,

    output logic [3:0]                                debug_rx_write_ptr,
    output logic [AXI_DATA_BITS-1:0]                  debug_rx_buffer_w0,
    output logic [AXI_DATA_BITS-1:0]                  debug_rx_buffer_w1,
    output logic [3:0]                                state_debug
);

    localparam logic [3:0] ST_IDLE        = 4'd0;
    localparam logic [3:0] ST_ARM         = 4'd1;
    localparam logic [3:0] ST_WAIT_NOTIFY = 4'd7;
    localparam logic [3:0] ST_REQ_PKG     = 4'd8;
    localparam logic [3:0] ST_RECV_DATA   = 4'd9;
    localparam logic [3:0] ST_ABORT       = 4'd11;
    localparam logic [3:0] ST_DONE        = 4'd15;

    logic [3:0] state_q, state_d;
    logic rx_meta_received_q, rx_meta_received_d;
    // A readPkg is half-consumed: the response ended inside it, so the next activation resumes in
    // ST_RECV_DATA instead of asking for another packet.
    logic pkg_active_q, pkg_active_d;
    logic [TCP_LEN_BITS-1:0] req_len_q, req_len_d;
    logic abort_dirty_q, abort_dirty_d;

    // strip_http handshake
    logic sh_resp_ack;
    logic sh_resp_done;
    logic sh_resp_dirty;
    logic sh_resp_error;

    // strip_http slave-side stream, fed straight from the TOE rx data.
    logic                       sh_s_tvalid;
    logic                       sh_s_tready;

    logic [AXI_DATA_BITS-1:0] payload_w0;
    logic [AXI_DATA_BITS-1:0] payload_w1;
    logic payload_w0_valid;
    logic payload_w1_valid;

    logic in_fire;

    assign sh_s_tvalid          = (state_q == ST_RECV_DATA) && s_axis_rx_data_TVALID;
    assign s_axis_rx_data_TREADY = (state_q == ST_RECV_DATA) && sh_s_tready;
    assign in_fire               = s_axis_rx_data_TVALID && s_axis_rx_data_TREADY;

    // One cycle in ST_ARM retires the previous response and re-arms the framer for this one.
    assign sh_resp_ack = (state_q == ST_ARM);

    strip_http inst_strip_http (
        .clk(clk),
        .rst_n(rst_n),
        .clear(clear_framing),
        .enable(1'b1),
        .body_last(body_last),
        .resp_ack(sh_resp_ack),
        .s_axis_tvalid(sh_s_tvalid),
        .s_axis_tdata(s_axis_rx_data_TDATA),
        .s_axis_tkeep(s_axis_rx_data_TKEEP),
        .s_axis_tlast(s_axis_rx_data_TLAST),
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
        .resp_done(sh_resp_done),
        .resp_dirty(sh_resp_dirty),
        .resp_error(sh_resp_error),
        .status_ascii(status_ascii),
        .status_ok(status_ok),
        .body_remaining(body_remaining),
        .out_payload_idx()
    );

    always_comb begin
        state_d            = state_q;
        rx_meta_received_d = rx_meta_received_q;
        pkg_active_d       = pkg_active_q;
        req_len_d          = req_len_q;
        abort_dirty_d      = abort_dirty_q;

        m_axis_read_package_TVALID = 1'b0;
        m_axis_read_package_TDATA  = {req_len_q, session_id};
        s_axis_rx_metadata_TREADY  = 1'b0;
        rx_take_en                 = 1'b0;

        case (state_q)
            ST_IDLE: begin
                if (start) begin
                    abort_dirty_d = 1'b0;
                    state_d       = ST_ARM;
                end
            end

            // resp_ack is asserted for this whole cycle; the framer clears resp_done on the edge.
            ST_ARM: begin
                state_d = pkg_active_q ? ST_RECV_DATA : ST_WAIT_NOTIFY;
            end

            ST_WAIT_NOTIFY: begin
                // Order matters. A complete response wins over everything: the framer may well have
                // finished it out of bytes it was already holding, with no new announcement and no
                // readPkg needed. Only then is `closed` end-of-connection rather than end-of-body,
                // and only once the announcement queue is empty -- one notification can carry both
                // the final segment and the FIN.
                if (sh_resp_error) begin
                    abort_dirty_d = sh_resp_dirty;
                    state_d       = ST_ABORT;
                end else if (sh_resp_done) begin
                    state_d = ST_DONE;
                end else if (rx_req_len != 0) begin
                    rx_take_en = 1'b1;
                    req_len_d  = rx_req_len;
                    state_d    = ST_REQ_PKG;
                end else if (rx_closed) begin
                    abort_dirty_d = sh_resp_dirty;
                    state_d       = ST_ABORT;
                end
            end

            ST_REQ_PKG: begin
                m_axis_read_package_TVALID = 1'b1;
                if (m_axis_read_package_TREADY) begin
                    rx_meta_received_d = 1'b0;
                    pkg_active_d       = 1'b1;
                    state_d            = ST_RECV_DATA;
                end
            end

            ST_RECV_DATA: begin
                // One rx metadata beat per readPkg.
                if (!rx_meta_received_q) begin
                    s_axis_rx_metadata_TREADY = 1'b1;
                    if (s_axis_rx_metadata_TVALID) rx_meta_received_d = 1'b1;
                end

                if (sh_resp_error) begin
                    abort_dirty_d = sh_resp_dirty;
                    state_d       = ST_ABORT;
                end else if (in_fire && s_axis_rx_data_TLAST) begin
                    // The packet is fully handed over. Whether it completed the response is decided
                    // back in ST_WAIT_NOTIFY, once the framer has drained it.
                    pkg_active_d = 1'b0;
                    state_d      = ST_WAIT_NOTIFY;
                end else if (sh_resp_done) begin
                    // The response ended inside this packet. Stop here with pkg_active_q set: the
                    // rest of the packet belongs to the next response and is read by the next
                    // activation, which resumes in this state.
                    state_d = ST_DONE;
                end
            end

            ST_ABORT: begin
                if (!start) state_d = ST_IDLE;
            end

            ST_DONE: begin
                if (!start) state_d = ST_IDLE;
            end

            default: state_d = ST_IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q            <= ST_IDLE;
            rx_meta_received_q <= 1'b0;
            pkg_active_q       <= 1'b0;
            req_len_q          <= '0;
            abort_dirty_q      <= 1'b0;
        end else begin
            state_q            <= state_d;
            rx_meta_received_q <= rx_meta_received_d;
            req_len_q          <= req_len_d;
            abort_dirty_q      <= abort_dirty_d;
            // A new connection throws the half-read packet away with everything else.
            pkg_active_q       <= clear_framing ? 1'b0 : pkg_active_d;
        end
    end

    assign done               = (state_q == ST_DONE) || (state_q == ST_ABORT);
    assign error              = (state_q == ST_ABORT);
    assign error_dirty        = (state_q == ST_ABORT) && abort_dirty_q;
    assign resp_error         = sh_resp_error;
    assign debug_rx_write_ptr = payload_w1_valid ? 4'd2 : payload_w0_valid ? 4'd1 : 4'd0;
    assign debug_rx_buffer_w0 = payload_w0;
    assign debug_rx_buffer_w1 = payload_w1;

    assign state_debug        = state_q;

endmodule
