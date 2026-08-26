`timescale 1ns / 1ps

import lynxTypes::*;

// Forwards pre-built HTTP request bytes from the host into the TCP transmit path.
//
// WHY THIS REPLACES THE REQUEST RING
// ----------------------------------
// The handler used to hold a ring of NUM_SLOTS request DESCRIPTORS -- server IP, host string, 16
// path words, both range endpoints -- and rebuild the GET text in hardware from them for every
// request (http_req_builder). That put a hard ceiling on how many requests could be queued: each one
// costs 1160 bits of registers, so the ring was 4 deep and the elaboration guard stopped at 8. The
// host then had to poll for a free slot before every GET.
//
// None of that is necessary. Every byte range a query needs is known the moment the Parquet footer
// is parsed -- nothing is discovered later and nothing is revised -- so the host can build ALL of
// the GET text up front, hand it over as one byte stream, and let TCP carry it. A request is only
// text; there is nothing to store per-request on the FPGA at all.
//
// So the queue depth stops being an amount of FPGA memory and becomes an amount of HOST memory,
// which is not a constraint worth designing around. What arrives here is a flat concatenation:
//
//     GET /path HTTP/1.1\r\nHost: ...\r\nRange: bytes=0-786431\r\n...\r\n\r\n
//     GET /path HTTP/1.1\r\nHost: ...\r\nRange: bytes=786432-1572863\r\n...\r\n\r\n
//     ... one after another, for the whole query
//
// The server answers them in order on the one connection, the bodies concatenate into one stream,
// and where each column chunk ends is decided downstream by byte count (DataRewriteLast) rather
// than by a per-request flag travelling with a descriptor.
//
// WHY A LENGTH REGISTER RATHER THAN TLAST
// ---------------------------------------
// The TOE's transmit interface wants the length BEFORE the data: announce N on tx_meta, wait for
// tx_status to reserve room, then push N bytes. A stream does not know its own length until it
// ends, so the host writes the total byte count first. That also lets this module chunk the
// transfer without inspecting tkeep: it forwards whole 64-byte beats and computes the final beat's
// keep from what is left.
//
// WHY THE HOST STREAM IS NEVER CONSUMED SPECULATIVELY
// ---------------------------------------------------
// If the TOE refuses a reservation, the announced bytes must be sent again later, and an AXI-Stream
// cannot be rewound. So nothing is read from the input until the reservation is granted: on a
// refusal the FSM returns to IDLE with the input untouched and re-announces the same chunk. The
// stream stalling is the back-pressure, and it costs nothing because the host DMA is holding the
// bytes anyway.
module http_req_stream #(
    // Bytes announced per tx_meta. The TOE's length field is 16 bits, so 65535 is the ceiling;
    // MSS (4096) is the natural choice because the TOE always has room for one segment, which makes
    // a refusal rare rather than routine. Smaller chunks cost one meta/status round trip each.
    parameter int CHUNK_BYTES = 4096
) (
    input  logic clk,
    input  logic rst_n,

    // Connection state from the handler. Requests may only flow on an established session.
    input  logic        conn_up,
    input  logic [15:0] session_id,

    // Total request bytes the host is about to stream, and the pulse that arms it. Writing a new
    // total while one is in flight is a host bug; `busy` is how the host avoids it.
    input  logic [31:0] req_total_bytes,
    input  logic        req_start,

    // Request bytes from the host (Coyote LOCAL_READ into this stream).
    input  logic                        s_axis_req_TVALID,
    output logic                        s_axis_req_TREADY,
    input  logic [AXI_DATA_BITS-1:0]    s_axis_req_TDATA,
    input  logic [AXI_DATA_BITS/8-1:0]  s_axis_req_TKEEP,
    input  logic                        s_axis_req_TLAST,

    // TCP transmit.
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

    // Transmit-path arbitration. N lanes share ONE TOE transmit interface, and the
    // meta -> status -> data sequence cannot interleave: tx_status is a single ordered response
    // stream, so a second announcement made before the first lane's data is pushed takes the other
    // lane's reservation. bus_req is high from the arm until the whole transfer is sent; the lane
    // only leaves ST_IDLE while it holds the grant.
    //
    // Granting for a whole TRANSFER rather than per chunk is deliberate. Request text is a few
    // hundred bytes per GET against a ~1 ms server round trip, so serialising transmit costs
    // nothing measurable and removes every interleaving hazard. Tie bus_grant high for single-lane
    // use and this module behaves exactly as before.
    output logic        bus_req,
    input  logic        bus_grant,

    // Status.
    output logic        busy,          // a transfer is armed and not yet fully sent
    output logic        refused_sticky,// the TOE refused at least one reservation (informational)
    output logic [29:0] tx_space,      // remaining_space from the last status word
    output logic [3:0]  state_debug
);

    localparam int LANES      = AXI_DATA_BITS / 8;         // 64
    localparam int BEAT_BITS  = $clog2(LANES);             // 6

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

    // Bytes this beat carries: a whole lane-width unless the chunk ends inside it.
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
                    // Arm. Nothing is sent until the connection is up.
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
                        // Refused: no room was reserved. Push nothing -- beats with no reservation
                        // behind them destroy the boundary between this request and the next, and
                        // every later request on the connection with it. The input stream has not
                        // been touched, so re-announcing the same chunk is the whole recovery.
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
                        // Done with this chunk. If that was also the end of the whole transfer but
                        // the DMA has not signalled TLAST yet, there are padding beats behind it --
                        // see ST_DRAIN.
                        state_d = ((remaining_q - 32'(beat_bytes)) == 32'd0 && !s_axis_req_TLAST)
                                    ? ST_DRAIN : ST_IDLE;
                    end
                end
            end

            // Swallow whatever the DMA appends past the byte count we were given.
            //
            // Coyote moves whole 64-byte beats, so a request-text buffer of, say, 132 bytes arrives
            // as 192: 132 real bytes and 60 of tail. Consuming only the 132 leaves those 60 at the
            // head of the stream, where they become the prefix of the NEXT batch's request line --
            // a malformed GET, which the server answers 400 and which then desynchronises
            // everything after it. Observed as intermittent "400 Bad Request" on an otherwise
            // healthy connection.
            //
            // Nothing here reaches the wire; TLAST from the DMA is the real end of the transfer.
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
    assign bus_req = (remaining_q != 32'd0);
    assign refused_sticky = refused_q;
    assign tx_space       = space_q;
    assign state_debug    = state_q;

endmodule
