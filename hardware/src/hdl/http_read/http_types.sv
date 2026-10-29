`timescale 1ns / 1ps

// The HttpConfig write registers as one packed struct, emitted as one beat when START is written.
// The handler reads only server_ip, server_port and the req_* fields (see http_config.sv).
package http_types;

typedef struct packed {
    logic [31:0] server_ip;     // TCP target, big-endian octets in low bytes
    logic [31:0] server_port;   // TCP target port (only [15:0] used)
    // Reserved, write registers 2..38: latched and echoed, read by no handler.
    logic [31:0] port_hex;
    logic [7:0]  ip_hex_len;
    logic [31:0] ip_hex_w0;
    logic [31:0] ip_hex_w1;
    logic [31:0] ip_hex_w2;
    logic [31:0] ip_hex_w3;
    logic [31:0] file_len;
    logic [31:0] file_w0;
    logic [31:0] file_w1;
    logic [31:0] file_w2;
    logic [31:0] file_w3;
    logic [31:0] file_w4;
    logic [31:0] file_w5;
    logic [31:0] file_w6;
    logic [31:0] file_w7;
    logic [31:0] file_w8;
    logic [31:0] file_w9;
    logic [31:0] file_w10;
    logic [31:0] file_w11;
    logic [31:0] file_w12;
    logic [31:0] file_w13;
    logic [31:0] file_w14;
    logic [31:0] file_w15;
    logic [7:0]  range_begin_len;
    logic [31:0] range_begin_w0;
    logic [31:0] range_begin_w1;
    logic [31:0] range_begin_w2;
    logic [31:0] range_begin_w3;
    logic [7:0]  range_end_len;
    logic [31:0] range_end_w0;
    logic [31:0] range_end_w1;
    logic [31:0] range_end_w2;
    logic [31:0] range_end_w3;
    logic [15:0] req_flags;
    logic [31:0] pkg_word_count;
    logic [31:0] user_frequency;
    logic [31:0] time_in_seconds;
    // Non-zero arms a lane with this many bytes of host-built request text; zero makes the beat a
    // chunk-length entry.
    logic [31:0] req_total_bytes;
    // Bytes in one decoder stream (one column chunk); axis_rewrite_last counts them down for tlast.
    logic [31:0] req_chunk_bytes;
    // Decoder lane of the chunk, from bits [35:32] of the 64-bit write register 41.
    logic [3:0]  req_chunk_dest;
} http_config_t;

endpackage
