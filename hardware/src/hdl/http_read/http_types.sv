`timescale 1ns / 1ps

// HTTP client configuration: host sends binary fields only; ASCII for the
// Host:/Range: headers is derived in http_req_builder from server_ip/port and
// range_begin/range_end.
package http_types;

// 0..12 path/range fields, 13 size, 14 session_id (from SW openConnTcp), 15 start
parameter int NUM_HTTP_READ_CONFIG_REGS = 16;
parameter longint unsigned HTTP_READ_CONFIG_ID = 64'h0000000000485454;

typedef struct packed {
    logic [31:0] server_ip;
    logic [31:0] server_port;
    logic [31:0] file_len;
    logic [31:0] file_w0;
    logic [31:0] file_w1;
    logic [31:0] file_w2;
    logic [31:0] file_w3;
    logic [31:0] file_w4;
    logic [31:0] file_w5;
    logic [31:0] file_w6;
    logic [31:0] file_w7;
    logic [63:0] range_begin;
    logic [63:0] range_end;
    // Coyote open/listen/close are SW-managed; HW only uses this session ID.
    logic [15:0] session_id;
} http_config_t;

endpackage
