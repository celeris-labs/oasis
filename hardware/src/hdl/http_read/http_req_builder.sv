import http_ascii::*;

module http_req_builder (
    input  logic          ap_clk,
    input  logic          ap_rst_n,
    input  logic          start,
    input  logic          partial_en,
    input  logic [31:0]   serverIp,
    input  logic [15:0]   serverPort,
    input  logic [5:0]    fileLen,
    input  logic [31:0]   fileWord0,
    input  logic [31:0]   fileWord1,
    input  logic [31:0]   fileWord2,
    input  logic [31:0]   fileWord3,
    input  logic [31:0]   fileWord4,
    input  logic [31:0]   fileWord5,
    input  logic [31:0]   fileWord6,
    input  logic [31:0]   fileWord7,
    input  logic [63:0]   rangeBegin,
    input  logic [63:0]   rangeEnd,
    output logic [1023:0] header_data,
    output logic [15:0]   header_len,
    output logic          req_ready
);

    localparam int LEN_PRE       = 4;
    localparam int LEN_HOST      = 17;
    localparam int LEN_RANGE_PRE = 13;
    localparam int LEN_CRLF      = 2;
    localparam int LEN_POST      = 21;

    localparam logic [LEN_PRE *8-1:0] STR_PRE = 32'h20544547;
    localparam logic [LEN_HOST*8-1:0] STR_HOST = {
        64'h203A74736F480A0D,
        64'h312E312F50545448,
        8'h20
    };
    localparam logic [LEN_RANGE_PRE*8-1:0] STR_RANGE_PRE = {
        8'h3D, 8'h73, 8'h65, 8'h74, 8'h79, 8'h62, 8'h20, 8'h3A,
        8'h65, 8'h67, 8'h6E, 8'h61, 8'h52
    };
    localparam logic [LEN_POST*8-1:0] STR_POST = {
        8'h0A, 8'h0D, 8'h0A, 8'h0D, 8'h65, 8'h73, 8'h6F, 8'h6C,
        8'h63, 8'h20, 8'h3A, 8'h6E, 8'h6F, 8'h69, 8'h74, 8'h63,
        8'h65, 8'h6E, 8'h6E, 8'h6F, 8'h43
    };

    typedef enum logic [3:0] {
        IDLE        = 4'd0,
        PRE         = 4'd1,
        PATH        = 4'd2,
        HOST        = 4'd3,
        IP          = 4'd4,
        COLON       = 4'd5,
        PORT        = 4'd6,
        HOST_CRLF   = 4'd7,
        RANGE_PRE   = 4'd8,
        RANGE_BEGIN = 4'd9,
        RANGE_DASH  = 4'd10,
        RANGE_END   = 4'd11,
        RANGE_CRLF  = 4'd12,
        POST        = 4'd13
    } state_t;

    state_t state_q, state_d;
    logic [7:0] idx_q, idx_d;
    logic [5:0] sub_idx_q, sub_idx_d;

    logic [7:0] buffer_q [127:0];
    logic [31:0] file_words [7:0];

    logic req_ready_q, req_ready_d;
    assign req_ready = req_ready_q;

    logic       write_en;
    logic [7:0] write_byte;

    logic [7:0] ip_chars [0:15];
    logic [7:0] ip_char_len;
    logic [7:0] port_chars [0:4];
    logic [7:0] port_char_len;
    logic [7:0] range_begin_chars [0:19];
    logic [7:0] range_begin_len;
    logic [7:0] range_end_chars [0:19];
    logic [7:0] range_end_len;

    always_comb begin
        ipv4_to_ascii(serverIp, ip_char_len, ip_chars);
        u16_to_ascii(serverPort, port_char_len, port_chars);
        u64_to_ascii(rangeBegin, range_begin_len, range_begin_chars);
        u64_to_ascii(rangeEnd, range_end_len, range_end_chars);
    end

    always_comb begin
        file_words[0] = fileWord0;
        file_words[1] = fileWord1;
        file_words[2] = fileWord2;
        file_words[3] = fileWord3;
        file_words[4] = fileWord4;
        file_words[5] = fileWord5;
        file_words[6] = fileWord6;
        file_words[7] = fileWord7;
    end

    genvar i;
    generate
        for (i = 0; i < 128; i++) begin : gen_header_pack
            assign header_data[i*8 +: 8] = buffer_q[i];
        end
    endgenerate

    always_comb begin
        state_d     = state_q;
        idx_d       = idx_q;
        sub_idx_d   = sub_idx_q;
        req_ready_d = req_ready_q;

        write_en   = 1'b0;
        write_byte = 8'h00;
        header_len = {8'h00, idx_q};

        case (state_q)
            IDLE: begin
                if (start) begin
                    state_d     = PRE;
                    idx_d       = '0;
                    sub_idx_d   = '0;
                    req_ready_d = 1'b0;
                end
            end

            PRE: begin
                write_byte = STR_PRE[sub_idx_q*8 +: 8];
                write_en   = 1'b1;
                idx_d      = idx_q + 1'b1;
                sub_idx_d  = sub_idx_q + 1'b1;

                if (sub_idx_q == (LEN_PRE - 1)) begin
                    state_d   = (fileLen == 0) ? HOST : PATH;
                    sub_idx_d = '0;
                end
            end

            PATH: begin
                write_byte = file_words[sub_idx_q[4:2]][sub_idx_q[1:0]*8 +: 8];
                write_en   = 1'b1;
                idx_d      = idx_q + 1'b1;
                sub_idx_d  = sub_idx_q + 1'b1;

                if (sub_idx_q == (fileLen - 1)) begin
                    state_d   = HOST;
                    sub_idx_d = '0;
                end
            end

            HOST: begin
                write_byte = STR_HOST[sub_idx_q*8 +: 8];
                write_en   = 1'b1;
                idx_d      = idx_q + 1'b1;
                sub_idx_d  = sub_idx_q + 1'b1;

                if (sub_idx_q == (LEN_HOST - 1)) begin
                    state_d   = IP;
                    sub_idx_d = '0;
                end
            end

            IP: begin
                write_byte = ip_chars[sub_idx_q];
                write_en   = 1'b1;
                idx_d      = idx_q + 1'b1;
                sub_idx_d  = sub_idx_q + 1'b1;

                if (sub_idx_q == (ip_char_len - 1) || ip_char_len == 0) begin
                    state_d   = COLON;
                    sub_idx_d = '0;
                end
            end

            COLON: begin
                write_byte = 8'h3A;
                write_en   = 1'b1;
                idx_d      = idx_q + 1'b1;
                state_d    = PORT;
                sub_idx_d  = '0;
            end

            PORT: begin
                write_byte = port_chars[sub_idx_q];
                write_en   = 1'b1;
                idx_d      = idx_q + 1'b1;
                sub_idx_d  = sub_idx_q + 1'b1;

                if (sub_idx_q == (port_char_len - 1) || port_char_len == 0) begin
                    state_d   = HOST_CRLF;
                    sub_idx_d = '0;
                end
            end

            HOST_CRLF: begin
                write_byte = (sub_idx_q == 0) ? 8'h0D : 8'h0A;
                write_en   = 1'b1;
                idx_d      = idx_q + 1'b1;
                sub_idx_d  = sub_idx_q + 1'b1;

                if (sub_idx_q == (LEN_CRLF - 1)) begin
                    state_d   = partial_en ? RANGE_PRE : POST;
                    sub_idx_d = '0;
                end
            end

            RANGE_PRE: begin
                write_byte = STR_RANGE_PRE[sub_idx_q*8 +: 8];
                write_en   = 1'b1;
                idx_d      = idx_q + 1'b1;
                sub_idx_d  = sub_idx_q + 1'b1;

                if (sub_idx_q == (LEN_RANGE_PRE - 1)) begin
                    state_d   = (range_begin_len == 0) ? RANGE_DASH : RANGE_BEGIN;
                    sub_idx_d = '0;
                end
            end

            RANGE_BEGIN: begin
                write_byte = range_begin_chars[sub_idx_q];
                write_en   = 1'b1;
                idx_d      = idx_q + 1'b1;
                sub_idx_d  = sub_idx_q + 1'b1;

                if (sub_idx_q == (range_begin_len - 1)) begin
                    state_d   = RANGE_DASH;
                    sub_idx_d = '0;
                end
            end

            RANGE_DASH: begin
                write_byte = 8'h2D;
                write_en   = 1'b1;
                idx_d      = idx_q + 1'b1;
                state_d    = (range_end_len == 0) ? RANGE_CRLF : RANGE_END;
                sub_idx_d  = '0;
            end

            RANGE_END: begin
                write_byte = range_end_chars[sub_idx_q];
                write_en   = 1'b1;
                idx_d      = idx_q + 1'b1;
                sub_idx_d  = sub_idx_q + 1'b1;

                if (sub_idx_q == (range_end_len - 1)) begin
                    state_d   = RANGE_CRLF;
                    sub_idx_d = '0;
                end
            end

            RANGE_CRLF: begin
                write_byte = (sub_idx_q == 0) ? 8'h0D : 8'h0A;
                write_en   = 1'b1;
                idx_d      = idx_q + 1'b1;
                sub_idx_d  = sub_idx_q + 1'b1;

                if (sub_idx_q == (LEN_CRLF - 1)) begin
                    state_d   = POST;
                    sub_idx_d = '0;
                end
            end

            POST: begin
                write_byte = STR_POST[sub_idx_q*8 +: 8];
                write_en   = 1'b1;
                idx_d      = idx_q + 1'b1;
                sub_idx_d  = sub_idx_q + 1'b1;

                if (sub_idx_q == (LEN_POST - 1)) begin
                    state_d     = IDLE;
                    req_ready_d = 1'b1;
                end
            end

            default: state_d = IDLE;
        endcase
    end

    always_ff @(posedge ap_clk) begin
        if (!ap_rst_n) begin
            state_q     <= IDLE;
            idx_q       <= '0;
            sub_idx_q   <= '0;
            req_ready_q <= 1'b0;
            for (int k = 0; k < 128; k++) begin
                buffer_q[k] <= '0;
            end
        end else begin
            state_q     <= state_d;
            idx_q       <= idx_d;
            sub_idx_q   <= sub_idx_d;
            req_ready_q <= req_ready_d;

            if (write_en) begin
                buffer_q[idx_q] <= write_byte;
            end
        end
    end

endmodule
