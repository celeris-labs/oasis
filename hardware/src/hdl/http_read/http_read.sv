`timescale 1ns / 1ps

import lynxTypes::*;
import http_types::*;
import libstf::data8_t;
import libstf::data64_t;

/*
 * HTTP ranged-GET engine — same role as RDMARead at the top level:
 * host CSRs trigger one fetch via conf.valid/ready.
 *
 * Connection management is SW-only on Coyote dev/tcp (openConnTcp /
 * closeConnTcp). The host injects the returned session_id via conf.cfg
 * before starting; this module only drives the TCP data path.
 *
 * The received body is stripped of its HTTP header, re-aligned to lane 0 by
 * strip_http, then trimmed to the exact content size by FixLast and streamed on
 * `out` into the OBM bypass path (mirrors RDMARead's out -> FixLast -> out).
 */
module HTTPRead (
    input logic clk,
    input logic rst_n,

    http_read_config_i.s conf,

    input  logic                                      s_axis_notifications_TVALID,
    output logic                                      s_axis_notifications_TREADY,
    input  logic [TCP_NOTIFY_BITS-1:0]                s_axis_notifications_TDATA,

    output logic                                      m_axis_read_package_TVALID,
    input  logic                                      m_axis_read_package_TREADY,
    output logic [TCP_RD_PKG_REQ_BITS-1:0]            m_axis_read_package_TDATA,

    input  logic                                      s_axis_rx_metadata_TVALID,
    output logic                                      s_axis_rx_metadata_TREADY,
    input  logic [TCP_RX_META_BITS-1:0]               s_axis_rx_metadata_TDATA,

    input  logic                                      s_axis_rx_data_TVALID,
    output logic                                      s_axis_rx_data_TREADY,
    input  logic [AXI_DATA_BITS-1:0]                  s_axis_rx_data_TDATA,
    input  logic [AXI_DATA_BITS/8-1:0]                s_axis_rx_data_TKEEP,
    input  logic                                      s_axis_rx_data_TLAST,

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

    ndata_i.m                                         out    // #(data8_t, AXI_DATA_BITS/8)
);

localparam int DATABEAT_SIZE = AXI_DATA_BITS / 8;

typedef enum logic [1:0] {
    CONF_IDLE,
    CONF_BUSY
} conf_state_t;

conf_state_t conf_state_q, conf_state_d;
logic        runTx_q, runTx_d;
http_config_t cfg_q;
data32_t      size_q;

localparam logic [3:0] ST_IDLE     = 4'd0;
localparam logic [3:0] ST_TCP_SEND = 4'd1;
localparam logic [3:0] ST_TCP_READ = 4'd2;

logic [3:0] state_q, state_d;
logic [15:0] session_id_q, session_id_d;

logic send_done;
logic send_error;
logic [15:0] debug_http_len;
logic [AXI_DATA_BITS-1:0] debug_req_lo;
logic [AXI_DATA_BITS-1:0] debug_req_hi;
logic debug_req_ready;

logic read_done;
logic read_error;
logic [1:0] strip_state_dbg;
logic [6:0] debug_payload_idx;
logic [AXI_DATA_BITS-1:0] debug_rx_out_beat;

logic handler_idle;
assign handler_idle = (state_q == ST_IDLE);
assign conf.ready = (conf_state_q == CONF_IDLE);

// -- Debug: live FSM state exposed on a host-readable read CSR ---------------
logic [3:0] send_state_dbg;
logic [3:0] read_state_dbg;

assign conf.status = {
    9'd0,                              // [31:23] reserved
    (conf_state_q == CONF_BUSY),       // [22] handler busy with a queued request
    read_error,                        // [21]
    read_done,                         // [20]
    send_error,                        // [19]
    send_done,                         // [18]
    1'b0,                              // [17] init_error (unused; SW opens TCP)
    1'b0,                              // [16] init_done  (unused; SW opens TCP)
    read_state_dbg,                    // [15:12] tcp_read FSM
    send_state_dbg,                    // [11:8]  tcp_send_http FSM
    4'd0,                              // [7:4]   tcp_init FSM (removed)
    state_q                            // [3:0]   HTTPRead FSM (IDLE/SEND/READ)
};

always_comb begin
    conf_state_d = conf_state_q;
    runTx_d        = 1'b0;

    if (conf.valid && conf.ready) begin
        conf_state_d = CONF_BUSY;
        runTx_d      = 1'b1;
    end else if (conf_state_q == CONF_BUSY && handler_idle) begin
        conf_state_d = CONF_IDLE;
    end
end

always_ff @(posedge clk) begin
    if (!rst_n) begin
        conf_state_q <= CONF_IDLE;
        runTx_q      <= 1'b0;
        cfg_q        <= '0;
        size_q       <= '0;
    end else begin
        conf_state_q <= conf_state_d;
        runTx_q      <= runTx_d;
        if (conf.valid && conf.ready) begin
            cfg_q  <= conf.cfg;
            size_q <= conf.size;
        end
    end
end

tcp_send_http inst_tcp_send_http (
    .clk(clk),
    .rst_n(rst_n),
    .start(state_q == ST_TCP_SEND),
    .session_id(session_id_q),
    .serverIp(cfg_q.server_ip),
    .serverPort(cfg_q.server_port[15:0]),
    .fileLen(cfg_q.file_len),
    .fileWord0(cfg_q.file_w0),
    .fileWord1(cfg_q.file_w1),
    .fileWord2(cfg_q.file_w2),
    .fileWord3(cfg_q.file_w3),
    .fileWord4(cfg_q.file_w4),
    .fileWord5(cfg_q.file_w5),
    .fileWord6(cfg_q.file_w6),
    .fileWord7(cfg_q.file_w7),
    .rangeBegin(cfg_q.range_begin),
    .rangeEnd(cfg_q.range_end),
    .m_axis_tx_meta_TVALID(m_axis_tx_meta_TVALID),
    .m_axis_tx_meta_TREADY(m_axis_tx_meta_TREADY),
    .m_axis_tx_meta_TDATA(m_axis_tx_meta_TDATA),
    .m_axis_tx_data_TVALID(m_axis_tx_data_TVALID),
    .m_axis_tx_data_TREADY(m_axis_tx_data_TREADY),
    .m_axis_tx_data_TDATA(m_axis_tx_data_TDATA),
    .m_axis_tx_data_TKEEP(m_axis_tx_data_TKEEP),
    .m_axis_tx_data_TLAST(m_axis_tx_data_TLAST),
    .s_axis_tx_status_TVALID(s_axis_tx_status_TVALID),
    .s_axis_tx_status_TREADY(s_axis_tx_status_TREADY),
    .s_axis_tx_status_TDATA(s_axis_tx_status_TDATA),
    .done(send_done),
    .error(send_error),
    .debug_http_len(debug_http_len),
    .debug_req_lo(debug_req_lo),
    .debug_req_hi(debug_req_hi),
    .debug_req_ready(debug_req_ready),
    .state_debug(send_state_dbg)
);

// -- RX path: strip HTTP header + re-align body to lane 0 --------------------
ndata_i #(data8_t, DATABEAT_SIZE) rx_ndata();

tcp_read inst_tcp_read (
    .clk(clk),
    .rst_n(rst_n),
    .start(state_q == ST_TCP_READ),
    .s_axis_notifications_TVALID(s_axis_notifications_TVALID),
    .s_axis_notifications_TREADY(s_axis_notifications_TREADY),
    .s_axis_notifications_TDATA(s_axis_notifications_TDATA),
    .m_axis_read_package_TVALID(m_axis_read_package_TVALID),
    .m_axis_read_package_TREADY(m_axis_read_package_TREADY),
    .m_axis_read_package_TDATA(m_axis_read_package_TDATA),
    .s_axis_rx_metadata_TVALID(s_axis_rx_metadata_TVALID),
    .s_axis_rx_metadata_TREADY(s_axis_rx_metadata_TREADY),
    .s_axis_rx_metadata_TDATA(s_axis_rx_metadata_TDATA),
    .s_axis_rx_data_TVALID(s_axis_rx_data_TVALID),
    .s_axis_rx_data_TREADY(s_axis_rx_data_TREADY),
    .s_axis_rx_data_TDATA(s_axis_rx_data_TDATA),
    .s_axis_rx_data_TKEEP(s_axis_rx_data_TKEEP),
    .s_axis_rx_data_TLAST(s_axis_rx_data_TLAST),
    .out(rx_ndata),
    .done(read_done),
    .error(read_error),
    .state_debug(read_state_dbg),
    .strip_state_debug(strip_state_dbg),
    .debug_payload_idx(debug_payload_idx),
    .debug_out_beat(debug_rx_out_beat)
);

// -- Trim to the exact content size and drive the OBM bypass stream ----------
valid_i #(data64_t) size_if();
assign size_if.valid = runTx_q;
assign size_if.data  = {{(64-$bits(size_q)){1'b0}}, size_q};

data64_t remaining_dbg;

FixLast #(.NUM_ELEMENTS(DATABEAT_SIZE)) inst_fix_last (
    .clk(clk),
    .rst_n(rst_n),
    .size(size_if),
    .rem(remaining_dbg),
    .in(rx_ndata),
    .out(out)
);

always_comb begin
    state_d = state_q;
    session_id_d = session_id_q;

    case (state_q)
        ST_IDLE: begin
            if (runTx_q) begin
                session_id_d = cfg_q.session_id;
                state_d = ST_TCP_SEND;
            end
        end

        ST_TCP_SEND: begin
            if (send_done) begin
                state_d = ST_TCP_READ;
            end
        end

        ST_TCP_READ: begin
            if (read_done) begin
                state_d = ST_IDLE;
            end
        end

        default: state_d = ST_IDLE;
    endcase
end

always_ff @(posedge clk) begin
    if (!rst_n) begin
        state_q <= ST_IDLE;
        session_id_q <= 16'd0;
    end else begin
        state_q <= state_d;
        session_id_q <= session_id_d;
    end
end

// -- Debug ILA ---------------------------------------------------------------
// Exposes the request being built, the FSMs, the TCP handshakes and the
// stream-back path so the full flow can be traced in hardware.
`ifdef SYNTHESIS
ila_http_read inst_ila_http_read (
    .clk(clk),
    .probe0 (rst_n),

    .probe1 (state_q),                    // 4  HTTPRead FSM
    .probe2 (send_state_dbg),             // 4  tcp_send_http FSM
    .probe3 (read_state_dbg),             // 4  tcp_read FSM
    .probe4 (strip_state_dbg),            // 2  strip_http FSM

    .probe5 (runTx_q),                    // 1
    .probe6 (conf.valid),                 // 1
    .probe7 (conf.ready),                 // 1
    .probe8 (session_id_q),               // 16
    .probe9 (size_q),                     // 32

    .probe10(debug_http_len),             // 16
    .probe11(debug_req_lo),               // 512  built request bytes [0..63]
    .probe12(debug_req_hi),               // 512  built request bytes [64..127]
    .probe13(debug_req_ready),            // 1

    .probe14(m_axis_tx_meta_TVALID),      // 1
    .probe15(m_axis_tx_meta_TREADY),      // 1
    .probe16(m_axis_tx_data_TVALID),      // 1
    .probe17(m_axis_tx_data_TREADY),      // 1
    .probe18(m_axis_tx_data_TLAST),       // 1
    .probe19(s_axis_tx_status_TVALID),    // 1
    .probe20(send_done),                  // 1
    .probe21(send_error),                 // 1

    .probe22(s_axis_notifications_TVALID),// 1
    .probe23(s_axis_notifications_TREADY),// 1
    .probe24(s_axis_rx_data_TVALID),      // 1
    .probe25(s_axis_rx_data_TREADY),      // 1
    .probe26(s_axis_rx_data_TLAST),       // 1
    .probe27(read_done),                  // 1

    .probe28(out.valid),                  // 1
    .probe29(out.ready),                  // 1
    .probe30(out.last),                   // 1
    .probe31(remaining_dbg),              // 64
    .probe32(debug_rx_out_beat)           // 512  last packed body beat
);
`endif

endmodule
