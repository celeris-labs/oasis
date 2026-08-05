`timescale 1ns / 1ps

import lynxTypes::*;
import http_types::*;

// =================================================================================================
// Testbench for the pipelined HTTP client handler.
//
// It models enough of the Coyote TOE to drive the whole request lifecycle -- openConnection /
// openStatus, tx meta+data, appNotification, readPkg, rx meta+data, closeConnection -- for SEVERAL
// CONCURRENT SESSIONS, which is the thing the old single-session model could not exercise.
//
// What it proves:
//   1. Every response body reaches m_axis_body byte-exact and IN REQUEST ORDER. Ordering is not a
//      nicety: the bodies are concatenated into one decoder stream, so a swap silently corrupts a
//      column.
//   2. Exactly one tlast per body. The downstream DataNormalizer resets its byte offset on tlast,
//      so a missing or extra one desynchronises everything after it.
//   3. The GET for request k+1 is on the wire BEFORE body k has finished streaming -- i.e. the
//      connection setup and the server's think time actually overlap the previous transfer. This is
//      the entire point of the change; without this assertion the test would pass just as happily
//      on the old sequential handler.
//   4. More than one TCP session is open at once.
//   5. A notification for session B that arrives while session A is being read is not lost. This is
//      the specific failure that made the old "filter notifications by session id" approach
//      unusable, and the model deliberately provokes it.
//
// Deliberate awkwardness in the model, all of it representative of a real server:
//   - response headers vary in length, so the body starts at a different lane each time and
//     strip_http's bottom-justify is exercised with several shift amounts;
//   - bodies are announced and delivered in several segments, so the body stream contains partial
//     beats in the middle (which is legal -- DataNormalizer repacks downstream);
//   - body lengths are mostly not multiples of 64, including a 1-byte body;
//   - the consumer applies back-pressure.
// =================================================================================================
module http_pipeline_tb #(
    // Overridable from xelab (-generic_top "NUM_SLOTS=1") so the same cases also cover the
    // pipelining-off fallback, where correctness must still hold but overlap obviously cannot.
    parameter int NUM_SLOTS = 4
);

    localparam int NUM_REQS   = 6;   // > NUM_SLOTS so the slot ring wraps
    localparam int LANES      = AXI_DATA_BITS / 8;
    localparam int MAX_RESP   = 4096;

    logic clk = 0;
    logic rst_n = 0;
    always #2 clk = ~clk;   // 250 MHz

    // ---------------------------------------------------------------------------------------------
    // DUT interface signals
    // ---------------------------------------------------------------------------------------------
    logic                             open_req_valid, open_req_ready;
    logic [TCP_OPEN_CONN_REQ_BITS-1:0]  open_req_data;
    logic                             open_rsp_valid, open_rsp_ready;
    logic [TCP_OPEN_CONN_RSP_BITS-1:0]  open_rsp_data;
    logic                             close_valid, close_ready;
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

    logic             body_tvalid, body_tready;
    logic [AXI_DATA_BITS-1:0] body_tdata;
    logic [LANES-1:0] body_tkeep;
    logic             body_tlast;

    logic [31:0] total_word, inflight_word, stall_word;

    // STALL_CYCLES shrunk so the watchdog is reachable in a simulation: the default is
    // ~1.07 s of hardware time. 20000 cycles is far longer than any healthy stage here
    // (the slowest is the 700-cycle server think-time) so a passing run must not trip it.
    handler #(.NUM_SLOTS(NUM_SLOTS), .STALL_CYCLES(20000)) dut (
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

        .req_valid(req_valid),
        .req_ready(req_ready),
        .req_data (req_data),

        .m_axis_body_tvalid(body_tvalid),
        .m_axis_body_tready(body_tready),
        .m_axis_body_tdata (body_tdata),
        .m_axis_body_tkeep (body_tkeep),
        .m_axis_body_tlast (body_tlast),

        .debug_rx_write_ptr (),
        .debug_rx_buffer_w0 (),
        .debug_rx_buffer_w1 (),
        .debug_tx_acc       (),
        .debug_tx_acc_cnt   (),
        .debug_tx_acc_last  (),
        .debug_http_len     (),
        .debug_builder_state(),
        .debug_req_lo       (),
        .debug_req_hi       (),
        .debug_req_cnt      (),
        .totalWord          (total_word),
        .inflightWord       (inflight_word),
        .stallWord          (stall_word),
        .state_debug        ()
    );

    // ---------------------------------------------------------------------------------------------
    // Golden data: per-request body length and contents.
    // ---------------------------------------------------------------------------------------------
    int          body_len [NUM_REQS];
    logic [7:0]  body_gold[NUM_REQS][$];

    initial begin
        body_len[0] = 100;  // spans two beats, ragged tail
        body_len[1] = 64;   // exactly one beat
        body_len[2] = 200;
        body_len[3] = 63;   // one byte short of a beat
        body_len[4] = 321;
        body_len[5] = 1;    // single byte
    end

    // ---------------------------------------------------------------------------------------------
    // TOE model state, indexed by session id offset (sid = SID_BASE + n)
    // ---------------------------------------------------------------------------------------------
    localparam int SID_BASE = 16'h0100;

    int          sess_req      [NUM_REQS];   // which request each session serves
    logic [7:0]  sess_resp     [NUM_REQS][$]; // full response bytes (header + body)
    int          sess_delivered[NUM_REQS];   // bytes handed over via readPkg
    int          seg_q         [NUM_REQS][$]; // announced-but-not-yet-read segment lengths
    int          sess_announced[NUM_REQS];   // bytes announced via notifications
    bit          sess_get_seen [NUM_REQS];   // the GET for this session has arrived
    bit          sess_open     [NUM_REQS];

    int next_sid_idx = 0;     // sessions allocated so far
    int open_sessions = 0;
    int max_open_sessions = 0;

    time t_get_rx    [NUM_REQS];
    time t_body_done [NUM_REQS];

    // Notification queue, shared by all sessions -- this is what serialises announcements from
    // different connections onto the single TOE notification stream.
    logic [TCP_NOTIFY_BITS-1:0] notify_q [$];

    function automatic logic [TCP_NOTIFY_BITS-1:0] make_notify(input int sid, input int len,
                                                               input bit closed);
        logic [TCP_NOTIFY_BITS-1:0] n;
        begin
            n = '0;
            n[TCP_SESSION_BITS-1:0]                                 = sid[15:0];
            n[TCP_LEN_BITS+TCP_SESSION_BITS-1:TCP_SESSION_BITS]     = len[15:0];
            n[80]                                                    = closed;  // CLOSED_BIT
            return n;
        end
    endfunction

    // Append the characters of `s` to session r's response.
    task automatic push_str(input int r, input string s);
        for (int i = 0; i < s.len(); i++) sess_resp[r].push_back(8'(s.getc(i)));
    endtask

    // CR LF written as explicit bytes. NOT as "\r\n": \r is not one of the escape sequences
    // SystemVerilog defines, so a literal containing it does not reliably produce 0x0D -- which
    // means the header never ends in \r\n\r\n and strip_http scans past it forever. Costs an hour
    // if you assume C string semantics here.
    task automatic push_crlf(input int r);
        sess_resp[r].push_back(8'h0D);
        sess_resp[r].push_back(8'h0A);
    endtask

    // Build a realistic ranged-GET response: header + body. The header length is deliberately
    // varied per request so the body starts at a different byte offset every time, exercising
    // strip_http's bottom-justify with several different shift amounts.
    task automatic build_response(input int r);
        string pad;
        int    i;
        begin
            body_gold[r].delete();
            for (i = 0; i < body_len[r]; i++) begin
                body_gold[r].push_back(8'(r * 37 + i * 7 + 11));
            end
            pad = "";
            for (i = 0; i <= r; i++) pad = {pad, "x"};

            sess_resp[r].delete();
            push_str(r, "HTTP/1.1 206 Partial Content");                     push_crlf(r);
            push_str(r, $sformatf("Content-Length: %0d", body_len[r]));      push_crlf(r);
            push_str(r, {"Server: ", pad});                                  push_crlf(r);
            push_str(r, "Connection: close");                                push_crlf(r);
            push_crlf(r); // blank line: end of header
            for (i = 0; i < body_len[r]; i++) begin
                sess_resp[r].push_back(body_gold[r][i]);
            end
        end
    endtask

    // ---------------------------------------------------------------------------------------------
    // TOE: openConnection -> openStatus
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

            begin
                automatic int idx = next_sid_idx;
                automatic int sid = SID_BASE + idx;
                next_sid_idx++;
                sess_req[idx]       = idx;
                sess_delivered[idx] = 0;
                sess_announced[idx] = 0;
                sess_get_seen[idx]  = 0;
                sess_open[idx]      = 1;
                open_sessions++;
                if (open_sessions > max_open_sessions) max_open_sessions = open_sessions;
                build_response(idx);

                repeat (7) @(posedge clk);     // handshake latency
                open_rsp_data  <= {16'd0, 32'd0, 8'd1, 16'(sid)}; // success = 1
                open_rsp_valid <= 1'b1;
                @(posedge clk);
                while (!open_rsp_ready) @(posedge clk);
                open_rsp_valid <= 1'b0;
            end
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
                automatic int idx = int'(close_data) - SID_BASE;
                if (idx >= 0 && idx < NUM_REQS) begin
                    if (sess_open[idx]) open_sessions--;
                    sess_open[idx] = 0;
                end
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
    // ---------------------------------------------------------------------------------------------
    initial begin
        txmeta_ready = 1'b1;
        txdata_ready = 1'b1;
        txstat_valid = 1'b0;
        txstat_data  = '0;
        @(posedge rst_n);
        forever begin
            automatic int sid;
            automatic int idx;
            automatic int len;
            @(posedge clk);
            if (txmeta_valid && txmeta_ready) begin
                sid = int'(txmeta_data[TCP_SESSION_BITS-1:0]);
                len = int'(txmeta_data[31:16]);
                idx = sid - SID_BASE;

                repeat (3) @(posedge clk);
                // {error[63:62], remaining_space[61:32], len[31:16], sid[15:0]}, error = 0.
                txstat_data  <= {2'd0, 30'd65536, 16'(len), 16'(sid)};
                txstat_valid <= 1'b1;
                @(posedge clk);
                while (!txstat_ready) @(posedge clk);
                txstat_valid <= 1'b0;

                // Now drain the request beats.
                do begin
                    @(posedge clk);
                end while (!(txdata_valid && txdata_ready && txdata_last));

                if (idx >= 0 && idx < NUM_REQS) begin
                    t_get_rx[idx]      = $time;
                    sess_get_seen[idx] = 1;
                end
            end
        end
    end

    // ---------------------------------------------------------------------------------------------
    // The "server": once a session's GET has arrived, wait, then announce the response in several
    // segments and finally announce the FIN. Runs independently per session, which is what makes a
    // notification for session B land while session A is being read.
    // ---------------------------------------------------------------------------------------------
    genvar g;
    generate
        for (g = 0; g < NUM_REQS; g++) begin : gen_server
            initial begin
                automatic int total;
                automatic int chunk;
                automatic int sent;
                @(posedge rst_n);
                wait (sess_get_seen[g] == 1);
                // Server think-time. It has to dominate everything the FPGA does per request,
                // because that is the real ratio being modelled: a MinIO ranged GET answers in
                // hundreds of microseconds while assembling and sending the request takes well
                // under one. (http_req_builder alone is ~90 cycles, so a think-time of a few dozen
                // cycles would make the test send-bound and prove nothing about latency hiding.)
                //
                // Odd-numbered requests answer much faster than even ones. That is deliberate: it
                // guarantees a notification for a later session lands while an earlier session is
                // still being read -- the exact case the old "filter notifications by session id"
                // reader dropped on the floor.
                repeat ((g % 2 == 1) ? 250 : 700) @(posedge clk);

                total = sess_resp[g].size();
                sent  = 0;
                // Announce in up to three segments so the reader loops and the concatenator has to
                // mask the per-readPkg tlast.
                while (sent < total) begin
                    chunk = (total - sent > 96) ? 96 : (total - sent);
                    sent += chunk;
                    // Record the segment as well as announcing it. The TOE hands back ONE announced
                    // segment per readPkg (see the readPkg model below), so the model needs the
                    // announcement boundaries, not just a byte total.
                    seg_q[g].push_back(chunk);
                    notify_q.push_back(make_notify(SID_BASE + g, chunk, 1'b0));
                    repeat (6) @(posedge clk);
                end
                // FIN, with no further data.
                notify_q.push_back(make_notify(SID_BASE + g, 0, 1'b1));
            end
        end
    endgenerate

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
            automatic int sid, idx, len, off, n, i, lane;
            automatic logic [AXI_DATA_BITS-1:0] beat;
            automatic logic [LANES-1:0]         keep;

            @(posedge clk);
            rdpkg_ready <= 1'b1;
            @(posedge clk);
            while (!(rdpkg_valid && rdpkg_ready)) @(posedge clk);
            sid = int'(rdpkg_data[TCP_SESSION_BITS-1:0]);
            len = int'(rdpkg_data[TCP_LEN_BITS+TCP_SESSION_BITS-1:TCP_SESSION_BITS]);
            rdpkg_ready <= 1'b0;
            idx = sid - SID_BASE;

            if (idx < 0 || idx >= NUM_REQS) begin
                $fatal(1, "readPkg for unknown session %0d", sid);
            end

            // The Coyote TOE is built with TCP_STACK_RX_DDR_BYPASS_EN=1, so the receive buffer is a
            // shared on-chip PACKET fifo, not a per-session circular buffer. rx_app_stream_if turns
            // a readPkg into a bare 1-bit token and rxAppMemDataRead then forwards exactly one
            // queued packet, whatever length the request named; the length is used only to advance
            // the app read pointer that the advertised window is derived from. So a reader that
            // coalesces several announcements into one readPkg drains ONE segment while telling the
            // TOE it consumed all of them -- the receive window runs ahead of reality, the shared
            // fifo backs up, and rx_engine starts dropping segments with ACK_NODELAY.
            //
            // The first version of this bench delivered `len` bytes for any `len`, which is why the
            // coalescing bug reached hardware. Model the real contract instead, and assert it.
            if (seg_q[idx].size() == 0) begin
                $fatal(1, "readPkg on session %0d with no announcement outstanding", sid);
            end
            if (len != seg_q[idx][0]) begin
                $fatal(1, "readPkg asked for %0d bytes but the oldest announcement on session %0d is %0d -- one readPkg must name exactly one announced segment",
                       len, sid, seg_q[idx][0]);
            end
            len = seg_q[idx].pop_front();
            if (sess_delivered[idx] + len > sess_resp[idx].size()) begin
                $fatal(1, "readPkg asked for %0d bytes at offset %0d but the response is only %0d",
                       len, sess_delivered[idx], sess_resp[idx].size());
            end

            repeat (2) @(posedge clk);
            rxmeta_data  <= 16'(sid);
            rxmeta_valid <= 1'b1;
            @(posedge clk);
            while (!rxmeta_ready) @(posedge clk);
            rxmeta_valid <= 1'b0;

            off = sess_delivered[idx];
            n   = (len + LANES - 1) / LANES;
            for (i = 0; i < n; i++) begin
                automatic int in_beat = ((len - i * LANES) > LANES) ? LANES : (len - i * LANES);
                beat = '0;
                keep = '0;
                for (lane = 0; lane < in_beat; lane++) begin
                    beat[lane*8 +: 8] = sess_resp[idx][off + i * LANES + lane];
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
            sess_delivered[idx] = off + len;
        end
    end

    // ---------------------------------------------------------------------------------------------
    // Consumer: collect body beats, split on tlast, compare against the golden bodies in order.
    // ---------------------------------------------------------------------------------------------
    logic [7:0] got [$];
    int         bodies_seen = 0;
    int         errors      = 0;
    int         lfsr        = 32'hACE1;

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
            for (int lane = 0; lane < LANES; lane++) begin
                if (body_tkeep[lane]) got.push_back(body_tdata[lane*8 +: 8]);
            end
            if (body_tlast) begin
                automatic int r = bodies_seen;
                t_body_done[r] = $time;
                if (r >= NUM_REQS) begin
                    $error("more bodies than requests: saw %0d", r + 1);
                    errors++;
                end else if (got.size() != body_len[r]) begin
                    $error("body %0d: length %0d, expected %0d", r, got.size(), body_len[r]);
                    errors++;
                end else begin
                    for (int i = 0; i < body_len[r]; i++) begin
                        if (got[i] !== body_gold[r][i]) begin
                            $error("body %0d: byte %0d = 0x%02x, expected 0x%02x",
                                   r, i, got[i], body_gold[r][i]);
                            errors++;
                            i = body_len[r]; // one report per body is enough
                        end
                    end
                end
                got.delete();
                bodies_seen++;
            end
        end
    end

    // ---------------------------------------------------------------------------------------------
    // Request driver: push all NUM_REQS descriptors. req_ready back-pressures once the ring is full,
    // which is exactly the credit the host has to respect.
    // ---------------------------------------------------------------------------------------------
    function automatic http_config_t make_req(input int r);
        http_config_t c;
        begin
            c = '0;
            c.server_ip   = 32'h0A_FD_4A_4A; // 10.253.74.74
            c.server_port = 32'd9000;
            c.port_hex    = 32'h30303039;    // "9000" little-endian
            c.ip_hex_len  = 8'd12;
            c.ip_hex_w0   = 32'h2E303122;
            c.file_len    = 32'd8;
            c.file_w0     = 32'h6D742F00;
            c.file_w1     = 32'h00007870;
            // Distinct ranges per request, so a swapped GET would be visible on the wire too.
            c.range_begin_len = 8'd3;
            c.range_begin_w0  = 32'h00303030 | (32'(r) << 16);
            c.range_end_len   = 8'd3;
            c.range_end_w0    = 32'h00393939;
            return c;
        end
    endfunction

    initial begin
        req_valid = 1'b0;
        req_data  = '0;
        @(posedge rst_n);
        repeat (4) @(posedge clk);
        for (int r = 0; r < NUM_REQS; r++) begin
            req_data  <= make_req(r);
            req_valid <= 1'b1;
            @(posedge clk);
            while (!req_ready) @(posedge clk);
            req_valid <= 1'b0;
            @(posedge clk);
        end
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
        if (rxdata_valid && rxdata_ready)
            $display("%0t RX keep=%0d last=%0b | sh_v=%0b sh_r=%0b hold=%0b scan=%0b bval=%0b dn=%0b",
                     $time, $countones(rxdata_keep), rxdata_last,
                     dut.inst_tcp_read.sh_s_tvalid, dut.inst_tcp_read.sh_s_tready,
                     dut.inst_tcp_read.hold_valid_q,
                     dut.inst_tcp_read.inst_strip_http.scan_q,
                     dut.inst_tcp_read.inst_strip_http.b_valid_q,
                     dut.inst_tcp_read.inst_strip_http.done_q);
    end
    initial begin
        @(posedge rst_n);
        forever begin
            repeat (100) @(posedge clk);
            $display("%0t ptr f/c/s/r=%0d/%0d/%0d/%0d st c/s/r=%0d/%0d/%0d rd_st=%0d pend0=%0d req_len=%0d closed=%0b",
                     $time, dut.fill_ptr_q, dut.conn_ptr_q, dut.send_ptr_q, dut.read_ptr_q,
                     dut.conn_state_q, dut.send_state_q, dut.read_state_q,
                     dut.inst_tcp_read.state_q, dut.inst_session_table.pending_q[0],
                     dut.tbl_req_len, dut.tbl_closed);
        end
    end
`endif

    // ---------------------------------------------------------------------------------------------
    // Run control
    // ---------------------------------------------------------------------------------------------
    initial begin
        rst_n = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;

        fork
            begin
                wait (bodies_seen == NUM_REQS);
                repeat (50) @(posedge clk);
            end
            begin
                repeat (60000) @(posedge clk);
                $error("TIMEOUT: only %0d of %0d bodies completed", bodies_seen, NUM_REQS);
                errors++;
            end
        join_any
        disable fork;

        // -- Pipelining assertions ----------------------------------------------------------------
        // Only meaningful with more than one slot. At NUM_SLOTS==1 the handler is deliberately
        // sequential and correctness (checked above) is the whole contract.
        if (NUM_SLOTS > 1) begin
            // (3) the GET for request k must be on the wire before body k-1 finished.
            for (int k = 1; k < NUM_REQS; k++) begin
                if (t_get_rx[k] >= t_body_done[k-1]) begin
                    $error("NOT PIPELINED: GET for request %0d arrived at %0t, after body %0d finished at %0t",
                           k, t_get_rx[k], k-1, t_body_done[k-1]);
                    errors++;
                end
            end

            // (4) more than one connection open at once.
            if (max_open_sessions < 2) begin
                $error("NOT PIPELINED: at most %0d session(s) were ever open at the same time",
                       max_open_sessions);
                errors++;
            end
        end else if (max_open_sessions != 1) begin
            $error("NUM_SLOTS=1 must never open more than one session at a time (saw %0d)",
                   max_open_sessions);
            errors++;
        end

        $display("--------------------------------------------------------------");
        // A healthy run must not trip any stage watchdog.
        if (stall_word[4:0] != 5'd0) begin
            $error("stage stall/error flags set on a healthy run: stallWord=0x%08x", stall_word);
            errors++;
        end
        $display("bodies checked      : %0d / %0d", bodies_seen, NUM_REQS);
        $display("stallWord           : 0x%08x (flags [4:0] must be 0; upper bytes are slot indices)", stall_word);
        $display("max open sessions   : %0d (NUM_SLOTS = %0d)", max_open_sessions, NUM_SLOTS);
        for (int k = 1; k < NUM_REQS; k++) begin
            $display("  GET[%0d] at %0t vs body[%0d] done at %0t -> overlap %0s",
                     k, t_get_rx[k], k-1, t_body_done[k-1],
                     (t_get_rx[k] < t_body_done[k-1]) ? "YES" : "NO");
        end
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d error(s))", errors);
        $display("--------------------------------------------------------------");
        $finish;
    end

endmodule
