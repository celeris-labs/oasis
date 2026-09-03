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
    //
    // 4096 -> 8192 (256 KiB -> 512 KiB), build-105. This is slack, not a fix. The decoder ingests
    // Snappy at ~615 MB/s measured (one vhsnunzip unbuffered core, ~5.5 B/cycle by its own README)
    // while the server delivers faster, so the imbalance is permanent and no fifo size makes it go
    // away. What the extra depth buys is TIME: tcp_read can keep issuing readPkg, which advances
    // rxSar.appd, which keeps the advertised window above rx_engine's 24000-byte accept floor for
    // roughly twice as long. Doubling absorbs ~1.3 ms of the imbalance instead of ~0.64 ms.
    //
    // The actual fix is the window clamp in rx_sar_table.cpp, which stops a dip below that floor
    // being catastrophic. This only makes the dips rarer. Cost: 128 RAMB36, +3.2% of the device.
    parameter int RX_FIFO_DEPTH = 8192,

    // Cycles to wait for ANY progress before giving up on a response. At 250 MHz, 2^29 is ~2.1 s.
    //
    // ST_WAIT_NOTIFY used to have no way out at all: it left only when the framer finished, an
    // announcement arrived, or the connection closed. After a reconnect none of those can happen if
    // the pending announcement was bound to the session that just died -- the reader waits on a
    // notification that no longer exists and the query hangs until the host's 30 s credit timeout,
    // leaving the handler outside ST_IDLE where only reprogramming clears it. That cost a 900 s
    // scale-30 timeout and a board cycle.
    //
    // A response should land in single-digit milliseconds; the slowest ever measured against MinIO
    // was ~8 ms. Two seconds is three orders of magnitude of headroom, so this fires only when
    // something is genuinely never going to arrive -- and then it aborts, which the handler already
    // knows how to turn into a reconnect and replay.
    parameter int WATCHDOG_BITS = 29,

    // 0 (default): this module owns the receive path -- it consumes tcp_session_table's
    //    announcements, issues its own readPkg, and consumes one rx_metadata beat per packet.
    //    Correct for exactly ONE session, which is what the single-connection handler holds.
    //
    // 1: rx_dispatch owns all of that, for N sessions at once. Data arrives here PRE-ROUTED on
    //    s_axis_rx_data_* -- already selected for this lane and already in global arrival order --
    //    so ST_WAIT_NOTIFY and ST_REQ_PKG have nothing to do and are skipped. The notification and
    //    readPkg ports are tied off; rx_space_ok is what this lane offers back to the dispatcher.
    //
    //    The framer, the decoupling fifo and the response state machine are IDENTICAL in both
    //    modes: each lane still sees one ordered single-session HTTP byte stream, which is the
    //    whole reason a per-lane strip_http needs no new logic.
    parameter bit EXTERNAL_DISPATCH = 0
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
    output logic                                      read_timeout,
    output logic [23:0]                               status_ascii,
    output logic                                      status_ok,
    output logic [31:0]                               content_length,
    output logic [31:0]                               body_remaining,

    // Decoupling fifo occupancy, and a sticky bit saying the TCP stack was ever back-pressured
    // anyway. If rx_fifo_stall ever sets, the fifo is undersized and we are back to stalling the
    // TOE -- exactly what this whole change exists to prevent, so it is worth a CSR bit.
    output logic [$clog2(RX_FIFO_DEPTH+1)-1:0]        rx_fifo_level,
    output logic                                      rx_fifo_stall,

    // EXTERNAL_DISPATCH only: room for a WHOLE MSS, not for one beat. rx_dispatch gates its
    // readPkg on this, and once it issues, every beat of that packet is accepted unconditionally --
    // so a lane that says "ok" with room for less than a full segment forces the dispatcher to
    // stall the shared stream, which stalls every other lane too. That is the one failure this
    // whole arrangement exists to avoid, so the margin is deliberate.
    output logic                                      rx_space_ok,

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

    // Progress watchdog. Cleared by any forward motion, counted while waiting.
    logic [WATCHDOG_BITS-1:0] wdog_q, wdog_d;
    logic                     wdog_expired;
    logic                     wdog_timeout_q, wdog_timeout_d;
    assign wdog_expired = (wdog_q == '1);

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
    //
    // AND, UNDER EXTERNAL DISPATCH, DECOUPLED FROM THIS FSM AS WELL.
    //
    // rx_dispatch accepts every beat of a packet it has issued a readPkg for, unconditionally --
    // that line is what keeps the TOE's single shared fifo draining for all the other lanes, so it
    // must never gain a term. The beats it routes here therefore arrive whether or not this state
    // machine happens to be in ST_RECV_DATA, and it is NOT: between two responses the reader walks
    // ST_DONE -> ST_IDLE -> ST_ARM -> ST_RECV_DATA, four cycles during which the old gate held
    // TREADY low. Those beats were pulled off the shared bus by the dispatcher and silently
    // dropped, and a response boundary lands mid-packet often enough that this is not rare -- it is
    // the difference between a hang (before the re-arm fix in handler_multi) and corruption after.
    //
    // So under external dispatch the FIFO decides, and only the FIFO: it has room or it does not.
    // Its s_axis_tready is independent of `clear`, so a lane being torn down still consumes what is
    // routed to it -- and DISCARDS it, because those bytes belong to a session that no longer
    // exists. Discarding is the point: stalling instead would back-pressure the shared bus.
    //
    // The EXTERNAL_DISPATCH=0 path is unchanged. There this module owns the readPkg, so bytes
    // arrive only after it has asked for them and only while it is in ST_RECV_DATA anyway.
    // The `|| clear_framing` makes the discard unconditional rather than merely usual. The fifo's
    // s_axis_tready is almost-full, and `clear` zeroes its level only on the NEXT edge -- so a lane
    // torn down while its fifo happened to be full would refuse for one cycle, which is one cycle
    // of the shared bus stalled for every other lane. Discarding must never depend on there being
    // room to discard into.
    assign fifo_s_tvalid         = EXTERNAL_DISPATCH ? (s_axis_rx_data_TVALID && !clear_framing)
                                                     : ((state_q == ST_RECV_DATA) && s_axis_rx_data_TVALID);
    assign s_axis_rx_data_TREADY = EXTERNAL_DISPATCH ? (fifo_s_tready || clear_framing)
                                                     : ((state_q == ST_RECV_DATA) && fifo_s_tready);
    // Only ever read on the EXTERNAL_DISPATCH=0 path (the tlast exit from ST_RECV_DATA), where the
    // two expressions above are the originals.
    assign in_fire               = s_axis_rx_data_TVALID && s_axis_rx_data_TREADY;

    // Space for one maximum segment, in beats. MSS is 4096 on this stack (see the TOE's
    // MSS/mss_table); at 512 bit that is 64 beats. The +2 covers the fifo's own registered
    // output stage, which is occupied but not counted in rx_fifo_level.
    localparam int MSS_BEATS = (4096 / (AXI_DATA_BITS/8)) + 2;
    assign rx_space_ok = (RX_FIFO_DEPTH - rx_fifo_level) > MSS_BEATS;

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
        wdog_timeout_d     = wdog_timeout_q;
        // Progress watchdog. Counts only while a request is genuinely outstanding, and is cleared by
        // any forward motion: a beat of body data, an announcement, or the framer changing its mind.
        // Idle states reload it so it can never fire on a reader that has nothing to do.
        if (state_q == ST_IDLE || state_q == ST_DONE || state_q == ST_ABORT ||
            s_axis_rx_data_TVALID || (rx_req_len != 0) || sh_resp_done || sh_resp_error) begin
            wdog_d = '0;
        end else begin
            wdog_d = wdog_expired ? wdog_q : (wdog_q + 1'b1);
        end
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
                // Under external dispatch there is no notification to wait for and no readPkg to
                // issue -- rx_dispatch has already done both, and bytes for this lane may already
                // be arriving. Go straight to accepting them.
                if (EXTERNAL_DISPATCH) state_d = ST_RECV_DATA;
                else                   state_d = pkg_active_q ? ST_RECV_DATA : ST_WAIT_NOTIFY;
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
                end else if (wdog_expired) begin
                    // Nothing is coming. Abort rather than wait forever: the handler turns a
                    // non-dirty error into a reconnect and replay, which is recoverable, whereas
                    // hanging here is not -- it needs a reprogram.
                    wdog_timeout_d = 1'b1;
                    abort_dirty_d  = sh_resp_dirty;
                    state_d        = ST_ABORT;
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
                // Unreachable under EXTERNAL_DISPATCH (ST_ARM never routes here); the guard keeps
                // the readPkg port provably quiet rather than relying on that argument.
                m_axis_read_package_TVALID = !EXTERNAL_DISPATCH;
                if (m_axis_read_package_TREADY) begin
                    rx_meta_received_d = 1'b0;
                    pkg_active_d       = 1'b1;
                    state_d            = ST_RECV_DATA;
                end
            end

            ST_RECV_DATA: begin
                // One rx metadata beat per readPkg -- but only when this module issued the readPkg.
                // Under external dispatch rx_dispatch consumes the metadata (it is what names the
                // lane), so touching it here would steal a beat and mis-route the next packet.
                if (!EXTERNAL_DISPATCH && !rx_meta_received_q) begin
                    s_axis_rx_metadata_TREADY = 1'b1;
                    if (s_axis_rx_metadata_TVALID) rx_meta_received_d = 1'b1;
                end

                if (sh_resp_error) begin
                    abort_dirty_d = sh_resp_dirty;
                    state_d       = ST_ABORT;
                end else if (EXTERNAL_DISPATCH) begin
                    // Stay here for the whole response. There is no per-packet round trip to make:
                    // packets for this lane simply arrive, and the framer decides when the response
                    // is complete. tlast here is a PACKET boundary, not a response boundary.
                    if (sh_resp_done)   state_d = ST_DONE;
                    else if (rx_closed) state_d = ST_DRAIN;
                    else if (wdog_expired) begin
                        wdog_timeout_d = 1'b1;
                        abort_dirty_d  = sh_resp_dirty;
                        state_d        = ST_ABORT;
                    end
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
            wdog_q             <= '0;
            wdog_timeout_q     <= 1'b0;
        end else begin
            state_q            <= state_d;
            rx_meta_received_q <= rx_meta_received_d;
            req_len_q          <= req_len_d;
            abort_dirty_q      <= abort_dirty_d;
            drain_cnt_q        <= drain_cnt_d;
            wdog_q             <= wdog_d;
            wdog_timeout_q     <= wdog_timeout_d;
            // A new connection throws the half-read packet away with everything else.
            pkg_active_q       <= clear_framing ? 1'b0 : pkg_active_d;
        end
    end

    assign done               = (state_q == ST_DONE) || (state_q == ST_ABORT);
    assign error              = (state_q == ST_ABORT);
    assign error_dirty        = (state_q == ST_ABORT) && abort_dirty_q;
    assign resp_error         = sh_resp_error;
    // Sticky, for the host: this abort was a watchdog expiry, not a server error. Distinguishes
    // "nothing ever arrived" from "the server said no", which look identical from the CSRs otherwise.
    assign read_timeout       = wdog_timeout_q;
    assign debug_rx_write_ptr = payload_w1_valid ? 4'd2 : payload_w0_valid ? 4'd1 : 4'd0;
    assign debug_rx_buffer_w0 = payload_w0;
    assign debug_rx_buffer_w1 = payload_w1;

    assign state_debug        = state_q;

endmodule
