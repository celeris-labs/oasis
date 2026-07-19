`timescale 1ns / 1ps

import lynxTypes::*;
import libstf::data8_t;

/*
 * strip_http
 * ----------
 * Consumes the raw TCP RX byte stream of an HTTP response, drops everything up
 * to and including the end-of-header marker (CRLF CRLF = 0x0D0A0D0A), and emits
 * the remaining body as a lane-0-packed ndata stream (all-ones keep per beat).
 *
 * The body does not start on a beat boundary, so a 128-byte accumulator
 * re-aligns it to lane 0. The true end/last-beat trimming is done downstream by
 * FixLast using the known content size, so this module only needs to emit full
 * 64-byte beats plus one final (padded) beat containing the trailing <64 bytes
 * once `flush` is asserted by tcp_read at end of response.
 *
 * clear : reset search + accumulator at the start of a fresh response
 * enable: accept RX input beats (asserted while receiving)
 * flush : response finished, drain the last partial beat
 */
module strip_http (
    input  logic                           clk,
    input  logic                           rst_n,
    input  logic                           clear,
    input  logic                           enable,
    input  logic                           flush,

    input  logic                           s_axis_tvalid,
    input  logic [AXI_DATA_BITS-1:0]        s_axis_tdata,
    input  logic [AXI_DATA_BITS/8-1:0]      s_axis_tkeep,
    input  logic                           s_axis_tlast,
    output logic                           s_axis_tready,

    ndata_i.m                              out,   // #(data8_t, AXI_DATA_BITS/8)

    output logic                           done,
    output logic [6:0]                     out_payload_idx,
    output logic [AXI_DATA_BITS-1:0]        debug_out_beat,
    output logic [1:0]                     state_debug
);

    localparam int BYTES    = AXI_DATA_BITS / 8;   // 64
    localparam int ACC_BITS = 2 * AXI_DATA_BITS;   // 1024 (128 bytes)

    typedef enum logic [1:0] {
        SCAN = 2'd0,
        RUN  = 2'd1,
        FIN  = 2'd2
    } state_t;

    state_t             state_q, state_d;
    logic [23:0]        prev_tail_q, prev_tail_d;
    logic [ACC_BITS-1:0] acc_q, acc_d;
    logic [7:0]         acc_cnt_q, acc_cnt_d;   // buffered bytes, 0..127
    logic               done_q, done_d;
    logic [6:0]         payload_idx_q, payload_idx_d;

    // -- Count of contiguous kept bytes (TCP RX keep is a LSB prefix) ----------
    function automatic logic [6:0] keep_count(input logic [BYTES-1:0] k);
        logic [6:0] c;
        begin
            c = 7'd0;
            for (int i = 0; i < BYTES; i++) begin
                if (k[i]) c = c + 7'd1;
            end
            keep_count = c;
        end
    endfunction

    logic [6:0] kept;
    assign kept = keep_count(s_axis_tkeep);

    // -- Header search over {current beat, previous 3 bytes} -------------------
    localparam int SEARCH_BYTES = BYTES + 3;
    logic [SEARCH_BYTES*8-1:0] search_win;
    assign search_win = {s_axis_tdata, prev_tail_q};

    logic       header_match;
    logic [6:0] header_offset;
    always_comb begin : header_search
        header_match  = 1'b0;
        header_offset = '0;
        for (int i = 0; i < SEARCH_BYTES - 3; i++) begin
            if (!header_match && search_win[i*8 +: 32] == 32'h0A0D0A0D) begin
                header_match  = 1'b1;
                header_offset = i[6:0];
            end
        end
    end

    // Payload start byte index within the *current* beat. prev_tail occupies
    // window bytes 0..2, so payload begins at (header_offset + 4) - 3.
    logic [6:0] payload_start;
    assign payload_start = header_offset + 7'd1;

    // -- Payload bytes contributed by the current beat (right-aligned) ---------
    logic [6:0]                add_cnt;
    logic [AXI_DATA_BITS-1:0]  add_data;
    always_comb begin
        add_cnt  = 7'd0;
        add_data = '0;
        if (state_q == SCAN) begin
            if (header_match) begin
                add_cnt  = (kept > payload_start) ? (kept - payload_start) : 7'd0;
                add_data = s_axis_tdata >> (payload_start * 8);
            end
        end else begin // RUN
            add_cnt  = kept;
            add_data = s_axis_tdata;
        end
    end

    logic [AXI_DATA_BITS-1:0] add_data_masked;
    assign add_data_masked = (add_cnt == 0) ? '0 :
        (add_data & ({AXI_DATA_BITS{1'b1}} >> (AXI_DATA_BITS - add_cnt * 8)));

    // -- Handshakes ------------------------------------------------------------
    // Accept only while there is guaranteed room for a full 64-byte beat.
    assign s_axis_tready = enable && !flush && (state_q != FIN) && (acc_cnt_q <= 8'd63);
    logic in_fire;
    assign in_fire = s_axis_tvalid && s_axis_tready;

    logic emit_full, emit_tail;
    assign emit_full = (acc_cnt_q >= 8'd64);
    assign emit_tail = flush && (acc_cnt_q != 0) && (acc_cnt_q < 8'd64);
    assign out.valid = emit_full || emit_tail;
    assign out.keep  = {BYTES{1'b1}};                    // FixLast sets the real last-beat keep
    assign out.last  = flush && (acc_cnt_q <= 8'd64);    // hint only; FixLast overrides
    logic out_fire;
    assign out_fire = out.valid && out.ready;

    genvar gi;
    generate
        for (gi = 0; gi < BYTES; gi++) begin : gen_out_bytes
            assign out.data[gi] = acc_q[gi*8 +: 8];
        end
    endgenerate

    // -- Next-state logic ------------------------------------------------------
    always_comb begin
        state_d       = state_q;
        prev_tail_d   = prev_tail_q;
        acc_d         = acc_q;
        acc_cnt_d     = acc_cnt_q;
        done_d        = done_q;
        payload_idx_d = payload_idx_q;

        if (clear) begin
            state_d       = SCAN;
            prev_tail_d   = '0;
            acc_d         = '0;
            acc_cnt_d     = '0;
            done_d        = 1'b0;
            payload_idx_d = '0;
        end else begin
            // Drain (emit_full and accept are disjoint by acc_cnt range).
            if (out_fire) begin
                if (emit_full) begin
                    acc_d     = acc_q >> AXI_DATA_BITS;
                    acc_cnt_d = acc_cnt_q - 8'd64;
                end else begin // tail
                    acc_d     = '0;
                    acc_cnt_d = '0;
                    done_d    = 1'b1;
                    state_d   = FIN;
                end
            end else if (flush && (acc_cnt_q == 0) && (state_q != FIN)) begin
                done_d  = 1'b1;
                state_d = FIN;
            end

            // Fill.
            if (in_fire) begin
                prev_tail_d = s_axis_tdata[AXI_DATA_BITS-1 -: 24];
                if (state_q == SCAN) begin
                    if (header_match) begin
                        payload_idx_d = payload_start;
                        acc_d         = acc_q | ({{(ACC_BITS-AXI_DATA_BITS){1'b0}}, add_data_masked} << (acc_cnt_q * 8));
                        acc_cnt_d     = acc_cnt_q + add_cnt;
                        state_d       = RUN;
                    end
                end else if (state_q == RUN) begin
                    acc_d     = acc_q | ({{(ACC_BITS-AXI_DATA_BITS){1'b0}}, add_data_masked} << (acc_cnt_q * 8));
                    acc_cnt_d = acc_cnt_q + add_cnt;
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q       <= SCAN;
            prev_tail_q   <= '0;
            acc_q         <= '0;
            acc_cnt_q     <= '0;
            done_q        <= 1'b0;
            payload_idx_q <= '0;
        end else begin
            state_q       <= state_d;
            prev_tail_q   <= prev_tail_d;
            acc_q         <= acc_d;
            acc_cnt_q     <= acc_cnt_d;
            done_q        <= done_d;
            payload_idx_q <= payload_idx_d;
        end
    end

    assign done            = done_q;
    assign out_payload_idx = payload_idx_q;
    assign debug_out_beat  = acc_q[AXI_DATA_BITS-1:0];
    assign state_debug     = state_q;

endmodule
