`timescale 1ns / 1ps

import lynxTypes::*;
import libstf::data8_t;

/*
 * tcp_read
 * --------
 * Drives the TCP RX side of one HTTP response: waits for notifications, requests
 * packages, and streams the received bytes through strip_http, which removes the
 * HTTP header and re-aligns the body. The re-aligned body is exposed on `out`
 * (lane-0-packed ndata); the true end/last is fixed downstream by FixLast using
 * the known content size.
 *
 * The response spans one or more notifications; reception ends on a zero-length
 * (connection-closed) notification, after which strip_http is flushed to emit
 * the final partial beat.
 */
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

    ndata_i.m                                         out,   // #(data8_t, AXI_DATA_BITS/8)

    output logic                                      done,
    output logic                                      error,
    output logic [3:0]                                state_debug,
    output logic [1:0]                                strip_state_debug,
    output logic [6:0]                                debug_payload_idx,
    output logic [AXI_DATA_BITS-1:0]                  debug_out_beat
);

    localparam logic [3:0] ST_IDLE        = 4'd0;
    localparam logic [3:0] ST_WAIT_NOTIFY = 4'd7;
    localparam logic [3:0] ST_REQ_PKG     = 4'd8;
    localparam logic [3:0] ST_RECV_DATA   = 4'd9;
    localparam logic [3:0] ST_FLUSH       = 4'd10;
    localparam logic [3:0] ST_DONE        = 4'd15;

    logic [3:0]                 state_q, state_d;
    logic [TCP_NOTIFY_BITS-1:0] notify_q, notify_d;
    logic                       rx_meta_received_q, rx_meta_received_d;

    logic strip_done;

    // Notification length field (0 => connection closed / end of response).
    logic [TCP_LEN_BITS-1:0] notif_len;
    assign notif_len = s_axis_notifications_TDATA[TCP_LEN_BITS+TCP_SESSION_BITS-1:TCP_SESSION_BITS];

    strip_http inst_strip_http (
        .clk            (clk),
        .rst_n          (rst_n),
        .clear          (state_q == ST_IDLE),
        .enable         (state_q == ST_RECV_DATA),
        .flush          (state_q == ST_FLUSH),
        .s_axis_tvalid  (s_axis_rx_data_TVALID),
        .s_axis_tdata   (s_axis_rx_data_TDATA),
        .s_axis_tkeep   (s_axis_rx_data_TKEEP),
        .s_axis_tlast   (s_axis_rx_data_TLAST),
        .s_axis_tready  (s_axis_rx_data_TREADY),
        .out            (out),
        .done           (strip_done),
        .out_payload_idx(debug_payload_idx),
        .debug_out_beat (debug_out_beat),
        .state_debug    (strip_state_debug)
    );

    always_comb begin
        state_d            = state_q;
        notify_d           = notify_q;
        rx_meta_received_d = rx_meta_received_q;

        s_axis_notifications_TREADY = 1'b0;
        m_axis_read_package_TVALID  = 1'b0;
        m_axis_read_package_TDATA   = {notify_q[TCP_LEN_BITS+TCP_SESSION_BITS-1:TCP_SESSION_BITS],
                                       notify_q[TCP_SESSION_BITS-1:0]};
        s_axis_rx_metadata_TREADY   = 1'b0;

        case (state_q)
            ST_IDLE: begin
                if (start) begin
                    state_d = ST_WAIT_NOTIFY;
                end
            end

            ST_WAIT_NOTIFY: begin
                s_axis_notifications_TREADY = 1'b1;
                if (s_axis_notifications_TVALID && s_axis_notifications_TREADY) begin
                    notify_d = s_axis_notifications_TDATA;
                    if (notif_len == 0) begin
                        state_d = ST_FLUSH;
                    end else begin
                        state_d = ST_REQ_PKG;
                    end
                end
            end

            ST_REQ_PKG: begin
                m_axis_read_package_TVALID = 1'b1;
                if (m_axis_read_package_TVALID && m_axis_read_package_TREADY) begin
                    rx_meta_received_d = 1'b0;
                    state_d            = ST_RECV_DATA;
                end
            end

            ST_RECV_DATA: begin
                if (!rx_meta_received_q) begin
                    s_axis_rx_metadata_TREADY = 1'b1;
                end
                if (s_axis_rx_metadata_TVALID && s_axis_rx_metadata_TREADY) begin
                    rx_meta_received_d = 1'b1;
                end
                // End of this package: go back for the next notification.
                if (s_axis_rx_data_TVALID && s_axis_rx_data_TREADY && s_axis_rx_data_TLAST) begin
                    state_d = ST_WAIT_NOTIFY;
                end
            end

            ST_FLUSH: begin
                if (strip_done) begin
                    state_d = ST_DONE;
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
        end else begin
            state_q            <= state_d;
            notify_q           <= notify_d;
            rx_meta_received_q <= rx_meta_received_d;
        end
    end

    assign done        = (state_q == ST_DONE);
    assign error       = 1'b0;
    assign state_debug = (state_q == ST_DONE) ? 4'd9 : state_q;

endmodule
