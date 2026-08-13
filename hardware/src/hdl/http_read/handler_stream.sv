`timescale 1ns / 1ps

import lynxTypes::*;
import http_types::*;

// =================================================================================================
// HTTP client handler, streamed-request variant.
//
// Same job as handler.sv -- hold one TCP connection to an object store, issue ranged GETs, hand the
// concatenated response bodies to the decoder -- with one structural difference: the host builds
// the request TEXT and streams it in, instead of writing a descriptor per request for the FPGA to
// rebuild the text from.
//
// WHY
// ---
// handler.sv stores a full http_config_t per outstanding request: server IP, host string, 16 path
// words, both range endpoints, 1160 bits. The queue depth is therefore an amount of FPGA registers,
// which is why it is 4 with an elaboration ceiling of 8. Measured on a scale-30 lineitem scan, that
// ring is full for 1462 of 1465 requests: the host spends essentially the whole query blocked
// waiting for a slot, and whether deeper queueing helps cannot be answered while the depth is
// pinned at 4 and pegged.
//
// Every byte range is known once the Parquet footer is parsed, so the host can build all of the GET
// text up front. A request is only text; nothing about it needs to be stored here.
//
// WHAT STILL NEEDS A QUEUE, AND WHY IT IS 512 DEEP FOR 512 BITS
// -------------------------------------------------------------
// The descriptor splits unevenly. The send side needs nothing. The read side needs exactly one bit
// per response -- body_last, which says whether this response ends a decoder stream, because the
// host may split one column chunk across several ranged GETs and the DataNormalizer resets its
// running byte offset on tlast. So the ring does not disappear, it gets narrow: 512 entries of one
// bit is less than half of ONE old slot.
//
// That is deliberately a smaller change than deleting the read path. tcp_read, strip_http and the
// notification queue are untouched here -- they keep the behaviour that is currently working and
// simulated, and the receive path is where every deadlock this week has come from.
//
// HOW THE HOST DRIVES IT
// ----------------------
//   1. one cfg beat per request with req_total_bytes == 0, pushing that request's body_last bit
//   2. one cfg beat with req_total_bytes != 0, which latches the server address and arms the
//      transfer -- this is what opens the connection
//   3. the request text itself, DMA'd in over s_axis_req (Coyote LOCAL_READ)
//
// Responses come back in request order on the one connection, which is what makes a single bit per
// entry sufficient: the k-th response belongs to the k-th entry, by construction.
// =================================================================================================
module handler_stream #(
    // Entries, i.e. responses that may be outstanding. One bit each. 512 is not a considered
    // optimum, it is "large enough that the host is never the one waiting" at a cost that does not
    // merit thinking about.
    parameter int QUEUE_DEPTH = 512,
    // Cycles a stage may make no progress before its stall bit latches. See handler.sv.
    parameter int STALL_CYCLES = 268435456,
    // Bytes announced to the TOE per transmit reservation.
    parameter int TX_CHUNK_BYTES = 4096
) (
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

    // Config beats from HttpConfig. req_total_bytes == 0 pushes one queue entry; non-zero arms a
    // request-text transfer and latches the server address.
    input  logic                                      req_valid,
    output logic                                      req_ready,
    input  http_config_t                              req_data,

    // Pre-built request text from the host (Coyote LOCAL_READ into this stream).
    input  logic                                      s_axis_req_TVALID,
    output logic                                      s_axis_req_TREADY,
    input  logic [AXI_DATA_BITS-1:0]                  s_axis_req_TDATA,
    input  logic [AXI_DATA_BITS/8-1:0]                s_axis_req_TKEEP,
    input  logic                                      s_axis_req_TLAST,

    output logic                       m_axis_body_tvalid,
    input  logic                       m_axis_body_tready,
    output logic [AXI_DATA_BITS-1:0]   m_axis_body_tdata,
    output logic [AXI_DATA_BITS/8-1:0] m_axis_body_tkeep,
    output logic                       m_axis_body_tlast,

    output logic [31:0]                               totalWord,
    output logic [31:0]                               inflightWord,
    output logic [31:0]                               stallWord,
    output logic [31:0]                               respWord,
    output logic [31:0]                               contentLengthWord,
    output logic [31:0]                               bodyRemainingWord,
    output logic [3:0]                                state_debug
);

    localparam int PTR_BITS = $clog2(QUEUE_DEPTH) + 1; // one extra bit so full and empty differ
    localparam int IDX_BITS = $clog2(QUEUE_DEPTH);

    initial begin
        if (QUEUE_DEPTH < 2 || (QUEUE_DEPTH & (QUEUE_DEPTH - 1)))
            $error("handler_stream: QUEUE_DEPTH must be a power of two >= 2 (pointers wrap on it)");
    end

    // -- the response queue: one bit per expected response ----------------------------------------
    logic                body_last_q [QUEUE_DEPTH];
    logic [PTR_BITS-1:0] fill_ptr_q, read_ptr_q;
    logic [IDX_BITS-1:0] fill_idx, read_idx;
    assign fill_idx = fill_ptr_q[IDX_BITS-1:0];
    assign read_idx = read_ptr_q[IDX_BITS-1:0];

    logic [PTR_BITS-1:0] occupancy;
    assign occupancy = fill_ptr_q - read_ptr_q;

    // -- the latched query context ------------------------------------------------------------
    logic [31:0] server_ip_q, server_port_q;
    logic        armed_q;          // a request-text transfer has been armed

    logic cfg_fire, cfg_is_arm, cfg_is_entry;
    assign req_ready     = (occupancy < PTR_BITS'(QUEUE_DEPTH));
    assign cfg_fire      = req_valid && req_ready;
    assign cfg_is_arm    = cfg_fire && (req_data.req_total_bytes != 32'd0);
    assign cfg_is_entry  = cfg_fire && (req_data.req_total_bytes == 32'd0);

    // -- the one connection -----------------------------------------------------------------------
    logic        conn_valid_q;
    logic [15:0] conn_sid_q;

    localparam logic [1:0] CS_DOWN  = 2'd0;
    localparam logic [1:0] CS_OPEN  = 2'd1;
    localparam logic [1:0] CS_UP    = 2'd2;
    localparam logic [1:0] CS_CLOSE = 2'd3;

    logic [1:0] cs_q, cs_d;
    logic reconn_q, reconn_d;
    logic fatal_q, fatal_d;
    logic [7:0] reconn_cnt_q;

    localparam int RETRY_BITS = 16;
    logic [RETRY_BITS-1:0] retry_wait_q;

    logic clear_framing;
    assign clear_framing = !conn_valid_q;

    // -- sub-module handshakes --------------------------------------------------------------------
    logic init_done, init_error;
    logic [15:0] init_session_id;
    logic [3:0]  init_state_debug;

    logic read_done, read_error, read_error_dirty;
    logic [3:0]  read_state_debug;
    logic        read_resp_error;
    logic [23:0] read_status_ascii;
    logic        read_status_ok;
    logic [31:0] read_content_length;
    logic [31:0] read_body_remaining;
    logic        read_timeout_w, rx_fifo_stall_w;

    logic        stream_busy, stream_refused;
    logic [29:0] stream_space;
    logic [3:0]  stream_state_debug;

    localparam logic ST_STAGE_IDLE = 1'b0;
    localparam logic ST_STAGE_RUN  = 1'b1;
    logic read_state_q, read_state_d;

    logic read_has_work;
    assign read_has_work = (read_ptr_q != fill_ptr_q);

    // -- session table (notifications) ------------------------------------------------------------
    logic [TCP_LEN_BITS-1:0] tbl_req_len;
    logic                    tbl_closed, tbl_take_en, tbl_bound;
    logic [31:0]             tbl_pending;
    logic [0:0]              tbl_dbg_has_pending, tbl_dbg_closed, tbl_dbg_overflow;
    logic                    bind_en, release_en;

    tcp_session_table #(.NUM_SLOTS(1)) inst_tbl (
        .clk(ap_clk), .rst_n(ap_rst_n),
        .s_axis_notifications_TVALID(s_axis_notifications_TVALID),
        .s_axis_notifications_TREADY(s_axis_notifications_TREADY),
        .s_axis_notifications_TDATA(s_axis_notifications_TDATA),
        .bind_en(bind_en), .bind_slot(1'b0), .bind_sid(init_session_id),
        .release_en(release_en), .release_slot(1'b0),
        .q_slot(1'b0), .q_pending(tbl_pending), .q_req_len(tbl_req_len),
        .q_closed(tbl_closed), .q_bound(tbl_bound),
        .take_en(tbl_take_en),
        .dbg_has_pending(tbl_dbg_has_pending), .dbg_closed(tbl_dbg_closed),
        .dbg_overflow(tbl_dbg_overflow)
    );

    // -- connect ----------------------------------------------------------------------------------
    tcp_init inst_tcp_init (
        .clk(ap_clk), .rst_n(ap_rst_n),
        .start(cs_q == CS_OPEN),
        .serverIpAddress(server_ip_q),
        .serverPort(server_port_q),
        .m_axis_open_connection_TVALID(m_axis_open_connection_TVALID),
        .m_axis_open_connection_TREADY(m_axis_open_connection_TREADY),
        .m_axis_open_connection_TDATA(m_axis_open_connection_TDATA),
        .s_axis_open_status_TVALID(s_axis_open_status_TVALID),
        .s_axis_open_status_TREADY(s_axis_open_status_TREADY),
        .s_axis_open_status_TDATA(s_axis_open_status_TDATA),
        .done(init_done), .error(init_error),
        .session_id(init_session_id), .state_debug(init_state_debug)
    );

    // -- send: the host's request text straight into the transmit path ----------------------------
    logic        stream_arm_pulse;
    logic [31:0] stream_total_d;
    assign stream_arm_pulse = cfg_is_arm;
    assign stream_total_d   = req_data.req_total_bytes;

    http_req_stream #(.CHUNK_BYTES(TX_CHUNK_BYTES)) inst_req_stream (
        .clk(ap_clk), .rst_n(ap_rst_n),
        .conn_up(cs_q == CS_UP && !reconn_q && !fatal_q),
        .session_id(conn_sid_q),
        .req_total_bytes(stream_total_d),
        .req_start(stream_arm_pulse),
        .s_axis_req_TVALID(s_axis_req_TVALID),
        .s_axis_req_TREADY(s_axis_req_TREADY),
        .s_axis_req_TDATA(s_axis_req_TDATA),
        .s_axis_req_TKEEP(s_axis_req_TKEEP),
        .s_axis_req_TLAST(s_axis_req_TLAST),
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
        .busy(stream_busy), .refused_sticky(stream_refused),
        .tx_space(stream_space), .state_debug(stream_state_debug)
    );

    // -- read -------------------------------------------------------------------------------------
    tcp_read inst_tcp_read (
        .clk(ap_clk), .rst_n(ap_rst_n),
        .start(read_state_q == ST_STAGE_RUN),
        .session_id(conn_sid_q),
        .body_last(body_last_q[read_idx]),
        .clear_framing(clear_framing),
        .rx_req_len(tbl_req_len), .rx_closed(tbl_closed), .rx_take_en(tbl_take_en),
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
        .done(read_done), .error(read_error), .error_dirty(read_error_dirty),
        .resp_error(read_resp_error), .status_ascii(read_status_ascii),
        .status_ok(read_status_ok), .content_length(read_content_length),
        .read_timeout(read_timeout_w), .body_remaining(read_body_remaining),
        .rx_fifo_level(), .rx_fifo_stall(rx_fifo_stall_w),
        .state_debug(read_state_debug)
    );

    // -- sequencing -------------------------------------------------------------------------------
    logic read_advance, conn_bind;

    always_comb begin
        cs_d         = cs_q;
        read_state_d = read_state_q;
        reconn_d     = reconn_q;
        fatal_d      = fatal_q;
        read_advance = 1'b0;
        conn_bind    = 1'b0;
        bind_en      = 1'b0;
        release_en   = 1'b0;

        m_axis_close_connection_TVALID = 1'b0;
        m_axis_close_connection_TDATA  = conn_sid_q[TCP_CLOSE_CONN_REQ_BITS-1:0];

        case (cs_q)
            CS_DOWN: begin
                // Open once the host has armed a transfer. Unlike handler.sv this does not key off
                // queue occupancy: the entries say how many responses to expect, not whether there
                // is anything to send.
                if (armed_q && !fatal_q && (retry_wait_q == '0)) cs_d = CS_OPEN;
            end
            CS_OPEN: begin
                if (init_done) begin
                    if (init_error) begin
                        cs_d = CS_DOWN;
                    end else begin
                        bind_en   = 1'b1;
                        conn_bind = 1'b1;
                        cs_d      = CS_UP;
                    end
                end
            end
            CS_UP: begin
                if (reconn_q && (read_state_q == ST_STAGE_IDLE) && !stream_busy) cs_d = CS_CLOSE;
            end
            CS_CLOSE: begin
                m_axis_close_connection_TVALID = 1'b1;
                if (m_axis_close_connection_TREADY) begin
                    release_en = 1'b1;
                    reconn_d   = 1'b0;
                    cs_d       = CS_DOWN;
                end
            end
        endcase

        case (read_state_q)
            ST_STAGE_IDLE: begin
                if (read_has_work && (cs_q == CS_UP) && !reconn_q && !fatal_q) begin
                    read_state_d = ST_STAGE_RUN;
                end
            end
            ST_STAGE_RUN: begin
                if (read_done) begin
                    read_state_d = ST_STAGE_IDLE;
                    if (read_error) begin
                        // Do not advance: this request has not been answered.
                        if (read_error_dirty) fatal_d  = 1'b1;
                        else                  reconn_d = 1'b1;
                    end else begin
                        read_advance = 1'b1;
                    end
                end
            end
        endcase
    end

    // -- state ------------------------------------------------------------------------------------
    logic init_err_q, stream_err_q, resp_err_q, status_bad_q;
    logic conn_stall_q, read_stall_q;
    localparam int STALL_BITS = $clog2(STALL_CYCLES) + 1;
    logic [STALL_BITS-1:0] conn_cnt_q, read_cnt_q;

    always_ff @(posedge ap_clk) begin
        if (!ap_rst_n) begin
            fill_ptr_q   <= '0;
            read_ptr_q   <= '0;
            cs_q         <= CS_DOWN;
            read_state_q <= ST_STAGE_IDLE;
            conn_valid_q <= 1'b0;
            conn_sid_q   <= 16'd0;
            reconn_q     <= 1'b0;
            fatal_q      <= 1'b0;
            reconn_cnt_q <= '0;
            retry_wait_q <= '0;
            armed_q      <= 1'b0;
            server_ip_q  <= '0;
            server_port_q<= '0;
            init_err_q   <= 1'b0;
            stream_err_q <= 1'b0;
            resp_err_q   <= 1'b0;
            status_bad_q <= 1'b0;
            conn_stall_q <= 1'b0;
            read_stall_q <= 1'b0;
            conn_cnt_q   <= '0;
            read_cnt_q   <= '0;
        end else begin
            cs_q         <= cs_d;
            read_state_q <= read_state_d;
            reconn_q     <= reconn_d;
            fatal_q      <= fatal_d;

            if (cfg_is_entry) begin
                body_last_q[fill_idx] <= req_data.req_flags[0];
                fill_ptr_q            <= fill_ptr_q + 1'b1;
            end
            if (cfg_is_arm) begin
                server_ip_q   <= req_data.server_ip;
                server_port_q <= req_data.server_port;
                armed_q       <= 1'b1;
            end
            // The transfer is done once the forwarder has drained it and every response was read.
            if (armed_q && !stream_busy && (occupancy == '0)) armed_q <= 1'b0;

            if (read_advance) read_ptr_q <= read_ptr_q + 1'b1;

            if (retry_wait_q != '0) retry_wait_q <= retry_wait_q - 1'b1;
            if ((cs_q == CS_OPEN) && init_done && init_error) retry_wait_q <= '1;

            if (conn_bind) begin
                conn_valid_q <= 1'b1;
                conn_sid_q   <= init_session_id;
            end
            if (release_en) begin
                conn_valid_q <= 1'b0;
                reconn_cnt_q <= reconn_cnt_q + 1'b1;
            end

            if ((cs_q == CS_OPEN) && init_done && init_error)        init_err_q   <= 1'b1;
            if (stream_refused)                                       stream_err_q <= 1'b1;
            if ((read_state_q == ST_STAGE_RUN) && read_done && read_resp_error) resp_err_q <= 1'b1;
            if ((read_state_q == ST_STAGE_RUN) && read_done && !read_error && !read_status_ok)
                status_bad_q <= 1'b1;

            // Stage watchdogs: a stage that makes no progress for STALL_CYCLES latches its bit.
            if (cs_q == CS_OPEN) begin
                if (conn_cnt_q == STALL_BITS'(STALL_CYCLES)) conn_stall_q <= 1'b1;
                else                                          conn_cnt_q   <= conn_cnt_q + 1'b1;
            end else begin
                conn_cnt_q <= '0;
            end
            if (read_state_q == ST_STAGE_RUN) begin
                if (read_cnt_q == STALL_BITS'(STALL_CYCLES)) read_stall_q <= 1'b1;
                else                                          read_cnt_q   <= read_cnt_q + 1'b1;
            end else begin
                read_cnt_q <= '0;
            end
        end
    end

    // -- readback ---------------------------------------------------------------------------------
    assign totalWord = {8'd0, tbl_dbg_overflow, stream_refused, fatal_q, reconn_q,
                        (cs_q == CS_UP), 3'd0,
                        1'b0, (read_state_q == ST_STAGE_RUN) || stream_busy, 6'd0,
                        req_ready, 3'd0, read_state_debug, init_state_debug};

    // SAME LAYOUT AS handler.sv, deliberately, including the byte-wide fields that used to cap the
    // ring at 8. Widening them here would have been tidier and would have silently broken every
    // host reading a build-98 board: the software cannot tell which bitstream it is talking to, and
    // num_slots() -- which max_inflight() is derived from -- comes straight out of these bits.
    //
    // So both fields SATURATE instead. 255 means "at least 255", which is all the host needs: it
    // sizes its batches from this, and 255 is safely below the real 512.
    logic [7:0] occ_sat, depth_sat;
    assign occ_sat   = (occupancy > PTR_BITS'(255)) ? 8'd255 : 8'(occupancy);
    assign depth_sat = (QUEUE_DEPTH > 255) ? 8'd255 : 8'(QUEUE_DEPTH);

    assign inflightWord = {13'd0, conn_valid_q, tbl_dbg_closed, tbl_dbg_has_pending,
                           depth_sat, occ_sat};

    assign stallWord = {5'd0, read_timeout_w, rx_fifo_stall_w, tbl_dbg_overflow,
                        8'd0, reconn_cnt_q,
                        status_bad_q, fatal_q, resp_err_q, stream_err_q, init_err_q,
                        read_stall_q, 1'b0, conn_stall_q};

    assign respWord           = {5'd0, read_error_dirty, read_resp_error, read_status_ok,
                                 read_status_ascii};
    assign contentLengthWord  = read_content_length;
    assign bodyRemainingWord  = read_body_remaining;
    assign state_debug        = read_state_debug;

endmodule
