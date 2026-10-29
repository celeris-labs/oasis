import lynxTypes::*;

// Receive path of one lane: buffers the beats rx_dispatch routes to this lane's session and lets
// strip_http frame one HTTP response per start. The connection is kept alive, so a response ends
// by Content-Length, not by FIN or tlast, and bytes of the next response that arrive in the same
// segment stay buffered for the next start. error means the response did not complete; error_dirty
// means some of its body already reached the decoder, so it cannot be replayed.
module tcp_read #(
    // Decoupling fifo depth in 64-byte beats; it absorbs the byte-wise header walk, not responses.
    parameter int RX_FIFO_DEPTH = 8192,

    // Cycles without progress before a response is aborted; 2^29 is about 2.1 s at 250 MHz.
    parameter int WATCHDOG_BITS = 29
) (
    input  logic                                      clk,
    input  logic                                      rst_n,
    input  logic                                      start,

    // 0 when the response is not the last of its decoder stream.
    input  logic                                      body_last,
    // Resets the framer; only on a new connection, as the residue holds the next header.
    input  logic                                      clear_framing,

    // One pulse per readPkg rx_dispatch issues for this lane; its bytes arrive later.
    input  logic                                      rx_pkg_issued,

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

    output logic                                      resp_error,
    output logic                                      read_timeout,
    output logic [23:0]                               status_ascii,
    output logic                                      status_ok,
    output logic [31:0]                               content_length,
    output logic [31:0]                               body_remaining,

    // rx_fifo_stall is sticky: a beat routed here was refused and lost. It should never be set.
    output logic [$clog2(RX_FIFO_DEPTH+1)-1:0]        rx_fifo_level,
    output logic                                      rx_fifo_stall,

    // Room for a whole MSS, because once rx_dispatch has issued a readPkg it delivers every beat
    // of it without looking at TREADY.
    output logic                                      rx_space_ok,

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

    logic [WATCHDOG_BITS-1:0] wdog_q, wdog_d;
    logic                     wdog_expired;
    logic                     wdog_timeout_q, wdog_timeout_d;
    assign wdog_expired = (wdog_q == '1);

    // Quiet cycles ST_DRAIN waits for; strip_http needs at most 64 to walk a residue beat.
    localparam logic [7:0] DRAIN_SETTLE = 8'd200;
    logic [7:0] drain_cnt_q, drain_cnt_d;
    logic       parser_quiet_w, drain_settled_w;

    logic sh_resp_ack;
    logic sh_resp_done;
    logic sh_resp_dirty;
    logic sh_resp_error;

    logic                       sh_s_tvalid;
    logic                       sh_s_tready;
    logic [AXI_DATA_BITS-1:0]   sh_s_tdata;
    logic [AXI_DATA_BITS/8-1:0] sh_s_tkeep;
    logic                       sh_s_tlast;

    logic                       fifo_s_tvalid;
    logic                       fifo_s_tready;

    logic [AXI_DATA_BITS-1:0] payload_w0;
    logic [AXI_DATA_BITS-1:0] payload_w1;
    logic payload_w0_valid;
    logic payload_w1_valid;

    // TREADY towards rx_dispatch depends only on fifo space, not on the parser or this FSM:
    // rx_dispatch delivers every beat of an issued readPkg, also between two responses. While
    // clear_framing is high the beats are discarded, even if the fifo is full.
    assign fifo_s_tvalid         = s_axis_rx_data_TVALID && !clear_framing;
    assign s_axis_rx_data_TREADY = fifo_s_tready || clear_framing;

    // One MSS (4096 bytes) in beats, plus two beats of margin per readPkg.
    localparam int SEG_BEATS = 4096 / (AXI_DATA_BITS/8);
    localparam int MSS_BEATS = SEG_BEATS + 2;
    localparam int AF_SLACK  = 4;

    // readPkg reservation. The bytes of a readPkg arrive some cycles after it is issued, so the
    // fifo level alone would let rx_dispatch issue many readPkgs against the same free space. Each
    // issued readPkg reserves one segment until its tlast enters the fifo.
    localparam int RSV_BITS = $clog2(RX_FIFO_DEPTH+1) + 1;
    logic [RSV_BITS-1:0] rsv_beats_q;

    logic rx_pkt_done_w;
    assign rx_pkt_done_w = fifo_s_tvalid && fifo_s_tready && s_axis_rx_data_TLAST;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rsv_beats_q <= '0;
        end else if (clear_framing) begin
            // Also returns the reservations of packets rx_dispatch drops for a dead session.
            rsv_beats_q <= '0;
        end else begin
            case ({rx_pkg_issued, rx_pkt_done_w})
                // Saturate: a lane the head-of-line watchdog declared dead gets readPkgs anyway.
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

    // The fifo refuses beats from DEPTH - AF_SLACK on. An addition: level + reserved can exceed it.
    assign rx_space_ok = (RSV_BITS'(rx_fifo_level) + rsv_beats_q + RSV_BITS'(SEG_BEATS))
                         <= RSV_BITS'(RX_FIFO_DEPTH - AF_SLACK);

    axis_fifo #(
        .DATA_BITS(AXI_DATA_BITS),
        .DEPTH(RX_FIFO_DEPTH),
        .ALMOST_FULL_SLACK(AF_SLACK)
    ) inst_rx_fifo (
        .clk(clk),
        .rst_n(rst_n),
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

    assign parser_quiet_w  = (rx_fifo_level == '0) && !sh_s_tvalid;
    assign drain_settled_w = parser_quiet_w && (drain_cnt_q == 8'd0);

    // One cycle in ST_ARM retires the previous response and re-arms the framer.
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
        if (state_q == ST_IDLE || state_q == ST_DONE || state_q == ST_ABORT ||
            s_axis_rx_data_TVALID || sh_resp_done || sh_resp_error) begin
            wdog_d = '0;
        end else begin
            wdog_d = wdog_expired ? wdog_q : (wdog_q + 1'b1);
        end
        drain_cnt_d        = (state_q == ST_DRAIN && parser_quiet_w && drain_cnt_q != 8'd0)
                             ? drain_cnt_q - 8'd1 : DRAIN_SETTLE;

        case (state_q)
            ST_IDLE: begin
                if (start) begin
                    abort_dirty_d = 1'b0;
                    state_d       = ST_ARM;
                end
            end

            ST_ARM: begin
                state_d = ST_RECV_DATA;
            end

            // After a FIN the fifo and the framer may still hold bytes, and resp_dirty is final
            // only once they are drained; deciding earlier could replay a dirty response as clean.
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

            ST_RECV_DATA: begin
                if (sh_resp_error) begin
                    abort_dirty_d = sh_resp_dirty;
                    state_d       = ST_ABORT;
                end else if (sh_resp_done) begin
                    state_d = ST_DONE;
                end else if (rx_closed) begin
                    state_d = ST_DRAIN;
                end else if (wdog_expired) begin
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
    // Sticky: an abort came from the watchdog, not from the server.
    assign read_timeout       = wdog_timeout_q;
    assign debug_rx_write_ptr = payload_w1_valid ? 4'd2 : payload_w0_valid ? 4'd1 : 4'd0;
    assign debug_rx_buffer_w0 = payload_w0;
    assign debug_rx_buffer_w1 = payload_w1;

    assign state_debug        = state_q;

endmodule
