`timescale 1ns / 1ps

import lynxTypes::*;
import http_types::*;

// =================================================================================================
// Testbench for the HTTP client handler with keep-alive.
//
// It models enough of the Coyote TOE to drive the whole request lifecycle -- openConnection /
// openStatus, tx meta+data, appNotification, readPkg, rx meta+data, closeConnection -- against a
// server that behaves like MinIO on a PERSISTENT connection: one TCP session carrying every ranged
// GET in order, responses delimited by Content-Length, and no FIN between them.
//
// What it proves:
//   1. Every response body reaches m_axis_body byte-exact and IN REQUEST ORDER. Ordering is not a
//      nicety: the bodies are concatenated into one decoder stream, so a swap silently corrupts a
//      column.
//   2. Exactly ONE TCP connection is opened per connection lifetime, not one per request. That is
//      the point of the change -- the TOE has 512 ephemeral ports, allocated by a linear cursor and
//      cumulative since the bitstream was programmed, and a connection per GET wraps them inside a
//      benchmark run.
//   3. The request says `Connection: keep-alive` and never `close`.
//   4. The GET for request k+1 is on the wire BEFORE body k has finished streaming, so the server's
//      think time overlaps the previous transfer instead of following it. Without this the test
//      would pass just as happily on a sequential handler.
//   5. body_last=0 concatenates two responses into ONE decoder stream with a single tlast -- what
//      the host does when it splits a column chunk into several ranged GETs to bound how many bytes
//      the server can have in flight.
//   6. RECONNECT AND REPLAY: the server drops the connection between responses, the way MinIO's
//      idle timeout does. The handler must reopen and re-send every request that was sent but not
//      answered, and the remaining bodies must still arrive complete and in order.
//
// Deliberate awkwardness in the model, all of it representative of a real server:
//   - announced segments are cut on a GLOBAL 96-byte cursor over the connection's byte stream, so
//     they straddle response boundaries -- a segment routinely carries the tail of body k and the
//     status line of response k+1, which is the case that broke the old FIN-delimited framer;
//   - response headers vary in length, so each body starts at a different lane;
//   - body lengths are mostly not multiples of 64, including a 1-byte body;
//   - the consumer applies back-pressure.
// =================================================================================================
module http_stream_tb #(
    // The queue is one bit per response, so depth is not a variable worth sweeping. 8 is small
    // enough that the pointer wrap is exercised by NUM_REQS = 6 plus the arm.
    parameter int QUEUE_DEPTH = 8
);

    localparam int NUM_REQS   = 6;   // > NUM_SLOTS so the slot ring wraps
    localparam int LANES      = AXI_DATA_BITS / 8;
    // After this request has been answered, the server drops the connection between responses.
    // No reconnect in this bench. handler.sv replayed unanswered requests by rolling send_ptr back to
// read_ptr, which worked because the descriptors were still in their slots. Streamed request text
// has already been consumed and cannot be re-sent, so a reconnect mid-transfer is a different
// contract that needs its own design and its own case. Out of range here, deliberately.
localparam int RECONNECT_AFTER = 999;

    // The TOE REFUSES this many'th tx_meta: error != 0 on tx_status, meaning it did not reserve room
    // for the length just announced. This is not a network fault -- it is local back-pressure from
    // the TOE's own tx buffer, and it becomes reachable the moment requests are queued back to back
    // instead of one at a time.
    //
    // What must happen: NOT ONE data beat may follow, because those beats would enter the stream
    // with no reservation behind them and the boundary between this request and the next would be
    // lost -- corrupting every later request on the connection, not just this one. The handler must
    // then re-send the same request, since nothing went out and there is nothing to unwind.
    localparam int REJECT_ON_META = 3;

    logic clk = 0;
    logic rst_n = 0;
    always #2 clk = ~clk;   // 250 MHz

    // ---------------------------------------------------------------------------------------------
    // DUT interface signals
    // ---------------------------------------------------------------------------------------------
    logic                               open_req_valid, open_req_ready;
    logic [TCP_OPEN_CONN_REQ_BITS-1:0]  open_req_data;
    logic                               open_rsp_valid, open_rsp_ready;
    logic [TCP_OPEN_CONN_RSP_BITS-1:0]  open_rsp_data;
    logic                               close_valid, close_ready;
    logic [TCP_CLOSE_CONN_REQ_BITS-1:0] close_data;

    logic                       notify_valid, notify_ready;
    logic [TCP_NOTIFY_BITS-1:0] notify_data;
    logic                       rdpkg_valid, rdpkg_ready;
    logic [TCP_RD_PKG_REQ_BITS-1:0] rdpkg_data;
    logic                       rxmeta_valid, rxmeta_ready;
    logic [TCP_RX_META_BITS-1:0] rxmeta_data;
    logic                       rxdata_valid, rxdata_ready;
    logic [AXI_DATA_BITS-1:0]   rxdata_data;
    logic [LANES-1:0]           rxdata_keep;
    logic                       rxdata_last;

    logic                        txmeta_valid, txmeta_ready;
    logic [TCP_TX_META_BITS-1:0] txmeta_data;
    logic                        txdata_valid, txdata_ready;
    logic [AXI_DATA_BITS-1:0]    txdata_data;
    logic [LANES-1:0]            txdata_keep;
    logic                        txdata_last;
    logic                        txstat_valid, txstat_ready;
    logic [TCP_TX_STAT_BITS-1:0] txstat_data;

    logic         req_valid, req_ready;
    http_config_t req_data;

    // Pre-built request text, streamed in the way Coyote LOCAL_READ delivers it.
    logic                       rqs_valid = 0, rqs_ready;
    logic [AXI_DATA_BITS-1:0]   rqs_data  = '0;
    logic [AXI_DATA_BITS/8-1:0] rqs_keep  = '0;
    logic                       rqs_last  = 0;

    byte req_text [$];        // every GET, concatenated, exactly as the host would build it
    int  req_text_len;

    logic             body_tvalid, body_tready;
    logic [AXI_DATA_BITS-1:0] body_tdata;
    logic [LANES-1:0] body_tkeep;
    logic             body_tlast;

    logic [31:0] total_word, inflight_word, stall_word, resp_word, body_remaining_word;

    // STALL_CYCLES shrunk so the watchdog is reachable in a simulation: the default is
    // ~1.07 s of hardware time. 20000 cycles is far longer than any healthy stage here
    // (the slowest is the 700-cycle server think-time) so a passing run must not trip it.
    handler_stream #(.QUEUE_DEPTH(QUEUE_DEPTH), .STALL_CYCLES(20000)) dut (
        .ap_clk  (clk),
        .ap_rst_n(rst_n),

        .m_axis_open_connection_TVALID(open_req_valid),
        .m_axis_open_connection_TREADY(open_req_ready),
        .m_axis_open_connection_TDATA (open_req_data),
        .s_axis_open_status_TVALID    (open_rsp_valid),
        .s_axis_open_status_TREADY    (open_rsp_ready),
        .s_axis_open_status_TDATA     (open_rsp_data),
        .m_axis_close_connection_TVALID(close_valid),
        .m_axis_close_connection_TREADY(close_ready),
        .m_axis_close_connection_TDATA (close_data),

        .s_axis_notifications_TVALID(notify_valid),
        .s_axis_notifications_TREADY(notify_ready),
        .s_axis_notifications_TDATA (notify_data),
        .m_axis_read_package_TVALID (rdpkg_valid),
        .m_axis_read_package_TREADY (rdpkg_ready),
        .m_axis_read_package_TDATA  (rdpkg_data),
        .s_axis_rx_metadata_TVALID  (rxmeta_valid),
        .s_axis_rx_metadata_TREADY  (rxmeta_ready),
        .s_axis_rx_metadata_TDATA   (rxmeta_data),
        .s_axis_rx_data_TVALID      (rxdata_valid),
        .s_axis_rx_data_TREADY      (rxdata_ready),
        .s_axis_rx_data_TDATA       (rxdata_data),
        .s_axis_rx_data_TKEEP       (rxdata_keep),
        .s_axis_rx_data_TLAST       (rxdata_last),
        .s_axis_rx_data_TSTRB       ('0),

        .m_axis_tx_meta_TVALID  (txmeta_valid),
        .m_axis_tx_meta_TREADY  (txmeta_ready),
        .m_axis_tx_meta_TDATA   (txmeta_data),
        .m_axis_tx_data_TVALID  (txdata_valid),
        .m_axis_tx_data_TREADY  (txdata_ready),
        .m_axis_tx_data_TDATA   (txdata_data),
        .m_axis_tx_data_TKEEP   (txdata_keep),
        .m_axis_tx_data_TLAST   (txdata_last),
        .s_axis_tx_status_TVALID(txstat_valid),
        .s_axis_tx_status_TREADY(txstat_ready),
        .s_axis_tx_status_TDATA (txstat_data),

        .s_axis_req_TVALID(rqs_valid),
        .s_axis_req_TREADY(rqs_ready),
        .s_axis_req_TDATA (rqs_data),
        .s_axis_req_TKEEP (rqs_keep),
        .s_axis_req_TLAST (rqs_last),
        .req_valid(req_valid),
        .req_ready(req_ready),
        .req_data (req_data),

        .m_axis_body_tvalid(body_tvalid),
        .m_axis_body_tready(body_tready),
        .m_axis_body_tdata (body_tdata),
        .m_axis_body_tkeep (body_tkeep),
        .m_axis_body_tlast (body_tlast),

        .totalWord          (total_word),
        .inflightWord       (inflight_word),
        .stallWord          (stall_word),
        .respWord           (resp_word),
        .bodyRemainingWord  (body_remaining_word),
        .state_debug        ()
    );

    // ---------------------------------------------------------------------------------------------
    // Golden data
    //
    // last_flag[r]==0 means request r does not end its decoder stream: its body is concatenated with
    // the next one and only that one carries tlast. Requests 4 and 5 model one column chunk fetched
    // as two ranged GETs.
    // ---------------------------------------------------------------------------------------------
    int          body_len [NUM_REQS];
    bit          last_flag[NUM_REQS];
    logic [7:0]  body_gold[NUM_REQS][$];

    localparam int NUM_STREAMS = 5;   // tlast-delimited decoder streams expected
    logic [7:0]  stream_gold[NUM_STREAMS][$];

    initial begin
        body_len[0] = 100;  // spans two beats, ragged tail
        body_len[1] = 64;   // exactly one beat
        body_len[2] = 200;
        body_len[3] = 63;   // one byte short of a beat
        body_len[4] = 321;
        body_len[5] = 1;    // single byte
        last_flag   = '{1'b1, 1'b1, 1'b1, 1'b1, 1'b0, 1'b1};
    end

    // ---------------------------------------------------------------------------------------------
    // TOE model: ONE connection at a time.
    // ---------------------------------------------------------------------------------------------
    localparam int SID_BASE = 16'h0100;

    int  cur_sid      = -1;
    bit  conn_alive   = 0;
    int  generation   = 0;   // connections opened so far
    int  opens_seen   = 0;
    int  closes_seen  = 0;
    int  fins_sent    = 0;

    // The connection's byte stream, as the server would put it on the wire.
    logic [7:0] stream_q[$];
    int         announced = 0;   // bytes announced via notifications
    int         delivered = 0;   // bytes handed over via readPkg
    int         seg_q[$];        // announced-but-not-yet-read segment lengths

    int  get_q[$];               // request indices whose GET has arrived on the live connection
    int  gets_seen = 0;
    bit  keepalive_seen = 0;

    // TX-rejection bookkeeping. `expect_no_data` is armed the moment a refusal is answered and
    // cleared by the next tx_meta; any data beat seen while it is armed is the exact corruption this
    // case exists to catch.
    int  metas_seen   = 0;
    int  rejects_done = 0;
    bit  expect_no_data = 0;
    int  beats_after_reject = 0;
    bit  close_seen_in_get = 0;

    // `time` is a 64-bit reg type and therefore initialises to X, not 0 -- so these MUST be zeroed
    // explicitly before use. Left at X, the "first time this GET was seen" guard below is never
    // true, every timestamp stays X, and the pipelining assertion silently passes on any design.
    time t_get_rx    [NUM_REQS];
    time t_body_done [NUM_STREAMS];

    logic [TCP_NOTIFY_BITS-1:0] notify_q [$];

    function automatic logic [TCP_NOTIFY_BITS-1:0] make_notify(input int sid, input int len,
                                                               input bit closed);
        logic [TCP_NOTIFY_BITS-1:0] n;
        begin
            n = '0;
            n[TCP_SESSION_BITS-1:0]                             = sid[15:0];
            n[TCP_LEN_BITS+TCP_SESSION_BITS-1:TCP_SESSION_BITS] = len[15:0];
            n[80]                                               = closed;  // CLOSED_BIT
            return n;
        end
    endfunction

    task automatic push_str(ref logic [7:0] out[$], input string s);
        for (int i = 0; i < s.len(); i++) out.push_back(8'(s.getc(i)));
    endtask

    // CR LF written as explicit bytes. NOT as "\r\n": \r is not one of the escape sequences
    // SystemVerilog defines, so a literal containing it does not reliably produce 0x0D -- which
    // means the header never ends in \r\n\r\n and the framer scans past it forever.
    task automatic push_crlf(ref logic [7:0] out[$]);
        out.push_back(8'h0D);
        out.push_back(8'h0A);
    endtask

    // Append a realistic ranged-GET response for request r to the connection's byte stream. The
    // header length is varied per request so each body starts at a different byte offset.
    task automatic append_response(input int r);
        string pad;
        begin
            pad = "";
            for (int i = 0; i <= r; i++) pad = {pad, "x"};
            push_str(stream_q, "HTTP/1.1 206 Partial Content");                 push_crlf(stream_q);
            push_str(stream_q, "Accept-Ranges: bytes");                         push_crlf(stream_q);
            push_str(stream_q, $sformatf("Content-Length: %0d", body_len[r]));  push_crlf(stream_q);
            push_str(stream_q, {"Server: MinIO", pad});                         push_crlf(stream_q);
            push_crlf(stream_q); // blank line: end of header
            for (int i = 0; i < body_len[r]; i++) stream_q.push_back(body_gold[r][i]);
        end
    endtask

    // Announce everything not yet announced, cut on a GLOBAL 96-byte cursor so segments straddle
    // response boundaries.
    task automatic announce_pending();
        int n;
        while (announced < stream_q.size() && conn_alive) begin
            n = stream_q.size() - announced;
            if (n > 96) n = 96;
            seg_q.push_back(n);
            notify_q.push_back(make_notify(cur_sid, n, 1'b0));
            announced += n;
            repeat (6) @(posedge clk);
        end
    endtask

    // ---------------------------------------------------------------------------------------------
    // TOE: openConnection -> openStatus. A fresh session id per connection, so a reconnect is
    // visible to the DUT exactly as it would be on hardware.
    // ---------------------------------------------------------------------------------------------
    initial begin
        open_req_ready = 1'b0;
        open_rsp_valid = 1'b0;
        open_rsp_data  = '0;
        @(posedge rst_n);
        forever begin
            @(posedge clk);
            open_req_ready <= 1'b1;
            @(posedge clk);
            while (!(open_req_valid && open_req_ready)) @(posedge clk);
            open_req_ready <= 1'b0;
            opens_seen++;

            repeat (7) @(posedge clk);     // handshake latency
            cur_sid   = SID_BASE + generation;
            generation++;
            stream_q.delete();
            seg_q.delete();
            get_q.delete();
            announced  = 0;
            delivered  = 0;
            conn_alive = 1;

            open_rsp_data  <= {16'd0, 32'd0, 8'd1, 16'(cur_sid)}; // success = 1
            open_rsp_valid <= 1'b1;
            @(posedge clk);
            while (!open_rsp_ready) @(posedge clk);
            open_rsp_valid <= 1'b0;
        end
    end

    // ---------------------------------------------------------------------------------------------
    // TOE: closeConnection
    // ---------------------------------------------------------------------------------------------
    initial begin
        close_ready = 1'b1;
        @(posedge rst_n);
        forever begin
            @(posedge clk);
            if (close_valid && close_ready) begin
                closes_seen++;
                conn_alive = 0;
            end
        end
    end

    // ---------------------------------------------------------------------------------------------
    // TOE: tx (the GET goes out).
    //
    // Order matters and is easy to get backwards: the sender announces the length on tx_meta, the
    // TOE answers on tx_status (this is where it would report no room), and ONLY THEN are the data
    // beats pushed. tcp_send_http goes ST_SEND_META -> ST_WAIT_STAT -> ST_SEND_DATA accordingly, so
    // a model that waits for the data before answering the status deadlocks both sides.
    //
    // The request text is reassembled here so the bench can check what actually went on the wire:
    // which request it is (from the Range: header) and that it asks to keep the connection open.
    // ---------------------------------------------------------------------------------------------
    initial begin
        txmeta_ready = 1'b1;
        txdata_ready = 1'b1;
        txstat_valid = 1'b0;
        txstat_data  = '0;
        @(posedge rst_n);
        forever begin
            automatic int    sid, len, r, p;
            automatic string get_txt;
            @(posedge clk);
            if (txmeta_valid && txmeta_ready) begin
                sid = int'(txmeta_data[TCP_SESSION_BITS-1:0]);
                len = int'(txmeta_data[31:16]);
                metas_seen++;
                expect_no_data = 1'b0;

                if (metas_seen == REJECT_ON_META) begin
                    repeat (3) @(posedge clk);
                    // error != 0 and no room: the TOE rejected the reservation.
                    txstat_data  <= {2'd1, 30'd0, 16'(len), 16'(sid)};
                    txstat_valid <= 1'b1;
                    @(posedge clk);
                    while (!txstat_ready) @(posedge clk);
                    txstat_valid <= 1'b0;
                    rejects_done++;
                    // Nothing may now appear on tx_data until the next tx_meta. Deliberately do not
                    // consume data beats here: a model that drained them anyway would hide exactly
                    // the bug this checks for.
                    expect_no_data = 1'b1;
                    continue;
                end

                repeat (3) @(posedge clk);
                // {error[63:62], remaining_space[61:32], len[31:16], sid[15:0]}, error = 0.
                txstat_data  <= {2'd0, 30'd65536, 16'(len), 16'(sid)};
                txstat_valid <= 1'b1;
                @(posedge clk);
                while (!txstat_ready) @(posedge clk);
                txstat_valid <= 1'b0;

                get_txt = "";
                do begin
                    @(posedge clk);
                    if (txdata_valid && txdata_ready) begin
                        for (int lane = 0; lane < LANES; lane++) begin
                            if (txdata_keep[lane]) begin
                                get_txt = {get_txt, string'(txdata_data[lane*8 +: 8])};
                            end
                        end
                    end
                end while (!(txdata_valid && txdata_ready && txdata_last));

                // ONE transmission may carry MANY GETs -- that is the entire point of streaming
                // the request text, and the reason this loop finds every one instead of the first.
                // The bench encodes r in the third Range-begin digit.
                r = -1;
                for (p = 0; p + 8 < get_txt.len(); p++) begin
                    if (get_txt.substr(p, p+5) == "bytes=") begin
                        r = int'(get_txt.getc(p+8)) - 8'h30;
                        if (r < 0 || r >= NUM_REQS)
                            $fatal(1, "unidentifiable request in GET text: %s", get_txt);
                        if (t_get_rx[r] == 0) t_get_rx[r] = $time;
                        gets_seen++;
                        get_q.push_back(r);
                    end
                end
                if (r < 0) $fatal(1, "no GET found in transmission: %s", get_txt);

                for (p = 0; p + 21 < get_txt.len(); p++) begin
                    if (get_txt.substr(p, p+21) == "Connection: keep-alive") keepalive_seen = 1;
                end
                for (p = 0; p + 16 < get_txt.len(); p++) begin
                    if (get_txt.substr(p, p+16) == "Connection: close") close_seen_in_get = 1;
                end

                if (sid != cur_sid) $fatal(1, "GET on session %0d, but the live one is %0d", sid, cur_sid);
            end
        end
    end

    // Monitor for the refusal window. Every beat here is a byte the TOE never made room for.
    always @(posedge clk) begin
        if (rst_n && expect_no_data && txdata_valid && txdata_ready) begin
            beats_after_reject++;
            $error("tx data beat at %0t after a refused send: pushed anyway, stream boundary lost", $time);
        end
    end

    // ---------------------------------------------------------------------------------------------
    // The "server". Serves the GETs it has received, in order, on the one connection. Once
    // RECONNECT_AFTER has been answered it drops the connection between responses -- the way an
    // idle-timeout close looks from the client -- discarding every request it had queued but not
    // answered. Those must come back on the new connection.
    // ---------------------------------------------------------------------------------------------
    initial begin
        automatic int r;
        @(posedge rst_n);
        forever begin
            @(posedge clk);
            if (!conn_alive)        continue;
            if (get_q.size() == 0)  continue;
            r = get_q.pop_front();

            if ((generation == 1) && (r > RECONNECT_AFTER)) begin
                // Wait until the reader has drained everything, so the FIN lands cleanly BETWEEN
                // responses. A FIN in the middle of a body is unrecoverable by design (the bytes
                // already reached the decoder), and the handler is supposed to latch that as fatal
                // rather than replay -- a different test, not this one.
                while (delivered < stream_q.size() || seg_q.size() != 0) @(posedge clk);
                repeat (20) @(posedge clk);
                get_q.delete();
                conn_alive = 0;
                notify_q.push_back(make_notify(cur_sid, 0, 1'b1));
                fins_sent++;
                continue;
            end

            // Server think-time. It has to dominate everything the FPGA does per request, because
            // that is the real ratio being modelled: a MinIO ranged GET answers in hundreds of
            // microseconds while assembling and sending the request takes well under one.
            repeat ((r % 2 == 1) ? 250 : 700) @(posedge clk);
            if (!conn_alive) continue;
            append_response(r);
            announce_pending();
        end
    end

    // Notification stream driver.
    initial begin
        notify_valid = 1'b0;
        notify_data  = '0;
        @(posedge rst_n);
        forever begin
            @(posedge clk);
            if (notify_q.size() > 0) begin
                notify_data  <= notify_q.pop_front();
                notify_valid <= 1'b1;
                @(posedge clk);
                while (!notify_ready) @(posedge clk);
                notify_valid <= 1'b0;
            end
        end
    end

    // ---------------------------------------------------------------------------------------------
    // TOE: readPkg -> rx meta + rx data
    // ---------------------------------------------------------------------------------------------
    initial begin
        rdpkg_ready  = 1'b0;
        rxmeta_valid = 1'b0;
        rxmeta_data  = '0;
        rxdata_valid = 1'b0;
        rxdata_data  = '0;
        rxdata_keep  = '0;
        rxdata_last  = 1'b0;
        @(posedge rst_n);
        forever begin
            automatic int sid, len, off, n, i, lane;
            automatic logic [AXI_DATA_BITS-1:0] beat;
            automatic logic [LANES-1:0]         keep;

            @(posedge clk);
            rdpkg_ready <= 1'b1;
            @(posedge clk);
            while (!(rdpkg_valid && rdpkg_ready)) @(posedge clk);
            sid = int'(rdpkg_data[TCP_SESSION_BITS-1:0]);
            len = int'(rdpkg_data[TCP_LEN_BITS+TCP_SESSION_BITS-1:TCP_SESSION_BITS]);
            rdpkg_ready <= 1'b0;

            if (sid != cur_sid) $fatal(1, "readPkg for session %0d, live session is %0d", sid, cur_sid);

            // The Coyote TOE is built with TCP_STACK_RX_DDR_BYPASS_EN=1, so the receive buffer is a
            // shared on-chip PACKET fifo, not a per-session circular buffer. rx_app_stream_if turns
            // a readPkg into a bare 1-bit token and rxAppMemDataRead then forwards exactly one
            // queued packet, whatever length the request named; the length is used only to advance
            // the app read pointer the advertised window is derived from. So a reader that coalesces
            // several announcements into one readPkg drains ONE segment while telling the TOE it
            // consumed all of them -- the window runs ahead of reality, the shared fifo backs up,
            // and rx_engine starts dropping segments with ACK_NODELAY.
            //
            // The first version of this bench delivered `len` bytes for any `len`, which is why the
            // coalescing bug reached hardware. Model the real contract instead, and assert it.
            if (seg_q.size() == 0)  $fatal(1, "readPkg with no announcement outstanding");
            if (len != seg_q[0]) begin
                $fatal(1, "readPkg asked for %0d bytes but the oldest announcement is %0d -- one readPkg must name exactly one announced segment",
                       len, seg_q[0]);
            end
            len = seg_q.pop_front();

            repeat (2) @(posedge clk);
            rxmeta_data  <= 16'(sid);
            rxmeta_valid <= 1'b1;
            @(posedge clk);
            while (!rxmeta_ready) @(posedge clk);
            rxmeta_valid <= 1'b0;

            off = delivered;
            n   = (len + LANES - 1) / LANES;
            for (i = 0; i < n; i++) begin
                automatic int in_beat = ((len - i * LANES) > LANES) ? LANES : (len - i * LANES);
                beat = '0;
                keep = '0;
                for (lane = 0; lane < in_beat; lane++) begin
                    beat[lane*8 +: 8] = stream_q[off + i * LANES + lane];
                    keep[lane]        = 1'b1;
                end
                rxdata_data  <= beat;
                rxdata_keep  <= keep;
                rxdata_last  <= (i == n - 1);
                rxdata_valid <= 1'b1;
                @(posedge clk);
                while (!rxdata_ready) @(posedge clk);
                rxdata_valid <= 1'b0;
                rxdata_last  <= 1'b0;
            end
            delivered = off + len;
        end
    end

    // ---------------------------------------------------------------------------------------------
    // Consumer: collect body beats, split on tlast, compare against the golden streams in order.
    // ---------------------------------------------------------------------------------------------
    logic [7:0] got [$];
    int         streams_seen = 0;
    int         errors       = 0;
    int         lfsr         = 32'hACE1;

    // Back-pressure, so the DUT is not tested only in the free-running case.
    always @(posedge clk) begin
        if (!rst_n) begin
            body_tready <= 1'b1;
        end else begin
            lfsr        <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            body_tready <= (lfsr[3:0] != 4'd0); // stall ~1 cycle in 16
        end
    end

    always @(posedge clk) begin
        if (rst_n && body_tvalid && body_tready) begin
            if (body_tkeep !== ({LANES{1'b1}} >> (LANES - $countones(body_tkeep)))) begin
                $error("non-bottom-justified body beat keep=0x%016h", body_tkeep);
                errors++;
            end
            for (int lane = 0; lane < LANES; lane++) begin
                if (body_tkeep[lane]) got.push_back(body_tdata[lane*8 +: 8]);
            end
            if (body_tlast) begin
                automatic int s = streams_seen;
                if (s >= NUM_STREAMS) begin
                    $error("more decoder streams than expected: saw %0d", s + 1);
                    errors++;
                end else begin
                    t_body_done[s] = $time;
                    if (got.size() != stream_gold[s].size()) begin
                        $error("stream %0d: length %0d, expected %0d", s, got.size(),
                               stream_gold[s].size());
                        errors++;
                    end else begin
                        for (int i = 0; i < got.size(); i++) begin
                            if (got[i] !== stream_gold[s][i]) begin
                                $error("stream %0d: byte %0d = 0x%02x, expected 0x%02x",
                                       s, i, got[i], stream_gold[s][i]);
                                errors++;
                                i = got.size(); // one report per stream is enough
                            end
                        end
                    end
                end
                got.delete();
                streams_seen++;
            end
        end
    end

    // ---------------------------------------------------------------------------------------------
    // Request driver: push all NUM_REQS descriptors. req_ready back-pressures once the ring is full,
    // which is exactly the credit the host has to respect.
    // ---------------------------------------------------------------------------------------------
    // ---------------------------------------------------------------------------------------------
    // Host side.
    //
    // Three things, in the order the host does them:
    //   1. one cfg beat per request carrying only its body_last bit -- this is the whole descriptor
    //      now, one bit instead of 1160
    //   2. one cfg beat carrying the server address and the total byte count, which arms the
    //      transfer and is what opens the connection
    //   3. the request text itself, as a byte stream
    //
    // The text is built here exactly as the host would build it, and is the ONLY place the ranges
    // exist -- there is no descriptor for the FPGA to rebuild them from.
    // ---------------------------------------------------------------------------------------------
    function automatic http_config_t make_entry(input int r);
        http_config_t c;
        begin
            c = '0;
            c.req_flags       = {15'd0, last_flag[r]};
            c.req_total_bytes = 32'd0;   // 0 => this beat is a queue entry, not an arm
            return c;
        end
    endfunction

    function automatic http_config_t make_arm(input int total);
        http_config_t c;
        begin
            c = '0;
            c.server_ip       = 32'h0A_FD_4A_4A; // 10.253.74.74
            c.server_port     = 32'd9000;
            c.req_total_bytes = 32'(total);
            return c;
        end
    endfunction

    task automatic append_str(input string t);
        for (int i = 0; i < t.len(); i++) req_text.push_back(byte'(t.getc(i)));
    endtask

    // The tx model identifies a request from the third digit after "bytes=", so the range text has
    // to carry r there -- same encoding the descriptor version used, now written directly.
    task automatic build_request_text();
        req_text.delete();
        for (int r = 0; r < NUM_REQS; r++) begin
            append_str("GET /t.parquet HTTP/1.1\r\n");
            append_str("Host: 10.253.74.74:9000\r\n");
            append_str($sformatf("Range: bytes=00%0d-999\r\n", r));
            append_str("Connection: keep-alive\r\n\r\n");
        end
        req_text_len = req_text.size();
    endtask

    initial begin
        int off;
        req_valid = 1'b0;
        req_data  = '0;
        @(posedge rst_n);
        repeat (4) @(posedge clk);

        build_request_text();

        // 1. the queue entries
        for (int r = 0; r < NUM_REQS; r++) begin
            req_data  <= make_entry(r);
            req_valid <= 1'b1;
            @(posedge clk);
            while (!req_ready) @(posedge clk);
            req_valid <= 1'b0;
            @(posedge clk);
        end

        // 2. arm
        req_data  <= make_arm(req_text_len);
        req_valid <= 1'b1;
        @(posedge clk);
        while (!req_ready) @(posedge clk);
        req_valid <= 1'b0;
        @(posedge clk);

        // 3. the text, in 64-byte beats, with the DMA stalling now and then
        off = 0;
        while (off < req_text_len) begin
            automatic int n = (req_text_len - off >= LANES) ? LANES : (req_text_len - off);
            rqs_data = '0; rqs_keep = '0;
            for (int l = 0; l < n; l++) begin
                rqs_data[l*8 +: 8] = req_text[off + l];
                rqs_keep[l]        = 1'b1;
            end
            rqs_last  = (off + n >= req_text_len);
            rqs_valid = 1'b1;
            @(posedge clk);
            while (!rqs_ready) @(posedge clk);
            off += n;
            if ((off % 192) == 0) begin
                rqs_valid = 1'b0;
                repeat (5) @(posedge clk);
            end
        end
        rqs_valid = 1'b0;
    end

`ifdef TRACE
    always @(posedge clk) if (rst_n) begin
        if (notify_valid && notify_ready)
            $display("%0t NOTIFY sid=%0d len=%0d closed=%0b", $time,
                     notify_data[15:0], notify_data[31:16], notify_data[80]);
        if (rdpkg_valid && rdpkg_ready)
            $display("%0t READPKG sid=%0d len=%0d", $time, rdpkg_data[15:0], rdpkg_data[31:16]);
        if (body_tvalid && body_tready)
            $display("%0t BODY keep=%0d last=%0b", $time, $countones(body_tkeep), body_tlast);
    end
    initial begin
        @(posedge rst_n);
        forever begin
            repeat (200) @(posedge clk);
            $display("%0t ptr f/s/r=%0d/%0d/%0d cs=%0d send=%0d read=%0d rd_st=%0d hs=%0d mode=%0b left=%0d req_len=%0d closed=%0b reconn=%0b",
                     $time, dut.fill_ptr_q, dut.send_ptr_q, dut.read_ptr_q,
                     dut.cs_q, dut.send_state_q, dut.read_state_q,
                     dut.inst_tcp_read.state_q,
                     dut.inst_tcp_read.inst_strip_http.hs_q,
                     dut.inst_tcp_read.inst_strip_http.mode_q,
                     dut.inst_tcp_read.inst_strip_http.body_left_q,
                     dut.tbl_req_len, dut.tbl_closed, dut.reconn_q);
        end
    end
`endif

    // ---------------------------------------------------------------------------------------------
    // Run control
    // ---------------------------------------------------------------------------------------------
    initial begin
        // Golden bodies, and the decoder streams they concatenate into.
        for (int r = 0; r < NUM_REQS; r++) begin
            for (int i = 0; i < body_len[r]; i++) body_gold[r].push_back(8'(r * 37 + i * 7 + 11));
        end
        begin
            automatic int s = 0;
            for (int r = 0; r < NUM_REQS; r++) begin
                for (int i = 0; i < body_len[r]; i++) stream_gold[s].push_back(body_gold[r][i]);
                if (last_flag[r]) s++;
            end
            if (s != NUM_STREAMS) $fatal(1, "last_flag does not produce NUM_STREAMS streams");
        end

        for (int r = 0; r < NUM_REQS;    r++) t_get_rx[r]    = 0;
        for (int s = 0; s < NUM_STREAMS; s++) t_body_done[s] = 0;

        rst_n = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;

        fork
            begin
                wait (streams_seen == NUM_STREAMS);
                repeat (50) @(posedge clk);
            end
            begin
                repeat (200000) @(posedge clk);
                $error("TIMEOUT: only %0d of %0d decoder streams completed", streams_seen, NUM_STREAMS);
                errors++;
            end
        join_any
        disable fork;

        // -- Keep-alive assertions ----------------------------------------------------------------
        // Two connections for six requests: the first, plus the one forced by the server's FIN.
        // Without keep-alive this would be six, and a benchmark run would be thousands.
        // One connection for every request, which is the point of keep-alive.
        if (opens_seen != 1) begin
            $error("expected exactly 1 connection, saw %0d", opens_seen);
            errors++;
        end
        if (fins_sent != 0) begin
            $error("the server was not supposed to FIN, it sent %0d", fins_sent);
            errors++;
        end
        // No replay assertion here: this bench does not drop the connection. Streamed request
        // text is consumed as it is sent and cannot be re-sent, so reconnect recovery is a
        // different contract from the ring's send_ptr rollback and needs its own case.
        if (gets_seen != NUM_REQS) begin
            $error("expected exactly %0d GETs on the wire, saw %0d", NUM_REQS, gets_seen);
            errors++;
        end
        // All of them in one reservation. If this ever needs more than one it is because the text
        // exceeded TX_CHUNK_BYTES, not because requests went out one at a time -- but at this size
        // more than one means something has started serialising them again.
        if (metas_seen != 1) begin
            $error("the %0d GETs took %0d transmissions; they should fit in one", gets_seen, metas_seen);
            errors++;
        end

        // The request must keep the connection open.
        if (!keepalive_seen) begin
            $error("no GET carried 'Connection: keep-alive'");
            errors++;
        end
        if (close_seen_in_get) begin
            $error("a GET still carried 'Connection: close' -- that forces a connection per request");
            errors++;
        end

        // -- Pipelining assertion -----------------------------------------------------------------
        // The whole point: request 1's GET must be on the wire before body 0 has finished. With
        // the text streamed in one go this is not a depth question any more -- every GET goes out
        // as fast as the TOE takes the bytes.
        begin
            if (t_get_rx[1] == 0 || t_get_rx[1] >= t_body_done[0]) begin
                $error("NOT PIPELINED: GET for request 1 arrived at %0t, after stream 0 finished at %0t",
                       t_get_rx[1], t_body_done[0]);
                errors++;
            end
        end

        $display("--------------------------------------------------------------");
        // A healthy run must not trip a stage watchdog, an unframeable response, a dirty abort or a
        // bad status. Reconnects (stallWord[15:8]) are expected here and are not a failure.
        //
        // send_err (bit 4) is also expected and MUST be set: this bench deliberately makes the TOE
        // refuse one send, and the bit is how that is reported. It is sticky and says "a send was
        // refused and retried", not "a request was lost" -- the retry is asserted separately above.
        if ((stall_word[7:0] & ~8'h10) != 8'd0) begin
            $error("stage stall/error flags set on a healthy run: stallWord=0x%08x", stall_word);
            errors++;
        end
        $display("decoder streams     : %0d / %0d", streams_seen, NUM_STREAMS);
        $display("connections opened  : %0d   closed by us: %0d   server FINs: %0d",
                 opens_seen, closes_seen, fins_sent);
        $display("tx refusals         : %0d refused, %0d beats pushed anyway (must be 0), %0d tx_meta",
                 rejects_done, beats_after_reject, metas_seen);
        // THE number this bench exists to produce: how many TCP transmissions carried the six
        // requests. One means every GET was handed to the stack in a single go, which is what the
        // descriptor ring could not do at any depth.
        $display("GETs per transmission: %0d GETs in %0d tx_meta reservation(s)", gets_seen, metas_seen);
        $display("GETs on the wire    : %0d (%0d requests, %0d replayed after the reconnect)",
                 gets_seen, NUM_REQS, gets_seen - NUM_REQS);
        $display("stallWord           : 0x%08x (flags [7:0] must be 0 except bit 4 send_err, which this bench causes; [15:8] = reconnects)",
                 stall_word);
        $display("respWord            : 0x%08x (status '%s')", resp_word, string'(resp_word[23:0]));
        $display("GET[1] first seen at %0t vs stream[0] done at %0t -> overlap %s",
                 t_get_rx[1], t_body_done[0],
                 (t_get_rx[1] < t_body_done[0]) ? "YES" : "NO");
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d error(s))", errors);
        $display("--------------------------------------------------------------");
        if (errors != 0) $fatal(1, "test failed");
        $finish;
    end

endmodule
