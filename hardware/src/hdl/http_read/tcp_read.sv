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
module tcp_read #(
    // Beats of slack between the TCP stack and the parser. The header walk is the worst case: a
    // MinIO 206 header is ~550 bytes at one byte per cycle, during which 550 beats can arrive at
    // line rate. 1024 x 64 B = 64 KiB covers that with room to spare and costs a handful of BRAMs.
    // 4096 x 64 B = 256 KiB. Was 1024 (64 KiB), which measured too small: on build-94 the sticky
    // rx_fifo_stall bit SET during a scale-30 run at the 128 KiB chunk size, meaning the fifo filled
    // and back-pressure reached the TOE again -- the exact condition this fifo exists to prevent,
    // and the reason larger chunks stopped paying off in scripts/sweep.sh.
    //
    // Sized against what has to fit: one response (up to OASIS_HTTP_CHUNK_BYTES) plus the ~35 KB the
    // parser's header walk lets accumulate behind it. At 64 KiB that left nothing spare beyond a
    // 32 KiB response. 256 KiB covers a 128 KiB chunk with room, and matches the window the TOE
    // already advertises (2^18), so the host can stop sizing requests around a buffer that is
    // smaller than what the stack promises the sender.
    //
    // Cost is 64 RAMB36 instead of 16, out of 2016 on the U55C -- the design uses 25.8%.
    parameter int RX_FIFO_DEPTH = 4096
) (
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
    output logic [31:0]                               content_length,
    output logic [31:0]                               body_remaining,

    // Decoupling fifo occupancy, and a sticky bit saying the TCP stack was ever back-pressured
    // anyway. If rx_fifo_stall ever sets, the fifo is undersized and we are back to stalling the
    // TOE -- exactly what this whole change exists to prevent, so it is worth a CSR bit.
    output logic [$clog2(RX_FIFO_DEPTH+1)-1:0]        rx_fifo_level,
    output logic                                      rx_fifo_stall,

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
    localparam logic [3:0] ST_DRAIN       = 4'd10;
    localparam logic [3:0] ST_ABORT       = 4'd11;
    localparam logic [3:0] ST_DONE        = 4'd15;

    logic [3:0] state_q, state_d;
    logic rx_meta_received_q, rx_meta_received_d;
    // A readPkg is half-consumed: the response ended inside it, so the next activation resumes in
    // ST_RECV_DATA instead of asking for another packet.
    logic pkg_active_q, pkg_active_d;
    logic [TCP_LEN_BITS-1:0] req_len_q, req_len_d;
    logic abort_dirty_q, abort_dirty_d;

    // Settle timer for ST_DRAIN. Reloaded while the parser still has something to chew on, counted
    // down only once the fifo is empty. 200 cycles is comfortably more than the 64 it takes
    // strip_http to walk a full residue beat at one byte per cycle.
    localparam logic [7:0] DRAIN_SETTLE = 8'd200;
    logic [7:0] drain_cnt_q, drain_cnt_d;
    logic       parser_quiet_w, drain_settled_w; // driven below, once the fifo signals exist

    // strip_http handshake
    logic sh_resp_ack;
    logic sh_resp_done;
    logic sh_resp_dirty;
    logic sh_resp_error;

    // strip_http slave-side stream. NOT fed straight from the TOE any more -- see inst_rx_fifo.
    logic                       sh_s_tvalid;
    logic                       sh_s_tready;
    logic [AXI_DATA_BITS-1:0]   sh_s_tdata;
    logic [AXI_DATA_BITS/8-1:0] sh_s_tkeep;
    logic                       sh_s_tlast;

    // TOE-side of the fifo.
    logic                       fifo_s_tvalid;
    logic                       fifo_s_tready;

    logic [AXI_DATA_BITS-1:0] payload_w0;
    logic [AXI_DATA_BITS-1:0] payload_w1;
    logic payload_w0_valid;
    logic payload_w1_valid;

    logic in_fire;

    // THE DECOUPLING. TREADY towards the TCP stack is now decided by fifo space, never by whether
    // strip_http happens to be free. The parser walks header bytes one per cycle; while it did that
    // it used to hold TREADY low and let the TOE's single shared 64 KB rx fifo fill behind it --
    // ~35 KB of backlog per response, which is why a 32 KiB response worked and a 64 KiB one fell
    // off a cliff at every pipeline depth. See axis_fifo.sv for the full derivation.
    assign fifo_s_tvalid         = (state_q == ST_RECV_DATA) && s_axis_rx_data_TVALID;
    assign s_axis_rx_data_TREADY = (state_q == ST_RECV_DATA) && fifo_s_tready;
    assign in_fire               = s_axis_rx_data_TVALID && s_axis_rx_data_TREADY;

    axis_fifo #(
        .DATA_BITS(AXI_DATA_BITS),
        .DEPTH(RX_FIFO_DEPTH)
    ) inst_rx_fifo (
        .clk(clk),
        .rst_n(rst_n),
        // Only on a new connection. Between responses the residue is the next header.
        .clear(clear_framing),
        .s_axis_tvalid(fifo_s_tvalid),
        .s_axis_tready(fifo_s_tready),
        .s_axis_tdata(s_axis_rx_data_TDATA),
        .s_axis_tkeep(s_axis_rx_data_TKEEP),
        .s_axis_tlast(s_axis_rx_data_TLAST),
        .m_axis_tvalid(sh_s_tvalid),
        .m_axis_tready(sh_s_tready),
        .m_axis_tdata(sh_s_tdata),
        .m_axis_tkeep(sh_s_tkeep),
        .m_axis_tlast(sh_s_tlast),
        .level(rx_fifo_level),
        .overflow_stall(rx_fifo_stall)
    );

    // Nothing left anywhere between the TCP stack and the parser: the fifo is empty and its output
    // register has been taken. Used by ST_DRAIN to know when resp_dirty is finally trustworthy.
    assign parser_quiet_w  = (rx_fifo_level == '0) && !sh_s_tvalid;
    assign drain_settled_w = parser_quiet_w && (drain_cnt_q == 8'd0);

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
        .resp_done(sh_resp_done),
        .resp_dirty(sh_resp_dirty),
        .resp_error(sh_resp_error),
        .status_ascii(status_ascii),
        .status_ok(status_ok),
        .content_length(content_length),
        .body_remaining(body_remaining),
        .out_payload_idx()
    );

    always_comb begin
        state_d            = state_q;
        rx_meta_received_d = rx_meta_received_q;
        pkg_active_d       = pkg_active_q;
        req_len_d          = req_len_q;
        abort_dirty_d      = abort_dirty_q;
        // Hold the timer reloaded everywhere except ST_DRAIN, and reload it inside ST_DRAIN for as
        // long as the parser still has work, so only genuine quiet counts towards settling.
        drain_cnt_d        = (state_q == ST_DRAIN && parser_quiet_w && drain_cnt_q != 8'd0)
                             ? drain_cnt_q - 8'd1 : DRAIN_SETTLE;

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
                    state_d = ST_DRAIN;
                end
            end

            // The peer has closed and no announcements are left, so no further bytes will ever
            // arrive -- but the decoupling fifo may still hold some, and strip_http walks header
            // bytes one per cycle. Sampling resp_dirty now would report CLEAN for a response whose
            // body bytes are still queued, the handler would treat the abort as replayable, and
            // those bytes would be duplicated in the decoder stream. So: let the parser finish
            // everything already pulled, and only then decide.
            ST_DRAIN: begin
                if (sh_resp_error) begin
                    abort_dirty_d = sh_resp_dirty;
                    state_d       = ST_ABORT;
                end else if (sh_resp_done) begin
                    state_d = ST_DONE;
                end else if (drain_settled_w) begin
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
                    // The packet is fully handed over TO THE FIFO. Whether it completed the
                    // response is decided back in ST_WAIT_NOTIFY, once the framer has drained it.
                    pkg_active_d = 1'b0;
                    state_d      = ST_WAIT_NOTIFY;
                end
                // resp_done is deliberately NOT an exit from this state any more.
                //
                // Before the fifo, ingress and parsing were the same act, so a response finishing
                // mid-packet had to stop the read and leave the remainder for the next activation
                // (that is what pkg_active_q was for). Now they are separate: the bytes after a
                // response boundary belong to the next response and we want them pulled out of the
                // TOE's shared fifo immediately, not left sitting there while the handler
                // re-activates us. Stopping here would reintroduce exactly the stall this fifo
                // exists to remove -- and with more than one session it would hand the next
                // session's bytes to the wrong reader.
                //
                // Completion is therefore recognised only in ST_WAIT_NOTIFY, which already tests
                // sh_resp_done before it looks for more announcements.
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
            drain_cnt_q        <= DRAIN_SETTLE;
        end else begin
            state_q            <= state_d;
            rx_meta_received_q <= rx_meta_received_d;
            req_len_q          <= req_len_d;
            abort_dirty_q      <= abort_dirty_d;
            drain_cnt_q        <= drain_cnt_d;
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
