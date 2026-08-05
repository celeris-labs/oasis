`timescale 1ns / 1ps

// =================================================================================================
// HTTP client configuration types
//
// One packed struct that carries everything the HTTP client needs to issue a
// GET request. HttpConfig latches each field via AXI-Lite writes from the CPU
// and then emits the whole struct as a single beat on a ready/valid interface
// when the START register is written.
// =================================================================================================
package http_types;

typedef struct packed {
    logic [31:0] server_ip;     // TCP target, big-endian octets in low bytes
    logic [31:0] server_port;   // TCP target port (only [15:0] used)
    logic [31:0] port_hex;      // ASCII bytes of the port (for the Host: header)
    logic [7:0]  ip_hex_len;    // Number of ASCII bytes of the IP string (1..15)
    logic [31:0] ip_hex_w0;
    logic [31:0] ip_hex_w1;
    logic [31:0] ip_hex_w2;
    logic [31:0] ip_hex_w3;
    logic [31:0] file_len;      // Number of bytes of the GET path (0..64)
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
    // Range endpoints are absolute file offsets, so they need to span the whole
    // file: 4 words = 16 ASCII digits (~8.9 PiB).
    logic [7:0]  range_begin_len; // ASCII digit count for Range start (0..16)
    logic [31:0] range_begin_w0;
    logic [31:0] range_begin_w1;
    logic [31:0] range_begin_w2;
    logic [31:0] range_begin_w3;
    logic [7:0]  range_end_len;   // ASCII digit count for Range end (0..16)
    logic [31:0] range_end_w0;
    logic [31:0] range_end_w1;
    logic [31:0] range_end_w2;
    logic [31:0] range_end_w3;
    // Per-request flags. Bit 0 (body_last) says this response ends the decoder stream: the host
    // may split one logical column chunk into several ranged GETs to bound how many bytes the
    // server can have in flight, and the DataNormalizer resets its running byte offset on tlast, so
    // only the last of them may carry it. This register used to be a dead `num_sessions` field --
    // reusing it keeps the CSR address map byte-for-byte identical, which matters: every address
    // after a shifted register lands in the wrong place and the FPGA builds a garbage request out
    // of whatever happened to be there.
    logic [15:0] req_flags;
    logic [31:0] pkg_word_count;
    logic [31:0] user_frequency;
    logic [31:0] time_in_seconds;
} http_config_t;

endpackage
