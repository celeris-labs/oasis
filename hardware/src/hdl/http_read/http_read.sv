`timescale 1ns / 1ps

import lynxTypes::*;
import http_types::*;

/*
 * HTTP ranged-GET engine — same role as RDMARead at the top level:
 * host CSRs trigger one fetch via conf.valid/ready; TCP+HTTP client runs inline.
 */
module HTTPRead (
    input logic clk,
    input logic rst_n,

    http_read_config_i.s conf,

    output logic                                      m_axis_open_connection_TVALID,
    input  logic                                      m_axis_open_connection_TREADY,
    output logic [TCP_OPEN_CONN_REQ_BITS-1:0]         m_axis_open_connection_TDATA,

    input  logic                                      s_axis_open_status_TVALID,
    output logic                                      s_axis_open_status_TREADY,
    input  logic [TCP_OPEN_CONN_RSP_BITS-1:0]         s_axis_open_status_TDATA,

    output logic                                      m_axis_close_connection_TVALID,
    input  logic                                      m_axis_close_connection_TREADY,
    output logic [TCP_CLOSE_CONN_REQ_BITS-1:0]        m_axis_close_connection_TDATA,

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
    input  logic [TCP_TX_STAT_BITS-1:0]               s_axis_tx_status_TDATA
);

typedef enum logic [1:0] {
    CONF_IDLE,
    CONF_BUSY
} conf_state_t;

conf_state_t conf_state_q, conf_state_d;
logic        runTx_q, runTx_d;
http_config_t cfg_q;

localparam logic [3:0] ST_IDLE     = 4'd0;
localparam logic [3:0] ST_TCP_INIT = 4'd1;
localparam logic [3:0] ST_TCP_SEND = 4'd2;
localparam logic [3:0] ST_TCP_READ = 4'd3;
localparam logic [3:0] ST_CLOSE    = 4'd4;

logic [3:0] state_q, state_d;
logic [15:0] session_id_q, session_id_d;

logic init_done;
logic init_error;
logic [15:0] init_session_id;

logic send_done;
logic send_error;
logic [15:0] debug_http_len;

logic read_done;
logic read_error;
logic [3:0] debug_rx_write_ptr;
logic [AXI_DATA_BITS-1:0] debug_rx_buffer_w0;
logic [AXI_DATA_BITS-1:0] debug_rx_buffer_w1;

logic handler_idle;
assign handler_idle = (state_q == ST_IDLE);
assign conf.ready = (conf_state_q == CONF_IDLE);

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
    end else begin
        conf_state_q <= conf_state_d;
        runTx_q      <= runTx_d;
        if (conf.valid && conf.ready) begin
            cfg_q <= conf.cfg;
        end
    end
end

tcp_init inst_tcp_init (
    .clk(clk),
    .rst_n(rst_n),
    .start(state_q == ST_TCP_INIT),
    .serverIpAddress(cfg_q.server_ip),
    .serverPort(cfg_q.server_port),
    .m_axis_open_connection_TVALID(m_axis_open_connection_TVALID),
    .m_axis_open_connection_TREADY(m_axis_open_connection_TREADY),
    .m_axis_open_connection_TDATA(m_axis_open_connection_TDATA),
    .s_axis_open_status_TVALID(s_axis_open_status_TVALID),
    .s_axis_open_status_TREADY(s_axis_open_status_TREADY),
    .s_axis_open_status_TDATA(s_axis_open_status_TDATA),
    .done(init_done),
    .error(init_error),
    .session_id(init_session_id),
    .state_debug()
);

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
    .state_debug()
);

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
    .done(read_done),
    .error(read_error),
    .debug_rx_write_ptr(debug_rx_write_ptr),
    .debug_rx_buffer_w0(debug_rx_buffer_w0),
    .debug_rx_buffer_w1(debug_rx_buffer_w1),
    .state_debug()
);

always_comb begin
    state_d = state_q;
    session_id_d = session_id_q;

    m_axis_close_connection_TVALID = 1'b0;
    m_axis_close_connection_TDATA  = session_id_q[TCP_CLOSE_CONN_REQ_BITS-1:0];

    case (state_q)
        ST_IDLE: begin
            if (runTx_q) begin
                state_d = ST_TCP_INIT;
            end
        end

        ST_TCP_INIT: begin
            if (init_done) begin
                session_id_d = init_session_id;
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
                state_d = ST_CLOSE;
            end
        end

        ST_CLOSE: begin
            m_axis_close_connection_TVALID = 1'b1;
            if (m_axis_close_connection_TVALID && m_axis_close_connection_TREADY) begin
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

endmodule
