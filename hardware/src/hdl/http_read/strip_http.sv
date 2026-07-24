`timescale 1ns / 1ps

import lynxTypes::*;

// Header strip + 64B align, with Content-Length response framing.
//
// Scans each HTTP response header byte-serially (headers are small, so the cost
// is negligible next to network latency) to find both the \r\n\r\n terminator and
// the Content-Length value. The body is then streamed at full rate as a packed,
// byte-0-aligned AXIS stream: every beat except the last of a response is full,
// the last carries a bottom-justified partial tkeep.
//
// Framing:
//   * Content-Length present -> body ends after exactly that many bytes, tlast is
//     asserted there, and the scanner returns to the header state. This is what
//     makes keep-alive / pipelined responses on one connection possible: several
//     responses can arrive back to back in a single TCP stream, even sharing a beat.
//   * Content-Length absent -> falls back to "body ends when the connection ends"
//     (TCP tlast), which is the Connection: close behaviour.
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

    // Aligned, packed body stream; tlast delimits each response body.
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

    // Level: the TCP stream ended (connection closed).
    output logic                           done,
    // Pulse: one response body was fully emitted.
    output logic                           resp_done,
    // Content-Length of the response being streamed (0 = absent / tlast framing).
    output logic [31:0]                    out_content_len,

    // Payload start index within the first body beat (0..64)
    output logic [6:0]                     out_payload_idx
);

    localparam int DW         = AXI_DATA_BITS;     // 512
    localparam int BYTE_LANES = AXI_DATA_BITS / 8; // 64

    // "content-length:" (lowercase, matched case-insensitively)
    localparam int CL_LEN = 15;
    localparam logic [CL_LEN*8-1:0] CL_PATTERN = "content-length:";

    typedef enum logic [1:0] {
        HDR   = 2'd0,
        BODY  = 2'd1,
        FLUSH = 2'd2,
        DONE  = 2'd3
    } state_t;

    state_t state_q, state_d;

    // Buffered beat under byte-serial header scan
    logic [DW-1:0] hdr_beat_q, hdr_beat_d;
    logic [6:0]    hdr_cnt_q, hdr_cnt_d;     // valid bytes in the buffered beat
    logic          hdr_last_q, hdr_last_d;   // buffered beat carried TCP tlast
    logic          hdr_valid_q, hdr_valid_d; // a beat is buffered
    logic [6:0]    byte_idx_q, byte_idx_d;   // scan position within the beat

    // Header scanner state
    logic [31:0] crlf_sr_q, crlf_sr_d;       // last 4 bytes, newest in the MSB
    logic [3:0]  cl_pos_q, cl_pos_d;         // matched chars of "content-length:"
    logic [31:0] cl_val_q, cl_val_d;         // accumulated decimal value
    logic        cl_found_q, cl_found_d;     // a Content-Length was parsed
    logic        cl_active_q, cl_active_d;   // consuming the value after the colon
    logic        line_start_q, line_start_d; // at the first byte of a header line

    // Body state
    logic [31:0] remaining_q, remaining_d;   // body bytes still expected
    logic        len_known_q, len_known_d;   // framing by Content-Length
    logic [DW-1:0] acc_q, acc_d;             // pending output bytes, bottom-justified
    logic [6:0]    acc_cnt_q, acc_cnt_d;     // valid bytes in acc (0..63)
    logic          stream_end_q, stream_end_d; // TCP tlast seen for this stream

    // Debug
    logic [DW-1:0] w0_q, w0_d, w1_q, w1_d;
    logic          w0_valid_q, w0_valid_d, w1_valid_q, w1_valid_d;
    logic [6:0]    payload_idx_q, payload_idx_d;
    logic [31:0]   content_len_q, content_len_d;

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

    // Keep only the low `n` bytes of `data`.
    function automatic logic [DW-1:0] mask_low_bytes(
        input logic [DW-1:0] data,
        input logic [6:0]    n
    );
        begin
            mask_low_bytes = apply_tkeep(data, keep_from_count(n));
        end
    endfunction

    function automatic logic [7:0] to_lower(input logic [7:0] c);
        begin
            to_lower = (c >= 8'h41 && c <= 8'h5A) ? (c | 8'h20) : c;
        end
    endfunction

    function automatic logic is_digit(input logic [7:0] c);
        begin
            is_digit = (c >= 8'h30 && c <= 8'h39);
        end
    endfunction

    // ---------------------------------------------------------------
    // Body datapath: merge the incoming chunk on top of the accumulator
    // ---------------------------------------------------------------
    logic [6:0]      in_cnt_w;     // valid bytes on the wire
    logic [6:0]      take_w;       // bytes of those belonging to this body
    logic [DW-1:0]   chunk_w;      // bottom-justified bytes to append
    logic [2*DW-1:0] combined_w;
    logic [7:0]      total_w;

    assign in_cnt_w = $countones(s_axis_tkeep);
    always_comb begin
        if (len_known_q && (remaining_q < {25'b0, in_cnt_w})) begin
            take_w = remaining_q[6:0];
        end else begin
            take_w = in_cnt_w;
        end
    end
    assign chunk_w    = mask_low_bytes(apply_tkeep(s_axis_tdata, s_axis_tkeep), take_w);
    assign combined_w = {{DW{1'b0}}, acc_q}
                      | ({{DW{1'b0}}, chunk_w} << ({3'b0, acc_cnt_q} * 8));
    assign total_w    = {1'b0, acc_cnt_q} + {1'b0, take_w};

    // ---------------------------------------------------------------
    // Header scan of the currently buffered byte
    // ---------------------------------------------------------------
    logic [7:0] hdr_byte_w;
    logic [7:0] hdr_lower_w;
    logic       hdr_has_byte_w;

    assign hdr_byte_w     = hdr_beat_q[{3'b0, byte_idx_q} * 8 +: 8];
    assign hdr_lower_w    = to_lower(hdr_byte_w);
    assign hdr_has_byte_w = hdr_valid_q && (byte_idx_q < hdr_cnt_q);

    // Body start once the terminator is seen at byte_idx_q
    logic [6:0]  body_start_w;  // first body byte index in the buffered beat
    logic [6:0]  body_avail_w;  // body bytes available in this beat
    logic [6:0]  body_take_w;   // of those, how many belong to this response
    logic [31:0] body_len_w;

    assign body_start_w = byte_idx_q + 7'd1;
    assign body_avail_w = (hdr_cnt_q > body_start_w) ? (hdr_cnt_q - body_start_w) : 7'd0;
    assign body_len_w   = cl_found_q ? cl_val_q : 32'd0;
    always_comb begin
        if (cl_found_q && (body_len_w < {25'b0, body_avail_w})) begin
            body_take_w = body_len_w[6:0];
        end else begin
            body_take_w = body_avail_w;
        end
    end

    // ---------------------------------------------------------------
    // FSM
    // ---------------------------------------------------------------
    always_comb begin : fsm_logic
        state_d       = state_q;
        hdr_beat_d    = hdr_beat_q;
        hdr_cnt_d     = hdr_cnt_q;
        hdr_last_d    = hdr_last_q;
        hdr_valid_d   = hdr_valid_q;
        byte_idx_d    = byte_idx_q;
        crlf_sr_d     = crlf_sr_q;
        cl_pos_d      = cl_pos_q;
        cl_val_d      = cl_val_q;
        cl_found_d    = cl_found_q;
        cl_active_d   = cl_active_q;
        line_start_d  = line_start_q;
        remaining_d   = remaining_q;
        len_known_d   = len_known_q;
        acc_d         = acc_q;
        acc_cnt_d     = acc_cnt_q;
        stream_end_d  = stream_end_q;
        w0_d          = w0_q;
        w1_d          = w1_q;
        w0_valid_d    = w0_valid_q;
        w1_valid_d    = w1_valid_q;
        payload_idx_d = payload_idx_q;
        content_len_d = content_len_q;

        s_axis_tready = 1'b0;
        m_axis_tvalid = 1'b0;
        m_axis_tdata  = '0;
        m_axis_tkeep  = '0;
        m_axis_tlast  = 1'b0;
        resp_done     = 1'b0;

        if (clear) begin
            state_d       = HDR;
            hdr_beat_d    = '0;
            hdr_cnt_d     = '0;
            hdr_last_d    = 1'b0;
            hdr_valid_d   = 1'b0;
            byte_idx_d    = '0;
            crlf_sr_d     = '0;
            cl_pos_d      = '0;
            cl_val_d      = '0;
            cl_found_d    = 1'b0;
            cl_active_d   = 1'b0;
            line_start_d  = 1'b1;
            remaining_d   = '0;
            len_known_d   = 1'b0;
            acc_d         = '0;
            acc_cnt_d     = '0;
            stream_end_d  = 1'b0;
            w0_d          = '0;
            w1_d          = '0;
            w0_valid_d    = 1'b0;
            w1_valid_d    = 1'b0;
            payload_idx_d = '0;
            content_len_d = '0;
        end else if (enable && state_q != DONE) begin
            case (state_q)
                // Byte-serial scan for \r\n\r\n and Content-Length.
                HDR: begin
                    if (!hdr_valid_q) begin
                        // Need a beat to scan.
                        s_axis_tready = 1'b1;
                        if (s_axis_tvalid) begin
                            hdr_beat_d  = apply_tkeep(s_axis_tdata, s_axis_tkeep);
                            hdr_cnt_d   = $countones(s_axis_tkeep);
                            hdr_last_d  = s_axis_tlast;
                            hdr_valid_d = 1'b1;
                            byte_idx_d  = '0;
                            if (s_axis_tlast) begin
                                stream_end_d = 1'b1;
                            end
                            // An empty final beat ends the stream outright.
                            if (s_axis_tlast && ($countones(s_axis_tkeep) == 0)) begin
                                state_d = DONE;
                            end
                        end
                    end else if (hdr_has_byte_w) begin
                        byte_idx_d = byte_idx_q + 7'd1;
                        crlf_sr_d  = {hdr_byte_w, crlf_sr_q[31:8]};

                        // Track start-of-line so Content-Length only matches a header name.
                        if (hdr_byte_w == 8'h0A) begin
                            line_start_d = 1'b1;
                        end else if (hdr_byte_w != 8'h0D) begin
                            line_start_d = 1'b0;
                        end

                        // Content-Length matcher
                        if (cl_active_q) begin
                            if (is_digit(hdr_byte_w)) begin
                                cl_val_d   = (cl_val_q * 32'd10) + {28'b0, hdr_byte_w[3:0]};
                                cl_found_d = 1'b1;
                            end else if (hdr_byte_w != 8'h20 && hdr_byte_w != 8'h09) begin
                                // End of the value (CR or anything else).
                                cl_active_d = 1'b0;
                                cl_pos_d    = '0;
                            end
                        end else if (cl_pos_q == CL_LEN[3:0]) begin
                            cl_active_d = 1'b1;
                            cl_val_d    = '0;
                            if (is_digit(hdr_byte_w)) begin
                                cl_val_d   = {28'b0, hdr_byte_w[3:0]};
                                cl_found_d = 1'b1;
                            end
                        end else if (hdr_lower_w == CL_PATTERN[(CL_LEN-1-cl_pos_q)*8 +: 8] &&
                                     (cl_pos_q != 0 || line_start_q)) begin
                            cl_pos_d = cl_pos_q + 4'd1;
                        end else begin
                            cl_pos_d = '0;
                        end

                        // Header terminator?
                        if ({hdr_byte_w, crlf_sr_q[31:8]} == 32'h0A0D0A0D) begin
                            content_len_d = body_len_w;
                            len_known_d   = cl_found_q;
                            payload_idx_d = body_start_w;

                            // Load whatever body bytes share this beat.
                            acc_d     = mask_low_bytes(
                                            hdr_beat_q >> ({3'b0, body_start_w} * 8), body_take_w);
                            acc_cnt_d = body_take_w;
                            if (!w0_valid_q) begin
                                w0_d       = mask_low_bytes(
                                                 hdr_beat_q >> ({3'b0, body_start_w} * 8), body_take_w);
                                w0_valid_d = 1'b1;
                            end

                            if (cl_found_q && (body_len_w <= {25'b0, body_avail_w})) begin
                                // Whole body was in this beat.
                                remaining_d = '0;
                                byte_idx_d  = body_start_w + body_take_w;
                                state_d     = FLUSH;
                            end else begin
                                remaining_d = cl_found_q ? (body_len_w - {25'b0, body_take_w}) : 32'd0;
                                hdr_valid_d = 1'b0; // beat consumed, body continues on the wire
                                if (hdr_last_q) begin
                                    // Connection ended with the header's beat.
                                    state_d = FLUSH;
                                end else begin
                                    state_d = BODY;
                                end
                            end

                            // Reset per-response scanner state.
                            crlf_sr_d    = '0;
                            cl_pos_d     = '0;
                            cl_val_d     = '0;
                            cl_found_d   = 1'b0;
                            cl_active_d  = 1'b0;
                            line_start_d = 1'b1;
                        end
                    end else begin
                        // Beat exhausted without a terminator.
                        hdr_valid_d = 1'b0;
                        if (hdr_last_q) begin
                            state_d = DONE;
                        end
                    end
                end

                BODY: begin
                    if (s_axis_tvalid) begin
                        // A full output beat is ready.
                        if (total_w >= 8'd64) begin
                            m_axis_tvalid = 1'b1;
                            m_axis_tdata  = combined_w[DW-1:0];
                            m_axis_tkeep  = {BYTE_LANES{1'b1}};
                            m_axis_tlast  = (total_w == 8'd64) &&
                                            ((len_known_q && (remaining_q == {25'b0, take_w})) ||
                                             (!len_known_q && s_axis_tlast));
                            s_axis_tready = m_axis_tready;

                            if (m_axis_tready) begin
                                acc_d     = combined_w[2*DW-1:DW];
                                acc_cnt_d = total_w[6:0] - 7'd64;
                                if (!w1_valid_q) begin
                                    w1_d       = combined_w[DW-1:0];
                                    w1_valid_d = 1'b1;
                                end
                                if (s_axis_tlast) begin
                                    stream_end_d = 1'b1;
                                end
                                if (len_known_q) begin
                                    remaining_d = remaining_q - {25'b0, take_w};
                                end

                                if ((len_known_q && (remaining_q == {25'b0, take_w})) ||
                                    (!len_known_q && s_axis_tlast)) begin
                                    // Body complete.
                                    if (total_w == 8'd64) begin
                                        resp_done = 1'b1;
                                        if (s_axis_tlast || !len_known_q) begin
                                            state_d = DONE;
                                        end else begin
                                            state_d     = HDR;
                                            hdr_valid_d = 1'b0;
                                        end
                                        // Leftover bytes in this beat start the next response.
                                        if (len_known_q && (in_cnt_w > take_w) && !s_axis_tlast) begin
                                            hdr_beat_d  = apply_tkeep(s_axis_tdata, s_axis_tkeep);
                                            hdr_cnt_d   = in_cnt_w;
                                            hdr_last_d  = s_axis_tlast;
                                            hdr_valid_d = 1'b1;
                                            byte_idx_d  = take_w;
                                        end
                                    end else begin
                                        state_d = FLUSH;
                                        if (len_known_q && (in_cnt_w > take_w) && !s_axis_tlast) begin
                                            hdr_beat_d  = apply_tkeep(s_axis_tdata, s_axis_tkeep);
                                            hdr_cnt_d   = in_cnt_w;
                                            hdr_last_d  = s_axis_tlast;
                                            hdr_valid_d = 1'b1;
                                            byte_idx_d  = take_w;
                                        end else begin
                                            hdr_valid_d = 1'b0;
                                        end
                                    end
                                end
                            end
                        end else begin
                            // Accumulate; emit nothing this cycle.
                            s_axis_tready = 1'b1;
                            acc_d         = combined_w[DW-1:0];
                            acc_cnt_d     = total_w[6:0];
                            if (s_axis_tlast) begin
                                stream_end_d = 1'b1;
                            end
                            if (len_known_q) begin
                                remaining_d = remaining_q - {25'b0, take_w};
                            end

                            if ((len_known_q && (remaining_q == {25'b0, take_w})) ||
                                (!len_known_q && s_axis_tlast)) begin
                                state_d = FLUSH;
                                if (len_known_q && (in_cnt_w > take_w) && !s_axis_tlast) begin
                                    hdr_beat_d  = apply_tkeep(s_axis_tdata, s_axis_tkeep);
                                    hdr_cnt_d   = in_cnt_w;
                                    hdr_last_d  = s_axis_tlast;
                                    hdr_valid_d = 1'b1;
                                    byte_idx_d  = take_w;
                                end else begin
                                    hdr_valid_d = 1'b0;
                                end
                            end
                        end
                    end
                end

                // Emit the bytes still held in the accumulator as the response's last beat.
                FLUSH: begin
                    m_axis_tvalid = 1'b1;
                    m_axis_tdata  = acc_q;
                    m_axis_tkeep  = keep_from_count(acc_cnt_q);
                    m_axis_tlast  = 1'b1;
                    if (m_axis_tready) begin
                        resp_done = 1'b1;
                        acc_d     = '0;
                        acc_cnt_d = '0;
                        if (stream_end_q || !len_known_q) begin
                            state_d = DONE;
                        end else begin
                            state_d = HDR;
                        end
                    end
                end

                default: state_d = HDR;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q       <= HDR;
            hdr_beat_q    <= '0;
            hdr_cnt_q     <= '0;
            hdr_last_q    <= 1'b0;
            hdr_valid_q   <= 1'b0;
            byte_idx_q    <= '0;
            crlf_sr_q     <= '0;
            cl_pos_q      <= '0;
            cl_val_q      <= '0;
            cl_found_q    <= 1'b0;
            cl_active_q   <= 1'b0;
            line_start_q  <= 1'b1;
            remaining_q   <= '0;
            len_known_q   <= 1'b0;
            acc_q         <= '0;
            acc_cnt_q     <= '0;
            stream_end_q  <= 1'b0;
            w0_q          <= '0;
            w1_q          <= '0;
            w0_valid_q    <= 1'b0;
            w1_valid_q    <= 1'b0;
            payload_idx_q <= '0;
            content_len_q <= '0;
        end else begin
            state_q       <= state_d;
            hdr_beat_q    <= hdr_beat_d;
            hdr_cnt_q     <= hdr_cnt_d;
            hdr_last_q    <= hdr_last_d;
            hdr_valid_q   <= hdr_valid_d;
            byte_idx_q    <= byte_idx_d;
            crlf_sr_q     <= crlf_sr_d;
            cl_pos_q      <= cl_pos_d;
            cl_val_q      <= cl_val_d;
            cl_found_q    <= cl_found_d;
            cl_active_q   <= cl_active_d;
            line_start_q  <= line_start_d;
            remaining_q   <= remaining_d;
            len_known_q   <= len_known_d;
            acc_q         <= acc_d;
            acc_cnt_q     <= acc_cnt_d;
            stream_end_q  <= stream_end_d;
            w0_q          <= w0_d;
            w1_q          <= w1_d;
            w0_valid_q    <= w0_valid_d;
            w1_valid_q    <= w1_valid_d;
            payload_idx_q <= payload_idx_d;
            content_len_q <= content_len_d;
        end
    end

    assign out_w0          = w0_q;
    assign out_w1          = w1_q;
    assign out_w0_valid    = w0_valid_q;
    assign out_w1_valid    = w1_valid_q;
    assign done            = (state_q == DONE);
    assign out_content_len = content_len_q;
    assign out_payload_idx = payload_idx_q;

endmodule
