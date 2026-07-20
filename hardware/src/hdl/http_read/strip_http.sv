import lynxTypes::*;

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

    // Debug words
    output logic [AXI_DATA_BITS-1:0]       out_w0,
    output logic [AXI_DATA_BITS-1:0]       out_w1,
    output logic                           out_w0_valid,
    output logic                           out_w1_valid,
    output logic                           done,

    // Export the payload start index for your future tkeep manipulation
    output logic [6:0]                     out_payload_idx 
);

    localparam int BYTE_LANES   = AXI_DATA_BITS / 8; // 64
    localparam int SEARCH_BYTES = BYTE_LANES + 3;    // 67

    typedef enum logic [1:0] {
        SCAN    = 2'd0,
        FILL_W1 = 2'd1,
        DONE    = 2'd2
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
        input logic [AXI_DATA_BITS-1:0]        data_in,
        input logic [AXI_DATA_BITS/8-1:0]      keep_in
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

    // Calculate where payload starts in the CURRENT beat (s_axis_tdata).
    // prev_tail takes up indices 0, 1, 2 of search_win_w. 
    // Payload starts 4 bytes after the header match.
    // Index mapping: header_offset_w + 4 (skip header) - 3 (remove prev_tail offset)
    logic [6:0] current_beat_idx_w;
    assign current_beat_idx_w = header_offset_w + 7'd1;

    // Generate a mask to zero out the HTTP header bytes
    logic [511:0] mask_w;
    assign mask_w = {512{1'b1}} << (current_beat_idx_w * 8);


    // ---------------------------------------------------------------
    // 2. Main FSM & Data Path (Single always_comb)
    // ---------------------------------------------------------------
    always_comb begin : fsm_logic
        // Defaults
        state_d       = state_q;
        prev_tail_d   = prev_tail_q;
        w0_d          = w0_q;
        w1_d          = w1_q;
        w0_valid_d    = w0_valid_q;
        w1_valid_d    = w1_valid_q;
        done_d        = done_q;
        payload_idx_d = payload_idx_q;

        if (clear) begin
            state_d       = SCAN;
            prev_tail_d   = '0;
            w0_d          = '0;
            w1_d          = '0;
            w0_valid_d    = 1'b0;
            w1_valid_d    = 1'b0;
            done_d        = 1'b0;
            payload_idx_d = '0;
        end else if (enable && s_axis_tvalid && s_axis_tready) begin
            case (state_q)
                SCAN: begin
                    prev_tail_d = s_axis_tdata[AXI_DATA_BITS-1 -: 24];

                    if (header_match_w) begin
                        // Save the index for downstream tkeep manipulation
                        payload_idx_d = current_beat_idx_w;

                        // Apply the mask to zero out the header bytes
                        w0_d       = apply_tkeep(s_axis_tdata & mask_w, s_axis_tkeep);
                        w0_valid_d = 1'b1;

                        if (s_axis_tlast) begin
                            done_d  = 1'b1;
                            state_d = DONE;
                        end else begin
                            state_d = FILL_W1;
                        end
                    end else if (s_axis_tlast) begin
                        // Stream ended with no header found
                        done_d  = 1'b1;
                        state_d = DONE;
                    end
                end

                FILL_W1: begin
                    // Next beat is 100% payload, no masking needed
                    w1_d       = apply_tkeep(s_axis_tdata, s_axis_tkeep);
                    w1_valid_d = 1'b1;
                    done_d     = 1'b1;
                    state_d    = DONE;
                end

                DONE: begin
                    // Safely wait here. tready is automatically low.
                end

                default: state_d = SCAN;
            endcase
        end
    end

    // ---------------------------------------------------------------
    // 3. Sequential Logic
    // ---------------------------------------------------------------
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
    // 4. Output Assignments
    // ---------------------------------------------------------------
    // Only pull data when enabled and not locked in the DONE state.
    assign s_axis_tready = enable && (state_q != DONE);

    assign out_w0          = w0_q;
    assign out_w1          = w1_q;
    assign out_w0_valid    = w0_valid_q;
    assign out_w1_valid    = w1_valid_q;
    assign done            = done_q;
    assign out_payload_idx = payload_idx_q;

endmodule