`timescale 1ns / 1ps

import lynxTypes::*;

// HTTP/1.1 response framer for a persistent connection: parses the status line and the headers
// byte by byte, takes Content-Length and passes the body on bottom-justified (valid bytes from lane
// 0), as the DataNormalizer downstream requires. A beat can hold the end of one body and the start
// of the next response, so it is kept in a residue register and read through one byte cursor and
// barrel shift, for a header byte and a body beat alike. resp_done rises once the last body beat
// has left the output skid and stays up until resp_ack; meanwhile the parser may read the next
// header but stops at its final LF. A header block without Content-Length (e.g. chunked) sets
// resp_error and stops the input.
module strip_http (
    input  logic                           clk,
    input  logic                           rst_n,
    // Resets all framing state. Only on a new connection: the residue holds the next header.
    input  logic                           clear,
    input  logic                           enable,

    input  logic                           body_last,  // this response ends the decoder stream
    input  logic                           resp_ack,   // retire resp_done, arm the next response

    input  logic                           s_axis_tvalid,
    input  logic [AXI_DATA_BITS-1:0]       s_axis_tdata,
    input  logic [AXI_DATA_BITS/8-1:0]     s_axis_tkeep,
    input  logic                           s_axis_tlast,   // ignored: framing is by Content-Length
    output logic                           s_axis_tready,

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

    output logic                           resp_done,      // body complete and drained
    output logic                           resp_dirty,     // >=1 body beat of this response emitted
    output logic                           resp_error,     // header block had no Content-Length
    output logic [23:0]                    status_ascii,   // e.g. "206"
    output logic                           status_ok,      // 200 or 206
    output logic [31:0]                    content_length, // Content-Length of the last response
    output logic [31:0]                    body_remaining, // body bytes still to stream

    // Payload start index within the first body beat (0..63)
    output logic [6:0]                     out_payload_idx
);

    localparam int BYTE_LANES = AXI_DATA_BITS / 8;

    function automatic logic [BYTE_LANES-1:0] keep_from_count(input logic [6:0] n);
        begin
            if (n == 0)               keep_from_count = '0;
            else if (n >= BYTE_LANES) keep_from_count = {BYTE_LANES{1'b1}};
            else                      keep_from_count = {BYTE_LANES{1'b1}} >> (BYTE_LANES - n);
        end
    endfunction

    function automatic logic [AXI_DATA_BITS-1:0] mask_bytes(
        input logic [AXI_DATA_BITS-1:0] data_in,
        input logic [BYTE_LANES-1:0]    keep_in
    );
        begin
            mask_bytes = '0;
            for (int lane = 0; lane < BYTE_LANES; lane++) begin
                if (keep_in[lane]) mask_bytes[lane*8 +: 8] = data_in[lane*8 +: 8];
            end
        end
    endfunction

    // Output skid registers, declared early because the completion logic reads them.
    logic [AXI_DATA_BITS-1:0] skid_data_q,  skid_data2_q;
    logic [BYTE_LANES-1:0]    skid_keep_q,  skid_keep2_q;
    logic                     skid_last_q,  skid_last2_q;
    logic                     skid_valid_q, skid_valid2_q;

    // Residue: one input beat plus the byte cursor into it.
    logic                     res_valid_q;
    logic [AXI_DATA_BITS-1:0] res_data_q;
    logic [6:0]               res_len_q;   // valid bytes in the held beat (0..64)
    logic [6:0]               res_cur_q;   // bytes already consumed

    logic [6:0] avail_w;
    assign avail_w = res_len_q - res_cur_q;

    // Only res_cur_q[5:0] is used: the cursor is below res_len_q (<= 64) whenever this is read, and
    // a 6-bit amount gives a plain 64-way byte shifter.
    logic [AXI_DATA_BITS-1:0] shifted_w;
    assign shifted_w = res_data_q >> {res_cur_q[5:0], 3'b000};

    logic [7:0] cur_byte_w;
    assign cur_byte_w = shifted_w[7:0];

    localparam logic M_HDR  = 1'b0;
    localparam logic M_BODY = 1'b1;

    logic        mode_q;
    logic [31:0] body_left_q;

    // Header parser. In HS_LINE_BEGIN a bare CR is the blank line that ends the block; HS_NAME
    // matches "content-length" case-insensitively and HS_VAL accumulates its digits.
    localparam logic [2:0] HS_STATUS     = 3'd0;
    localparam logic [2:0] HS_LINE_BEGIN = 3'd1;
    localparam logic [2:0] HS_HDR_CR     = 3'd2;
    localparam logic [2:0] HS_NAME       = 3'd3;
    localparam logic [2:0] HS_VAL        = 3'd4;
    localparam logic [2:0] HS_LINE_LF    = 3'd5;

    localparam int NAME_CL_LEN = 14;
    localparam logic [NAME_CL_LEN*8-1:0] NAME_CL = "content-length";

    logic [2:0]  hs_q;
    logic [4:0]  name_pos_q;   // 0..31, saturating
    logic        name_is_cl_q; // still matching "content-length"
    logic        val_is_cl_q;  // the value being consumed belongs to Content-Length
    logic [31:0] cl_q;
    logic        cl_seen_q;
    // Content-Length of the response being framed, latched: body_remaining counts down to zero.
    logic [31:0] cl_latched_q;
    logic [23:0] status_q;
    // Latched like cl_latched_q: status_q already shifts in the next response's digits while the
    // handler may still be sampling this one.
    logic [23:0] status_latched_q;
    // Registered beside status_latched_q, from the same value, so the compares are not on the path
    // to the handler, which may sit in another SLR.
    logic        status_ok_q;
    logic [1:0]  status_sp_q;  // spaces seen in the status line (saturating)
    logic [1:0]  status_cnt_q; // status digits captured (0..3)

    logic [7:0] lower_w;
    assign lower_w = (cur_byte_w >= 8'h41 && cur_byte_w <= 8'h5A) ? (cur_byte_w | 8'h20) : cur_byte_w;

    logic [4:0] name_idx_w;
    assign name_idx_w = (name_pos_q < 5'(NAME_CL_LEN)) ? (5'(NAME_CL_LEN-1) - name_pos_q) : 5'd0;

    // A string literal packs its last character into the LSB, so character i sits at (LEN-1-i)*8.
    logic name_char_hit_w;  // current byte continues the "content-length" match
    logic name_first_hit_w; // current byte is its first character
    assign name_char_hit_w  = name_is_cl_q && (name_pos_q < 5'(NAME_CL_LEN)) &&
                              (lower_w == NAME_CL[name_idx_w*8 +: 8]);
    assign name_first_hit_w = (lower_w == NAME_CL[(NAME_CL_LEN-1)*8 +: 8]);

    logic is_digit_w;
    assign is_digit_w = (cur_byte_w >= 8'h30) && (cur_byte_w <= 8'h39);

    logic resp_done_q;   // body complete and drained; cleared by resp_ack
    logic drain_wait_q;  // final beat produced, still in the skid
    logic dirty_q;
    logic error_q;

    // The parser holds only at the LF that ends the next header block, from the moment the body
    // ends until resp_ack, so a segment that straddles two responses still drains.
    logic hdr_block_w;
    assign hdr_block_w = (resp_done_q || drain_wait_q) && (hs_q == HS_HDR_CR);

    logic       take_hdr_w;
    logic [6:0] body_n_w;
    logic       body_fire_w;

    assign take_hdr_w = enable && res_valid_q && !error_q && (mode_q == M_HDR) &&
                        (avail_w != 0) && !hdr_block_w;

    always_comb begin
        if ((mode_q == M_BODY) && res_valid_q && !error_q && (avail_w != 0)) begin
            body_n_w = (body_left_q < 32'(avail_w)) ? body_left_q[6:0] : avail_w;
        end else begin
            body_n_w = 7'd0;
        end
    end

    logic [AXI_DATA_BITS-1:0] fsm_tdata;
    logic [BYTE_LANES-1:0]    fsm_tkeep;
    logic                     fsm_tlast;
    logic                     fsm_tvalid;
    logic                     fsm_tready;

    assign fsm_tkeep   = keep_from_count(body_n_w);
    assign fsm_tdata   = mask_bytes(shifted_w, fsm_tkeep);
    assign fsm_tlast   = (body_left_q == 32'(body_n_w)) && body_last;
    assign fsm_tvalid  = enable && (body_n_w != 0);
    assign fsm_tready  = !skid_valid2_q;
    assign body_fire_w = fsm_tvalid && fsm_tready;

    logic [6:0] consumed_w;
    assign consumed_w = take_hdr_w ? 7'd1 : (body_fire_w ? body_n_w : 7'd0);

    // A beat with no keep bits counts as drained, or it would wedge the cursor.
    logic res_drain_w;
    assign res_drain_w = res_valid_q && ((avail_w == 0) || (consumed_w == avail_w));

    assign s_axis_tready = enable && (!res_valid_q || res_drain_w);

    logic in_fire;
    assign in_fire = s_axis_tvalid && s_axis_tready;

    logic [6:0] in_len_w;
    assign in_len_w = 7'($countones(s_axis_tkeep));

    logic resp_complete_w;
    assign resp_complete_w = body_fire_w && (body_left_q == 32'(body_n_w));

    // Debug capture: first two emitted body beats of the stream.
    logic [AXI_DATA_BITS-1:0] w0_q, w1_q;
    logic                     w0_valid_q, w1_valid_q;
    logic [6:0]               payload_idx_q;

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            res_valid_q   <= 1'b0;
            res_data_q    <= '0;
            res_len_q     <= '0;
            res_cur_q     <= '0;
            mode_q        <= M_HDR;
            body_left_q   <= '0;
            hs_q          <= HS_STATUS;
            name_pos_q    <= '0;
            name_is_cl_q  <= 1'b0;
            val_is_cl_q   <= 1'b0;
            cl_q          <= '0;
            cl_seen_q     <= 1'b0;
            cl_latched_q  <= '0;
            status_q          <= '0;
            status_latched_q  <= '0;
            status_ok_q       <= 1'b0;
            status_sp_q   <= '0;
            status_cnt_q  <= '0;
            resp_done_q   <= 1'b0;
            drain_wait_q  <= 1'b0;
            dirty_q       <= 1'b0;
            error_q       <= 1'b0;
            w0_q          <= '0;
            w1_q          <= '0;
            w0_valid_q    <= 1'b0;
            w1_valid_q    <= 1'b0;
            payload_idx_q <= '0;
        end else if (enable) begin
            // -- response handshake ---------------------------------------------------------------
            if (resp_ack) begin
                resp_done_q <= 1'b0;
                dirty_q     <= 1'b0;
            end

            // -- residue --------------------------------------------------------------------------
            if (in_fire) begin
                res_data_q  <= s_axis_tdata;
                res_len_q   <= in_len_w;
                res_cur_q   <= '0;
                res_valid_q <= 1'b1;
            end else if (res_drain_w) begin
                res_valid_q <= 1'b0;
                res_cur_q   <= '0;
            end else begin
                res_cur_q   <= res_cur_q + consumed_w;
            end

            // -- header parser --------------------------------------------------------------------
            if (take_hdr_w) begin
                case (hs_q)
                    HS_STATUS: begin
                        if (cur_byte_w == 8'h0A) begin
                            hs_q         <= HS_LINE_BEGIN;
                            name_pos_q   <= '0;
                            name_is_cl_q <= 1'b0;
                        end else if (cur_byte_w == 8'h20) begin
                            if (status_sp_q != 2'd3) status_sp_q <= status_sp_q + 2'd1;
                        end else if ((status_sp_q == 2'd1) && is_digit_w && (status_cnt_q != 2'd3)) begin
                            status_q     <= {status_q[15:0], cur_byte_w};
                            status_cnt_q <= status_cnt_q + 2'd1;
                        end
                    end

                    HS_LINE_BEGIN: begin
                        if (cur_byte_w == 8'h0D) begin
                            hs_q <= HS_HDR_CR;
                        end else begin
                            // Seed the matcher; name_is_cl_q still holds the last line's result.
                            name_is_cl_q <= name_first_hit_w;
                            name_pos_q   <= 5'd1;
                            hs_q         <= HS_NAME;
                        end
                    end

                    HS_HDR_CR: begin
                        // Only the LF gets here, and only once the previous response is retired
                        // (hdr_block_w), so what is latched below belongs to this response.
                        hs_q         <= HS_STATUS;
                        name_pos_q   <= '0;
                        name_is_cl_q <= 1'b0;
                        val_is_cl_q  <= 1'b0;
                        status_sp_q  <= '0;
                        status_cnt_q <= '0;
                        cl_seen_q    <= 1'b0;
                        cl_q         <= '0;
                        cl_latched_q     <= cl_q;
                        status_latched_q <= status_q;
                        status_ok_q      <= (status_q == "200") || (status_q == "206");
                        if (!cl_seen_q) begin
                            error_q <= 1'b1;
                        end else if (cl_q == 32'd0) begin
                            // Nothing to stream: the response is complete right here.
                            resp_done_q <= 1'b1;
                        end else begin
                            mode_q        <= M_BODY;
                            body_left_q   <= cl_q;
                            payload_idx_q <= res_cur_q + 7'd1;
                        end
                    end

                    HS_NAME: begin
                        if (cur_byte_w == 8'h3A) begin // ':'
                            val_is_cl_q <= name_is_cl_q && (name_pos_q == 5'(NAME_CL_LEN));
                            hs_q        <= HS_VAL;
                        end else if (cur_byte_w == 8'h0D) begin
                            hs_q <= HS_LINE_LF;          // malformed line, skip it
                        end else begin
                            name_is_cl_q <= name_char_hit_w;
                            if (name_pos_q != 5'd31) name_pos_q <= name_pos_q + 5'd1;
                        end
                    end

                    HS_VAL: begin
                        if (cur_byte_w == 8'h0D) begin
                            hs_q <= HS_LINE_LF;
                        end else if (val_is_cl_q && is_digit_w) begin
                            cl_q      <= (cl_q * 32'd10) + 32'(cur_byte_w - 8'h30);
                            cl_seen_q <= 1'b1;
                        end
                    end

                    HS_LINE_LF: begin
                        hs_q         <= HS_LINE_BEGIN;
                        val_is_cl_q  <= 1'b0;
                        name_pos_q   <= '0;
                        name_is_cl_q <= 1'b0;
                    end

                    default: hs_q <= HS_STATUS;
                endcase
            end

            // -- body -----------------------------------------------------------------------------
            if (body_fire_w) begin
                body_left_q <= body_left_q - 32'(body_n_w);
                dirty_q     <= 1'b1;

                if (!w0_valid_q) begin
                    w0_q       <= fsm_tdata;
                    w0_valid_q <= 1'b1;
                end else if (!w1_valid_q) begin
                    w1_q       <= fsm_tdata;
                    w1_valid_q <= 1'b1;
                end
            end

            if (resp_complete_w) begin
                mode_q       <= M_HDR;
                drain_wait_q <= 1'b1;
            end

            if (drain_wait_q && !skid_valid_q && !skid_valid2_q) begin
                drain_wait_q <= 1'b0;
                resp_done_q  <= 1'b1;
            end
        end
    end

    // Two-slot output skid buffer, so the barrel-shift cone ends at a register.
    assign m_axis_tvalid = skid_valid_q;
    assign m_axis_tdata  = skid_data_q;
    assign m_axis_tkeep  = skid_keep_q;
    assign m_axis_tlast  = skid_last_q;

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            skid_valid_q  <= 1'b0;
            skid_valid2_q <= 1'b0;
        end else if (m_axis_tready || !skid_valid_q) begin
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
    assign out_payload_idx = payload_idx_q;

    assign resp_done       = resp_done_q;
    assign resp_dirty      = dirty_q;
    assign resp_error      = error_q;
    assign status_ascii    = status_latched_q;
    assign status_ok       = status_ok_q;
    assign content_length  = cl_latched_q;
    assign body_remaining  = body_left_q;

endmodule
