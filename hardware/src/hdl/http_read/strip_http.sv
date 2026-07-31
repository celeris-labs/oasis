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
// when the valid bytes start at lane 0.
//
// PIPELINED (2 stages) to break the ctrl_clk critical path. The old design did the
// 67-byte header search AND the 512-bit variable barrel-shift AND the ready-signal
// generation in ONE combinational cone (18 logic levels, SLR-crossing, ending at the
// debug register CE -- WNS -2.281ns @250MHz, which on hardware latched the seam byte
// before it settled and corrupted the body at the first-beat/second-beat merge).
//   Stage 1 (search):   {beat, prev_tail} -> find \r\n\r\n -> register the raw beat
//                        plus its body-start lane (b_idx). Header-only beats are
//                        dropped here; the first body beat and every later beat are
//                        registered into b_*.
//   Stage 2 (justify):  b_* -> mask + 512-bit barrel-shift down to lane 0 -> skid -> m_axis.
// s_axis_tready is now `!b_valid || skid-has-room` -- a pure 2-register function with
// NO dependence on the search, so the search no longer feeds the upstream ready path.
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
    // Stage 1 registers: the captured body beat + where its payload starts.
    // scan_q = still hunting the header (drop beats); cleared once the body starts.
    // ---------------------------------------------------------------
    logic [23:0]                prev_tail_q;
    logic                       scan_q;
    logic [AXI_DATA_BITS-1:0]   b_data_q;
    logic [BYTE_LANES-1:0]      b_keep_q;
    logic [6:0]                 b_idx_q;     // body-start lane for this beat (0 = already justified)
    logic                       b_tlast_q;
    logic                       b_valid_q;
    logic                       done_q;
    logic [6:0]                 payload_idx_q;
    logic [AXI_DATA_BITS-1:0]   w0_q, w1_q;
    logic                       w0_valid_q, w1_valid_q;

    // ---------------------------------------------------------------
    // Combinational header search over {current beat, 3-byte tail of previous beat}.
    // Cone: {s_axis_tdata, prev_tail_q} -> header_offset_w -> current_beat_idx_w. Ends at Stage-1
    // registers -- the 512-bit shift is NOT here (it is in Stage 2).
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

    // Payload start index in current beat (64 => body starts next beat).
    logic [6:0]            current_beat_idx_w;
    assign current_beat_idx_w = header_offset_w + 7'd1;

    // Does THIS beat carry body bytes (header ends here AND at least one lane is >= idx)?
    logic [BYTE_LANES-1:0] scan_body_keep_w;
    logic                  scan_has_body_w;
    always_comb begin
        if (current_beat_idx_w < BYTE_LANES)
            scan_body_keep_w = s_axis_tkeep & ({BYTE_LANES{1'b1}} << current_beat_idx_w);
        else
            scan_body_keep_w = '0;
        scan_has_body_w = header_match_w && (scan_body_keep_w != '0);
    end

    // A beat produces a body beat into b_* when streaming, or (while scanning) when the header
    // ends in it with payload. Otherwise it is a header-only beat and is dropped.
    logic produce_w;
    assign produce_w = (!scan_q) || scan_has_body_w;

    // ---------------------------------------------------------------
    // Stage 2 combinational justify (the 512-bit barrel shift lives here).
    // ---------------------------------------------------------------
    logic [BYTE_LANES-1:0]      clean_keep_w;
    logic [AXI_DATA_BITS-1:0]   just_data_w;
    logic [BYTE_LANES-1:0]      just_keep_w;
    always_comb begin
        clean_keep_w = b_keep_q & ({BYTE_LANES{1'b1}} << b_idx_q); // b_idx_q in 0..63 while valid
        just_data_w  = apply_tkeep(b_data_q, clean_keep_w) >> {b_idx_q, 3'b000};
        just_keep_w  = keep_from_count($countones(clean_keep_w));
    end

    // FSM (Stage-2 -> skid) stream, registered by the skid buffer below.
    logic [AXI_DATA_BITS-1:0]   fsm_tdata;
    logic [BYTE_LANES-1:0]      fsm_tkeep;
    logic                       fsm_tlast;
    logic                       fsm_tvalid;
    logic                       fsm_tready;

    assign fsm_tvalid = b_valid_q;
    assign fsm_tdata  = just_data_w;
    assign fsm_tkeep  = just_keep_w;
    assign fsm_tlast  = b_tlast_q;

    logic b_fire;
    assign b_fire = b_valid_q && fsm_tready;    // Stage 2 consumes b_* into the skid

    // Slave-side ready: accept an input whenever b_* is empty or drains this cycle. No dependence
    // on the header search (during scan b_valid_q=0 => always ready to drop header beats).
    assign s_axis_tready = enable && (!b_valid_q || b_fire);

    logic in_fire;
    assign in_fire = s_axis_tvalid && s_axis_tready;

    // ---------------------------------------------------------------
    // Stage 1 sequential
    // ---------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            prev_tail_q   <= '0;
            scan_q        <= 1'b1;
            b_data_q      <= '0;
            b_keep_q      <= '0;
            b_idx_q       <= '0;
            b_tlast_q     <= 1'b0;
            b_valid_q     <= 1'b0;
            done_q        <= 1'b0;
            payload_idx_q <= '0;
            w0_q          <= '0;
            w1_q          <= '0;
            w0_valid_q    <= 1'b0;
            w1_valid_q    <= 1'b0;
        end else if (enable) begin
            // Stage 2 drained the held beat.
            if (b_fire) b_valid_q <= 1'b0;

            // Debug capture: first two emitted body beats.
            if (b_fire) begin
                if (!w0_valid_q) begin
                    w0_q       <= fsm_tdata;
                    w0_valid_q <= 1'b1;
                end else if (!w1_valid_q) begin
                    w1_q       <= fsm_tdata;
                    w1_valid_q <= 1'b1;
                end
            end

            // Consume one input beat.
            if (in_fire) begin
                prev_tail_q <= s_axis_tdata[AXI_DATA_BITS-1 -: 24];
                if (produce_w) begin
                    // Register a body beat (first beat: shift by current_beat_idx; later: idx 0).
                    b_data_q  <= s_axis_tdata;
                    b_keep_q  <= s_axis_tkeep;
                    b_idx_q   <= scan_q ? current_beat_idx_w : 7'd0;
                    b_tlast_q <= s_axis_tlast;
                    b_valid_q <= 1'b1;
                    if (scan_q) begin
                        payload_idx_q <= current_beat_idx_w;
                        scan_q        <= 1'b0;
                    end
                end else begin
                    // Header-only beat: drop it, keep scanning (or leave scan if header ended here
                    // with the body starting on the next beat, i.e. idx == 64).
                    if (header_match_w) begin
                        payload_idx_q <= current_beat_idx_w; // == 64
                        scan_q        <= 1'b0;
                        if (s_axis_tlast) done_q <= 1'b1;    // header closed with an empty body
                    end else if (s_axis_tlast) begin
                        done_q <= 1'b1;                      // closed before any header/body
                    end
                end
            end

            // The final body beat (tlast) has left Stage 2 -> the body is complete.
            if (b_fire && b_tlast_q) done_q <= 1'b1;
        end
    end

    // ---------------------------------------------------------------
    // Registered output: 2-slot AXI-Stream skid buffer (unchanged). It registers m_axis_* so the
    // Stage-2 barrel-shift cone ends at a flop here and two beats are held under back-pressure.
    // ---------------------------------------------------------------
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
    // Report done once the body's last beat has been produced AND fully drained downstream (Stage-2
    // register empty and both skid slots empty). tcp_read asserts `clear` on seeing `done`.
    assign done            = done_q && !b_valid_q && !skid_valid_q && !skid_valid2_q;
    assign out_payload_idx = payload_idx_q;

endmodule
