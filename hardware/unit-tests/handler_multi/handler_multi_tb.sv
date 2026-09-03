`timescale 1ns / 1ps

import lynxTypes::*;
import http_types::*;

// =================================================================================================
// handler_multi -- N TCP sessions, one per decoder lane, end to end.
//
// The receive half is already covered by http_multilane_tb (rx_dispatch + N framers) and the grant
// logic by tx_arbiter_tb. What only this bench can check is the two halves together inside the real
// module, against a TOE model that fails the run if the shared transmit path is ever misused:
//
//   * four connections opened and bound, each to its own lane
//   * four lanes' request text transmitted with NO interleaving -- the failure the arbiter exists
//     to prevent is one lane's bytes landing inside another lane's reservation, which on the wire
//     is a spliced GET the server answers 400 and which misframes everything behind it
//   * four responses arriving interleaved on the shared receive stream, each framed onto its lane
// =================================================================================================
module handler_multi_tb;

    localparam int NUM_CONNS = 4;
    localparam int LANES     = AXI_DATA_BITS / 8;
    localparam int QUEUE_DEPTH = 8;
    localparam int RX_DEPTH  = 512;

    logic clk = 0, rst_n = 0;
    always #2 clk = ~clk;

    // -- connection management --------------------------------------------------------------------
    logic                              open_valid, open_ready;
    logic [TCP_OPEN_CONN_REQ_BITS-1:0] open_data;
    logic                              ostat_valid, ostat_ready;
    logic [TCP_OPEN_CONN_RSP_BITS-1:0] ostat_data;
    logic                              close_valid, close_ready;
    logic [TCP_CLOSE_CONN_REQ_BITS-1:0] close_data;

    // -- receive ----------------------------------------------------------------------------------
    logic                       notif_valid, notif_ready;
    logic [TCP_NOTIFY_BITS-1:0] notif_data;
    logic                           rdpkg_valid, rdpkg_ready;
    logic [TCP_RD_PKG_REQ_BITS-1:0] rdpkg_data;
    logic                        rxmeta_valid, rxmeta_ready;
    logic [TCP_RX_META_BITS-1:0] rxmeta_data;
    logic                       rxdata_valid, rxdata_ready;
    logic [AXI_DATA_BITS-1:0]   rxdata_data;
    logic [AXI_DATA_BITS/8-1:0] rxdata_keep;
    logic                       rxdata_last;

    // -- transmit ---------------------------------------------------------------------------------
    logic                        txmeta_valid, txmeta_ready;
    logic [TCP_TX_META_BITS-1:0] txmeta_data;
    logic                        txdata_valid, txdata_ready;
    logic [AXI_DATA_BITS-1:0]    txdata_data;
    logic [AXI_DATA_BITS/8-1:0]  txdata_keep;
    logic                        txdata_last;
    logic                        txstat_valid, txstat_ready;
    logic [TCP_TX_STAT_BITS-1:0] txstat_data;

    // -- config and host streams ------------------------------------------------------------------
    logic         req_valid;
    logic         req_ready;
    http_config_t req_data;

    logic [NUM_CONNS-1:0]       hreq_valid, hreq_ready, hreq_last;
    logic [AXI_DATA_BITS-1:0]   hreq_data [NUM_CONNS];
    logic [AXI_DATA_BITS/8-1:0] hreq_keep [NUM_CONNS];

    logic [NUM_CONNS-1:0]       body_valid, body_ready, body_last;
    logic [AXI_DATA_BITS-1:0]   body_data [NUM_CONNS];
    logic [AXI_DATA_BITS/8-1:0] body_keep [NUM_CONNS];

    logic [31:0] totalWord, inflightWord, queueDepthWord, stallWord;
    logic [31:0] respWord, contentLengthWord, bodyRemainingWord;
    logic [3:0]  state_debug;
    logic [63:0] laneOccWord, laneReadyWord, laneStateWord, laneErrWord, lanePolicyWord;

    // The per-lane readback map (CSR revision 2), as software will index it. Decoding it here rather
    // than writing bit numbers into the checks is the point: if the packing and the host's idea of it
    // ever diverge, they diverge in one place.
    localparam int LANE_STALL_CYCLES_EXP = 65536;   // handler_multi's default, not overridden below

    function automatic int unsigned lane_occ (input int L); return laneOccWord[8*L +: 8]; endfunction
    function automatic bit arm_ready  (input int L); return laneReadyWord[4*L + 0]; endfunction
    function automatic bit entry_ready(input int L); return laneReadyWord[4*L + 1]; endfunction
    function automatic bit lane_up    (input int L); return laneReadyWord[4*L + 2]; endfunction
    function automatic bit lane_fatal (input int L); return laneReadyWord[4*L + 3]; endfunction
    function automatic bit lane_dead  (input int L); return laneErrWord  [8*L + 0]; endfunction

    function automatic string occ_str();
        string s = "";
        for (int L = 0; L < 8; L++) s = {s, $sformatf("%0d ", lane_occ(L))};
        return s;
    endfunction

    handler_multi #(
        .NUM_CONNS    (NUM_CONNS),
        .QUEUE_DEPTH  (QUEUE_DEPTH),
        .RX_FIFO_DEPTH(RX_DEPTH),
        .STALL_CYCLES (1 << 20)
    ) dut (
        .ap_clk(clk), .ap_rst_n(rst_n),

        .m_axis_open_connection_TVALID(open_valid),
        .m_axis_open_connection_TREADY(open_ready),
        .m_axis_open_connection_TDATA (open_data),
        .s_axis_open_status_TVALID(ostat_valid),
        .s_axis_open_status_TREADY(ostat_ready),
        .s_axis_open_status_TDATA (ostat_data),
        .m_axis_close_connection_TVALID(close_valid),
        .m_axis_close_connection_TREADY(close_ready),
        .m_axis_close_connection_TDATA (close_data),

        .s_axis_notifications_TVALID(notif_valid),
        .s_axis_notifications_TREADY(notif_ready),
        .s_axis_notifications_TDATA (notif_data),
        .m_axis_read_package_TVALID(rdpkg_valid),
        .m_axis_read_package_TREADY(rdpkg_ready),
        .m_axis_read_package_TDATA (rdpkg_data),
        .s_axis_rx_metadata_TVALID(rxmeta_valid),
        .s_axis_rx_metadata_TREADY(rxmeta_ready),
        .s_axis_rx_metadata_TDATA (rxmeta_data),
        .s_axis_rx_data_TVALID(rxdata_valid),
        .s_axis_rx_data_TREADY(rxdata_ready),
        .s_axis_rx_data_TDATA (rxdata_data),
        .s_axis_rx_data_TKEEP (rxdata_keep),
        .s_axis_rx_data_TLAST (rxdata_last),

        .m_axis_tx_meta_TVALID(txmeta_valid),
        .m_axis_tx_meta_TREADY(txmeta_ready),
        .m_axis_tx_meta_TDATA (txmeta_data),
        .m_axis_tx_data_TVALID(txdata_valid),
        .m_axis_tx_data_TREADY(txdata_ready),
        .m_axis_tx_data_TDATA (txdata_data),
        .m_axis_tx_data_TKEEP (txdata_keep),
        .m_axis_tx_data_TLAST (txdata_last),
        .s_axis_tx_status_TVALID(txstat_valid),
        .s_axis_tx_status_TREADY(txstat_ready),
        .s_axis_tx_status_TDATA (txstat_data),

        .req_valid(req_valid), .req_ready(req_ready), .req_data(req_data),

        .s_axis_req_TVALID(hreq_valid), .s_axis_req_TREADY(hreq_ready),
        .s_axis_req_TDATA (hreq_data),  .s_axis_req_TKEEP (hreq_keep),
        .s_axis_req_TLAST (hreq_last),

        .m_axis_body_tvalid(body_valid), .m_axis_body_tready(body_ready),
        .m_axis_body_tdata (body_data),  .m_axis_body_tkeep (body_keep),
        .m_axis_body_tlast (body_last),

        .totalWord(totalWord), .inflightWord(inflightWord),
        .queueDepthWord(queueDepthWord), .stallWord(stallWord),
        .respWord(respWord), .contentLengthWord(contentLengthWord),
        .bodyRemainingWord(bodyRemainingWord), .state_debug(state_debug),

        .laneOccWord(laneOccWord), .laneReadyWord(laneReadyWord),
        .laneStateWord(laneStateWord), .laneErrWord(laneErrWord),
        .lanePolicyWord(lanePolicyWord)
    );

    assign body_ready = '1;

    int pass_cnt = 0, fail_cnt = 0;
    task automatic ok (input string n); $display("[PASS] %s", n); pass_cnt++; endtask
    task automatic bad(input string n); $display("[FAIL] %s", n); fail_cnt++; endtask

    // =============================================================================================
    // TOE model: connect
    // =============================================================================================
    int opens = 0;
    initial begin
        open_ready  = 1'b0;
        ostat_valid = 1'b0;
        ostat_data  = '0;
        @(posedge rst_n);
        forever begin
            @(posedge clk);
            open_ready <= 1'b1;
            @(posedge clk);
            while (!(open_valid && open_ready)) @(posedge clk);
            open_ready <= 1'b0;
            repeat (3) @(posedge clk);
            // {success, session_id} -- one fresh session per open, 200 upward.
            ostat_data  <= {1'b1, TCP_SESSION_BITS'(200 + opens)};
            ostat_valid <= 1'b1;
            opens++;
            @(posedge clk);
            while (!ostat_ready) @(posedge clk);
            ostat_valid <= 1'b0;
        end
    end
    assign close_ready = 1'b1;

    // =============================================================================================
    // TOE model: transmit.
    //
    // This is the arbitration check, and it is structural rather than an assertion at the end: a
    // reservation is opened by tx_meta and MUST be filled by exactly the bytes that follow it. If
    // two lanes ever overlap, the bytes attributed to a session will not match its request text and
    // the comparison at the end fails -- which is precisely what would happen on the wire.
    // =============================================================================================
    logic [7:0] tx_seen [int];   // session id -> bytes transmitted, concatenated
    int         tx_metas = 0;

    logic [7:0] tx_capture [int][$];

    initial begin
        txmeta_ready = 1'b0;
        txdata_ready = 1'b0;
        txstat_valid = 1'b0;
        txstat_data  = '0;
        @(posedge rst_n);
        forever begin
            automatic int sid, len, got, b;

            @(posedge clk);
            txmeta_ready <= 1'b1;
            @(posedge clk);
            while (!(txmeta_valid && txmeta_ready)) @(posedge clk);
            sid = int'(txmeta_data[TCP_SESSION_BITS-1:0]);
            len = int'(txmeta_data[TCP_SESSION_BITS +: 16]);
            txmeta_ready <= 1'b0;
            tx_metas++;

            // Grant the reservation.
            repeat (2) @(posedge clk);
            txstat_data  <= {TCP_ERROR_BITS'(0), 30'(1 << 20), TCP_SESSION_BITS'(sid)};
            txstat_valid <= 1'b1;
            @(posedge clk);
            while (!txstat_ready) @(posedge clk);
            txstat_valid <= 1'b0;

            // Collect exactly `len` bytes. Anything else means the reservation was misused.
            got = 0;
            txdata_ready <= 1'b1;
            while (got < len) begin
                @(posedge clk);
                if (txdata_valid && txdata_ready) begin
                    for (b = 0; b < LANES; b++) begin
                        if (txdata_keep[b] && got < len) begin
                            tx_capture[sid].push_back(txdata_data[b*8 +: 8]);
                            got++;
                        end
                    end
                end
            end
            txdata_ready <= 1'b0;
        end
    end

    // =============================================================================================
    // TOE model: receive. One byte stream per session, one globally ordered packet queue.
    // =============================================================================================
    logic [7:0] sess_bytes [NUM_CONNS][$];
    int         sess_off   [NUM_CONNS];
    int         pkt_conn_q [$];
    int         pkt_len_q  [$];
    int         readpkgs = 0;

    task automatic push_str(input int c, input string s);
        for (int i = 0; i < s.len(); i++) sess_bytes[c].push_back(8'(s.getc(i)));
    endtask
    task automatic push_crlf(input int c);
        sess_bytes[c].push_back(8'h0D); sess_bytes[c].push_back(8'h0A);
    endtask
    task automatic append_response(input int c, input int body_len, input byte unsigned base);
        push_str(c, "HTTP/1.1 206 Partial Content");             push_crlf(c);
        push_str(c, $sformatf("Content-Length: %0d", body_len)); push_crlf(c);
        push_str(c, "Server: MinIO");                            push_crlf(c);
        push_crlf(c);
        for (int i = 0; i < body_len; i++) sess_bytes[c].push_back(base + i[7:0]);
    endtask

    // A FIN for session c: length 0, closed=1. That is what MinIO's idle timeout looks like.
    task automatic announce_fin(input int c);
        notif_data  <= {6'd0, 1'b0, 1'b1, 16'd9000, 32'h0A00_0001,
                        TCP_LEN_BITS'(0), TCP_SESSION_BITS'(200 + c)};
        notif_valid <= 1'b1;
        @(posedge clk);
        while (!notif_ready) @(posedge clk);
        notif_valid <= 1'b0;
        @(posedge clk);
    endtask

    task automatic announce(input int c, input int n);
        pkt_conn_q.push_back(c);
        pkt_len_q.push_back(n);
        notif_data  <= {6'd0, 1'b0, 1'b0, 16'd9000, 32'h0A00_0001,
                        TCP_LEN_BITS'(n), TCP_SESSION_BITS'(200 + c)};
        notif_valid <= 1'b1;
        @(posedge clk);
        while (!notif_ready) @(posedge clk);
        notif_valid <= 1'b0;
        @(posedge clk);
    endtask

    initial begin
        rdpkg_ready  = 1'b0;
        rxmeta_valid = 1'b0; rxmeta_data = '0;
        rxdata_valid = 1'b0; rxdata_data = '0; rxdata_keep = '0; rxdata_last = 1'b0;
        @(posedge rst_n);
        forever begin
            automatic int c, len, off, n, i, b;
            automatic logic [AXI_DATA_BITS-1:0] beat;
            automatic logic [LANES-1:0]         keep;

            @(posedge clk);
            rdpkg_ready <= 1'b1;
            @(posedge clk);
            while (!(rdpkg_valid && rdpkg_ready)) @(posedge clk);
            rdpkg_ready <= 1'b0;
            readpkgs++;

            if (pkt_conn_q.size() == 0) $fatal(1, "readPkg with no packet outstanding");
            c   = pkt_conn_q.pop_front();
            len = pkt_len_q.pop_front();
            if (int'(rdpkg_data[TCP_SESSION_BITS-1:0]) != 200 + c)
                $fatal(1, "readPkg named session %0d but the fifo head is session %0d",
                       int'(rdpkg_data[TCP_SESSION_BITS-1:0]), 200 + c);

            repeat (2) @(posedge clk);
            rxmeta_data  <= TCP_RX_META_BITS'(200 + c);
            rxmeta_valid <= 1'b1;
            @(posedge clk);
            while (!rxmeta_ready) @(posedge clk);
            rxmeta_valid <= 1'b0;

            off = sess_off[c];
            n   = (len + LANES - 1) / LANES;
            for (i = 0; i < n; i++) begin
                automatic int in_beat = ((len - i*LANES) > LANES) ? LANES : (len - i*LANES);
                beat = '0; keep = '0;
                for (b = 0; b < in_beat; b++) begin
                    beat[b*8 +: 8] = sess_bytes[c][off + i*LANES + b];
                    keep[b]        = 1'b1;
                end
                rxdata_data  <= beat; rxdata_keep <= keep; rxdata_last <= (i == n-1);
                rxdata_valid <= 1'b1;
                @(posedge clk);
                while (!rxdata_ready) @(posedge clk);
                rxdata_valid <= 1'b0; rxdata_last <= 1'b0;
            end
            sess_off[c] = off + len;
        end
    end

    // =============================================================================================
    // Body capture
    // =============================================================================================
    logic [7:0] got    [NUM_CONNS][$];
    int         tlasts [NUM_CONNS];
    always @(negedge clk) begin
        if (rst_n) begin
            for (int L = 0; L < NUM_CONNS; L++) begin
                if (body_valid[L] && body_ready[L]) begin
                    for (int b = 0; b < LANES; b++)
                        if (body_keep[L][b]) got[L].push_back(body_data[L][b*8 +: 8]);
                    if (body_last[L]) tlasts[L]++;
                end
            end
        end
    end

    // =============================================================================================
    // Host driver
    // =============================================================================================
    string req_text [NUM_CONNS];

    task automatic cfg_beat(input http_config_t c);
        req_data  <= c;
        req_valid <= 1'b1;
        @(posedge clk);
        while (!req_ready) @(posedge clk);
        req_valid <= 1'b0;
        @(posedge clk);
    endtask

    // One chunk-length entry for lane L.
    task automatic push_entry(input int L, input int nbytes);
        automatic http_config_t c = '0;
        c.req_total_bytes = 32'd0;
        c.req_chunk_bytes = 32'(nbytes);
        c.req_chunk_dest  = 4'(L);
        cfg_beat(c);
    endtask

    // Arm lane L's request-text transfer.
    task automatic push_arm(input int L, input int nbytes);
        automatic http_config_t c = '0;
        c.server_ip       = 32'h0A00_0001;
        c.server_port     = 32'd9000;
        c.req_total_bytes = 32'(nbytes);
        c.req_chunk_dest  = 4'(L);
        cfg_beat(c);
    endtask

    // DMA lane L's request text in, padded to whole beats the way the host does.
    task automatic dma_text(input int L, input string s);
        automatic int nbeats = (s.len() + LANES - 1) / LANES;
        for (int i = 0; i < nbeats; i++) begin
            automatic logic [AXI_DATA_BITS-1:0] beat = '0;
            automatic logic [LANES-1:0]         keep = '0;
            for (int b = 0; b < LANES; b++) begin
                automatic int idx = i*LANES + b;
                if (idx < s.len()) begin
                    beat[b*8 +: 8] = 8'(s.getc(idx));
                    keep[b]        = 1'b1;
                end
            end
            hreq_data[L] <= beat;
            hreq_keep[L] <= keep;
            hreq_last[L] <= (i == nbeats-1);
            hreq_valid[L] <= 1'b1;
            @(posedge clk);
            while (!hreq_ready[L]) @(posedge clk);
            hreq_valid[L] <= 1'b0;
            hreq_last[L]  <= 1'b0;
        end
    endtask

    task automatic reset_all();
        req_valid = 0; req_data = '0;
        hreq_valid = '0; hreq_last = '0;
        notif_valid = 0; notif_data = '0;
        opens = 0; readpkgs = 0; tx_metas = 0;
        rst_n = 0;
        for (int L = 0; L < NUM_CONNS; L++) begin
            sess_bytes[L].delete(); got[L].delete();
            sess_off[L] = 0; tlasts[L] = 0;
            hreq_data[L] = '0; hreq_keep[L] = '0;
        end
        pkt_conn_q.delete(); pkt_len_q.delete();
        tx_capture.delete();
        repeat (6) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);
    endtask

    // =============================================================================================
    initial begin
        automatic int body_len = 160;
        automatic bit good;

        $display("--- four_lane_query ---");
        reset_all();

        for (int L = 0; L < NUM_CONNS; L++) begin
            req_text[L] = $sformatf(
                "GET /bucket/col%0d.parquet HTTP/1.1\r\nHost: 10.0.0.1:9000\r\nRange: bytes=%0d-%0d\r\nConnection: keep-alive\r\n\r\n",
                L, L*1000, L*1000 + body_len - 1);
            append_response(L, body_len, byte'(8'h10 * (L+1)));
        end

        // Chunk-length entry then arm, per lane -- the single-lane protocol, with a lane on each
        // beat. req_ready is polled inside cfg_beat, which is the part that cannot be skipped.
        for (int L = 0; L < NUM_CONNS; L++) begin
            push_entry(L, body_len);
            push_arm  (L, req_text[L].len());
        end

        // Every lane's text at once; the arbiter decides the order on the wire.
        fork
            dma_text(0, req_text[0]);
            dma_text(1, req_text[1]);
            dma_text(2, req_text[2]);
            dma_text(3, req_text[3]);
        join

        // Wait for bring-up: four opens, four distinct sessions bound.
        begin
            automatic int t = 0;
            while (opens < NUM_CONNS && t < 20000) begin @(posedge clk); t++; end
        end
        if (opens == NUM_CONNS) ok("bringup/four_connections_opened");
        else bad($sformatf("bringup/four_connections_opened (%0d opened)", opens));

        // Let transmit finish before the server answers.
        repeat (8000) @(posedge clk);

        // -- the arbitration check ---------------------------------------------------------------
        good = 1;
        for (int L = 0; L < NUM_CONNS; L++) begin
            automatic int sid = 200 + L;
            if (!tx_capture.exists(sid)) begin
                $display("        session %0d transmitted nothing", sid);
                good = 0;
            end else if (tx_capture[sid].size() < req_text[L].len()) begin
                $display("        session %0d sent %0d bytes, expected %0d",
                         sid, tx_capture[sid].size(), req_text[L].len());
                good = 0;
            end else begin
                for (int i = 0; i < req_text[L].len(); i++) begin
                    if (tx_capture[sid][i] !== 8'(req_text[L].getc(i))) begin
                        $display("        session %0d byte %0d: got %02h expected %02h -- a lane's bytes landed in another lane's reservation",
                                 sid, i, tx_capture[sid][i], 8'(req_text[L].getc(i)));
                        good = 0;
                        break;
                    end
                end
            end
        end
        if (good) ok("tx/no_interleaving (each session's GET text arrived intact and contiguous)");
        else bad("tx/no_interleaving");

        // -- responses, interleaved across sessions -----------------------------------------------
        for (int round = 0; round < 3; round++) begin
            for (int L = 0; L < NUM_CONNS; L++) begin
                automatic int total = sess_bytes[L].size();
                automatic int chunk = (total + 2) / 3;
                automatic int base  = round * chunk;
                automatic int n     = (base + chunk > total) ? (total - base) : chunk;
                if (n > 0) announce(L, n);
            end
        end

        begin
            automatic int t = 0;
            automatic bit all_done;
            forever begin
                all_done = 1;
                for (int L = 0; L < NUM_CONNS; L++) if (tlasts[L] < 1) all_done = 0;
                if (all_done || t > 200000) break;
                @(posedge clk); t++;
            end
        end

        for (int L = 0; L < NUM_CONNS; L++) begin
            automatic bit lane_ok = 1;
            if (got[L].size() != body_len) begin
                $display("        lane %0d: %0d body bytes, expected %0d",
                         L, got[L].size(), body_len);
                lane_ok = 0;
            end else begin
                for (int i = 0; i < body_len; i++) begin
                    if (got[L][i] !== (byte'(8'h10 * (L+1)) + i[7:0])) begin
                        $display("        lane %0d byte %0d: got %02h expected %02h",
                                 L, i, got[L][i], byte'(8'h10 * (L+1)) + i[7:0]);
                        lane_ok = 0;
                        break;
                    end
                end
            end
            if (lane_ok) ok($sformatf("rx/lane%0d_body", L));
            else         bad($sformatf("rx/lane%0d_body", L));
        end

        // -- readback sanity ----------------------------------------------------------------------
        if (inflightWord[18]) ok("readback/all_connections_up");
        else bad("readback/all_connections_up");

        // The lane count the host sizes its batches from. A concat that does not add up to 32 bits
        // silently shifts every field below it, so check the value, not just that the bit moved.
        if (inflightWord[23:20] == 4'(NUM_CONNS))
            ok($sformatf("readback/lane_count (%0d)", inflightWord[23:20]));
        else
            bad($sformatf("readback/lane_count (read %0d, expected %0d)",
                          inflightWord[23:20], NUM_CONNS));

        if (stallWord[19:0] == '0) ok("readback/no_stall_bits");
        else bad($sformatf("readback/no_stall_bits (stallWord=%08h)", stallWord));

        // =========================================================================================
        // TWO responses per lane, on every lane, with NO drain in between.
        //
        // Everything above arms exactly one chunk and one response per lane, which is why it never
        // saw the bug this case exists for. tcp_read serves ONE response per activation and leaves
        // ST_DONE only when `start` FALLS; a handler that drives `start` from a level which stays
        // high while any chunk is queued frames the first response on each lane and then parks
        // forever, with the wire still delivering. One response per lane cannot distinguish that
        // from a working design.
        //
        // The announcements deliberately do NOT align with the response boundaries: three packets
        // carry two responses, so the seam between them falls INSIDE a packet. That is the second
        // half of the same bug -- beats routed to a lane which is between activations are accepted
        // off the shared bus by rx_dispatch (unconditionally, by design) and must not be dropped on
        // the way into the lane. A design that only re-arms turns the hang into corruption here.
        // =========================================================================================
        $display("--- two_responses_per_lane ---");
        begin
            automatic int    body2 = 208;
            automatic int    got_before   [NUM_CONNS];
            automatic int    tlast_before [NUM_CONNS];
            automatic int    new_bytes    [NUM_CONNS];
            automatic string txt2         [NUM_CONNS];
            automatic int    t = 0;
            automatic bit    all_done;

            for (int L = 0; L < NUM_CONNS; L++) begin
                automatic int before_sz = sess_bytes[L].size();
                got_before[L]   = got[L].size();
                tlast_before[L] = tlasts[L];
                // One arm carries BOTH GETs, the way the host DMAs a batch's request text.
                txt2[L] = $sformatf(
                    "GET /bucket/col%0d.parquet HTTP/1.1\r\nHost: 10.0.0.1:9000\r\nRange: bytes=%0d-%0d\r\nConnection: keep-alive\r\n\r\nGET /bucket/col%0d.parquet HTTP/1.1\r\nHost: 10.0.0.1:9000\r\nRange: bytes=%0d-%0d\r\nConnection: keep-alive\r\n\r\n",
                    L, 20000 + L*1000, 20000 + L*1000 + body2 - 1,
                    L, 30000 + L*1000, 30000 + L*1000 + body2 - 1);
                // Distinct bases per response AND per lane: a body served to the wrong lane, or the
                // two responses merged into one, changes the bytes rather than only their count.
                append_response(L, body2, byte'(8'h40 + L));
                append_response(L, body2, byte'(8'h80 + L));
                new_bytes[L] = sess_bytes[L].size() - before_sz;
            end

            // Both chunk-length entries, then the arm -- and the arm does not rewrite
            // req_chunk_bytes, so the register still holds the last entry's value, as on the host.
            for (int L = 0; L < NUM_CONNS; L++) begin
                push_entry(L, body2);
                push_entry(L, body2);
                push_arm  (L, txt2[L].len());
            end
            fork
                dma_text(0, txt2[0]);
                dma_text(1, txt2[1]);
                dma_text(2, txt2[2]);
                dma_text(3, txt2[3]);
            join
            repeat (8000) @(posedge clk);

            // Three packets per lane across two responses, interleaved over the lanes.
            for (int round = 0; round < 3; round++) begin
                for (int L = 0; L < NUM_CONNS; L++) begin
                    automatic int chunk = (new_bytes[L] + 2) / 3;
                    automatic int base  = round * chunk;
                    automatic int n     = (base + chunk > new_bytes[L])
                                          ? (new_bytes[L] - base) : chunk;
                    if (n > 0) announce(L, n);
                end
            end

            forever begin
                all_done = 1;
                for (int L = 0; L < NUM_CONNS; L++)
                    if (tlasts[L] < tlast_before[L] + 2) all_done = 0;
                if (all_done || t > 400000) break;
                @(posedge clk); t++;
            end

            for (int L = 0; L < NUM_CONNS; L++) begin
                automatic bit lane_ok = 1;
                automatic int n_new   = got[L].size() - got_before[L];
                if (tlasts[L] - tlast_before[L] != 2) begin
                    $display("        lane %0d: %0d tlast pulses, expected 2 (one per response)",
                             L, tlasts[L] - tlast_before[L]);
                    lane_ok = 0;
                end
                if (n_new != 2*body2) begin
                    $display("        lane %0d: %0d new body bytes, expected %0d",
                             L, n_new, 2*body2);
                    lane_ok = 0;
                end else begin
                    for (int i = 0; i < 2*body2; i++) begin
                        automatic int             off  = (i < body2) ? i : (i - body2);
                        automatic byte unsigned   want = (i < body2)
                            ? (byte'(8'h40 + L) + off[7:0])
                            : (byte'(8'h80 + L) + off[7:0]);
                        if (got[L][got_before[L] + i] !== want) begin
                            $display("        lane %0d response %0d byte %0d: got %02h expected %02h",
                                     L, (i < body2) ? 1 : 2, off,
                                     got[L][got_before[L] + i], want);
                            lane_ok = 0;
                            break;
                        end
                    end
                end
                if (lane_ok) ok($sformatf("pipelined/lane%0d_two_bodies", L));
                else         bad($sformatf("pipelined/lane%0d_two_bodies", L));
            end

            // The sticky bits that say the receive path misbehaved even though the bytes came out
            // right: [28] a lane refused a routed beat (it was dropped), [27] body bytes arrived
            // with no chunk length configured, [25] the per-lane fifo back-pressured the TCP stack,
            // [7] a response was retired with a status read as neither 200 nor 206.
            if (!stallWord[28] && !stallWord[27] && !stallWord[25] && !stallWord[7])
                ok("pipelined/no_sticky_stalls");
            else
                bad($sformatf("pipelined/no_sticky_stalls (stallWord=%08h)", stallWord));
        end

        // =========================================================================================
        // UNEQUAL LOAD ACROSS THE LANES, and the per-lane readback that has to track it.
        //
        // Every readback check above reads a word that ORs the lanes together. Those cannot tell
        // "lane 0 owes eight responses and lane 2 owes one" from "some lane owes something" -- and
        // the second is not an answer to the question the host actually asks, which is per lane and
        // asked before every single config beat: may I push another entry on THIS lane, may I arm
        // it. CSR revision 2 answers that; this case is what says the answer is true.
        //
        // The load is deliberately lopsided, and lane 0 is filled to QUEUE_DEPTH *exactly*. Filling
        // one lane is what makes the check sharp: ENTRY_READY must go LOW on lane 0 while staying
        // HIGH on its neighbours, which is a distinction a design that folded the lanes together --
        // or that indexed one nibble along -- cannot produce. Lanes 1 and 3 stay empty throughout,
        // so a packing that leaked a busy lane's count into a quiet lane's slot shows up as a
        // non-zero count on a lane that was never used.
        // =========================================================================================
        $display("--- per_lane_readback_unequal_load ---");
        begin
            automatic int    body3   = 96;
            automatic int    n_lane0 = QUEUE_DEPTH;   // exactly fills lane 0's chunk queue
            automatic int    r_len [16];              // byte length of each of lane 0's responses
            automatic int    r2_len  = 0;
            automatic int    tl0     = tlasts[0];
            automatic int    tl2     = tlasts[2];
            automatic int    got0_before = got[0].size();
            automatic int    got2_before = got[2].size();
            automatic string txt0    = "";
            automatic string txt2;
            automatic bit    good3;
            automatic int    t  = 0;
            automatic int    sz = 0;

            // Responses waiting on the wire: n_lane0 on lane 0, one on lane 2, none on 1 and 3.
            // A distinct base byte per response, so a body served to the wrong lane or in the wrong
            // order changes the bytes and not only their count.
            for (int r = 0; r < n_lane0; r++) begin
                sz = sess_bytes[0].size();
                append_response(0, body3, byte'(8'hA0 + r));
                r_len[r] = sess_bytes[0].size() - sz;
            end
            sz = sess_bytes[2].size();
            append_response(2, body3, 8'h5A);
            r2_len = sess_bytes[2].size() - sz;

            for (int r = 0; r < n_lane0; r++)
                txt0 = {txt0, $sformatf(
                    "GET /bucket/u0_%0d.parquet HTTP/1.1\r\nHost: 10.0.0.1:9000\r\nRange: bytes=%0d-%0d\r\nConnection: keep-alive\r\n\r\n",
                    r, 50000 + r*1000, 50000 + r*1000 + body3 - 1)};
            txt2 = $sformatf(
                "GET /bucket/u2.parquet HTTP/1.1\r\nHost: 10.0.0.1:9000\r\nRange: bytes=0-%0d\r\nConnection: keep-alive\r\n\r\n",
                body3 - 1);

            // -- BEFORE: the entries are queued, nothing is armed, nothing is on the wire ---------
            for (int r = 0; r < n_lane0; r++) push_entry(0, body3);
            push_entry(2, body3);
            repeat (4) @(posedge clk);

            good3 = 1;
            if (lane_occ(0) != n_lane0) begin
                $display("        lane 0 occupancy reads %0d, expected %0d", lane_occ(0), n_lane0);
                good3 = 0;
            end
            if (lane_occ(2) != 1) begin
                $display("        lane 2 occupancy reads %0d, expected 1", lane_occ(2));
                good3 = 0;
            end
            // Lanes 1 and 3 were never touched; 4..7 do not exist on a 4-lane bitstream and must
            // read as absent rather than as an alias of a lane that does.
            for (int L = 0; L < 8; L++) begin
                if (L != 0 && L != 2 && lane_occ(L) != 0) begin
                    $display("        lane %0d occupancy reads %0d, expected 0 (unused lane)",
                             L, lane_occ(L));
                    good3 = 0;
                end
            end
            if (good3) ok($sformatf("readback/occupancy_before_drain (%s)", occ_str()));
            else       bad($sformatf("readback/occupancy_before_drain (occ = %s)", occ_str()));

            good3 = 1;
            if (entry_ready(0)) begin
                $display("        lane 0 holds %0d of QUEUE_DEPTH=%0d entries but still reads ENTRY_READY",
                         lane_occ(0), QUEUE_DEPTH);
                good3 = 0;
            end
            for (int L = 1; L < NUM_CONNS; L++) begin
                if (!entry_ready(L)) begin
                    $display("        lane %0d reads ENTRY_READY low with %0d entries queued -- a full lane blocked an empty one",
                             L, lane_occ(L));
                    good3 = 0;
                end
            end
            for (int L = 0; L < NUM_CONNS; L++) begin
                if (!arm_ready(L)) begin
                    $display("        lane %0d reads ARM_READY low with nothing armed", L);
                    good3 = 0;
                end
                if (!lane_up(L)) begin
                    $display("        lane %0d reads CONN_UP low", L);
                    good3 = 0;
                end
                if (lane_fatal(L)) begin
                    $display("        lane %0d reads FATAL on a healthy run", L);
                    good3 = 0;
                end
            end
            if (good3) ok("readback/admission_bits_before_drain (the full lane refuses entries, the empty ones do not)");
            else       bad($sformatf("readback/admission_bits_before_drain (laneReady=0x%016h)",
                                     laneReadyWord));

            // -- arm both loaded lanes and let the request text go out ---------------------------
            push_arm(0, txt0.len());
            push_arm(2, txt2.len());
            fork
                dma_text(0, txt0);
                dma_text(2, txt2);
            join
            repeat (8000) @(posedge clk);

            // -- DURING: retire three of lane 0's eight responses ---------------------------------
            for (int r = 0; r < 3; r++) announce(0, r_len[r]);
            t = 0;
            while (tlasts[0] < tl0 + 3 && t < 200000) begin @(posedge clk); t++; end
            repeat (8) @(posedge clk);

            good3 = 1;
            if (tlasts[0] != tl0 + 3) begin
                $display("        lane 0 framed %0d of 3 responses before the mid-drain sample",
                         tlasts[0] - tl0);
                good3 = 0;
            end
            if (lane_occ(0) != n_lane0 - 3) begin
                $display("        lane 0 occupancy reads %0d after 3 of %0d retired, expected %0d",
                         lane_occ(0), n_lane0, n_lane0 - 3);
                good3 = 0;
            end
            if (lane_occ(2) != 1) begin
                $display("        lane 2 occupancy reads %0d, expected 1 (its response is still on the wire)",
                         lane_occ(2));
                good3 = 0;
            end
            // Room again on lane 0, and only because it drained -- nothing else was written.
            if (!entry_ready(0)) begin
                $display("        lane 0 still refuses entries with %0d of %0d used",
                         lane_occ(0), QUEUE_DEPTH);
                good3 = 0;
            end
            if (good3) ok($sformatf("readback/occupancy_during_drain (%s)", occ_str()));
            else       bad($sformatf("readback/occupancy_during_drain (occ = %s)", occ_str()));

            // -- AFTER: everything drains ---------------------------------------------------------
            for (int r = 3; r < n_lane0; r++) announce(0, r_len[r]);
            announce(2, r2_len);
            t = 0;
            while ((tlasts[0] < tl0 + n_lane0 || tlasts[2] < tl2 + 1) && t < 400000) begin
                @(posedge clk); t++;
            end
            repeat (8) @(posedge clk);

            good3 = 1;
            if (got[0].size() - got0_before != n_lane0 * body3) begin
                $display("        lane 0 delivered %0d body bytes, expected %0d",
                         got[0].size() - got0_before, n_lane0 * body3);
                good3 = 0;
            end
            if (got[2].size() - got2_before != body3) begin
                $display("        lane 2 delivered %0d body bytes, expected %0d",
                         got[2].size() - got2_before, body3);
                good3 = 0;
            end
            for (int i = 0; i < n_lane0 * body3 && good3; i++) begin
                automatic int           r    = i / body3;
                automatic int           off  = i % body3;
                automatic byte unsigned want = byte'(8'hA0 + r) + off[7:0];
                if (got[0][got0_before + i] !== want) begin
                    $display("        lane 0 response %0d byte %0d: got %02h expected %02h",
                             r, off, got[0][got0_before + i], want);
                    good3 = 0;
                end
            end
            for (int L = 0; L < 8; L++) begin
                if (lane_occ(L) != 0) begin
                    $display("        lane %0d occupancy reads %0d after the drain, expected 0",
                             L, lane_occ(L));
                    good3 = 0;
                end
            end
            for (int L = 0; L < NUM_CONNS; L++) begin
                if (!entry_ready(L) || !arm_ready(L) || !lane_up(L) || lane_fatal(L)) begin
                    $display("        lane %0d admission nibble reads %04b after a clean drain",
                             L, laneReadyWord[4*L +: 4]);
                    good3 = 0;
                end
            end
            // Not one sticky cause on a run where nothing went wrong. If this ever fires it is
            // naming the lane and the reason, which is the entire point of the register.
            if (laneErrWord != 64'd0) begin
                $display("        sticky per-lane causes on a clean run: laneErr=0x%016h", laneErrWord);
                good3 = 0;
            end
            // Every lane's transmit FSM back in ST_IDLE with its text sent. This is the state a
            // wedged transmit path is NOT in, so it is worth reading even when nothing is wrong.
            if (laneStateWord[63:32] != 32'd0) begin
                $display("        a request-stream FSM is not idle after the drain: laneState=0x%016h",
                         laneStateWord);
                good3 = 0;
            end
            if (good3) ok($sformatf("readback/occupancy_after_drain (%s, no sticky causes)", occ_str()));
            else       bad("readback/occupancy_after_drain");

            // -- the compatibility stamp ----------------------------------------------------------
            //
            // The whole scheme for keeping deployed bitstreams and installed libraries apart rests
            // on this byte: it was a literal zero through revision 1, so a host reading 0 knows not
            // to touch registers 16..20 (which answer resp_error on those bitstreams), and a
            // library that predates the byte ignores it.
            if (inflightWord[31:24] == 8'd2)
                ok("readback/csr_revision (inflightWord[31:24] == 2)");
            else
                bad($sformatf("readback/csr_revision (reads %0d, expected 2; inflight=0x%08h)",
                              inflightWord[31:24], inflightWord));

            // -- the identity word, against the parameters this instance was elaborated with ------
            good3 = 1;
            if (lanePolicyWord[7:0] != 8'd2) begin
                $display("        policy revision reads %0d, expected 2", lanePolicyWord[7:0]);
                good3 = 0;
            end
            if (lanePolicyWord[15:8] != 8'(NUM_CONNS)) begin
                $display("        policy NUM_CONNS reads %0d, expected %0d",
                         lanePolicyWord[15:8], NUM_CONNS);
                good3 = 0;
            end
            if (lanePolicyWord[31:16] != 16'(QUEUE_DEPTH)) begin
                $display("        policy QUEUE_DEPTH reads %0d, expected %0d",
                         lanePolicyWord[31:16], QUEUE_DEPTH);
                good3 = 0;
            end
            if (lanePolicyWord[55:32] != 24'(LANE_STALL_CYCLES_EXP)) begin
                $display("        policy LANE_STALL_CYCLES reads %0d, expected %0d",
                         lanePolicyWord[55:32], LANE_STALL_CYCLES_EXP);
                good3 = 0;
            end
            if (lanePolicyWord[61:56] != 6'($clog2(LANE_STALL_CYCLES_EXP))) begin
                $display("        policy log2(LANE_STALL_CYCLES) reads %0d, expected %0d",
                         lanePolicyWord[61:56], $clog2(LANE_STALL_CYCLES_EXP));
                good3 = 0;
            end
            if (good3)
                ok($sformatf("readback/identity_word (rev=2 lanes=%0d depth=%0d hol=%0d cycles)",
                             lanePolicyWord[15:8], lanePolicyWord[31:16], lanePolicyWord[55:32]));
            else
                bad($sformatf("readback/identity_word (lanePolicy=0x%016h)", lanePolicyWord));
        end

        // =========================================================================================
        // Reconnect: MinIO drops an idle connection. With N lanes this is the NORMAL case, not a
        // fault -- a lane can sit idle past the ~30 s server timeout while its neighbours work.
        // The lane must come back on a fresh session, and the other lanes must not notice.
        // =========================================================================================
        $display("--- reconnect_on_idle_fin ---");
        begin
            automatic int opens_before = opens;
            automatic int t = 0;
            automatic int new_sid = -1;

            // Lane 2 is idle (its query finished above). Close it from the server side.
            announce_fin(2);

            // Wait for the lane to actually come BACK, not merely for the open to be issued:
            // `opens` increments in the TOE model as soon as it accepts the request, several
            // cycles before tcp_init reports done and the FSM rebinds. Sampling on `opens` reads
            // the lane mid-reconnect, when it is legitimately down.
            while (dut.conn_up_q[2] && t < 40000) begin @(posedge clk); t++; end   // released
            while (!dut.conn_up_q[2] && t < 40000) begin @(posedge clk); t++; end  // rebound
            repeat (4) @(posedge clk);

            if (opens == opens_before + 1)
                ok("reconnect/reopened_once (idle FIN -> exactly one new connection)");
            else
                bad($sformatf("reconnect/reopened_once (%0d new opens)", opens - opens_before));

            // It must be a NEW session id, not the dead one rebound.
            new_sid = int'(dut.conn_sid_q[2]);
            if (new_sid == 200 + opens_before)
                ok($sformatf("reconnect/fresh_session (lane 2 moved 202 -> %0d)", new_sid));
            else
                bad($sformatf("reconnect/fresh_session (lane 2 on session %0d, expected %0d)",
                              new_sid, 200 + opens_before));

            if (dut.conn_up_q[2]) ok("reconnect/lane_back_up");
            else bad("reconnect/lane_back_up");

            // The other three lanes are untouched: still up, still on their original sessions.
            good = 1;
            for (int L = 0; L < NUM_CONNS; L++) begin
                if (L != 2) begin
                    if (!dut.conn_up_q[L] || int'(dut.conn_sid_q[L]) != 200 + L) good = 0;
                end
            end
            if (good) ok("reconnect/neighbours_undisturbed");
            else bad("reconnect/neighbours_undisturbed");

            // A reconnect is not a fault: no lane may have latched fatal.
            if (dut.lane_fatal_q == '0) ok("reconnect/no_fatal (a clean idle close is recoverable)");
            else bad($sformatf("reconnect/no_fatal (lane_fatal_q=%b)", dut.lane_fatal_q));

            if (stallWord[15:8] == 8'd1) ok("reconnect/counted_once (reconnect count = 1)");
            else bad($sformatf("reconnect/counted_once (count=%0d)", stallWord[15:8]));
        end

        $display("========================================");
        $display("handler_multi_tb: %0d passed, %0d failed", pass_cnt, fail_cnt);
        $display("========================================");
        if (fail_cnt != 0) $fatal(1, "failures");
        $finish;
    end

    initial begin
        #60_000_000;
        $fatal(1, "global timeout");
    end

endmodule
