`timescale 1ns / 1ps

import lynxTypes::*;

module strip_http (
    input  logic                               clk,
    input  logic                               rst_n,
    input  logic                               clear,
    input  logic                               enable,

    // Input AXI-Stream
    input  logic                               s_axis_tvalid,
    input  logic [AXI_DATA_BITS-1:0]           s_axis_tdata,
    input  logic [AXI_DATA_BITS/8-1:0]         s_axis_tkeep,
    input  logic                               s_axis_tlast,
    output logic                               s_axis_tready,

    // Output Aligned AXI-Stream
    output logic                               m_axis_tvalid,
    output logic [AXI_DATA_BITS-1:0]           m_axis_tdata,
    output logic [AXI_DATA_BITS/8-1:0]         m_axis_tkeep,
    output logic                               m_axis_tlast,
    input  logic                               m_axis_tready,

    // Debug words
    output logic [AXI_DATA_BITS-1:0]           out_w0,
    output logic [AXI_DATA_BITS-1:0]           out_w1,
    output logic                               out_w0_valid,
    output logic                               out_w1_valid,
    output logic                               done,

    // Export the payload start index
    output logic [6:0]                         out_payload_idx
);

    localparam int BYTE_LANES   = AXI_DATA_BITS / 8; // 64
    localparam int SEARCH_BYTES = BYTE_LANES + 3;    // 67

    typedef enum logic [1:0] {
        SCAN    = 2'd0,
        FORWARD = 2'd1,
        FLUSH   = 2'd2,
        DONE    = 2'd3
    } state_t;

    state_t state_q, state_d;

    // Registers
    logic [23:0]  prev_tail_q, prev_tail_d;
    logic [511:0] w0_q, w0_d;
    logic [511:0] w1_q, w1_d;
    logic         w0_valid_q, w0_valid_d;
    logic         w1_valid_q, w1_valid_d;
    logic         done_q, done_d;
    logic [6:0]   offset_q, offset_d;

    // Double buffer registers (replaces shift_buffer_q)
    logic [AXI_DATA_BITS-1:0]   prev_tdata_q, prev_tdata_d;
    logic [AXI_DATA_BITS/8-1:0] prev_tkeep_q, prev_tkeep_d;

    // ---------------------------------------------------------------
    // 1. Combinational Search & Mask Generation
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

    // Payload starts 4 bytes after the \r\n\r\n match, adjusted for prev_tail
    // (search_win = {tdata, prev_tail[23:0]} → beat index = match_i + 1)
    logic [6:0] current_beat_idx_w;
    assign current_beat_idx_w = header_offset_w + 7'd1;

    // Generate a clean tkeep mask that drops the HTTP header bytes
    logic [BYTE_LANES-1:0] clean_tkeep_w;
    always_comb begin
        clean_tkeep_w = '0;
        if (current_beat_idx_w < BYTE_LANES) begin
            clean_tkeep_w = {BYTE_LANES{1'b1}} << current_beat_idx_w;
        end
    end

    // ---------------------------------------------------------------
    // 2. The 1024-bit Aligner Logic
    // ---------------------------------------------------------------
    logic [(2*AXI_DATA_BITS)-1:0]   double_tdata_w;
    logic [(2*BYTE_LANES)-1:0]      double_tkeep_w;

    logic [AXI_DATA_BITS-1:0]       shifted_tdata_w;
    logic [BYTE_LANES-1:0]          shifted_tkeep_w;
    logic                           needs_flush_w;

    always_comb begin
        if (state_q == FLUSH) begin
            // In flush, there is no new data, pad the upper 512 bits with zeros
            double_tdata_w = { {AXI_DATA_BITS{1'b0}}, prev_tdata_q };
            double_tkeep_w = { {BYTE_LANES{1'b0}}, prev_tkeep_q };
        end else begin
            // Concatenate current beat and previous beat
            double_tdata_w = { s_axis_tdata, prev_tdata_q };
            double_tkeep_w = { s_axis_tkeep, prev_tkeep_q };
        end

        // Dynamically shift the 1024-bit window down to byte 0
        shifted_tdata_w = double_tdata_w >> (offset_q * 8);
        shifted_tkeep_w = double_tkeep_w >> offset_q;

        // Leftover bytes in the incoming beat after taking `offset` bytes for emit
        needs_flush_w = (s_axis_tkeep >> offset_q) != '0;
    end

    // ---------------------------------------------------------------
    // 3. Main FSM & Data Path
    // ---------------------------------------------------------------
    always_comb begin : fsm_logic
        // Defaults
        state_d      = state_q;
        prev_tail_d  = prev_tail_q;
        w0_d         = w0_q;
        w1_d         = w1_q;
        w0_valid_d   = w0_valid_q;
        w1_valid_d   = w1_valid_q;
        done_d       = done_q;
        offset_d     = offset_q;
        prev_tdata_d = prev_tdata_q;
        prev_tkeep_d = prev_tkeep_q;

        s_axis_tready = 1'b0;
        m_axis_tvalid = 1'b0;
        m_axis_tdata  = '0;
        m_axis_tkeep  = '0;
        m_axis_tlast  = 1'b0;

        if (clear) begin
            state_d      = SCAN;
            prev_tail_d  = '0;
            w0_d         = '0;
            w1_d         = '0;
            w0_valid_d   = 1'b0;
            w1_valid_d   = 1'b0;
            done_d       = 1'b0;
            offset_d     = '0;
            prev_tdata_d = '0;
            prev_tkeep_d = '0;
        end else if (enable && state_q != DONE) begin
            case (state_q)
                SCAN: begin
                    s_axis_tready = 1'b1;
                    if (s_axis_tvalid) begin
                        prev_tail_d = s_axis_tdata[AXI_DATA_BITS-1 -: 24];

                        if (header_match_w) begin
                            // Save the offset and buffer the first beat
                            offset_d     = current_beat_idx_w;
                            prev_tdata_d = s_axis_tdata;
                            prev_tkeep_d = s_axis_tkeep & clean_tkeep_w; // Mask out the header!

                            if (s_axis_tlast) begin
                                // Tiny file that ended in the exact same beat as the header
                                state_d = FLUSH;
                            end else begin
                                state_d = FORWARD;
                            end
                        end else if (s_axis_tlast) begin
                            done_d  = 1'b1;
                            state_d = DONE;
                        end
                    end
                end

                FORWARD: begin
                    // Emit the shifted data
                    m_axis_tvalid = s_axis_tvalid;
                    m_axis_tdata  = shifted_tdata_w;
                    m_axis_tkeep  = shifted_tkeep_w;

                    s_axis_tready = m_axis_tready;

                    if (s_axis_tvalid && m_axis_tready) begin
                        // Save the current beat to act as the bottom half of next cycle's shift
                        prev_tdata_d = s_axis_tdata;
                        prev_tkeep_d = s_axis_tkeep;

                        // Debug saving
                        if (!w0_valid_q) begin
                            w0_d       = shifted_tdata_w;
                            w0_valid_d = 1'b1;
                        end else if (!w1_valid_q) begin
                            w1_d       = shifted_tdata_w;
                            w1_valid_d = 1'b1;
                        end

                        if (s_axis_tlast) begin
                            if (needs_flush_w) begin
                                state_d = FLUSH;
                            end else begin
                                m_axis_tlast = 1'b1;
                                done_d       = 1'b1;
                                state_d      = DONE;
                            end
                        end
                    end
                end

                FLUSH: begin
                    // Emit the remaining upper bytes of the final beat
                    m_axis_tvalid = 1'b1;
                    m_axis_tdata  = shifted_tdata_w;
                    m_axis_tkeep  = shifted_tkeep_w;
                    m_axis_tlast  = 1'b1;

                    if (m_axis_tready) begin
                        // Debug saving for tiny files
                        if (!w0_valid_q) begin
                            w0_d       = shifted_tdata_w;
                            w0_valid_d = 1'b1;
                        end
                        done_d  = 1'b1;
                        state_d = DONE;
                    end
                end

                default: state_d = SCAN;
            endcase
        end
    end

    // ---------------------------------------------------------------
    // 4. Sequential Logic
    // ---------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q      <= SCAN;
            prev_tail_q  <= '0;
            w0_q         <= '0;
            w1_q         <= '0;
            w0_valid_q   <= 1'b0;
            w1_valid_q   <= 1'b0;
            done_q       <= 1'b0;
            offset_q     <= '0;
            prev_tdata_q <= '0;
            prev_tkeep_q <= '0;
        end else begin
            state_q      <= state_d;
            prev_tail_q  <= prev_tail_d;
            w0_q         <= w0_d;
            w1_q         <= w1_d;
            w0_valid_q   <= w0_valid_d;
            w1_valid_q   <= w1_valid_d;
            done_q       <= done_d;
            offset_q     <= offset_d;
            prev_tdata_q <= prev_tdata_d;
            prev_tkeep_q <= prev_tkeep_d;
        end
    end

    // ---------------------------------------------------------------
    // 5. Outputs
    // ---------------------------------------------------------------
    assign out_w0          = w0_q;
    assign out_w1          = w1_q;
    assign out_w0_valid    = w0_valid_q;
    assign out_w1_valid    = w1_valid_q;
    assign done            = done_q;
    assign out_payload_idx = offset_q;

endmodule