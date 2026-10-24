`timescale 1ns / 1ps

// =================================================================================================
// HTTP client configuration types
//
// One packed struct with every HttpConfig write register. HttpConfig latches
// each field via AXI-Lite writes from the CPU and emits the whole struct as a
// single beat on a ready/valid interface when the START register is written.
// The host builds the request text itself; the handler reads only server_ip,
// server_port, req_total_bytes, req_chunk_bytes and req_chunk_dest.
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
    // Unused by the handler (the chunk boundary is req_chunk_bytes'). Kept so no address moves.
    logic [15:0] req_flags;
    logic [31:0] pkg_word_count;
    logic [31:0] user_frequency;
    logic [31:0] time_in_seconds;
    // Total bytes of pre-built request text the host is about to stream in over axis_host_recv.
    //
    // NON-ZERO MAKES THE BEAT AN ARM: the host has already built the text for every request of a
    // lane batch and hands it over as one byte stream on that lane's request stream. Zero makes the
    // beat a chunk-length entry. No per-request field above is read by the handler -- only
    // server_ip and server_port, to open the connection; the rest of the map is kept so no address
    // moves.
    logic [31:0] req_total_bytes;
    // Bytes in one decoder stream, i.e. one column chunk's compressed extent.
    //
    // A byte count scales with the number of COLUMN CHUNKS, of which a row group has a handful
    // however finely each is split into ranged GETs, where a per-response flag would scale with
    // the number of REQUESTS. axis_rewrite_last counts the bytes down and asserts tlast on the beat
    // that completes the chunk, so how many GETs it took is invisible downstream.
    logic [31:0] req_chunk_bytes;
    // Decoder lane this chunk belongs to. Carried in the SPARE UPPER BITS of the 64-bit
    // req_chunk_bytes register rather than in a register of its own: the address map is full of
    // traps (moving anything shifts every later parameter silently), and a chunk length has never
    // needed more than 32 bits.
    logic [3:0]  req_chunk_dest;
} http_config_t;

endpackage
