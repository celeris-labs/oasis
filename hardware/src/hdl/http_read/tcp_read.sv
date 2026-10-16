import lynxTypes::*;

// =================================================================================================
// TCP receive path for ONE HTTP response on a persistent connection, one lane.
//
// A TCP byte stream has no message boundaries and the TOE surfaces it INCREMENTALLY: it emits an
// appNotification whenever more bytes have landed, and a separate notification with `closed=1,
// length=0` when the peer FINs. The handler's receive dispatcher (rx_dispatch in handler_multi,
// toe_rx in handler_toe) owns all of that for every lane at once: it takes the notifications,
// issues the readPkgs and consumes the rx_metadata. The bytes of this lane's session arrive here
// PRE-ROUTED on s_axis_rx_data_*, in order; rx_pkg_issued says a readPkg was charged to this lane,
// and rx_space_ok / rx_free_beats is the room this lane offers back to the dispatcher.
//
// KEEP-ALIVE
// ----------
// The connection is persistent, so the FIN is not a frame marker: strip_http delimits each body by
// Content-Length and raises `resp_done` when it has drained. This module therefore serves exactly
// ONE response per activation and leaves the connection open; the handler starts us again for the
// next one.
//
// Two consequences worth spelling out:
//
//   * The 1-beat-delay concatenator is GONE. It existed to mask the per-readPkg tlast so the
//     downstream normalizer saw one continuous stream, which meant holding every beat back until
//     the next one arrived. strip_http now ignores the input tlast entirely and produces the single
//     tlast itself from the byte count, so rx_data feeds it directly -- one less register stage and
//     one less place for a seam byte to go wrong.
//
//   * A response can end in the MIDDLE of a packet, because a TCP segment may carry the tail of
//     body k and the head of response k+1. The bytes after the boundary stay in the decoupling
//     fifo and the framer's residue and are the start of the next activation's response.
//
// FAILURE REPORTING
// -----------------
// `error` means this activation ended without a complete response: the peer FINed with nothing left
// to read (an idle-timeout close, or a lost pipelined request), or strip_http could not frame the
// response at all. `error_dirty` says body bytes of THIS response already reached the decoder, so
// the stream is corrupt and the handler must not silently reconnect and replay. See handler_multi.sv.
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
    // Waiting for data used to have no way out at all: it ended only when the framer finished, an
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

    // 0 (default): the reservation is one MSS segment per readPkg, handed back at the packet's
    // tlast (rx_dispatch, TOE in bypass mode, where one readPkg returns one announced segment
    // whatever length it names). handler_multi; rx_pkg_beats / rx_free_beats are unused
    // (rx_free_beats reads 0).
    //
    // 1: the reservation is EXACT (toe_rx, TOE with its per-session receive ring: a readPkg returns
    // exactly the bytes it names, up to RD_MAX, so a segment is the wrong unit). Every readPkg
    // reserves rx_pkg_beats, every beat accepted into the fifo hands one back, and rx_free_beats
    // says how many beats a new readPkg may still be promised -- see the reservation below.
    parameter bit RSV_EXACT = 0
) (
    input  logic                                      clk,
    input  logic                                      rst_n,
    input  logic                                      start,

    // Does this response end the decoder stream? 0 when the host split one column chunk across
    // several ranged GETs and this is not the last of them.
    input  logic                                      body_last,
    // Reset the response framer. ONLY on a new connection -- between responses it would discard the
    // residue, which holds the bytes of the next header.
    input  logic                                      clear_framing,

    // The dispatcher has just issued a readPkg for THIS lane. One pulse per readPkg; the bytes it
    // names arrive later. See the reservation below -- without this,
    // rx_space_ok is a promise the fifo cannot keep.
    input  logic                                      rx_pkg_issued,
    // RSV_EXACT only: the readPkg pulsed on rx_pkg_issued returns this many beats.
    input  logic [$clog2(RX_FIFO_DEPTH+1)-1:0]        rx_pkg_beats,

    // The peer has FINed (sticky), from the handler.
    input  logic                                      rx_closed,

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

    // Room for a WHOLE MSS, not for one beat. rx_dispatch gates its
    // readPkg on this, and once it issues, every beat of that packet is accepted unconditionally --
    // so a lane that says "ok" with room for less than a full segment forces the dispatcher to
    // stall the shared stream, which stalls every other lane too. That is the one failure this
    // whole arrangement exists to avoid, so the margin is deliberate.
    output logic                                      rx_space_ok,
    // RSV_EXACT only: beats a new readPkg may still be promised, REGISTERED (one cycle behind the
    // reservation it is computed from; the caller must not grant this lane again before the
    // readPkg it just charged shows up here -- toe_rx blocks a lane for that long). 0 otherwise.
    output logic [$clog2(RX_FIFO_DEPTH+1)-1:0]        rx_free_beats,

    output logic [3:0]                                debug_rx_write_ptr,
    output logic [AXI_DATA_BITS-1:0]                  debug_rx_buffer_w0,
    output logic [AXI_DATA_BITS-1:0]                  debug_rx_buffer_w1,
    output logic [3:0]                                state_debug
);

    localparam logic [3:0] ST_IDLE        = 4'd0;
    localparam logic [3:0] ST_ARM         = 4'd1;
    localparam logic [3:0] ST_RECV_DATA   = 4'd9;
    localparam logic [3:0] ST_DRAIN       = 4'd10;
    localparam logic [3:0] ST_ABORT       = 4'd11;
    localparam logic [3:0] ST_DONE        = 4'd15;

    logic [3:0] state_q, state_d;
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

    // THE DECOUPLING. TREADY towards the TCP stack is now decided by fifo space, never by whether
    // strip_http happens to be free. The parser walks header bytes one per cycle; while it did that
    // it used to hold TREADY low and let the TOE's single shared 64 KB rx fifo fill behind it --
    // ~35 KB of backlog per response, which is why a 32 KiB response worked and a 64 KiB one fell
    // off a cliff at every pipeline depth. See axis_fifo.sv for the full derivation.
    //
    // AND DECOUPLED FROM THIS FSM AS WELL.
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
    // So the FIFO decides, and only the FIFO: it has room or it does not. Its s_axis_tready is
    // independent of `clear`, so a lane being torn down still consumes what is routed to it -- and
    // DISCARDS it, because those bytes belong to a session that no longer exists. Discarding is the
    // point: stalling instead would back-pressure the shared bus.
    //
    // The `|| clear_framing` makes the discard unconditional rather than merely usual. The fifo's
    // s_axis_tready is almost-full, and `clear` zeroes its level only on the NEXT edge -- so a lane
    // torn down while its fifo happened to be full would refuse for one cycle, which is one cycle
    // of the shared bus stalled for every other lane. Discarding must never depend on there being
    // room to discard into.
    assign fifo_s_tvalid         = s_axis_rx_data_TVALID && !clear_framing;
    assign s_axis_rx_data_TREADY = fifo_s_tready || clear_framing;

    // Space for one maximum segment, in beats. MSS is 4096 on this stack (see the TOE's
    // MSS/mss_table); at 512 bit that is 64 beats. The +2 covers the fifo's own registered
    // output stage, which is occupied but not counted in rx_fifo_level.
    localparam int MSS_BEATS = (4096 / (AXI_DATA_BITS/8)) + 2;

    // ---------------------------------------------------------------------------------------------
    // readPkg reservation. WHY rx_space_ok CANNOT SIMPLY ASK THE FIFO.
    //
    // A readPkg's bytes do not arrive when it is issued -- they arrive some time later. So
    // rx_fifo_level says nothing about what is already on its way, and a check for "room for one
    // MSS" passes again the very next cycle, and again after that. rx_dispatch can therefore issue
    // an unbounded run of readPkgs against the SAME single-segment reservation, and every one of
    // them delivers a full segment. With N in flight the fifo takes N*MSS into space that was only
    // ever checked once. It is not the fifo that is undersized, it is over-committed.
    //
    // Measured on build-116 against MinIO, with the host varying lane_depth x chunk_bytes:
    //   256 KiB in flight per lane -> completes;  512 KiB -> overruns, framing desynchronises and
    //   the response comes out unframeable. 8192 beats / 66 beats-per-segment is 124 segments,
    //   i.e. ~508 KiB, which is exactly where it broke. The arithmetic is the bug.
    //
    // One readPkg returns exactly ONE announced segment however many bytes it names (rx_dispatch's
    // header says so), so a segment is the right unit and MSS_BEATS the right size -- no length has
    // to be plumbed across the module boundary.
    localparam int RSV_BITS = $clog2(RX_FIFO_DEPTH+1) + 1;
    logic [RSV_BITS-1:0] rsv_beats_q;

    // A promised packet becomes real space at its tlast on the way INTO the fifo.
    logic rx_pkt_done_w;
    assign rx_pkt_done_w = fifo_s_tvalid && fifo_s_tready && s_axis_rx_data_TLAST;

    if (!RSV_EXACT) begin : gen_rsv_mss
        always_ff @(posedge clk) begin
            if (!rst_n) begin
                rsv_beats_q <= '0;
            end else if (clear_framing) begin
                // The session is gone and the fifo is being cleared, so every outstanding promise dies
                // with it. This is also what stops the one leak: a packet rx_dispatch DROPS (a released
                // or dead session) never reaches this fifo, so its tlast never arrives and nothing else
                // would ever hand the reservation back. clear_framing is exactly when that happens.
                rsv_beats_q <= '0;
            end else begin
                case ({rx_pkg_issued, rx_pkt_done_w})
                    // Saturate rather than wrap: a lane the head-of-line watchdog has declared dead is
                    // issued readPkgs with the space check bypassed, so this can otherwise keep climbing.
                    2'b10:   rsv_beats_q <= (rsv_beats_q > RSV_BITS'(RX_FIFO_DEPTH))
                                                ? rsv_beats_q
                                                : rsv_beats_q + RSV_BITS'(MSS_BEATS);
                    2'b01:   rsv_beats_q <= (rsv_beats_q >= RSV_BITS'(MSS_BEATS))
                                                ? rsv_beats_q - RSV_BITS'(MSS_BEATS)
                                                : '0;
                    default: ;
                endcase
            end
        end
        assign rx_free_beats = '0;
    end else begin : gen_rsv_exact
        // ---------------------------------------------------------------------------------------
        // THE EXACT RESERVATION (RSV_EXACT, toe_rx).
        //
        // With the TOE's per-session receive ring a readPkg returns exactly the bytes it names
        // (ceil(len/64) beats), so the promise can be exact instead of one MSS per packet: a readPkg
        // reserves its beats, and each beat that enters the fifo hands one back -- it is then
        // counted by the fifo's own level instead. rsv + level is therefore every beat this fifo has
        // promised or holds, at every cycle, and
        //
        //     free = (DEPTH - ALMOST_FULL_SLACK) - level - rsv
        //
        // is what a new readPkg may still be promised. ALMOST_FULL_SLACK is axis_fifo's 4: its
        // s_axis_tready is !(level >= DEPTH - 4), and level counts the memory only (the output
        // register needs no memory slot), so DEPTH - 4 beats are what it accepts unconditionally.
        // A readPkg admitted with need <= free leaves level + rsv <= DEPTH - 4, so even if the
        // reader takes nothing, the last promised beat arrives at a level of at most DEPTH - 5 and is
        // accepted: the receive path is never refused.
        //
        // REGISTERED. free is one cycle behind rsv_beats_q, which is one cycle behind the pulse;
        // free only ever SHRINKS at a reservation (a beat moving from rsv into the fifo leaves it
        // unchanged, the reader taking one grows it), so a late value is wrong only towards the
        // lane that was just charged, and toe_rx does not grant that lane again until the charge is
        // visible here.
        // ---------------------------------------------------------------------------------------
        localparam int FREE_BITS = $clog2(RX_FIFO_DEPTH+1);
        localparam int AF_SLACK  = 4;   // axis_fifo's ALMOST_FULL_SLACK (default, not overridden)

        logic                 beat_in_w;
        logic [RSV_BITS:0]    rsv_next_w;   // one bit wider: rsv + beats before the -1
        logic [RSV_BITS+1:0]  free_w;       // signed room, two bits wider than its operands
        logic [FREE_BITS-1:0] free_q;

        assign beat_in_w  = fifo_s_tvalid && fifo_s_tready;
        assign rsv_next_w = (RSV_BITS+1)'(rsv_beats_q)
                          + (rx_pkg_issued ? (RSV_BITS+1)'(rx_pkg_beats) : '0);

        always_ff @(posedge clk) begin
            if (!rst_n) begin
                rsv_beats_q <= '0;
            end else if (clear_framing) begin
                // The session is gone and the fifo is cleared: every promise dies with it. The
                // handler does not rebind the lane while a readPkg of it is still outstanding, so
                // nothing promised to the old session can land in the new one's fifo.
                rsv_beats_q <= '0;
            end else if (beat_in_w) begin
                // Never below zero: a beat always arrives after the readPkg that reserved it.
                rsv_beats_q <= (rsv_next_w == '0) ? '0 : RSV_BITS'(rsv_next_w - 1'b1);
            end else begin
                rsv_beats_q <= RSV_BITS'(rsv_next_w);
            end
        end

        assign free_w = (RSV_BITS+2)'(RX_FIFO_DEPTH - AF_SLACK)
                      - (RSV_BITS+2)'(rx_fifo_level)
                      - (RSV_BITS+2)'(rsv_beats_q);

        always_ff @(posedge clk) begin
            if (!rst_n || clear_framing) free_q <= '0;
            else                         free_q <= free_w[RSV_BITS+1] ? '0 : FREE_BITS'(free_w);
        end

        assign rx_free_beats = free_q;
    end

    // Room for everything already promised PLUS the segment this would admit. Written as an
    // addition, not as (DEPTH - level - reserved), because level + reserved may legitimately exceed
    // the depth for a cycle and the subtraction would wrap to a huge unsigned "yes".
    assign rx_space_ok = (RSV_BITS'(rx_fifo_level) + rsv_beats_q + RSV_BITS'(MSS_BEATS))
                         < RSV_BITS'(RX_FIFO_DEPTH);

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
        abort_dirty_d      = abort_dirty_q;
        wdog_timeout_d     = wdog_timeout_q;
        // Progress watchdog. Counts only while a request is genuinely outstanding, and is cleared by
        // any forward motion: a beat of data, or the framer changing its mind. Idle states reload it
        // so it can never fire on a reader that has nothing to do.
        if (state_q == ST_IDLE || state_q == ST_DONE || state_q == ST_ABORT ||
            s_axis_rx_data_TVALID || sh_resp_done || sh_resp_error) begin
            wdog_d = '0;
        end else begin
            wdog_d = wdog_expired ? wdog_q : (wdog_q + 1'b1);
        end
        // Hold the timer reloaded everywhere except ST_DRAIN, and reload it inside ST_DRAIN for as
        // long as the parser still has work, so only genuine quiet counts towards settling.
        drain_cnt_d        = (state_q == ST_DRAIN && parser_quiet_w && drain_cnt_q != 8'd0)
                             ? drain_cnt_q - 8'd1 : DRAIN_SETTLE;

        case (state_q)
            ST_IDLE: begin
                if (start) begin
                    abort_dirty_d = 1'b0;
                    state_d       = ST_ARM;
                end
            end

            // resp_ack is asserted for this whole cycle; the framer clears resp_done on the edge.
            // There is no notification to wait for and no readPkg to issue -- the dispatcher has
            // already done both, and bytes for this lane may already be arriving. Go straight to
            // accepting them.
            ST_ARM: begin
                state_d = ST_RECV_DATA;
            end

            // The peer has closed, so no further bytes will ever arrive -- but the decoupling fifo
            // may still hold some, and strip_http walks header bytes one per cycle. Sampling
            // resp_dirty now would report CLEAN for a response whose body bytes are still queued,
            // the handler would treat the abort as replayable, and those bytes would be duplicated
            // in the decoder stream. So: let the parser finish everything already pulled, and only
            // then decide.
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

            // Stay here for the whole response. There is no per-packet round trip to make: packets
            // for this lane simply arrive, and the framer decides when the response is complete. A
            // tlast here is a PACKET boundary, not a response boundary.
            ST_RECV_DATA: begin
                if (sh_resp_error) begin
                    abort_dirty_d = sh_resp_dirty;
                    state_d       = ST_ABORT;
                end else if (sh_resp_done) begin
                    state_d = ST_DONE;
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
            abort_dirty_q      <= 1'b0;
            drain_cnt_q        <= DRAIN_SETTLE;
            wdog_q             <= '0;
            wdog_timeout_q     <= 1'b0;
        end else begin
            state_q            <= state_d;
            abort_dirty_q      <= abort_dirty_d;
            drain_cnt_q        <= drain_cnt_d;
            wdog_q             <= wdog_d;
            wdog_timeout_q     <= wdog_timeout_d;
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
