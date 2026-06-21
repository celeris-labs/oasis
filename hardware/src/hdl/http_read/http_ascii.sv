`timescale 1ns / 1ps

// Utilities for formatting binary network/config values as HTTP header ASCII.
package http_ascii;

// Append the decimal representation of an 8-bit value to chars[pos..].
function automatic int append_u8_dec(input logic [7:0] value, output logic [7:0] chars [0:15],
                                   input int pos);
    logic [7:0] rem;
    int         p;
    begin
        rem = value;
        p   = pos;
        if (rem >= 8'd100) begin
            chars[p] = 8'd48 + rem / 8'd100;
            p++;
            rem = rem % 8'd100;
        end
        if (rem >= 8'd10 || value >= 8'd100) begin
            chars[p] = 8'd48 + rem / 8'd10;
            p++;
            rem = rem % 8'd10;
        end
        chars[p] = 8'd48 + rem;
        p++;
        append_u8_dec = p;
    end
endfunction

function automatic void ipv4_to_ascii(input logic [31:0] ip, output logic [7:0] len,
                                      output logic [7:0] chars [0:15]);
    int p;
    begin
        p = append_u8_dec(ip[31:24], chars, 0);
        chars[p] = 8'h2E;
        p++;
        p = append_u8_dec(ip[23:16], chars, p);
        chars[p] = 8'h2E;
        p++;
        p = append_u8_dec(ip[15:8], chars, p);
        chars[p] = 8'h2E;
        p++;
        p        = append_u8_dec(ip[7:0], chars, p);
        len      = p[7:0];
    end
endfunction

function automatic void u16_to_ascii(input logic [15:0] value, output logic [7:0] len,
                                     output logic [7:0] chars [0:4]);
    logic [15:0] rem;
    int          p;
    begin
        rem = value;
        p   = 0;
        if (rem >= 16'd10000) begin
            chars[p] = 8'd48 + rem / 16'd10000;
            p++;
            rem = rem % 16'd10000;
        end
        if (rem >= 16'd1000 || value >= 16'd10000) begin
            chars[p] = 8'd48 + rem / 16'd1000;
            p++;
            rem = rem % 16'd1000;
        end
        if (rem >= 16'd100 || value >= 16'd1000) begin
            chars[p] = 8'd48 + rem / 16'd100;
            p++;
            rem = rem % 16'd100;
        end
        if (rem >= 16'd10 || value >= 16'd100) begin
            chars[p] = 8'd48 + rem / 16'd10;
            p++;
            rem = rem % 16'd10;
        end
        chars[p] = 8'd48 + rem[7:0];
        p++;
        len = p[7:0];
    end
endfunction

function automatic void u64_to_ascii(input logic [63:0] value, output logic [7:0] len,
                                     output logic [7:0] chars [0:19]);
    logic [63:0] divisors [0:19];
    logic [63:0] rem;
    int          first;
    int          p;
    begin
        divisors[0]  = 64'd10000000000000000000;
        divisors[1]  = 64'd1000000000000000000;
        divisors[2]  = 64'd100000000000000000;
        divisors[3]  = 64'd10000000000000000;
        divisors[4]  = 64'd1000000000000000;
        divisors[5]  = 64'd100000000000000;
        divisors[6]  = 64'd10000000000000;
        divisors[7]  = 64'd1000000000000;
        divisors[8]  = 64'd100000000000;
        divisors[9]  = 64'd10000000000;
        divisors[10] = 64'd1000000000;
        divisors[11] = 64'd100000000;
        divisors[12] = 64'd10000000;
        divisors[13] = 64'd1000000;
        divisors[14] = 64'd100000;
        divisors[15] = 64'd10000;
        divisors[16] = 64'd1000;
        divisors[17] = 64'd100;
        divisors[18] = 64'd10;
        divisors[19] = 64'd1;

        rem   = value;
        first = 1;
        p     = 0;
        for (int i = 0; i < 20; i++) begin
            logic [3:0] digit;
            digit = rem / divisors[i];
            if (!first || digit != 0 || i == 19) begin
                chars[p] = 8'd48 + digit;
                p++;
                first = 0;
            end
            rem = rem % divisors[i];
        end
        len = p[7:0];
    end
endfunction

endpackage
