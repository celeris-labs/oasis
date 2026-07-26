import lynxTypes::*;

module tcp_read (
    input  logic                                      clk,
    input  logic                                      rst_n,
    input  logic                                      start,
    
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

    output logic                       m_axis_body_tvalid,
    input  logic                       m_axis_body_tready,
    output logic [AXI_DATA_BITS-1:0]   m_axis_body_tdata,
    output logic [AXI_DATA_BITS/8-1:0] m_axis_body_tkeep,
    output logic                       m_axis_body_tlast,
    
    output logic                                      done,
    output logic                                      error,
    output logic [3:0]                                debug_rx_write_ptr,
    output logic [AXI_DATA_BITS-1:0]                  debug_rx_buffer_w0,
    output logic [AXI_DATA_BITS-1:0]                  debug_rx_buffer_w1,
    output logic [3:0]                                state_debug
);

    localparam logic [3:0] ST_IDLE          = 4'd0;
    localparam logic [3:0] ST_WAIT_NOTIFY   = 4'd7;
    localparam logic [3:0] ST_REQ_PKG       = 4'd8;
    localparam logic [3:0] ST_RECV_DATA     = 4'd9;
    localparam logic [3:0] ST_DONE          = 4'd15;

    logic [3:0] state_q, state_d;
    logic [TCP_NOTIFY_BITS-1:0] notify_q, notify_d;
    logic rx_meta_received_q, rx_meta_received_d;
    logic [AXI_DATA_BITS-1:0] payload_w0;
    logic [AXI_DATA_BITS-1:0] payload_w1;
    logic payload_w0_valid;
    logic payload_w1_valid;
    logic payload_done;
    logic payload_ready;

    logic [AXI_DATA_BITS-1:0] payload_w0_q, payload_w0_d;
    logic [AXI_DATA_BITS-1:0] payload_w1_q, payload_w1_d;
    
    logic done_q, done_d;

    strip_http inst_strip_http (
        .clk(clk),
        .rst_n(rst_n),
        .clear(state_q != ST_RECV_DATA),
        .enable(state_q == ST_RECV_DATA),
        .s_axis_tvalid(s_axis_rx_data_TVALID),
        .s_axis_tdata(s_axis_rx_data_TDATA),
        .s_axis_tkeep(s_axis_rx_data_TKEEP),
        .s_axis_tlast(s_axis_rx_data_TLAST),
        .s_axis_tready(s_axis_rx_data_TREADY),
        .m_axis_tvalid(m_axis_body_tvalid),
        .m_axis_tdata(m_axis_body_tdata),
        .m_axis_tkeep(m_axis_body_tkeep),
        .m_axis_tlast(m_axis_body_tlast),
        .m_axis_tready(m_axis_body_tready),
        .out_w0(payload_w0),
        .out_w1(payload_w1),
        .out_w0_valid(payload_w0_valid),
        .out_w1_valid(payload_w1_valid),
        .done(payload_done),
        .out_payload_idx()
    );

    always_comb begin
        state_d             = state_q;
        notify_d            = notify_q;
        rx_meta_received_d  = rx_meta_received_q;
        payload_w0_d        = payload_w0_q;
        payload_w1_d        = payload_w1_q;
        done_d              = done_q;

        s_axis_notifications_TREADY = 1'b0;
        m_axis_read_package_TVALID  = 1'b0;
        m_axis_read_package_TDATA   = {notify_q[TCP_LEN_BITS+TCP_SESSION_BITS-1:TCP_SESSION_BITS],
                                       notify_q[TCP_SESSION_BITS-1:0]};
        s_axis_rx_metadata_TREADY   = 1'b0;

        case (state_q)
            ST_IDLE: begin
                if (start) begin
                    rx_meta_received_d = 1'b0;
                    state_d            = ST_WAIT_NOTIFY;
                end
            end

            ST_WAIT_NOTIFY: begin
                s_axis_notifications_TREADY = 1'b1;
                if (s_axis_notifications_TVALID && s_axis_notifications_TREADY) begin
                    notify_d = s_axis_notifications_TDATA;
                    state_d  = ST_REQ_PKG;
                end
            end

            ST_REQ_PKG: begin
                m_axis_read_package_TVALID = 1'b1;
                if (m_axis_read_package_TVALID && m_axis_read_package_TREADY) begin
                    if (notify_q[TCP_LEN_BITS+TCP_SESSION_BITS-1:TCP_SESSION_BITS] == 0) begin
                        state_d = ST_DONE;
                    end else begin
                        state_d = ST_RECV_DATA;
                    end
                end
            end

            ST_RECV_DATA: begin
                // METADATA HANDSHAKE
                if (s_axis_rx_metadata_TVALID && s_axis_rx_metadata_TREADY) begin
                    rx_meta_received_d = 1'b1;
                end
                if (!rx_meta_received_q) begin
                    s_axis_rx_metadata_TREADY = 1'b1;
                end

                if (payload_done) begin
                    // Latch stripped payload into debug registers on completion.
                    payload_w0_d = payload_w0;
                    payload_w1_d = payload_w1;
                    state_d      = ST_DONE;
                end
            end

            ST_DONE: begin
                if (!start) begin
                    state_d = ST_IDLE;
                end
            end

            default: state_d = ST_IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q            <= ST_IDLE;
            notify_q           <= '0;
            rx_meta_received_q <= 1'b0;
            payload_w0_q       <= '0;
            payload_w1_q       <= '0;
            done_q             <= 1'b0;
        end else begin
            state_q            <= state_d;
            notify_q           <= notify_d;
            rx_meta_received_q <= rx_meta_received_d;
            payload_w0_q       <= payload_w0_d;
            payload_w1_q       <= payload_w1_d;
            done_q             <= done_d;
        end
    end

    assign done               = (state_q == ST_DONE);
    assign error              = 1'b0;
    assign debug_rx_write_ptr = payload_w1_valid ? 4'd2 : payload_w0_valid ? 4'd1 : 4'd0;
    assign debug_rx_buffer_w0 = payload_w0_q;
    assign debug_rx_buffer_w1 = payload_w1_q;
    
    assign state_debug        = (state_q == ST_DONE) ? 4'd9 : state_q;

endmodule