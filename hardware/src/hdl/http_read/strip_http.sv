`timescale 1ns / 1ps

import lynxTypes::*;

// Header strip + 64B align.
// Finds the end of the HTTP header (\r\n\r\n) and emits the body as a fully
// packed, byte-0-aligned AXIS stream: every beat except the last is full
// (tkeep all ones), the last carries a bottom-justified partial tkeep.
//
// Only the first payload beat is offset (payload starts at lane `payload_idx`);
// every following network beat is already bottom-justified. So a single one-beat
// accumulator with one variable byte-shift is enough -- no DataNormalizer /
// DataCompactor needed downstream.
module strip_http (
    input  logic                           clk,
    input  logic                           rst_n,
    input  logic                           clear,
    input  logic                           enable,

    input  logic                           s_axis_tvalid,
    input  logic [AXI_DATA_BITS-1:0]       s_axis_tdata,
    input  logic [AXI_DATA_BITS/8-1:0]     s_axis_tkeep,
    input  logic                           s_axis_tlast,
    output logic                           s_axis_tready,

    // Aligned, packed body stream
    output logic                           m_axis_tvalid,
    output logic [AXI_DATA_BITS-1:0]       m_axis_tdata,
    output logic [AXI_DATA_BITS/8-1:0]     m_axis_tkeep,
    output logic                           m_axis_tlast,
    input  logic                           m_axis_tready,

    // Debug words
    output logic [AXI_DATA_BITS-1:0]       out_w0,
    output logic [AXI_DATA_BITS-1:0]       out_w1,
    output logic                           out_w0_valid,
    output logic                           out_w1_valid,
    output logic                           done,

    // Payload start index within the first body beat (0..64)
    output logic [6:0]                     out_payload_idx
);

    localparam int DW           = AXI_DATA_BITS;     // 512
    localparam int BYTE_LANES   = AXI_DATA_BITS / 8; // 64
    localparam int SEARCH_BYTES = BYTE_LANES + 3;    // 67

    typedef enum logic [1:0] {
        SCAN   = 2'd0,
        STREAM = 2'd1,
        FLUSH  = 2'd2,
        DONE   = 2'd3
    } state_t;

    state_t state_q, state_d;

    logic [23:0]     prev_tail_q, prev_tail_d;
    logic [DW-1:0]   acc_q, acc_d;          // pending bytes, bottom-justified
    logic [6:0]      acc_cnt_q, acc_cnt_d;  // valid bytes in acc (0..63)
    logic [DW-1:0]   w0_q, w0_d;
    logic [DW-1:0]   w1_q, w1_d;
    logic            w0_valid_q, w0_valid_d;
    logic            w1_valid_q, w1_valid_d;
    logic            done_q, done_d;
    logic [6:0]      payload_idx_q, payload_idx_d;

    function automatic logic [DW-1:0] apply_tkeep(
        input logic [DW-1:0]         data_in,
        input logic [BYTE_LANES-1:0] keep_in
    );
        logic [DW-1:0] data_masked;
        begin
            data_masked = '0;
            for (int lane = 0; lane < BYTE_LANES; lane++) begin
                if (keep_in[lane]) begin
                    data_masked[lane*8 +: 8] = data_in[lane*8 +: 8];
                end
            end
            return data_masked;
        end
    endfunction

    // Bottom-justified tkeep for `n` valid bytes.
    function automatic logic [BYTE_LANES-1:0] keep_from_count(input logic [6:0] n);
        begin
            if (n == 0)               keep_from_count = '0;
            else if (n >= BYTE_LANES) keep_from_count = {BYTE_LANES{1'b1}};
            else                      keep_from_count = {BYTE_LANES{1'b1}} >> (BYTE_LANES - n);
        end
    endfunction

    // ---------------------------------------------------------------
    // Header search: locate \r\n\r\n across the 3-byte carry + this beat
    // ---------------------------------------------------------------
    logic [SEARCH_BYTES*8-1:0] search_win_w;
    assign search_win_w = {s_axis_tdata, prev_tail_q};

    logic       header_match_w;
    logic [6:0] header_offset_w;

    always_comb begin : header_search
        header_match_w  = 1'b0;
        header_offset_w = '0;
        for (int i = 0; i < SEARCH_BYTES - 3; i++) begin
            if (!header_match_w && search_win_w[i*8 +: 32] == 32'h0A0D0A0D) begin
                header_match_w  = 1'b1;
                header_offset_w = i[6:0];
            end
        end
    end

    // Payload start index in current beat (64 => body starts next beat)
    logic [6:0] current_beat_idx_w;
    assign current_beat_idx_w = header_offset_w + 7'd1;

    // First body beat: mask off the header lanes, then shift the (top-justified)
    // payload down to lane 0.
    logic [BYTE_LANES-1:0] clean_tkeep_w;
    logic [DW-1:0]         clean_tdata_w;
    logic                  first_has_payload_w;
    logic [DW-1:0]         chunk_b0_w;
    logic [6:0]            cnt_b0_w;

    always_comb begin
        if (current_beat_idx_w < BYTE_LANES)
            clean_tkeep_w = s_axis_tkeep & ({BYTE_LANES{1'b1}} << current_beat_idx_w);
        else
            clean_tkeep_w = '0;
        clean_tdata_w       = apply_tkeep(s_axis_tdata, clean_tkeep_w);
        first_has_payload_w = (clean_tkeep_w != '0);
        chunk_b0_w          = clean_tdata_w >> ({3'b0, current_beat_idx_w} * 8);
        cnt_b0_w            = $countones(clean_tkeep_w);
    end

    // Subsequent beats are already bottom-justified.
    logic [DW-1:0] chunk_st_w;
    logic [6:0]    cnt_st_w;
    assign chunk_st_w = apply_tkeep(s_axis_tdata, s_axis_tkeep);
    assign cnt_st_w   = $countones(s_axis_tkeep);

    // Merge the selected chunk on top of the accumulator.
    logic [DW-1:0]   chunk_w;
    logic [6:0]      chunk_cnt_w;
    logic [2*DW-1:0] combined_w;
    logic [7:0]      total_w;

    assign chunk_w     = (state_q == SCAN) ? chunk_b0_w : chunk_st_w;
    assign chunk_cnt_w = (state_q == SCAN) ? cnt_b0_w   : cnt_st_w;
    assign combined_w  = {{DW{1'b0}}, acc_q}
                       | ({{DW{1'b0}}, chunk_w} << ({3'b0, acc_cnt_q} * 8));
    assign total_w     = {1'b0, acc_cnt_q} + {1'b0, chunk_cnt_w};

    // ---------------------------------------------------------------
    // FSM
    // ---------------------------------------------------------------
    always_comb begin : fsm_logic
        state_d       = state_q;
        prev_tail_d   = prev_tail_q;
        acc_d         = acc_q;
        acc_cnt_d     = acc_cnt_q;
        w0_d          = w0_q;
        w1_d          = w1_q;
        w0_valid_d    = w0_valid_q;
        w1_valid_d    = w1_valid_q;
        done_d        = done_q;
        payload_idx_d = payload_idx_q;

        s_axis_tready = 1'b0;
        m_axis_tvalid = 1'b0;
        m_axis_tdata  = '0;
        m_axis_tkeep  = '0;
        m_axis_tlast  = 1'b0;

        if (clear) begin
            state_d       = SCAN;
            prev_tail_d   = '0;
            acc_d         = '0;
            acc_cnt_d     = '0;
            w0_d          = '0;
            w1_d          = '0;
            w0_valid_d    = 1'b0;
            w1_valid_d    = 1'b0;
            done_d        = 1'b0;
            payload_idx_d = '0;
        end else if (enable && state_q != DONE) begin
            case (state_q)
                // SCAN drops header bytes; it never emits (first beat holds
                // <64 payload bytes), so it can always accept.
                SCAN: begin
                    s_axis_tready = 1'b1;
                    if (s_axis_tvalid) begin
                        prev_tail_d = s_axis_tdata[DW-1 -: 24];

                        if (header_match_w) begin
                            payload_idx_d = current_beat_idx_w;

                            if (first_has_payload_w) begin
                                acc_d      = combined_w[DW-1:0]; // acc was empty
                                acc_cnt_d  = total_w[6:0];
                                w0_d       = combined_w[DW-1:0];
                                w0_valid_d = 1'b1;
                                state_d    = s_axis_tlast ? FLUSH : STREAM;
                            end else begin
                                // header ends on a beat boundary: body next beat
                                if (s_axis_tlast) begin
                                    done_d  = 1'b1;
                                    state_d = DONE;
                                end else begin
                                    state_d = STREAM;
                                end
                            end
                        end else if (s_axis_tlast) begin
                            // no header found before end of stream
                            done_d  = 1'b1;
                            state_d = DONE;
                        end
                    end
                end

                STREAM: begin
                    if (s_axis_tvalid) begin
                        if (total_w >= 8'd64) begin
                            // A full output beat is ready.
                            m_axis_tvalid = 1'b1;
                            m_axis_tdata  = combined_w[DW-1:0];
                            m_axis_tkeep  = {BYTE_LANES{1'b1}};
                            m_axis_tlast  = s_axis_tlast && (total_w == 8'd64);
                            s_axis_tready = m_axis_tready;

                            if (m_axis_tready) begin
                                acc_d     = combined_w[2*DW-1:DW]; // overflow bytes
                                acc_cnt_d = total_w[6:0] - 7'd64;
                                if (!w1_valid_q) begin
                                    w1_d       = combined_w[DW-1:0];
                                    w1_valid_d = 1'b1;
                                end
                                if (s_axis_tlast) begin
                                    if (total_w == 8'd64) begin
                                        done_d  = 1'b1;
                                        state_d = DONE;
                                    end else begin
                                        state_d = FLUSH; // remainder still in acc
                                    end
                                end
                            end
                        end else if (s_axis_tlast) begin
                            // Last beat, everything fits in one partial beat.
                            if (total_w != 8'd0) begin
                                m_axis_tvalid = 1'b1;
                                m_axis_tdata  = combined_w[DW-1:0];
                                m_axis_tkeep  = keep_from_count(total_w[6:0]);
                                m_axis_tlast  = 1'b1;
                                s_axis_tready = m_axis_tready;
                                if (m_axis_tready) begin
                                    done_d  = 1'b1;
                                    state_d = DONE;
                                end
                            end else begin
                                s_axis_tready = 1'b1;
                                done_d        = 1'b1;
                                state_d       = DONE;
                            end
                        end else begin
                            // Accumulate only.
                            s_axis_tready = 1'b1;
                            acc_d         = combined_w[DW-1:0];
                            acc_cnt_d     = total_w[6:0];
                        end
                    end
                end

                // Flush the bytes still held in the accumulator as the last beat.
                FLUSH: begin
                    m_axis_tvalid = 1'b1;
                    m_axis_tdata  = acc_q;
                    m_axis_tkeep  = keep_from_count(acc_cnt_q);
                    m_axis_tlast  = 1'b1;
                    if (m_axis_tready) begin
                        done_d  = 1'b1;
                        state_d = DONE;
                    end
                end

                default: state_d = SCAN;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q       <= SCAN;
            prev_tail_q   <= '0;
            acc_q         <= '0;
            acc_cnt_q     <= '0;
            w0_q          <= '0;
            w1_q          <= '0;
            w0_valid_q    <= 1'b0;
            w1_valid_q    <= 1'b0;
            done_q        <= 1'b0;
            payload_idx_q <= '0;
        end else begin
            state_q       <= state_d;
            prev_tail_q   <= prev_tail_d;
            acc_q         <= acc_d;
            acc_cnt_q     <= acc_cnt_d;
            w0_q          <= w0_d;
            w1_q          <= w1_d;
            w0_valid_q    <= w0_valid_d;
            w1_valid_q    <= w1_valid_d;
            done_q        <= done_d;
            payload_idx_q <= payload_idx_d;
        end
    end

    assign out_w0          = w0_q;
    assign out_w1          = w1_q;
    assign out_w0_valid    = w0_valid_q;
    assign out_w1_valid    = w1_valid_q;
    assign done            = done_q;
    assign out_payload_idx = payload_idx_q;

endmodule
