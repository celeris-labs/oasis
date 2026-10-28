`timescale 1ns / 1ps

import lynxTypes::*;

// =================================================================================================
// HTTP/1.1 response framer -- strips headers, delimits bodies by Content-Length.
//
// WHY CONTENT-LENGTH
// ------------------
// Using the server's FIN as the end-of-body marker is only correct when the request carries
// `Connection: close`, which forces a fresh TCP connection per ranged GET -- and a connection per
// GET exhausts the TOE's 512-entry ephemeral port pool partway through a query.
//
// To reuse one connection the framer has to know where each body ends by itself, because on a
// persistent connection there is no FIN between responses: body k is followed immediately by the
// status line of response k+1, frequently inside the SAME 64-byte beat. So this module
//
//   * parses the status line and the header block byte by byte,
//   * extracts Content-Length,
//   * counts the body down and raises tlast on the beat carrying its last byte,
//   * and then keeps the leftover bytes of that beat and resumes header parsing at the exact byte
//     after the body.
//
// STRUCTURE
// ---------
// One input beat is held in a residue register (res_data_q) that is kept SHIFTED TO THE CURSOR: its
// low byte is always the next byte not yet consumed. That one register serves both roles at once --
// its low byte is the next header character, and the whole word is the already-bottom-justified
// body beat -- and both read it straight off flops. The header is matched one byte at a time, an
// 8-bit compare against a 14-byte ROM, so no wide parallel "\r\n\r\n" search is needed either.
//
// The shifting is done where bytes are consumed, in the residue's next-state logic, by the ONE
// 512-bit barrel shift:
//
//     res_data_q <= res_data_q >> (step_w * 8)
//
// step_w is the cursor's step when the residue is not used up: one byte in a header, and in a body
// the body bytes left (a body that ends inside the beat; one that does not uses the beat up). It
// comes from registers, and so does everything the beat's keep, byte count, tlast and the
// residue's drain are derived from (avail_q, body_left_q, body_big_q), which keeps the per-beat
// loop through the residue at a few logic levels instead of a subtract, a 32-bit compare and a
// mux in front of the shifter's mask.
//
// Header parsing is byte-serial, so a ~200-byte response header costs ~200 cycles (0.8 us at
// 250 MHz). Bodies move a full 64-byte beat per cycle.
//
// BOTTOM-JUSTIFICATION IS THE CONTRACT
// ------------------------------------
// Downstream is the pipelined DataNormalizer with ENABLE_COMPACTOR=0, which places bytes using
// $countones(tkeep) and therefore requires every beat's valid bytes to start at lane 0. Beats are
// emitted as res_data_q masked to body_n_w bytes, so that holds for every beat, not just the first.
//
// THE tlast CONTRACT (body_last)
// ------------------------------
// The normalizer resets its running byte offset on tlast, so one decoder stream must carry exactly
// one tlast. body_last says, per response, whether that response ends the decoder stream;
// body_last=0 means "emit the final beat with tlast=0 and keep going". handler_multi ties it to 0
// and take the decoder's tlast from axis_rewrite_last, which counts chunk bytes across ranged GETs;
// body_last=1 is exercised by the strip_http bench only.
//
// HANDSHAKE WITH tcp_read
// -----------------------
// resp_done rises when a response's last body beat has drained through the skid, and stays up until
// tcp_read pulses resp_ack. Over that whole window the framer will parse the NEXT response's
// headers but stops one byte short of entering its body, so it can never emit body k+1 under the
// body_last of response k. It deliberately does NOT stop consuming input outright: a TCP segment can
// straddle the boundary, and refusing the rest of that segment would stall the TOE's data mover
// mid-packet.
//
// resp_dirty says at least one body beat of the CURRENT response has already been emitted
// downstream. The handler uses it to decide whether a connection that dies can be transparently
// reopened and replayed (clean) or has already corrupted the decoder stream (dirty, fatal).
//
// NO Content-Length IS A HARD ERROR
// ---------------------------------
// A header block that ends without Content-Length cannot be framed. That covers
// `Transfer-Encoding: chunked` without parsing it -- a ranged GET of a static object must never
// produce either, so resp_error latches and the framer stops accepting input rather than guessing.
// The stall is deliberate and visible: the handler's read watchdog reports it and resp_error is in
// the status CSR. status_ascii keeps the three status digits, so a 404 or 416 shows up there
// instead of flowing into the decoder as if it were column data.
// =================================================================================================
module strip_http (
    input  logic                           clk,
    input  logic                           rst_n,
    // Reset all framing state. Only legitimate on a NEW connection: between responses on a
    // persistent one it would throw away the residue, which holds the next header.
    input  logic                           clear,
    input  logic                           enable,

    // Per-response controls from tcp_read.
    input  logic                           body_last,  // this response ends the decoder stream
    input  logic                           resp_ack,   // retire resp_done, arm the next response

    input  logic                           s_axis_tvalid,
    input  logic [AXI_DATA_BITS-1:0]       s_axis_tdata,
    input  logic [AXI_DATA_BITS/8-1:0]     s_axis_tkeep,
    // $countones(s_axis_tkeep), counted by the stage that registered the beat (tcp_read's count
    // register), so the residue's byte count is loaded from a flop. s_axis_tkeep is only checked
    // against it, in simulation.
    input  logic [6:0]                     s_axis_tbytes,
    input  logic                           s_axis_tlast,   // ignored: framing is by Content-Length
    output logic                           s_axis_tready,

    // Bottom-justified body stream (packed downstream by DataNormalizer)
    output logic                           m_axis_tvalid,
    output logic [AXI_DATA_BITS-1:0]       m_axis_tdata,
    output logic [AXI_DATA_BITS/8-1:0]     m_axis_tkeep,
    output logic                           m_axis_tlast,
    // $countones(m_axis_tkeep), carried with the beat, so the consumer does not have to count it
    // (axis_rewrite_last's s_tbytes).
    output logic [6:0]                     m_axis_tbytes,
    input  logic                           m_axis_tready,

    // Debug words
    output logic [AXI_DATA_BITS-1:0]       out_w0,
    output logic [AXI_DATA_BITS-1:0]       out_w1,
    output logic                           out_w0_valid,
    output logic                           out_w1_valid,

    // Response framing status
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

    localparam int BYTE_LANES = AXI_DATA_BITS / 8; // 64

    // Bottom-justified tkeep for `n` valid bytes (n ones from lane 0).
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

    // ---------------------------------------------------------------------------------------------
    // Output skid buffer registers (declared first: the framer's completion logic looks at them).
    // ---------------------------------------------------------------------------------------------
    logic [AXI_DATA_BITS-1:0] skid_data_q,  skid_data2_q;
    logic [BYTE_LANES-1:0]    skid_keep_q,  skid_keep2_q;
    logic                     skid_last_q,  skid_last2_q;
    logic [6:0]               skid_bytes_q, skid_bytes2_q;
    logic                     skid_valid_q, skid_valid2_q;

    // ---------------------------------------------------------------------------------------------
    // Residue: one input beat, shifted to the cursor, and how much of it is left.
    // ---------------------------------------------------------------------------------------------
    logic                     res_valid_q;
    logic [AXI_DATA_BITS-1:0] res_data_q;  // the held beat; byte 0 is the next one not consumed
    logic [6:0]               avail_q;     // bytes of it not yet consumed (0..64)
    logic [6:0]               res_cur_q;   // bytes already consumed (for out_payload_idx)

    // Low byte = next header character; whole word = bottom-justified body.
    logic [7:0] cur_byte_w;
    assign cur_byte_w = res_data_q[7:0];

    // ---------------------------------------------------------------------------------------------
    // Framer mode
    // ---------------------------------------------------------------------------------------------
    localparam logic M_HDR  = 1'b0;
    localparam logic M_BODY = 1'b1;

    logic        mode_q;
    logic [31:0] body_left_q;
    // "Is the body longer than any beat?", answered from a flop, so that the beat's byte count,
    // keep and tlast and the residue's drain compare 7-bit registers (body_left_q[6:0] against
    // avail_q) instead of the 32-bit count. It is a one-sided summary of body_left_q:
    //
    //     body_big_q = 1  =>  body_left_q >= 65   (more than a beat holds: the beat goes whole)
    //     body_big_q = 0  =>  body_left_q <= 127  (so body_left_q[6:0] IS the count)
    //
    // A body fire consumes 1..64 bytes, so setting it from body_left_q > 128 BEFORE the fire keeps
    // both after it, and entering a body sets it from Content-Length > 64. Between 65 and 127
    // either value is true, which is what lets it be computed from the old count instead of from
    // the subtraction's result.
    logic        body_big_q;

    // ---------------------------------------------------------------------------------------------
    // Byte-serial header parser.
    //
    //   HS_STATUS     status line; the three digits after the first space are captured
    //   HS_LINE_BEGIN first byte of a header line; a bare CR here is the blank line ending the block
    //   HS_HDR_CR     saw that CR, expect LF -> headers complete
    //   HS_NAME       header name, matched case-insensitively against "content-length"
    //   HS_VAL        header value; digits accumulate only if the name matched. Leading spaces need
    //                 no state of their own -- they are neither digits nor CR, so they fall through.
    //   HS_LINE_LF    saw the CR ending a header line, expect LF
    // ---------------------------------------------------------------------------------------------
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
    // The parsed Content-Length, LATCHED. body_remaining counts down to zero, so on its own it can
    // never answer "what did the server say the length was?" after the fact -- and that is exactly
    // the question when a response turns out not to be the one that was asked for. The host knows
    // what it requested; this is what arrived, and the two disagreeing is the whole diagnosis.
    logic [31:0] cl_latched_q;
    logic [23:0] status_q;
    // The status code of the response BEING RETIRED, latched beside cl_latched_q for the same
    // reason and at the same instant. status_q is a live shift register: it takes the digits of
    // whatever status line the parser is walking, so once responses are pipelined it holds the NEXT
    // response's code while the handler is still sampling the previous one's completion: sampled
    // on the level of `done` it would catch the parser mid-"206" and raise the sticky bad-status
    // bit on a good response. So status is latched here like Content-Length.
    logic [23:0] status_latched_q;
    // status_ok, REGISTERED beside status_latched_q, so the two 24-bit compares do not sit between
    // status_latched_q and the handler's bad-status check / the CSR readback, across an SLR boundary
    // whenever the framer and the handler core are placed apart. Loaded in the same branch, from the
    // same value, so it is status_latched_q's compare in every cycle: no latency.
    logic        status_ok_q;
    logic [1:0]  status_sp_q;  // spaces seen in the status line (saturating)
    logic [1:0]  status_cnt_q; // status digits captured (0..3)

    logic [7:0] lower_w;
    assign lower_w = (cur_byte_w >= 8'h41 && cur_byte_w <= 8'h5A) ? (cur_byte_w | 8'h20) : cur_byte_w;

    // Index of the expected character, clamped so the part-select is always in range.
    logic [4:0] name_idx_w;
    assign name_idx_w = (name_pos_q < 5'(NAME_CL_LEN)) ? (5'(NAME_CL_LEN-1) - name_pos_q) : 5'd0;

    // A string literal packs its LAST character into the LSB, so character i sits at (LEN-1-i)*8.
    logic name_char_hit_w;  // current byte continues the "content-length" match
    logic name_first_hit_w; // current byte is its first character
    assign name_char_hit_w  = name_is_cl_q && (name_pos_q < 5'(NAME_CL_LEN)) &&
                              (lower_w == NAME_CL[name_idx_w*8 +: 8]);
    assign name_first_hit_w = (lower_w == NAME_CL[(NAME_CL_LEN-1)*8 +: 8]);

    logic is_digit_w;
    assign is_digit_w = (cur_byte_w >= 8'h30) && (cur_byte_w <= 8'h39);

    // ---------------------------------------------------------------------------------------------
    // Response completion handshake
    // ---------------------------------------------------------------------------------------------
    logic resp_done_q;   // body complete AND drained; cleared by resp_ack
    logic drain_wait_q;  // final beat produced, still in the skid
    logic dirty_q;
    logic error_q;

    // The single point where the framer must hold: the LF that completes a header block, while the
    // previous response has not been retired yet. drain_wait_q is included so the window is closed
    // from the moment the body finishes, not from the moment resp_done rises -- under heavy
    // downstream back-pressure those are far apart. Stopping HERE rather than at resp_done keeps the
    // TOE's rx stream moving through a segment that straddles two responses.
    logic hdr_block_w;
    assign hdr_block_w = (resp_done_q || drain_wait_q) && (hs_q == HS_HDR_CR);

    // ---------------------------------------------------------------------------------------------
    // Consumption
    // ---------------------------------------------------------------------------------------------
    logic       take_hdr_w;
    logic [6:0] body_n_w;
    logic       body_fire_w;

    assign take_hdr_w = enable && res_valid_q && !error_q && (mode_q == M_HDR) &&
                        (avail_q != 0) && !hdr_block_w;

    // The body against the residue, from 7-bit registers only (see body_big_q).
    logic body_on_w;    // in a body, with a residue to take from
    logic body_ends_w;  // body_left_q <  avail_q: the body ends inside this beat
    logic body_fits_w;  // body_left_q <= avail_q: this beat carries the body's last byte
    logic body_nz_w;    // body_left_q != 0
    assign body_on_w   = (mode_q == M_BODY) && res_valid_q && !error_q;
    assign body_ends_w = !body_big_q && (body_left_q[6:0] <  avail_q);
    assign body_fits_w = !body_big_q && (body_left_q[6:0] <= avail_q);
    assign body_nz_w   = body_big_q || (body_left_q[6:0] != 7'd0);

    // min(body_left_q, avail_q): the bytes this beat moves.
    assign body_n_w = (body_on_w && (avail_q != 0)) ? (body_ends_w ? body_left_q[6:0] : avail_q)
                                                    : 7'd0;

    // The cursor's step on a cycle that consumes without using the residue up: a header byte, or
    // the rest of a body that ends inside the beat (under 64, see below). Chosen by the mode, a
    // register, rather than by which of the two fired, so the shifter does not wait for either.
    logic [6:0] step_w;
    assign step_w = (mode_q == M_HDR) ? 7'd1 : body_left_q[6:0];

    // ---------------------------------------------------------------------------------------------
    // Stage-2 stream into the skid buffer
    // ---------------------------------------------------------------------------------------------
    logic [AXI_DATA_BITS-1:0] fsm_tdata;
    logic [BYTE_LANES-1:0]    fsm_tkeep;
    logic                     fsm_tlast;
    logic                     fsm_tvalid;
    logic                     fsm_tready;

    // keep_from_count(body_n_w), as the AND of the two counts' own keeps (the keep of a minimum is
    // the AND of the keeps), so no decode waits for body_n_w.
    assign fsm_tkeep   = body_on_w ? (keep_from_count(avail_q) &
                                      (body_big_q ? {BYTE_LANES{1'b1}}
                                                  : keep_from_count(body_left_q[6:0])))
                                   : '0;
    assign fsm_tdata   = mask_bytes(res_data_q, fsm_tkeep);
    // body_left_q == body_n_w, for either value of body_n_w.
    assign fsm_tlast   = ((body_on_w && (avail_q != 0)) ? body_fits_w : !body_nz_w) && body_last;
    assign fsm_tvalid  = enable && body_on_w && (avail_q != 0) && body_nz_w;
    assign fsm_tready  = !skid_valid2_q;
    assign body_fire_w = fsm_tvalid && fsm_tready;

    // The residue is finished when it holds no more useful bytes: either it never had any (a beat
    // with no keep bits, which would otherwise wedge the cursor) or this cycle consumes the rest --
    // its last header byte, or a body that does not end inside it.
    logic res_drain_w;
    assign res_drain_w = res_valid_q && ((avail_q == 0) ||
                                         (take_hdr_w  && (avail_q == 7'd1)) ||
                                         (body_fire_w && !body_ends_w));

    // Slave-side ready: two registers plus the skid's ready. No dependence on the parser FSM.
    assign s_axis_tready = enable && (!res_valid_q || res_drain_w);

    logic in_fire;
    assign in_fire = s_axis_tvalid && s_axis_tready;

    logic [6:0] in_len_w;
    assign in_len_w = s_axis_tbytes;

`ifndef SYNTHESIS
    // The carried count must be the keep's own: a wrong one shifts every later byte of the stream.
    always @(posedge clk) begin
        if (rst_n && !clear && s_axis_tvalid && (s_axis_tbytes !== 7'($countones(s_axis_tkeep))))
            $error("strip_http: s_axis_tbytes=%0d, but s_axis_tkeep has %0d bytes",
                   s_axis_tbytes, $countones(s_axis_tkeep));
    end
`endif

    // This response's body has just been fully emitted.
    logic resp_complete_w;
    assign resp_complete_w = body_fire_w && body_fits_w;

    // ---------------------------------------------------------------------------------------------
    // Debug capture: first two emitted body beats of the stream.
    // ---------------------------------------------------------------------------------------------
    logic [AXI_DATA_BITS-1:0] w0_q, w1_q;
    logic                     w0_valid_q, w1_valid_q;
    logic [6:0]               payload_idx_q;

    // ---------------------------------------------------------------------------------------------
    // Sequential
    // ---------------------------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            res_valid_q   <= 1'b0;
            res_data_q    <= '0;
            avail_q       <= '0;
            res_cur_q     <= '0;
            mode_q        <= M_HDR;
            body_left_q   <= '0;
            body_big_q    <= 1'b0;
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
                avail_q     <= in_len_w;
                res_cur_q   <= '0;
                res_valid_q <= 1'b1;
            end else if (res_drain_w) begin
                res_valid_q <= 1'b0;
                res_cur_q   <= '0;
            end else if (take_hdr_w || body_fire_w) begin
                // One header byte, or the end of a body inside the beat (a body that does not end
                // inside it has drained it, above): fewer than 64 bytes either way.
                res_data_q  <= res_data_q >> {step_w[5:0], 3'b000};
                avail_q     <= avail_q - step_w;
                res_cur_q   <= res_cur_q + step_w;
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
                            // Seed the name matcher with this first character. Deliberately does not
                            // read name_is_cl_q -- the previous line left it at whatever it failed at.
                            name_is_cl_q <= name_first_hit_w;
                            name_pos_q   <= 5'd1;
                            hs_q         <= HS_NAME;
                        end
                    end

                    HS_HDR_CR: begin
                        // Only the LF gets here (hdr_block_w holds us off until the previous
                        // response is retired), so the header block is complete.
                        hs_q         <= HS_STATUS;
                        name_pos_q   <= '0;
                        name_is_cl_q <= 1'b0;
                        val_is_cl_q  <= 1'b0;
                        status_sp_q  <= '0;
                        status_cnt_q <= '0;
                        cl_seen_q    <= 1'b0;
                        cl_q         <= '0;
                        // Both header-derived facts about THIS response are frozen here, at the LF
                        // that completes its header block. hdr_block_w holds the parser at exactly
                        // this point until the previous response is retired, so the pair latched
                        // here is provably the pair belonging to the response about to be framed.
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
                            body_big_q    <= (cl_q > 32'd64);
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
                        // The LF closing a header line.
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
                // body_left_q - body_n_w, with the subtrahend a register: the beat either carries
                // the body's last byte (body_n_w = body_left_q) or goes whole (body_n_w = avail_q).
                body_left_q <= body_fits_w ? 32'd0 : (body_left_q - 32'(avail_q));
                body_big_q  <= (body_left_q > 32'd128);
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

            // The final beat has left the skid: the response is complete downstream.
            if (drain_wait_q && !skid_valid_q && !skid_valid2_q) begin
                drain_wait_q <= 1'b0;
                resp_done_q  <= 1'b1;
            end
        end
    end

    // ---------------------------------------------------------------------------------------------
    // Registered output: 2-slot AXI-Stream skid buffer. It registers m_axis_* so the framer's cone
    // ends at a flop here.
    // ---------------------------------------------------------------------------------------------
    assign m_axis_tvalid = skid_valid_q;
    assign m_axis_tdata  = skid_data_q;
    assign m_axis_tkeep  = skid_keep_q;
    assign m_axis_tlast  = skid_last_q;
    assign m_axis_tbytes = skid_bytes_q;

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            skid_valid_q  <= 1'b0;
            skid_valid2_q <= 1'b0;
        end else if (m_axis_tready || !skid_valid_q) begin
            if (skid_valid2_q) begin
                skid_data_q   <= skid_data2_q;
                skid_keep_q   <= skid_keep2_q;
                skid_last_q   <= skid_last2_q;
                skid_bytes_q  <= skid_bytes2_q;
                skid_valid_q  <= 1'b1;
                skid_valid2_q <= 1'b0;
            end else begin
                skid_data_q  <= fsm_tdata;
                skid_keep_q  <= fsm_tkeep;
                skid_last_q  <= fsm_tlast;
                skid_bytes_q <= body_n_w;
                skid_valid_q <= fsm_tvalid;
            end
        end else if (fsm_tvalid && fsm_tready) begin
            skid_data2_q  <= fsm_tdata;
            skid_keep2_q  <= fsm_tkeep;
            skid_last2_q  <= fsm_tlast;
            skid_bytes2_q <= body_n_w;
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
