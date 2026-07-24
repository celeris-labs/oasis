import lynxTypes::*;

module handler (
    input  logic                                      ap_clk,
    input  logic                                      ap_rst_n,

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
    input  logic [AXI_DATA_BITS/8-1:0]                s_axis_rx_data_TSTRB,

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

    input  logic                                      runTx,
    input  logic [15:0]                               numSessions,
    input  logic [31:0]                               pkgWordCount,
    input  logic [31:0]                               serverIpAddress,
    input  logic [7:0]                                ipHexLen,
    input  logic [31:0]                               ipHexWord0,
    input  logic [31:0]                               ipHexWord1,
    input  logic [31:0]                               ipHexWord2,
    input  logic [31:0]                               ipHexWord3,
    input  logic [31:0]                               portHexWord0,
    input  logic [31:0]                               serverPort,
    input  logic [31:0]                               fileLen,
    input  logic [31:0]                               fileWord0,
    input  logic [31:0]                               fileWord1,
    input  logic [31:0]                               fileWord2,
    input  logic [31:0]                               fileWord3,
    input  logic [31:0]                               fileWord4,
    input  logic [31:0]                               fileWord5,
    input  logic [31:0]                               fileWord6,
    input  logic [31:0]                               fileWord7,
    input  logic [7:0]                                rangeBeginLen,
    input  logic [31:0]                               rangeBeginW0,
    input  logic [31:0]                               rangeBeginW1,
    input  logic [7:0]                                rangeEndLen,
    input  logic [31:0]                               rangeEndW0,
    input  logic [31:0]                               rangeEndW1,
    input  logic [31:0]                               userFrequency,
    input  logic [31:0]                               timeInSeconds,
    output logic                       m_axis_body_tvalid,
    input  logic                       m_axis_body_tready,
    output logic [AXI_DATA_BITS-1:0]   m_axis_body_tdata,
    output logic [AXI_DATA_BITS/8-1:0] m_axis_body_tkeep,
    output logic                                      m_axis_body_tlast,

    output logic [3:0]                                debug_rx_write_ptr,
    output logic [AXI_DATA_BITS-1:0]                  debug_rx_buffer_w0,
    output logic [AXI_DATA_BITS-1:0]                  debug_rx_buffer_w1,
    output logic [AXI_DATA_BITS-1:0]                  debug_tx_acc,
    output logic [6:0]                                debug_tx_acc_cnt,
    output logic                                      debug_tx_acc_last,
    output logic [15:0]                               debug_http_len,
    output logic [3:0]                                debug_builder_state,
    output logic [AXI_DATA_BITS-1:0]                  debug_req_lo,
    output logic [AXI_DATA_BITS-1:0]                  debug_req_hi,
    output logic [7:0]                                debug_req_cnt,
    output logic [31:0]                               totalWord,
    output logic [3:0]                                state_debug
);

    localparam logic [3:0] ST_IDLE     = 4'd0;
    localparam logic [3:0] ST_TCP_INIT = 4'd1;
    localparam logic [3:0] ST_TCP_SEND = 4'd2;
    localparam logic [3:0] ST_TCP_READ = 4'd3;
    localparam logic [3:0] ST_CLOSE    = 4'd4;

    logic [3:0] state_q, state_d;
    logic [15:0] session_id_q, session_id_d;

    // Cached TCP session (keep-alive). Valid while the peer keeps the connection up
    // and the request targets the same server, letting requests skip ST_TCP_INIT.
    logic        session_valid_q, session_valid_d;
    logic [31:0] sess_ip_q, sess_ip_d;
    logic [31:0] sess_port_q, sess_port_d;
    logic        session_reusable;

    assign session_reusable = session_valid_q && (sess_ip_q == serverIpAddress) &&
                              (sess_port_q == serverPort);

    logic init_done;
    logic init_error;
    logic [15:0] init_session_id;
    logic [3:0] init_state_debug;

    logic send_done;
    logic send_error;
    logic [3:0] send_state_debug;

    logic read_done;
    logic read_error;
    logic read_conn_closed;
    logic [3:0] read_state_debug;

    assign totalWord = 0;

    tcp_init inst_tcp_init (
        .clk(ap_clk),
        .rst_n(ap_rst_n),
        .start(state_q == ST_TCP_INIT),
        .serverIpAddress(serverIpAddress),
        .serverPort(serverPort),
        .m_axis_open_connection_TVALID(m_axis_open_connection_TVALID),
        .m_axis_open_connection_TREADY(m_axis_open_connection_TREADY),
        .m_axis_open_connection_TDATA(m_axis_open_connection_TDATA),
        .s_axis_open_status_TVALID(s_axis_open_status_TVALID),
        .s_axis_open_status_TREADY(s_axis_open_status_TREADY),
        .s_axis_open_status_TDATA(s_axis_open_status_TDATA),
        .done(init_done),
        .error(init_error),
        .session_id(init_session_id),
        .state_debug(init_state_debug)
    );

    tcp_send_http inst_tcp_send_http (
        .clk(ap_clk),
        .rst_n(ap_rst_n),
        .start(state_q == ST_TCP_SEND),
        .session_id(session_id_q),
        .ipHexLen(ipHexLen),
        .ipHexWord0(ipHexWord0),
        .ipHexWord1(ipHexWord1),
        .ipHexWord2(ipHexWord2),
        .ipHexWord3(ipHexWord3),
        .portHexWord0(portHexWord0),
        .fileLen(fileLen),
        .fileWord0(fileWord0),
        .fileWord1(fileWord1),
        .fileWord2(fileWord2),
        .fileWord3(fileWord3),
        .fileWord4(fileWord4),
        .fileWord5(fileWord5),
        .fileWord6(fileWord6),
        .fileWord7(fileWord7),
        .rangeBeginLen(rangeBeginLen),
        .rangeBeginW0(rangeBeginW0),
        .rangeBeginW1(rangeBeginW1),
        .rangeEndLen(rangeEndLen),
        .rangeEndW0(rangeEndW0),
        .rangeEndW1(rangeEndW1),
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
        .state_debug(send_state_debug)
    );

    tcp_read inst_tcp_read (
        .clk(ap_clk),
        .rst_n(ap_rst_n),
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
        .m_axis_body_tvalid(m_axis_body_tvalid),
        .m_axis_body_tready(m_axis_body_tready),
        .m_axis_body_tdata(m_axis_body_tdata),
        .m_axis_body_tkeep(m_axis_body_tkeep),
        .m_axis_body_tlast(m_axis_body_tlast),
        .done(read_done),
        .error(read_error),
        .conn_closed(read_conn_closed),
        .debug_rx_write_ptr(debug_rx_write_ptr),
        .debug_rx_buffer_w0(debug_rx_buffer_w0),
        .debug_rx_buffer_w1(debug_rx_buffer_w1),
        .state_debug(read_state_debug)
    );

    assign debug_tx_acc         = '0;
    assign debug_tx_acc_cnt     = '0;
    assign debug_tx_acc_last    = 1'b0;
    assign debug_builder_state  = 4'd0;
    assign debug_req_lo         = '0;
    assign debug_req_hi         = '0;
    assign debug_req_cnt        = 8'd0;

    always_comb begin
        state_d = state_q;
        session_id_d = session_id_q;
        session_valid_d = session_valid_q;
        sess_ip_d = sess_ip_q;
        sess_port_d = sess_port_q;

        m_axis_close_connection_TVALID = 1'b0;
        m_axis_close_connection_TDATA  = session_id_q[TCP_CLOSE_CONN_REQ_BITS-1:0];

        case (state_q)
            ST_IDLE: begin
                if (runTx) begin
                    // Reuse the open connection when it targets the same server.
                    state_d = session_reusable ? ST_TCP_SEND : ST_TCP_INIT;
                end
            end

            ST_TCP_INIT: begin
                if (init_done) begin
                    session_id_d = init_session_id;
                    if (init_error) begin
                        //ignore
                    end else begin
                        session_valid_d = 1'b1;
                        sess_ip_d       = serverIpAddress;
                        sess_port_d     = serverPort;
                    end
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
                    // Content-Length framing lets the response finish without the peer
                    // closing, so hold the session open and skip the teardown. Only tear
                    // down when the peer actually closed the stream.
                    if (read_conn_closed) begin
                        session_valid_d = 1'b0;
                        state_d         = ST_CLOSE;
                    end else begin
                        state_d = ST_IDLE;
                    end
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

    always_ff @(posedge ap_clk) begin
        if (!ap_rst_n) begin
            state_q <= ST_IDLE;
            session_id_q <= 16'd0;
            session_valid_q <= 1'b0;
            sess_ip_q <= 32'd0;
            sess_port_q <= 32'd0;
        end else begin
            state_q <= state_d;
            session_id_q <= session_id_d;
            session_valid_q <= session_valid_d;
            sess_ip_q <= sess_ip_d;
            sess_port_q <= sess_port_d;
        end
    end

    always_comb begin
        case (state_q)
            ST_TCP_INIT: state_debug = init_state_debug;
            ST_TCP_SEND: state_debug = send_state_debug;
            ST_TCP_READ: state_debug = read_state_debug;
            ST_CLOSE:    state_debug = 4'd10;
            default:     state_debug = 4'd0;
        endcase
    end

endmodule
