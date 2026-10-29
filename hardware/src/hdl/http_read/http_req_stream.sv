`timescale 1ns / 1ps

import lynxTypes::*;

// Sends the HTTP request text the host has built (all GETs of a lane batch, back to back) to the
// TOE. The TOE wants each length before its data, so the host writes req_total_bytes first and the
// module sends the text in CHUNK_BYTES pieces: tx_meta, then tx_status, then the data beats.
// Nothing is read from the host stream before a reservation is granted, so a refused chunk is
// simply announced again; the stalled stream is the back-pressure.
module http_req_stream #(
    // Bytes per tx_meta, at most 65535; one MSS means the TOE almost never refuses a reservation.
    parameter int CHUNK_BYTES = 4096
) (
    input  logic clk,
    input  logic rst_n,

    input  logic        conn_up,
    input  logic [15:0] session_id,

    // Arms a transfer of req_total_bytes. The host must not arm again while busy.
    input  logic [31:0] req_total_bytes,
    input  logic        req_start,

    // Request bytes from the host (Coyote LOCAL_READ into this stream).
    input  logic                        s_axis_req_TVALID,
    output logic                        s_axis_req_TREADY,
    input  logic [AXI_DATA_BITS-1:0]    s_axis_req_TDATA,
    input  logic [AXI_DATA_BITS/8-1:0]  s_axis_req_TKEEP,
    input  logic                        s_axis_req_TLAST,

    output logic                        m_axis_tx_meta_TVALID,
    input  logic                        m_axis_tx_meta_TREADY,
    output logic [TCP_TX_META_BITS-1:0] m_axis_tx_meta_TDATA,
    output logic                        m_axis_tx_data_TVALID,
    input  logic                        m_axis_tx_data_TREADY,
    output logic [AXI_DATA_BITS-1:0]    m_axis_tx_data_TDATA,
    output logic [AXI_DATA_BITS/8-1:0]  m_axis_tx_data_TKEEP,
    output logic                        m_axis_tx_data_TLAST,
    input  logic                        s_axis_tx_status_TVALID,
    output logic                        s_axis_tx_status_TREADY,
    input  logic [TCP_TX_STAT_BITS-1:0] s_axis_tx_status_TDATA,

    // The lanes share one TOE transmit interface (tx_arbiter). bus_req is held from the arm until
    // the whole transfer is sent, and the lane leaves ST_IDLE only with the grant.
    output logic        bus_req,
    input  logic        bus_grant,

    output logic        busy,          // a transfer is armed and not yet fully sent
    output logic        refused_sticky,// the TOE refused at least one reservation (informational)
    output logic [29:0] tx_space,      // remaining_space from the last status word
    output logic [3:0]  state_debug
);

    localparam int LANES      = AXI_DATA_BITS / 8;
    localparam int BEAT_BITS  = $clog2(LANES);

    localparam logic [3:0] ST_IDLE      = 4'd0;
    localparam logic [3:0] ST_SEND_META = 4'd1;
    localparam logic [3:0] ST_WAIT_STAT = 4'd2;
    localparam logic [3:0] ST_SEND_DATA = 4'd3;
    localparam logic [3:0] ST_DRAIN     = 4'd4;

    logic [3:0]  state_q, state_d;
    logic [31:0] remaining_q, remaining_d;   // bytes of the whole transfer still to send
    logic [16:0] chunk_q, chunk_d;           // bytes in the chunk currently announced
    logic [16:0] chunk_left_q, chunk_left_d; // bytes of that chunk still to push
    logic        refused_q, refused_d;
    logic [29:0] space_q, space_d;

    logic [BEAT_BITS:0] beat_bytes;
    logic               beat_is_last;
    always_comb begin
        beat_bytes   = (chunk_left_q >= 17'(LANES)) ? (BEAT_BITS+1)'(LANES)
                                                    : chunk_left_q[BEAT_BITS:0];
        beat_is_last = (chunk_left_q <= 17'(LANES));
    end

    function automatic logic [LANES-1:0] make_keep(input logic [BEAT_BITS:0] count);
        if (count >= (BEAT_BITS+1)'(LANES)) make_keep = '1;
        else if (count == '0)               make_keep = '0;
        else                                make_keep = ({LANES{1'b1}} >> (LANES - count));
    endfunction

    always_comb begin
        state_d      = state_q;
        remaining_d  = remaining_q;
        chunk_d      = chunk_q;
        chunk_left_d = chunk_left_q;
        refused_d    = refused_q;
        space_d      = space_q;

        s_axis_req_TREADY       = 1'b0;
        m_axis_tx_meta_TVALID   = 1'b0;
        m_axis_tx_meta_TDATA    = {16'(chunk_q), session_id};
        m_axis_tx_data_TVALID   = 1'b0;
        m_axis_tx_data_TDATA    = s_axis_req_TDATA;
        m_axis_tx_data_TKEEP    = make_keep(beat_bytes);
        m_axis_tx_data_TLAST    = beat_is_last;
        s_axis_tx_status_TREADY = 1'b0;

        case (state_q)
            ST_IDLE: begin
                if (req_start) begin
                    remaining_d = req_total_bytes;
                end else if ((remaining_q != 32'd0) && conn_up && bus_grant) begin
                    chunk_d      = (remaining_q >= 32'(CHUNK_BYTES)) ? 17'(CHUNK_BYTES)
                                                                     : remaining_q[16:0];
                    chunk_left_d = (remaining_q >= 32'(CHUNK_BYTES)) ? 17'(CHUNK_BYTES)
                                                                     : remaining_q[16:0];
                    state_d      = ST_SEND_META;
                end
            end

            ST_SEND_META: begin
                m_axis_tx_meta_TVALID = 1'b1;
                if (m_axis_tx_meta_TREADY) state_d = ST_WAIT_STAT;
            end

            ST_WAIT_STAT: begin
                s_axis_tx_status_TREADY = 1'b1;
                if (s_axis_tx_status_TVALID) begin
                    space_d = s_axis_tx_status_TDATA[TCP_TX_STAT_BITS-TCP_ERROR_BITS-1 -: 30];
                    if (s_axis_tx_status_TDATA[TCP_TX_STAT_BITS-1 -: TCP_ERROR_BITS] != '0) begin
                        // Refused: push nothing and announce the same chunk again.
                        refused_d = 1'b1;
                        state_d   = ST_IDLE;
                    end else begin
                        state_d = ST_SEND_DATA;
                    end
                end
            end

            ST_SEND_DATA: begin
                m_axis_tx_data_TVALID = s_axis_req_TVALID;
                s_axis_req_TREADY     = m_axis_tx_data_TREADY;
                if (s_axis_req_TVALID && m_axis_tx_data_TREADY) begin
                    chunk_left_d = chunk_left_q - 17'(beat_bytes);
                    remaining_d  = remaining_q  - 32'(beat_bytes);
                    if (beat_is_last) begin
                        state_d = ((remaining_q - 32'(beat_bytes)) == 32'd0 && !s_axis_req_TLAST)
                                    ? ST_DRAIN : ST_IDLE;
                    end
                end
            end

            // The DMA moves whole 64-byte beats, so the stream can carry padding past the byte
            // count. Drop it up to TLAST, or it would prefix the next batch's request line.
            ST_DRAIN: begin
                s_axis_req_TREADY = 1'b1;
                if (s_axis_req_TVALID && s_axis_req_TLAST) state_d = ST_IDLE;
            end

            default: state_d = ST_IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q      <= ST_IDLE;
            remaining_q  <= 32'd0;
            chunk_q      <= 17'd0;
            chunk_left_q <= 17'd0;
            refused_q    <= 1'b0;
            space_q      <= 30'd0;
        end else begin
            state_q      <= state_d;
            remaining_q  <= remaining_d;
            chunk_q      <= chunk_d;
            chunk_left_q <= chunk_left_d;
            refused_q    <= refused_d;
            space_q      <= space_d;
        end
    end

    assign busy           = (state_q != ST_IDLE) || (remaining_q != 32'd0);

    // Ask for the bus only while it can be used: a lane whose connection dropped while armed would
    // otherwise hold the grant forever and stop transmit for every lane. A lane past ST_IDLE keeps
    // it until the announced chunk is sent, since its reservation must be filled.
    assign bus_req        = (remaining_q != 32'd0) && (conn_up || (state_q != ST_IDLE));
    assign refused_sticky = refused_q;
    assign tx_space       = space_q;
    assign state_debug    = state_q;

endmodule
