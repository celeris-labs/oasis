`timescale 1ns / 1ps

import lynxTypes::*;

// Working header strip (SCAN + debug w0/w1), extended with a streaming AXIS body
// output: header bytes cleared in tkeep/tdata, body left unaligned for DataNormalizer.
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

    // Stripped (not aligned) body stream
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

    localparam int BYTE_LANES   = AXI_DATA_BITS / 8; // 64
    localparam int SEARCH_BYTES = BYTE_LANES + 3;    // 67

    typedef enum logic [1:0] {
        SCAN   = 2'd0,
        STREAM = 2'd1,
        DONE   = 2'd2
    } state_t;

    state_t state_q, state_d;

    logic [23:0]  prev_tail_q, prev_tail_d;
    logic [511:0] w0_q, w0_d;
    logic [511:0] w1_q, w1_d;
    logic         w0_valid_q, w0_valid_d;
    logic         w1_valid_q, w1_valid_d;
    logic         done_q, done_d;
    logic [6:0]   payload_idx_q, payload_idx_d;

    function automatic logic [AXI_DATA_BITS-1:0] apply_tkeep(
        input logic [AXI_DATA_BITS-1:0]   data_in,
        input logic [AXI_DATA_BITS/8-1:0] keep_in
    );
        logic [AXI_DATA_BITS-1:0] data_masked;
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

    // ---------------------------------------------------------------
    // Combinational search & mask (unchanged mapping from working RTL)
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

    logic [AXI_DATA_BITS-1:0]   mask_w;
    logic [BYTE_LANES-1:0]      clean_tkeep_w;
    logic [AXI_DATA_BITS-1:0]   clean_tdata_w;
    logic                       first_has_payload_w;

    always_comb begin
        mask_w = '0;
        if (current_beat_idx_w < BYTE_LANES) begin
            mask_w = {AXI_DATA_BITS{1'b1}} << (current_beat_idx_w * 8);
            clean_tkeep_w = s_axis_tkeep & ({BYTE_LANES{1'b1}} << current_beat_idx_w);
        end else begin
            clean_tkeep_w = '0;
        end
        clean_tdata_w      = apply_tkeep(s_axis_tdata & mask_w, clean_tkeep_w);
        first_has_payload_w = (clean_tkeep_w != '0);
    end

    // ---------------------------------------------------------------
    // FSM
    // ---------------------------------------------------------------
    always_comb begin : fsm_logic
        state_d       = state_q;
        prev_tail_d   = prev_tail_q;
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
            w0_d          = '0;
            w1_d          = '0;
            w0_valid_d    = 1'b0;
            w1_valid_d    = 1'b0;
            done_d        = 1'b0;
            payload_idx_d = '0;
        end else if (enable && state_q != DONE) begin
            case (state_q)
                SCAN: begin
                    if (header_match_w && first_has_payload_w) begin
                        // Present first (masked) body beat; tlast independent of ready
                        m_axis_tvalid = s_axis_tvalid;
                        m_axis_tdata  = clean_tdata_w;
                        m_axis_tkeep  = clean_tkeep_w;
                        m_axis_tlast  = s_axis_tlast;
                        s_axis_tready = m_axis_tready;

                        if (s_axis_tvalid && m_axis_tready) begin
                            prev_tail_d   = s_axis_tdata[AXI_DATA_BITS-1 -: 24];
                            payload_idx_d = current_beat_idx_w;
                            w0_d          = clean_tdata_w;
                            w0_valid_d    = 1'b1;

                            if (s_axis_tlast) begin
                                done_d  = 1'b1;
                                state_d = DONE;
                            end else begin
                                state_d = STREAM;
                            end
                        end
                    end else begin
                        // Drop header-only beats, or match with body on next beat
                        s_axis_tready = 1'b1;
                        if (s_axis_tvalid) begin
                            prev_tail_d = s_axis_tdata[AXI_DATA_BITS-1 -: 24];

                            if (header_match_w) begin
                                payload_idx_d = current_beat_idx_w;
                                // No payload in this beat — debug w0 stays empty until STREAM
                                if (s_axis_tlast) begin
                                    done_d  = 1'b1;
                                    state_d = DONE;
                                end else begin
                                    state_d = STREAM;
                                end
                            end else if (s_axis_tlast) begin
                                done_d  = 1'b1;
                                state_d = DONE;
                            end
                        end
                    end
                end

                STREAM: begin
                    // Full passthrough of remaining body (still unaligned if mid-beat start)
                    m_axis_tvalid = s_axis_tvalid;
                    m_axis_tdata  = apply_tkeep(s_axis_tdata, s_axis_tkeep);
                    m_axis_tkeep  = s_axis_tkeep;
                    m_axis_tlast  = s_axis_tlast;
                    s_axis_tready = m_axis_tready;

                    if (s_axis_tvalid && m_axis_tready) begin
                        if (!w0_valid_q) begin
                            w0_d       = apply_tkeep(s_axis_tdata, s_axis_tkeep);
                            w0_valid_d = 1'b1;
                        end else if (!w1_valid_q) begin
                            w1_d       = apply_tkeep(s_axis_tdata, s_axis_tkeep);
                            w1_valid_d = 1'b1;
                        end

                        if (s_axis_tlast) begin
                            done_d  = 1'b1;
                            state_d = DONE;
                        end
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
            w0_q          <= '0;
            w1_q          <= '0;
            w0_valid_q    <= 1'b0;
            w1_valid_q    <= 1'b0;
            done_q        <= 1'b0;
            payload_idx_q <= '0;
        end else begin
            state_q       <= state_d;
            prev_tail_q   <= prev_tail_d;
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
