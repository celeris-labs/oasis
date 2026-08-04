import lynxTypes::*;

module tcp_send_http (
    input  logic                                      clk,
    input  logic                                      rst_n,
    input  logic                                      start,
    input  logic [15:0]                               session_id,
    input  logic [7:0]                                ipHexLen,
    input  logic [31:0]                               ipHexWord0,
    input  logic [31:0]                               ipHexWord1,
    input  logic [31:0]                               ipHexWord2,
    input  logic [31:0]                               ipHexWord3,
    input  logic [31:0]                               portHexWord0,
    input  logic [31:0]                               fileLen,
    input  logic [31:0]                               fileWord0,
    input  logic [31:0]                               fileWord1,
    input  logic [31:0]                               fileWord2,
    input  logic [31:0]                               fileWord3,
    input  logic [31:0]                               fileWord4,
    input  logic [31:0]                               fileWord5,
    input  logic [31:0]                               fileWord6,
    input  logic [31:0]                               fileWord7,
    input  logic [31:0]                               fileWord8,
    input  logic [31:0]                               fileWord9,
    input  logic [31:0]                               fileWord10,
    input  logic [31:0]                               fileWord11,
    input  logic [31:0]                               fileWord12,
    input  logic [31:0]                               fileWord13,
    input  logic [31:0]                               fileWord14,
    input  logic [31:0]                               fileWord15,
    input  logic [7:0]                                rangeBeginLen,
    input  logic [31:0]                               rangeBeginW0,
    input  logic [31:0]                               rangeBeginW1,
    input  logic [31:0]                               rangeBeginW2,
    input  logic [31:0]                               rangeBeginW3,
    input  logic [7:0]                                rangeEndLen,
    input  logic [31:0]                               rangeEndW0,
    input  logic [31:0]                               rangeEndW1,
    input  logic [31:0]                               rangeEndW2,
    input  logic [31:0]                               rangeEndW3,
    output logic                                      m_axis_tx_meta_TVALID,
    input  logic                                      m_axis_tx_meta_TREADY,
    output logic [TCP_TX_META_BITS-1:0]               m_axis_tx_meta_TDATA,
    output logic                                      m_axis_tx_data_TVALID,
    input  logic                                      m_axis_tx_data_TREADY,
    output logic [AXI_DATA_BITS-1:0]                  m_axis_tx_data_TDATA,
    output logic [AXI_DATA_BITS/8-1:0]                m_axis_tx_data_TKEEP,
    output logic                                      m_axis_tx_data_TLAST,
    input  logic                                      s_axis_tx_status_TVALID,
    output logic                                      s_axis_tx_status_TREADY,
    input  logic [TCP_TX_STAT_BITS-1:0]               s_axis_tx_status_TDATA,
    output logic                                      done,
    output logic                                      error,
    output logic [15:0]                               debug_http_len,
    output logic [3:0]                                state_debug,

    // Debug taps. debug_req_lo/hi carry the request bytes that were actually LATCHED for
    // transmission, and debug_builder_len the length the builder is currently producing. If the two
    // lengths disagree while the request is going out, the latched header is not the one the builder
    // just built (the one-run-behind failure mode).
    output logic [AXI_DATA_BITS-1:0]                  debug_req_lo,
    output logic [AXI_DATA_BITS-1:0]                  debug_req_hi,
    output logic [7:0]                                debug_builder_len,
    output logic [3:0]                                debug_builder_state
);

    localparam logic [3:0] ST_IDLE       = 4'd0;
    localparam logic [3:0] ST_BUILD_HDR  = 4'd3;
    localparam logic [3:0] ST_SEND_META  = 4'd4;
    localparam logic [3:0] ST_SEND_DATA  = 4'd5;
    localparam logic [3:0] ST_WAIT_STAT  = 4'd6;
    localparam logic [3:0] ST_DONE       = 4'd15;

    logic [3:0] state_q, state_d;
    logic [15:0] http_len_q, http_len_d;
    logic [2047:0] http_data_q, http_data_d;
    // Beat index into http_data_q. The builder's buffer is 256 bytes, so a request is at most four
    // 64-byte beats; this used to be a single bit because the buffer was 128 bytes.
    logic [1:0] tx_beat_q, tx_beat_d;
    logic error_q, error_d;

    logic [2047:0] header_data_w;
    logic [15:0] header_len_w;
    logic req_ready_w;

    http_req_builder u_http_builder (
        .ap_clk        (clk),
        .ap_rst_n      (rst_n),
        .start         (state_q == ST_BUILD_HDR),
        .partial_en    (1'b1),
        .ipHexLen      (ipHexLen),
        .ipHex         ({ipHexWord3, ipHexWord2, ipHexWord1, ipHexWord0}),
        .portHex       (portHexWord0),
        .fileLen       (fileLen[6:0]),
        .fileWord0     (fileWord0),
        .fileWord1     (fileWord1),
        .fileWord2     (fileWord2),
        .fileWord3     (fileWord3),
        .fileWord4     (fileWord4),
        .fileWord5     (fileWord5),
        .fileWord6     (fileWord6),
        .fileWord7     (fileWord7),
        .fileWord8     (fileWord8),
        .fileWord9     (fileWord9),
        .fileWord10    (fileWord10),
        .fileWord11    (fileWord11),
        .fileWord12    (fileWord12),
        .fileWord13    (fileWord13),
        .fileWord14    (fileWord14),
        .fileWord15    (fileWord15),
        .rangeBeginLen (rangeBeginLen),
        .rangeBeginW0  (rangeBeginW0),
        .rangeBeginW1  (rangeBeginW1),
        .rangeBeginW2  (rangeBeginW2),
        .rangeBeginW3  (rangeBeginW3),
        .rangeEndLen   (rangeEndLen),
        .rangeEndW0    (rangeEndW0),
        .rangeEndW1    (rangeEndW1),
        .rangeEndW2    (rangeEndW2),
        .rangeEndW3    (rangeEndW3),
        .header_data   (header_data_w),
        .header_len    (header_len_w),
        .req_ready     (req_ready_w),
        .state_debug   (debug_builder_state)
    );

    assign debug_req_lo      = http_data_q[AXI_DATA_BITS-1:0];
    assign debug_req_hi      = http_data_q[2*AXI_DATA_BITS-1:AXI_DATA_BITS];
    assign debug_builder_len = header_len_w[7:0];

    function automatic logic [63:0] make_keep(input logic [6:0] count);
        if (count >= 7'd64) begin
            make_keep = 64'hFFFF_FFFF_FFFF_FFFF;
        end else if (count == 7'd0) begin
            make_keep = 64'h0;
        end else begin
            make_keep = (64'd1 << count) - 64'd1;
        end
    endfunction

    // Per-beat byte count and end-of-packet, derived from the beat index rather than hardcoded for
    // two beats. tx_last_beat drives TLAST, so a header of any length up to 256 bytes terminates on
    // whichever beat actually carries its final byte.
    logic [15:0] tx_offset;
    logic [15:0] tx_remaining;
    logic [6:0]  tx_bytes;
    logic        tx_last_beat;
    logic [11:0] tx_bit_base;

    always_comb begin
        tx_offset    = {14'b0, tx_beat_q} << 6; // tx_beat_q * 64 bytes
        tx_remaining = (http_len_q > tx_offset) ? (http_len_q - tx_offset) : 16'd0;
        tx_bytes     = (tx_remaining >= 16'd64) ? 7'd64 : tx_remaining[6:0];
        tx_last_beat = (tx_remaining <= 16'd64);
    end

    assign tx_bit_base = {10'b0, tx_beat_q} * AXI_DATA_BITS;

    always_comb begin
        state_d = state_q;
        http_len_d = http_len_q;
        http_data_d = http_data_q;
        tx_beat_d = tx_beat_q;
        error_d = error_q;

        m_axis_tx_meta_TVALID = 1'b0;
        m_axis_tx_meta_TDATA = {http_len_q, session_id};
        m_axis_tx_data_TVALID = 1'b0;
        m_axis_tx_data_TDATA = '0;
        m_axis_tx_data_TKEEP = '0;
        m_axis_tx_data_TLAST = 1'b0;
        s_axis_tx_status_TREADY = 1'b0;

        case (state_q)
            ST_IDLE: begin
                if (start) begin
                    error_d = 1'b0;
                    state_d = ST_BUILD_HDR;
                end
            end

            ST_BUILD_HDR: begin
                if (req_ready_w) begin
                    http_len_d = header_len_w;
                    http_data_d = header_data_w;
                    tx_beat_d = 2'd0;
                    state_d = ST_SEND_META;
                end
            end

            ST_SEND_META: begin
                m_axis_tx_meta_TVALID = 1'b1;
                if (m_axis_tx_meta_TVALID && m_axis_tx_meta_TREADY) begin
                    state_d = ST_WAIT_STAT;
                end
            end

            ST_WAIT_STAT: begin
                s_axis_tx_status_TREADY = 1'b1;
                if (s_axis_tx_status_TVALID && s_axis_tx_status_TREADY) begin
                    // tcp_tx_stat_t is {error[63:62], remaining_space[61:32], len[31:16], sid[15:0]}.
                    // This used to read [1:0], which is sid[1:0] -- not the error code.
                    // NOTE: `error` is still not acted upon; on error != 0 the TOE has rejected the
                    // send and pushing the data beats anyway desyncs the TX path. See TODO list.
                    error_d = (s_axis_tx_status_TDATA[TCP_TX_STAT_BITS-1 -: TCP_ERROR_BITS] != '0);
                    state_d = ST_SEND_DATA;
                end
            end

            ST_SEND_DATA: begin
                m_axis_tx_data_TVALID = 1'b1;
                m_axis_tx_data_TDATA  = http_data_q[tx_bit_base +: AXI_DATA_BITS];
                m_axis_tx_data_TKEEP  = make_keep(tx_bytes);
                m_axis_tx_data_TLAST  = tx_last_beat;

                if (m_axis_tx_data_TVALID && m_axis_tx_data_TREADY) begin
                    if (tx_last_beat) begin
                        tx_beat_d = 2'd0;
                        state_d   = ST_DONE;
                    end else begin
                        tx_beat_d = tx_beat_q + 2'd1;
                    end
                end
            end

            ST_DONE: begin
                if (!start) begin
                    state_d = ST_IDLE;
                end
            end

            default: state_d = ST_IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q <= ST_IDLE;
            http_len_q <= 16'd0;
            http_data_q <= '0;
            tx_beat_q <= 2'd0;
            error_q <= 1'b0;
        end else begin
            state_q <= state_d;
            http_len_q <= http_len_d;
            http_data_q <= http_data_d;
            tx_beat_q <= tx_beat_d;
            error_q <= error_d;
        end
    end

    assign done = (state_q == ST_DONE);
    assign error = error_q;
    assign debug_http_len = http_len_q;
    assign state_debug = (state_q == ST_DONE) ? 4'd6 : state_q;

endmodule
