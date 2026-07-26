`timescale 1ns / 1ps

import lynxTypes::*;

// Header strip + first-beat bottom-justify (single response, Connection: close).
//
// Finds the end of the HTTP header (\r\n\r\n) and emits the body as a stream of
// bottom-justified beats: the first body beat has its payload shifted down to
// lane 0 (keep = N ones from lane 0), and every following network beat is passed
// through unchanged (already bottom-justified). The cross-beat repacking into
// full 64B beats is done downstream by the *pipelined* DataNormalizer
// (ENABLE_COMPACTOR=0) -- that is why the first beat MUST be bottom-justified:
// the normalizer places bytes from $countones(keep), which only matches the data
// when the valid bytes start at lane 0. Leaving the first beat top-justified (the
// old behaviour) is exactly what scrambled the output.
//
// Body ends on TCP tlast (server closes the connection after the response).
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

    // Bottom-justified body stream (packed downstream by DataNormalizer)
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

    // FSM drives these (combinational). A registered skid buffer sits between them and
    // m_axis_* so the long header-search + barrel-shift cone does not feed the downstream
    // DataNormalizer combinationally (that 26-level path is the ctrl_clk WNS violator, and on
    // hardware it corrupts the seam bytes that are its deepest logic). fsm_tready is the skid
    // buffer's slave-side ready.
    logic [AXI_DATA_BITS-1:0]   fsm_tdata;
    logic [AXI_DATA_BITS/8-1:0] fsm_tkeep;
    logic                       fsm_tlast;
    logic                       fsm_tvalid;
    logic                       fsm_tready;

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

    // Bottom-justified tkeep for `n` valid bytes (n ones from lane 0).
    function automatic logic [BYTE_LANES-1:0] keep_from_count(input logic [6:0] n);
        begin
            if (n == 0)               keep_from_count = '0;
            else if (n >= BYTE_LANES) keep_from_count = {BYTE_LANES{1'b1}};
            else                      keep_from_count = {BYTE_LANES{1'b1}} >> (BYTE_LANES - n);
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

    logic [BYTE_LANES-1:0]      clean_tkeep_w;   // top-justified payload lanes [K..63]
    logic [AXI_DATA_BITS-1:0]   clean_tdata_w;
    logic                       first_has_payload_w;
    logic [9:0]                 payload_shift_w; // K*8, for shifting the first beat down
    logic [AXI_DATA_BITS-1:0]   first_beat_data_w;
    logic [BYTE_LANES-1:0]      first_beat_keep_w;

    always_comb begin
        if (current_beat_idx_w < BYTE_LANES)
            clean_tkeep_w = s_axis_tkeep & ({BYTE_LANES{1'b1}} << current_beat_idx_w);
        else
            clean_tkeep_w = '0;
        clean_tdata_w       = apply_tkeep(s_axis_tdata, clean_tkeep_w);
        first_has_payload_w = (clean_tkeep_w != '0);
        // Shift the first beat's payload down to lane 0 so the DataNormalizer can
        // pack it (it expects bottom-justified beats).
        payload_shift_w     = {current_beat_idx_w, 3'b0}; // current_beat_idx_w * 8
        first_beat_data_w   = clean_tdata_w >> payload_shift_w;
        first_beat_keep_w   = keep_from_count($countones(clean_tkeep_w));
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
        fsm_tvalid    = 1'b0;
        fsm_tdata     = '0;
        fsm_tkeep     = '0;
        fsm_tlast     = 1'b0;

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
                        // Present first body beat, bottom-justified.
                        fsm_tvalid    = s_axis_tvalid;
                        fsm_tdata     = first_beat_data_w;
                        fsm_tkeep     = first_beat_keep_w;
                        fsm_tlast     = s_axis_tlast;
                        s_axis_tready = fsm_tready;

                        if (s_axis_tvalid && fsm_tready) begin
                            prev_tail_d   = s_axis_tdata[AXI_DATA_BITS-1 -: 24];
                            payload_idx_d = current_beat_idx_w;
                            w0_d          = first_beat_data_w;
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
                                // No payload in this beat — body starts next beat (already
                                // bottom-justified), handled by STREAM passthrough.
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
                    // Full passthrough of remaining body (already bottom-justified).
                    fsm_tvalid    = s_axis_tvalid;
                    fsm_tdata     = apply_tkeep(s_axis_tdata, s_axis_tkeep);
                    fsm_tkeep     = s_axis_tkeep;
                    fsm_tlast     = s_axis_tlast;
                    s_axis_tready = fsm_tready;

                    if (s_axis_tvalid && fsm_tready) begin
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

    // ---------------------------------------------------------------
    // Registered output: 2-slot AXI-Stream skid buffer
    // ---------------------------------------------------------------
    // The FSM produces the first body beat combinationally from the header
    // search + 512-bit barrel shift. Feeding that straight into the downstream
    // DataNormalizer created a 26-logic-level path (header-search -> shift ->
    // AXIToNData -> normalizer offset/barrel) that is the ctrl_clk WNS violator;
    // on hardware its deepest bits (the merge-seam bytes) latch before settling
    // and corrupt the body. This skid buffer registers m_axis_* so the cone ends
    // at a flop here, while still holding two beats so no data is dropped under
    // back-pressure.
    logic [AXI_DATA_BITS-1:0]   skid_data_q,  skid_data2_q;
    logic [BYTE_LANES-1:0]      skid_keep_q,  skid_keep2_q;
    logic                       skid_last_q,  skid_last2_q;
    logic                       skid_valid_q, skid_valid2_q;

    assign fsm_tready    = !skid_valid2_q; // room while the skid slot is empty
    assign m_axis_tvalid = skid_valid_q;
    assign m_axis_tdata  = skid_data_q;
    assign m_axis_tkeep  = skid_keep_q;
    assign m_axis_tlast  = skid_last_q;

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            skid_valid_q  <= 1'b0;
            skid_valid2_q <= 1'b0;
        end else if (m_axis_tready || !skid_valid_q) begin
            // Primary slot free/advancing: drain the skid slot first, else take the FSM beat.
            if (skid_valid2_q) begin
                skid_data_q   <= skid_data2_q;
                skid_keep_q   <= skid_keep2_q;
                skid_last_q   <= skid_last2_q;
                skid_valid_q  <= 1'b1;
                skid_valid2_q <= 1'b0;
            end else begin
                skid_data_q  <= fsm_tdata;
                skid_keep_q  <= fsm_tkeep;
                skid_last_q  <= fsm_tlast;
                skid_valid_q <= fsm_tvalid;
            end
        end else if (fsm_tvalid && fsm_tready) begin
            // Primary stalled: park the incoming beat in the skid slot.
            skid_data2_q  <= fsm_tdata;
            skid_keep2_q  <= fsm_tkeep;
            skid_last2_q  <= fsm_tlast;
            skid_valid2_q <= 1'b1;
        end
    end

    assign out_w0          = w0_q;
    assign out_w1          = w1_q;
    assign out_w0_valid    = w0_valid_q;
    assign out_w1_valid    = w1_valid_q;
    // Only report done once the FSM is finished AND the skid buffer has fully drained
    // downstream. tcp_read asserts `clear` as soon as it sees `done`, which resets the skid;
    // gating done on an empty skid guarantees the last registered beat(s) are not flushed.
    assign done            = done_q && !skid_valid_q && !skid_valid2_q;
    assign out_payload_idx = payload_idx_q;

endmodule
