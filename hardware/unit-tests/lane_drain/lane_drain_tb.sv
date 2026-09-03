`timescale 1ns / 1ps
// =================================================================================================
// lane_drain_tb -- INDEPENDENT black-box liveness bench for handler_multi.
//
// Written from the external contract only.  Nothing below handler_multi's or rx_dispatch's port
// list was read, and none of the RTL author's benches were consulted.
//
// The bench is the whole outside world:
//   * TOE  : connection opens, a shared notification interface, and ONE shared packet FIFO
//            delivered in GLOBAL ARRIVAL ORDER.  One readPkg pops one packet, whatever session it
//            belongs to.  rx_metadata names the session actually delivered.  Data never stalls.
//   * HTTP : a keep-alive origin server.  It parses the GETs the DUT transmits, learns the lane
//            from the request path, and answers with Content-Length framed 200s.
//   * HOST : the config port (chunk-length entries, then the transfer arm) and the per-lane
//            request-text DMA, in the order software/oasis/configuration.cpp uses.
//   * DECODER: the per-lane body sink, which can apply arbitrary back-pressure.
//
// Properties checked continuously: LIVENESS (a readPkg within LIVENESS_BOUND cycles while a
// notification is outstanding), ROUTING (byte-exact, to the lane bound to that session), FRAMING
// (one tlast per response, at the Content-Length), RECOVERY (everything drains once a transient
// clears).
// =================================================================================================
import lynxTypes::*;
import http_types::*;

module lane_drain_tb #(
    parameter int NUM_CONNS     = 2,
    parameter int QUEUE_DEPTH   = 64,
    parameter int RX_FIFO_DEPTH = 2048
);

    localparam int BPB            = AXI_DATA_BITS/8;
    localparam int LIVENESS_BOUND = 100000;   // cycles without a readPkg while work is queued
    localparam int CFG_BOUND      = 200000;   // cycles waiting for req_ready
    localparam int MAX_CYCLES     = 4000000;
    localparam int SRV_IP         = 32'h0A00_0001;
    localparam int SRV_PORT       = 32'd80;

    logic clk = 1'b0, rst_n = 1'b0;
    always #2ns clk = ~clk;
    int cyc = 0;
    always @(posedge clk) cyc = cyc + 1;

    // =============================================================================================
    // DUT
    // =============================================================================================
    logic                              oc_tvalid, oc_tready;
    logic [TCP_OPEN_CONN_REQ_BITS-1:0] oc_tdata;
    logic                              os_tvalid, os_tready;
    logic [TCP_OPEN_CONN_RSP_BITS-1:0] os_tdata;
    logic                              cc_tvalid, cc_tready;
    logic [TCP_CLOSE_CONN_REQ_BITS-1:0] cc_tdata;

    logic                       n_tvalid, n_tready;
    logic [TCP_NOTIFY_BITS-1:0] n_tdata;
    logic                           rp_tvalid, rp_tready;
    logic [TCP_RD_PKG_REQ_BITS-1:0] rp_tdata;
    logic                        rm_tvalid, rm_tready;
    logic [TCP_RX_META_BITS-1:0] rm_tdata;
    logic                       rd_tvalid, rd_tready, rd_tlast;
    logic [AXI_DATA_BITS-1:0]   rd_tdata;
    logic [AXI_DATA_BITS/8-1:0] rd_tkeep;

    logic                        tm_tvalid, tm_tready;
    logic [TCP_TX_META_BITS-1:0] tm_tdata;
    logic                       td_tvalid, td_tready, td_tlast;
    logic [AXI_DATA_BITS-1:0]   td_tdata;
    logic [AXI_DATA_BITS/8-1:0] td_tkeep;
    logic                        ts_tvalid, ts_tready;
    logic [TCP_TX_STAT_BITS-1:0] ts_tdata;

    logic         req_valid, req_ready;
    http_config_t req_data;

    logic [NUM_CONNS-1:0]       rq_tvalid, rq_tready, rq_tlast;
    logic [AXI_DATA_BITS-1:0]   rq_tdata [NUM_CONNS];
    logic [AXI_DATA_BITS/8-1:0] rq_tkeep [NUM_CONNS];

    logic [NUM_CONNS-1:0]       bd_tvalid, bd_tready, bd_tlast;
    logic [AXI_DATA_BITS-1:0]   bd_tdata [NUM_CONNS];
    logic [AXI_DATA_BITS/8-1:0] bd_tkeep [NUM_CONNS];

    logic [31:0] totalWord, inflightWord, queueDepthWord, stallWord, respWord,
                 contentLengthWord, bodyRemainingWord;
    logic [3:0]  state_debug;

    handler_multi #(
        .NUM_CONNS    (NUM_CONNS),
        .QUEUE_DEPTH  (QUEUE_DEPTH),
        .RX_FIFO_DEPTH(RX_FIFO_DEPTH)
    ) dut (
        .ap_clk(clk), .ap_rst_n(rst_n),
        .m_axis_open_connection_TVALID(oc_tvalid),
        .m_axis_open_connection_TREADY(oc_tready),
        .m_axis_open_connection_TDATA (oc_tdata),
        .s_axis_open_status_TVALID(os_tvalid),
        .s_axis_open_status_TREADY(os_tready),
        .s_axis_open_status_TDATA (os_tdata),
        .m_axis_close_connection_TVALID(cc_tvalid),
        .m_axis_close_connection_TREADY(cc_tready),
        .m_axis_close_connection_TDATA (cc_tdata),
        .s_axis_notifications_TVALID(n_tvalid),
        .s_axis_notifications_TREADY(n_tready),
        .s_axis_notifications_TDATA (n_tdata),
        .m_axis_read_package_TVALID(rp_tvalid),
        .m_axis_read_package_TREADY(rp_tready),
        .m_axis_read_package_TDATA (rp_tdata),
        .s_axis_rx_metadata_TVALID(rm_tvalid),
        .s_axis_rx_metadata_TREADY(rm_tready),
        .s_axis_rx_metadata_TDATA (rm_tdata),
        .s_axis_rx_data_TVALID(rd_tvalid), .s_axis_rx_data_TREADY(rd_tready),
        .s_axis_rx_data_TDATA (rd_tdata),  .s_axis_rx_data_TKEEP (rd_tkeep),
        .s_axis_rx_data_TLAST (rd_tlast),
        .m_axis_tx_meta_TVALID(tm_tvalid), .m_axis_tx_meta_TREADY(tm_tready),
        .m_axis_tx_meta_TDATA (tm_tdata),
        .m_axis_tx_data_TVALID(td_tvalid), .m_axis_tx_data_TREADY(td_tready),
        .m_axis_tx_data_TDATA (td_tdata),  .m_axis_tx_data_TKEEP (td_tkeep),
        .m_axis_tx_data_TLAST (td_tlast),
        .s_axis_tx_status_TVALID(ts_tvalid), .s_axis_tx_status_TREADY(ts_tready),
        .s_axis_tx_status_TDATA (ts_tdata),
        .req_valid(req_valid), .req_ready(req_ready), .req_data(req_data),
        .s_axis_req_TVALID(rq_tvalid), .s_axis_req_TREADY(rq_tready),
        .s_axis_req_TDATA (rq_tdata),  .s_axis_req_TKEEP (rq_tkeep),
        .s_axis_req_TLAST (rq_tlast),
        .m_axis_body_tvalid(bd_tvalid), .m_axis_body_tready(bd_tready),
        .m_axis_body_tdata (bd_tdata),  .m_axis_body_tkeep (bd_tkeep),
        .m_axis_body_tlast (bd_tlast),
        .totalWord(totalWord), .inflightWord(inflightWord), .queueDepthWord(queueDepthWord),
        .stallWord(stallWord), .respWord(respWord), .contentLengthWord(contentLengthWord),
        .bodyRemainingWord(bodyRemainingWord), .state_debug(state_debug)
    );

    // =============================================================================================
    // Wire encodings -- Coyote lynx_pkg ground truth (packed struct: first member in the MSBs)
    // =============================================================================================
    function automatic logic [TCP_NOTIFY_BITS-1:0] pack_notif(int sid, int len, bit closed);
        logic [TCP_NOTIFY_BITS-1:0] w;
        w = '0; w[15:0] = 16'(sid); w[31:16] = 16'(len);
        w[63:32] = SRV_IP; w[79:64] = 16'd80; w[80] = closed;
        return w;
    endfunction
    function automatic logic [TCP_OPEN_CONN_RSP_BITS-1:0] pack_open_rsp(int sid, bit ok);
        logic [TCP_OPEN_CONN_RSP_BITS-1:0] w;
        w = '0; w[15:0] = 16'(sid); w[23:16] = ok ? 8'd1 : 8'd0;
        w[55:24] = SRV_IP; w[71:56] = 16'd80;
        return w;
    endfunction
    function automatic logic [TCP_TX_STAT_BITS-1:0] pack_tx_stat(int sid, int len);
        logic [TCP_TX_STAT_BITS-1:0] w;
        w = '0; w[15:0] = 16'(sid); w[31:16] = 16'(len);
        w[61:32] = 30'd1000000; w[63:62] = 2'b00;   // plenty of space, NO_ERROR
        return w;
    endfunction
    function automatic int rp_sid(logic [TCP_RD_PKG_REQ_BITS-1:0] w); return int'(w[15:0]);  endfunction
    function automatic int rp_len(logic [TCP_RD_PKG_REQ_BITS-1:0] w); return int'(w[31:16]); endfunction
    function automatic int tm_sid(logic [TCP_TX_META_BITS-1:0]    w); return int'(w[15:0]);  endfunction
    function automatic int tm_len(logic [TCP_TX_META_BITS-1:0]    w); return int'(w[31:16]); endfunction

    // =============================================================================================
    // Model state
    // =============================================================================================
    class Pkt;   int sid; byte unsigned d[$];  endclass
    class Notif; int sid; int len; bit closed; endclass
    class RPkg;  int sid; int len; int at;     endclass
    class Blob;  byte unsigned d[$];           endclass
    class Resp;  int lane; int seq; int len;   endclass

    class Sess;
        int  sid;
        bit  alive;
        int  lane;                 // discovered from the GET path; -1 until then
        byte unsigned rx[$];       // request bytes received from the DUT
        int  scanp;
        byte unsigned pending[$];  // response bytes waiting to go on the wire
        int  wr[$];                // sizes of the server's individual send() calls
        int  wr_left;
    endclass

    class Lane;
        Resp  plan[$];      // responses the server still has to produce (host's chunk plan)
        Resp  expq[$];      // responses handed to the network, awaiting delivery on the body stream
        Blob  txq[$];       // request text blobs waiting for DMA
        int   sid;          // session currently bound (as observed on the wire)
        // body checker state
        bit   active;
        int   cur_seq, cur_len, cur_idx;
        bit   must_end;
        int   bytes_in, resp_done;
        int   next_seq;
        int   planned_total;
    endclass

    Pkt   gfifo[$];
    Notif nq[$];
    Notif outst[$];
    RPkg  unmatched[$];
    Sess  sess[int];
    int   live_sids[$];
    Lane  ln[NUM_CONNS];

    int rp_issued = 0, pkt_taken = 0;
    int n_notif_sent = 0, n_notif_data = 0;
    int notif_bp_cycles = 0, rxdata_bp_cycles = 0;
    int idle_since_rp = 0;
    int n_open_req = 0, n_open_rsp = 0, n_close_req = 0;
    int next_sid = 1;
    int mss = 4096;

    int    n_err = 0;
    string verdict = "";
    bit    liveness_failed = 0;
    int    liveness_cycle = 0;
    bit    cfg_stalled = 0;
    int    cfg_stall_cycle = 0;
    bit    notif_overflow_suspected = 0;

    function automatic void err(string s);
        n_err = n_err + 1;
        if (n_err <= 25) $display("  [cyc=%0d] *** ERROR: %s", cyc, s);
    endfunction

    function automatic byte unsigned body_byte(int lane, int seq, int idx);
        return byte'((lane*211 + seq*37 + idx*11 + (idx/97)*53 + 7) & 32'hFF);
    endfunction

    // =============================================================================================
    // TOE: connection open / close
    // =============================================================================================
    assign oc_tready = 1'b1;
    assign cc_tready = 1'b1;

    int openq[$];
    always @(posedge clk) begin
        if (rst_n && oc_tvalid && oc_tready) begin n_open_req = n_open_req + 1; openq.push_back(1); end
        if (rst_n && cc_tvalid && cc_tready) begin
            n_close_req = n_close_req + 1;
            if (sess.exists(int'(cc_tdata[15:0]))) sess[int'(cc_tdata[15:0])].alive = 1'b0;
        end
    end

    initial begin : open_svc
        Sess s; int lat, sid;
        os_tvalid = 1'b0; os_tdata = '0;
        forever begin
            @(posedge clk);
            if (rst_n && openq.size() > 0) begin
                void'(openq.pop_front());
                lat = 40 + ($urandom_range(0, 240));      // tens..hundreds of cycles
                repeat (lat) @(posedge clk);
                sid = next_sid; next_sid = next_sid + 1;
                s = new(); s.sid = sid; s.alive = 1'b1; s.lane = -1; s.scanp = 0;
                sess[sid] = s; live_sids.push_back(sid);
                os_tdata  <= pack_open_rsp(sid, 1'b1);
                os_tvalid <= 1'b1;
                do @(posedge clk); while (!os_tready);
                os_tvalid <= 1'b0;
                n_open_rsp = n_open_rsp + 1;
                $display("  [cyc=%0d] TOE: opened session %0d (open request #%0d)", cyc, sid, n_open_rsp);
            end
        end
    end

    // =============================================================================================
    // TOE: notifications (shared; never held off by the bench)
    // =============================================================================================
    initial begin : notif_driver
        Notif nn;
        n_tvalid = 1'b0; n_tdata = '0;
        forever begin
            @(posedge clk);
            if (!rst_n) n_tvalid <= 1'b0;
            else if (n_tvalid && n_tready) begin
                nn = nq.pop_front();
                outst.push_back(nn);
                n_notif_sent = n_notif_sent + 1;
                if (nn.len > 0) n_notif_data = n_notif_data + 1;
                if (nq.size() > 0) begin
                    n_tdata <= pack_notif(nq[0].sid, nq[0].len, nq[0].closed); n_tvalid <= 1'b1;
                end else n_tvalid <= 1'b0;
            end else if (!n_tvalid && nq.size() > 0) begin
                n_tdata <= pack_notif(nq[0].sid, nq[0].len, nq[0].closed); n_tvalid <= 1'b1;
            end
        end
    end
    always @(posedge clk) if (rst_n && n_tvalid && !n_tready) notif_bp_cycles = notif_bp_cycles + 1;

    // =============================================================================================
    // TOE: readPkg sink + matcher
    // =============================================================================================
    assign rp_tready = 1'b1;
    always @(posedge clk) begin : rp_sink
        RPkg r; int i, hit;
        if (rst_n) begin
            if (rp_tvalid && rp_tready) begin
                rp_issued = rp_issued + 1; idle_since_rp = 0;
                if (rp_len(rp_tdata) == 0)
                    err($sformatf("readPkg with length 0 (sid=%0d): the real TOE's datamover hangs on this",
                                  rp_sid(rp_tdata)));
                r = new(); r.sid = rp_sid(rp_tdata); r.len = rp_len(rp_tdata); r.at = cyc;
                unmatched.push_back(r);
            end else idle_since_rp = idle_since_rp + 1;
            i = 0;
            while (i < unmatched.size()) begin
                hit = -1;
                for (int j = 0; j < outst.size(); j++)
                    if (hit < 0 && outst[j].sid == unmatched[i].sid && outst[j].len == unmatched[i].len)
                        hit = j;
                if (hit >= 0) begin outst.delete(hit); unmatched.delete(i); end
                else if ((cyc - unmatched[i].at) > 200) begin
                    err($sformatf("readPkg(sid=%0d,len=%0d) matches no notification the TOE sent",
                                  unmatched[i].sid, unmatched[i].len));
                    unmatched.delete(i);
                end else i = i + 1;
            end
        end
    end

    // =============================================================================================
    // TOE: packet delivery from the ONE shared FIFO, in arrival order
    // =============================================================================================
    int deliver_lane = -1;
    initial begin : deliver_engine
        Pkt p; int i, nb, k;
        logic [AXI_DATA_BITS-1:0] dw; logic [AXI_DATA_BITS/8-1:0] kw;
        rm_tvalid = 0; rm_tdata = '0; rd_tvalid = 0; rd_tdata = '0; rd_tkeep = '0; rd_tlast = 0;
        forever begin
            @(posedge clk);
            if (rst_n && (rp_issued - pkt_taken) > 0 && gfifo.size() > 0) begin
                p = gfifo.pop_front(); pkt_taken = pkt_taken + 1;
                deliver_lane = (sess.exists(p.sid)) ? sess[p.sid].lane : -1;
                rm_tdata <= TCP_RX_META_BITS'(p.sid); rm_tvalid <= 1'b1;
                do @(posedge clk); while (!rm_tready);
                rm_tvalid <= 1'b0;
                i = 0;
                while (i < p.d.size()) begin
                    nb = (p.d.size() - i > BPB) ? BPB : (p.d.size() - i);
                    dw = '0; kw = '0;
                    for (k = 0; k < nb; k++) begin dw[k*8 +: 8] = p.d[i+k]; kw[k] = 1'b1; end
                    rd_tdata <= dw; rd_tkeep <= kw;
                    rd_tlast <= ((i + nb) >= p.d.size()); rd_tvalid <= 1'b1;
                    do @(posedge clk); while (!rd_tready);
                    i = i + nb;
                end
                rd_tvalid <= 1'b0; rd_tlast <= 1'b0;
            end
        end
    end
    always @(posedge clk) if (rst_n && rd_tvalid && !rd_tready) rxdata_bp_cycles = rxdata_bp_cycles + 1;

    // =============================================================================================
    // TOE transmit side: accept everything, answer each meta with a NO_ERROR status
    // =============================================================================================
    assign tm_tready = 1'b1;
    assign td_tready = 1'b1;

    int txmq[$];        // session ids from tx_meta, in order
    int txsq[$];        // pending statuses to emit
    int txsl[$];
    int cur_tx_sid = -1;
    bit in_tx = 1'b0;

    always @(posedge clk) begin : tx_mon
        int b;
        if (rst_n) begin
            if (tm_tvalid && tm_tready) begin
                txmq.push_back(tm_sid(tm_tdata));
                txsq.push_back(tm_sid(tm_tdata));
                txsl.push_back(tm_len(tm_tdata));
            end
            if (td_tvalid && td_tready) begin
                if (!in_tx) begin
                    if (txmq.size() == 0) err("tx_data beat with no preceding tx_meta");
                    else cur_tx_sid = txmq.pop_front();
                    in_tx = 1'b1;
                end
                if (cur_tx_sid >= 0 && sess.exists(cur_tx_sid))
                    for (b = 0; b < BPB; b++)
                        if (td_tkeep[b]) sess[cur_tx_sid].rx.push_back(td_tdata[b*8 +: 8]);
                if (td_tlast) in_tx = 1'b0;
            end
        end
    end

    initial begin : tx_status_svc
        ts_tvalid = 1'b0; ts_tdata = '0;
        forever begin
            @(posedge clk);
            if (rst_n && txsq.size() > 0) begin
                repeat (4) @(posedge clk);
                ts_tdata  <= pack_tx_stat(txsq.pop_front(), txsl.pop_front());
                ts_tvalid <= 1'b1;
                do @(posedge clk); while (!ts_tready);
                ts_tvalid <= 1'b0;
            end
        end
    end

    // =============================================================================================
    // HTTP origin server: parse the GETs, learn the lane from the path, answer with framed 200s
    // =============================================================================================
    task automatic serve(int sid, int lane, int seq);
        Resp r; string hdr; int len; int i;
        if (ln[lane].plan.size() == 0) begin
            err($sformatf("lane %0d transmitted request seq %0d that the host never planned", lane, seq));
            return;
        end
        r = ln[lane].plan.pop_front();
        len = r.len;
        hdr = $sformatf("HTTP/1.1 206 Partial Content\015\012Content-Length: %0d\015\012Connection: keep-alive\015\012\015\012", len);
        for (i = 0; i < hdr.len(); i++) sess[sid].pending.push_back(byte'(hdr.getc(i)));
        for (i = 0; i < len; i++) sess[sid].pending.push_back(body_byte(lane, r.seq, i));
        sess[sid].wr.push_back(hdr.len() + len);
        ln[lane].expq.push_back(r);
    endtask

    // Scan a session's received bytes for complete request header blocks.
    task automatic scan_requests(int sid);
        Sess s; int i, j, lane, seq, start;
        bit found;
        s = sess[sid];
        forever begin
            found = 1'b0;
            for (i = s.scanp; i + 3 < s.rx.size(); i++) begin
                if (s.rx[i] == 8'h0D && s.rx[i+1] == 8'h0A && s.rx[i+2] == 8'h0D && s.rx[i+3] == 8'h0A) begin
                    start = s.scanp;
                    // "GET /L<d>/S<dddddd> HTTP/1.1"
                    if (s.rx[start] !== "G" || s.rx[start+4] !== "/" || s.rx[start+5] !== "L") begin
                        err($sformatf("session %0d: malformed request at offset %0d", sid, start));
                        s.scanp = i + 4;
                        found = 1'b1;
                        break;
                    end
                    lane = int'(s.rx[start+6]) - int'("0");
                    seq  = 0;
                    for (j = 0; j < 6; j++) seq = seq*10 + (int'(s.rx[start+9+j]) - int'("0"));
                    if (lane < 0 || lane >= NUM_CONNS) begin
                        err($sformatf("session %0d: request names lane %0d, out of range", sid, lane));
                    end else begin
                        if (s.lane < 0) begin
                            s.lane = lane;
                            ln[lane].sid = sid;
                            $display("  [cyc=%0d] server: session %0d carries lane %0d (first GET seq %0d)",
                                     cyc, sid, lane, seq);
                        end else if (s.lane != lane) begin
                            err($sformatf("session %0d carried a GET for lane %0d but is bound to lane %0d",
                                          sid, lane, s.lane));
                        end
                        serve(sid, lane, seq);
                    end
                    s.scanp = i + 4;
                    found = 1'b1;
                    break;
                end
            end
            if (!found) break;
        end
    endtask

    initial begin : server_proc
        forever begin
            repeat (8) @(posedge clk);
            if (rst_n) foreach (live_sids[k]) scan_requests(live_sids[k]);
        end
    end

    // =============================================================================================
    // Network: segment pending response bytes into packets, in round-robin arrival order.
    // Emission is paced at one 512-bit beat per cycle, i.e. line rate for this link.
    // =============================================================================================
    int  net_rr = 0;
    bit  net_paced = 1'b1;
    int  net_allow = 1000000000;   // packets the network may still put on the wire
    bit  net_coalesce = 1'b0;   // 1 = let one TCP segment carry the tail of one response and the head of the next
    initial begin : net_engine
        Pkt p; Notif nn; int i, k, sid, n, tries;
        forever begin
            @(posedge clk);
            if (rst_n && live_sids.size() > 0 && net_allow > 0) begin
                sid = -1;
                for (tries = 0; tries < live_sids.size(); tries++) begin
                    k = live_sids[(net_rr + tries) % live_sids.size()];
                    if (sess[k].pending.size() > 0) begin sid = k; net_rr = (net_rr + tries + 1); break; end
                end
                if (sid >= 0) begin
                    if (!net_coalesce) begin
                        if (sess[sid].wr_left == 0 && sess[sid].wr.size() > 0)
                            sess[sid].wr_left = sess[sid].wr.pop_front();
                    end
                    n = (sess[sid].pending.size() > mss) ? mss : sess[sid].pending.size();
                    if (!net_coalesce && sess[sid].wr_left > 0 && n > sess[sid].wr_left)
                        n = sess[sid].wr_left;
                    if (!net_coalesce) sess[sid].wr_left = sess[sid].wr_left - n;
                    p = new(); p.sid = sid;
                    for (i = 0; i < n; i++) p.d.push_back(sess[sid].pending.pop_front());
                    gfifo.push_back(p);
                    net_allow = net_allow - 1;
                    nn = new(); nn.sid = sid; nn.len = n; nn.closed = 1'b0;
                    nq.push_back(nn);
                    if (net_paced) repeat ((n + BPB - 1)/BPB) @(posedge clk);
                end
            end
        end
    end

    task automatic peer_close(int sid);
        Notif nn;
        nn = new(); nn.sid = sid; nn.len = 0; nn.closed = 1'b1;
        nq.push_back(nn);
        sess[sid].alive = 1'b0;
        $display("  [cyc=%0d] server: peer FIN on session %0d", cyc, sid);
    endtask

    // =============================================================================================
    // Decoder side: per-lane body checker (routing + framing)
    // =============================================================================================
    genvar gl;
    generate
        for (gl = 0; gl < NUM_CONNS; gl++) begin : g_body
            always @(posedge clk) begin : chk
                int b; byte unsigned got, want; Resp r;
                if (rst_n && bd_tvalid[gl] && bd_tready[gl]) begin
                    for (b = 0; b < BPB; b++) begin
                        if (bd_tkeep[gl][b]) begin
                            got = bd_tdata[gl][b*8 +: 8];
                            ln[gl].bytes_in = ln[gl].bytes_in + 1;
                            if (ln[gl].must_end)
                                err($sformatf("lane %0d: body bytes continue past the Content-Length without a tlast", gl));
                            if (!ln[gl].active) begin
                                if (ln[gl].expq.size() == 0) begin
                                    err($sformatf("lane %0d: body byte with no response outstanding", gl));
                                end else begin
                                    r = ln[gl].expq.pop_front();
                                    ln[gl].active  = 1'b1;
                                    ln[gl].cur_seq = r.seq;
                                    ln[gl].cur_len = r.len;
                                    ln[gl].cur_idx = 0;
                                end
                            end
                            if (ln[gl].active) begin
                                want = body_byte(gl, ln[gl].cur_seq, ln[gl].cur_idx);
                                if (got !== want)
                                    err($sformatf("lane %0d resp seq %0d byte %0d: got %02h want %02h",
                                                  gl, ln[gl].cur_seq, ln[gl].cur_idx, got, want));
                                ln[gl].cur_idx = ln[gl].cur_idx + 1;
                                if (ln[gl].cur_idx == ln[gl].cur_len) ln[gl].must_end = 1'b1;
                            end
                        end
                    end
                    if (bd_tlast[gl]) begin
                        if (!ln[gl].must_end)
                            err($sformatf("lane %0d: tlast after %0d of %0d body bytes",
                                          gl, ln[gl].cur_idx, ln[gl].cur_len));
                        ln[gl].resp_done = ln[gl].resp_done + 1;
                        ln[gl].active = 1'b0; ln[gl].must_end = 1'b0;
                    end
                end
            end
        end
    endgenerate

    // per-lane body back-pressure, driven by the scenarios
    logic [NUM_CONNS-1:0] body_ready_ctl;
    assign bd_tready = body_ready_ctl;

    // =============================================================================================
    // Host: config port + per-lane request-text DMA
    // =============================================================================================
    // Acceptance latency of a config beat, split by kind.  An ENTRY beat needs queue room; an ARM
    // beat needs the previous transfer to have finished sending -- the two have different
    // admission rules, so they are measured separately.
    int ent_n = 0, ent_wait_sum = 0, ent_wait_max = 0;
    int arm_n = 0, arm_wait_sum = 0, arm_wait_max = 0;

    task automatic push_cfg(input http_config_t c, output bit ok);
        int t0, w;
        t0 = cyc; ok = 1'b0;
        @(posedge clk);
        req_data <= c; req_valid <= 1'b1;
        while ((cyc - t0) < CFG_BOUND) begin
            @(posedge clk);
            if (req_ready) begin ok = 1'b1; break; end
        end
        req_valid <= 1'b0;
        w = cyc - t0;
        if (c.req_total_bytes != 0) begin
            arm_n = arm_n + 1; arm_wait_sum = arm_wait_sum + w;
            if (w > arm_wait_max) arm_wait_max = w;
        end else begin
            ent_n = ent_n + 1; ent_wait_sum = ent_wait_sum + w;
            if (w > ent_wait_max) ent_wait_max = w;
        end
        if (!ok && !cfg_stalled) begin
            cfg_stalled = 1'b1; cfg_stall_cycle = cyc;
            $display("  [cyc=%0d] *** CONFIG STALL: req_ready never asserted for %0d cycles", cyc, CFG_BOUND);
        end
    endtask

    function automatic http_config_t mk_cfg(int chunk_bytes, int dest, int total_bytes);
        http_config_t c;
        c = '0;
        c.server_ip       = SRV_IP;
        c.server_port     = SRV_PORT;
        c.req_chunk_bytes = 32'(chunk_bytes);
        c.req_chunk_dest  = 4'(dest);
        c.req_total_bytes = 32'(total_bytes);
        return c;
    endfunction

    // Build a batch of GETs for `lane`, padded to a whole 64-byte beat exactly as the host does.
    function automatic void build_text(int lane, int nreq, int startseq, ref byte unsigned txt[$]);
        string t, pad; int need, rem, i;
        t = "";
        for (i = 0; i < nreq; i++)
            t = {t, $sformatf("GET /L%0d/S%06d HTTP/1.1\015\012Host: 10.0.0.1:80\015\012Connection: keep-alive\015\012\015\012",
                              lane, startseq + i)};
        rem = t.len() % 64;
        if (rem != 0) begin
            need = 64 - rem;
            while (need < 9) need = need + 64;
            pad = "";
            for (i = 0; i < need - 9; i++) pad = {pad, "a"};
            // insert the pad header before the blank line that ends the LAST request
            t = {t.substr(0, t.len()-3), "X-Pad: ", pad, "\015\012", "\015\012"};
        end
        txt = {};
        for (i = 0; i < t.len(); i++) txt.push_back(byte'(t.getc(i)));
    endfunction

    // Variant: `nreq` GETs of `body_len` bytes each, but only `nchunk` chunk-length entries of
    // `chunk_len` bytes -- the documented real case where one column chunk is split into several
    // ranged GETs and axis_rewrite_last marks tlast once per CHUNK.
    task automatic submit_split(int lane, int nreq, int body_len, int nchunk, int chunk_len,
                                output bit ok);
        Blob bl; Resp r; byte unsigned txt[$]; int i; bit o;
        ok = 1'b1;
        build_text(lane, nreq, ln[lane].next_seq, txt);
        for (i = 0; i < nreq; i++) begin                    // what the SERVER will answer
            r = new(); r.lane = lane; r.seq = ln[lane].next_seq + i; r.len = body_len;
            ln[lane].plan.push_back(r);
        end
        for (i = 0; i < nchunk; i++) begin                  // what the HOST tells the hardware
            push_cfg(mk_cfg(chunk_len, lane, 0), o);
            if (!o) begin ok = 1'b0; return; end
        end
        push_cfg(mk_cfg(chunk_len, lane, txt.size()), o);
        if (!o) begin ok = 1'b0; return; end
        ln[lane].next_seq = ln[lane].next_seq + nreq;
        bl = new(); bl.d = txt;
        ln[lane].txq.push_back(bl);
    endtask

    // The host's submit_batch: N chunk-length entries, then the arm, then the text.
    task automatic submit_batch(int lane, int nreq, int len_each, output bit ok);
        Blob   bl; Resp r; byte unsigned txt[$]; int i;
        bit    o;
        ok = 1'b1;
        build_text(lane, nreq, ln[lane].next_seq, txt);
        for (i = 0; i < nreq; i++) begin
            r = new(); r.lane = lane; r.seq = ln[lane].next_seq + i; r.len = len_each;
            ln[lane].plan.push_back(r);
            ln[lane].planned_total = ln[lane].planned_total + 1;
            push_cfg(mk_cfg(len_each, lane, 0), o);         // chunk-length entry
            if (!o) begin ok = 1'b0; return; end
        end
        // The arm.  The real host does NOT rewrite req_chunk_bytes here, so the register still
        // holds the last entry's value (and its lane) -- reproduced exactly.
        push_cfg(mk_cfg(len_each, lane, txt.size()), o);
        if (!o) begin ok = 1'b0; return; end
        ln[lane].next_seq = ln[lane].next_seq + nreq;
        bl = new(); bl.d = txt;
        ln[lane].txq.push_back(bl);
    endtask

    generate
        for (gl = 0; gl < NUM_CONNS; gl++) begin : g_dma
            initial begin : dma
                Blob bl; int i, k, nb;
                logic [AXI_DATA_BITS-1:0] dw; logic [AXI_DATA_BITS/8-1:0] kw;
                rq_tvalid[gl] = 1'b0; rq_tlast[gl] = 1'b0; rq_tdata[gl] = '0; rq_tkeep[gl] = '0;
                forever begin
                    @(posedge clk);
                    if (rst_n && ln[gl] != null && ln[gl].txq.size() > 0) begin
                        bl = ln[gl].txq.pop_front();
                        i = 0;
                        while (i < bl.d.size()) begin
                            nb = (bl.d.size() - i > BPB) ? BPB : (bl.d.size() - i);
                            dw = '0; kw = '0;
                            for (k = 0; k < nb; k++) begin dw[k*8 +: 8] = bl.d[i+k]; kw[k] = 1'b1; end
                            rq_tdata[gl] <= dw; rq_tkeep[gl] <= kw;
                            rq_tlast[gl] <= ((i + nb) >= bl.d.size()); rq_tvalid[gl] <= 1'b1;
                            do @(posedge clk); while (!rq_tready[gl]);
                            i = i + nb;
                        end
                        rq_tvalid[gl] <= 1'b0; rq_tlast[gl] <= 1'b0;
                    end
                end
            end
        end
    endgenerate

    // A notification with length 0 (a bare FIN) must NOT draw a readPkg: a zero-length readPkg
    // hangs the real TOE's datamover (see rx_app_stream_if.cpp).  Only data notifications count
    // towards the liveness obligation.
    function automatic int outst_data();
        int n; n = 0;
        for (int i = 0; i < outst.size(); i++) if (outst[i].len > 0) n = n + 1;
        return n;
    endfunction

    // =============================================================================================
    // Pipelined-arm host driver.
    //
    // The board's shape: batching disabled and chunk splitting off, so each arm carries EXACTLY ONE
    // chunk-length entry and ONE ranged GET.  The host does NOT drain between arms -- it keeps
    // `depth` arms outstanding on a lane and pushes the next as soon as one retires, blocking on the
    // hardware credit in between.  Responses come back to back with no server think time.
    // =============================================================================================
    localparam int PROG_BOUND = 200000;    // cycles without a completed response = stopped

    int    stop_lane = -1, stop_resp = -1, stop_bytes = -1, stop_cycle = -1;
    string stop_why = "";

    task automatic pipeline(input int nlanes, input int depth, input int nresp, input int body_len,
                            output bit ok);
        int submitted[4];
        int last_done, tot_done, last_prog;
        bit o;
        ok = 1'b1;
        for (int i = 0; i < 4; i++) submitted[i] = 0;
        last_done = 0; last_prog = cyc;
        forever begin
            tot_done = 0;
            for (int L = 0; L < nlanes; L++) tot_done = tot_done + ln[L].resp_done;
            if (tot_done >= nresp*nlanes) return;
            // top every active lane back up to `depth` arms outstanding
            for (int L = 0; L < nlanes; L++) begin
                while (submitted[L] < nresp && (submitted[L] - ln[L].resp_done) < depth) begin
                    submit_batch(L, 1, body_len, o);
                    if (!o) begin
                        ok = 1'b0;
                        stop_lane = L; stop_resp = ln[L].resp_done; stop_bytes = ln[L].bytes_in;
                        stop_cycle = cyc; stop_why = "config port refused a beat (req_ready never rose)";
                        return;
                    end
                    submitted[L] = submitted[L] + 1;
                end
            end
            @(posedge clk);
            if (tot_done != last_done) begin last_done = tot_done; last_prog = cyc; end
            else if ((cyc - last_prog) > PROG_BOUND) begin
                ok = 1'b0;
                stop_lane = 0; stop_cycle = cyc;
                stop_resp = ln[0].resp_done; stop_bytes = ln[0].bytes_in;
                stop_why = $sformatf("no response completed for %0d cycles", PROG_BOUND);
                return;
            end
        end
    endtask

    task automatic report_pipeline(string tag, int nlanes, int depth, bit ok);
        $display("");
        $display("  == %s : depth=%0d, %0d lane(s) ==", tag, depth, nlanes);
        for (int L = 0; L < nlanes; L++)
            $display("     lane %0d: %0d responses framed, %0d body bytes (%0.2f MB), session %0d",
                     L, ln[L].resp_done, ln[L].bytes_in, real'(ln[L].bytes_in)/1048576.0, ln[L].sid);
        for (int L = nlanes; L < NUM_CONNS; L++)
            $display("     lane %0d (idle): %0d responses, %0d body bytes, session %0d",
                     L, ln[L].resp_done, ln[L].bytes_in, ln[L].sid);
        $display("     config beats: %0d entries (avg %0d, max %0d cyc), %0d arms (avg %0d, max %0d cyc)",
                 ent_n, (ent_n ? ent_wait_sum/ent_n : 0), ent_wait_max,
                 arm_n, (arm_n ? arm_wait_sum/arm_n : 0), arm_wait_max);
        $display("     readPkgs=%0d notifications=%0d outstanding=%0d sharedFIFO=%0d opens=%0d closes=%0d",
                 rp_issued, n_notif_sent, outst_data(), gfifo.size(), n_open_rsp, n_close_req);
        if (!ok) begin
            $display("     STOPPED: %s", stop_why);
            $display("     at cycle %0d, lane %0d had completed %0d responses / %0d body bytes",
                     stop_cycle, stop_lane, stop_resp, stop_bytes);
            dump(tag);
        end
    endtask

    function automatic int find_idle_session();
        // A session the TOE opened that has never carried a GET -- i.e. an armed-but-silent lane.
        foreach (live_sids[k])
            if (sess[live_sids[k]].alive && sess[live_sids[k]].lane < 0) return live_sids[k];
        return -1;
    endfunction

    // =============================================================================================
    // LIVENESS monitor
    // =============================================================================================
    always @(posedge clk) begin
        if (rst_n && !liveness_failed && outst_data() > 0 && idle_since_rp > LIVENESS_BOUND) begin
            liveness_failed = 1'b1; liveness_cycle = cyc;
            $display("  [cyc=%0d] *** LIVENESS: %0d data notification(s) outstanding, no readPkg for %0d cycles",
                     cyc, outst_data(), idle_since_rp);
        end
    end

    // =============================================================================================
    // Drain bookkeeping
    // =============================================================================================
    function automatic bit all_drained();
        bit ok;
        ok = (nq.size() == 0) && (outst_data() == 0) && (gfifo.size() == 0);
        for (int i = 0; i < NUM_CONNS; i++) begin
            if (ln[i].plan.size() != 0) ok = 0;
            if (ln[i].expq.size() != 0) ok = 0;
            if (ln[i].txq.size()  != 0) ok = 0;
            if (ln[i].resp_done != ln[i].planned_total) ok = 0;
        end
        foreach (live_sids[k]) if (sess[live_sids[k]].pending.size() != 0) ok = 0;
        return ok;
    endfunction

    task automatic wait_drain(int bound, output bit ok);
        int t0; t0 = cyc; ok = 0;
        while ((cyc - t0) < bound) begin
            @(posedge clk);
            if (all_drained()) begin ok = 1; return; end
            if (liveness_failed || cfg_stalled) begin ok = 0; return; end
        end
    endtask

    task automatic wait_cycles(int n); repeat (n) @(posedge clk); endtask

    task automatic dump(string tag);
        $display("  ---- state dump [%s] at cycle %0d ----", tag, cyc);
        $display("     notifications presented=%0d (data=%0d)  outstanding=%0d  not-yet-presented=%0d",
                 n_notif_sent, n_notif_data, outst.size(), nq.size());
        for (int i = 0; i < outst.size() && i < 10; i++)
            $display("       outstanding[%0d]: sid=%0d len=%0d closed=%0b",
                     i, outst[i].sid, outst[i].len, outst[i].closed);
        $display("     readPkgs=%0d  packets delivered=%0d  shared FIFO depth=%0d  cycles since last readPkg=%0d",
                 rp_issued, pkt_taken, gfifo.size(), idle_since_rp);
        $display("     opens req=%0d rsp=%0d   closes=%0d", n_open_req, n_open_rsp, n_close_req);
        for (int i = 0; i < NUM_CONNS; i++)
            $display("       lane %0d: sid=%0d tready=%0b planned=%0d served-to-net=%0d awaiting-body=%0d done=%0d bytes=%0d text-blobs-queued=%0d",
                     i, ln[i].sid, body_ready_ctl[i], ln[i].planned_total,
                     ln[i].planned_total - ln[i].plan.size(), ln[i].expq.size(),
                     ln[i].resp_done, ln[i].bytes_in, ln[i].txq.size());
        foreach (live_sids[k])
            $display("       session %0d: alive=%0b lane=%0d unsegmented-bytes=%0d req-bytes-in=%0d",
                     live_sids[k], sess[live_sids[k]].alive, sess[live_sids[k]].lane,
                     sess[live_sids[k]].pending.size(), sess[live_sids[k]].rx.size());
        // CSR readback, decoded per the map documented in http_config.sv
        $display("     CSR inflight=0x%08h (slots=%0d of %0d, announce_pending=%0b peerFIN=%0b up=%0b)",
                 inflightWord, inflightWord[7:0], inflightWord[15:8],
                 inflightWord[16], inflightWord[17], inflightWord[18]);
        $display("     CSR stall=0x%08h (connect=%0b send=%0b read=%0b init_err=%0b send_err=%0b noCL=%0b dirty=%0b bad_status=%0b reconnects=%0d slot=%0d annq_overflow=%0b)",
                 stallWord, stallWord[0], stallWord[1], stallWord[2], stallWord[3], stallWord[4],
                 stallWord[5], stallWord[6], stallWord[7], stallWord[15:8], stallWord[23:16], stallWord[24]);
        $display("     CSR stall upper (route_stall=%0b rwl_starved=%0b read_timeout=%0b rx_fifo_stall=%0b)",
                 stallWord[28], stallWord[27], stallWord[26], stallWord[25]);
        $display("     CSR resp=0x%08h  content_length=%0d  body_remaining=%0d  queue_depth=%0d  state=%0d",
                 respWord, contentLengthWord, bodyRemainingWord, queueDepthWord, state_debug);
        $display("     notif-backpressure=%0d cyc  rx_data-backpressure=%0d cyc", notif_bp_cycles, rxdata_bp_cycles);
        $display("  ------------------------------------------");
    endtask

    // =============================================================================================
    // STICKY STALL GATE
    //
    // Delivering every byte is necessary, not sufficient. Four bits in the handler's stallWord
    // record, stickily, that the receive path misbehaved on the way even when the data came out
    // right -- and each of them is a condition this bench exists to catch:
    //
    //   [28] rxd_route_stall  a lane refused a beat rx_dispatch had already accepted off the shared
    //                         bus, so that beat was DROPPED. Silent corruption, or a hang.
    //   [27] rwl_starved      body bytes arrived with no chunk length configured -- two columns
    //                         about to be merged into one decoder stream.
    //   [25] rx_fifo_stall    the per-lane decoupling fifo refused the producer, i.e. back-pressure
    //                         reached the TCP stack again, which is the thing the fifo exists to
    //                         prevent.
    //   [7]  status_bad       a response was retired with a status the handler read as not 200/206.
    //
    // Bit positions are handler_multi.sv's stallWord concatenation, not a guess: {3'd0,
    // rxd_route_stall, |rwl_starved, |lane_timeout, |lane_fifo_stall, rxd_overflow, 8'd0,
    // reconn_cnt_q, |lane_status_bad_q, ...}.
    //
    // Applied only to a verdict that already says PASS. Scenarios (e)/(s_e) deliberately kill a
    // lane's consumer for good and report CONTAINED/PARTIAL instead; their stall bits are the
    // expected consequence of the transient, not a defect, and this must not turn a containment
    // measurement into a failure.
    // =============================================================================================
    task automatic check_sticky();
        string why;
        why = "";
        if (stallWord[28]) why = {why, " route_stall(28)"};
        if (stallWord[27]) why = {why, " rwl_starved(27)"};
        if (stallWord[25]) why = {why, " rx_fifo_stall(25)"};
        if (stallWord[7])  why = {why, " status_bad(7)"};
        if (why != "") begin
            $display("  STICKY stall bits set:%s   (stallWord=0x%08h)", why, stallWord);
            if (verdict.len() >= 4 && verdict.substr(0, 3) == "PASS") begin
                verdict = $sformatf("FAIL (data ok, sticky stall bits:%s)", why);
                dump("sticky");
            end
        end
    endtask

    // =============================================================================================
    // Scenarios
    // =============================================================================================
    string scen;

    task automatic reset_all();
        rst_n = 1'b0;
        req_valid = 1'b0; req_data = '0;
        body_ready_ctl = '1;
        for (int i = 0; i < NUM_CONNS; i++) begin
            ln[i] = new();
            ln[i].sid = -1; ln[i].active = 0; ln[i].must_end = 0;
            ln[i].bytes_in = 0; ln[i].resp_done = 0; ln[i].next_seq = 0; ln[i].planned_total = 0;
        end
        repeat (30) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);
    endtask

    bit trace_on = 0;
    int trace_iv = 2000;
    initial begin : tracer
        if ($test$plusargs("TRACE")) trace_on = 1;
        void'($value$plusargs("TIV=%d", trace_iv));
        forever begin
            repeat (trace_iv) @(posedge clk);
            if (rst_n && trace_on)
                $display("  T[%0d] rp=%0d notif=%0d outst=%0d gf=%0d | L0 done=%0d by=%0d exp=%0d | L1 done=%0d by=%0d exp=%0d | st=%0d infl=%08h stall=%08h tot=%08h resp=%08h brem=%0d cl=%0d bdv=%b bdr=%b rqr=%b",
                         cyc, rp_issued, n_notif_sent, outst.size(), gfifo.size(),
                         ln[0].resp_done, ln[0].bytes_in, ln[0].expq.size(),
                         ln[1].resp_done, ln[1].bytes_in, ln[1].expq.size(),
                         state_debug, inflightWord, stallWord, totalWord, respWord,
                         bodyRemainingWord, contentLengthWord, bd_tvalid, bd_tready, rq_tready);
        end
    end

    initial begin : main
        bit ok, o;
        int mss_arg;
        int t0, b0, b1;
        if (!$value$plusargs("SCEN=%s", scen)) scen = "a";
        if ($value$plusargs("MSS=%d", mss_arg)) begin
            mss = mss_arg;
            $display("  (mss overridden to %0d)", mss);
        end
        $display("\n==================================================================");
        $display("lane_drain_tb scenario '%s'  NUM_CONNS=%0d QUEUE_DEPTH=%0d RX_FIFO_DEPTH=%0d",
                 scen, NUM_CONNS, QUEUE_DEPTH, RX_FIFO_DEPTH);
        $display("liveness bound=%0d cycles, config bound=%0d cycles", LIVENESS_BOUND, CFG_BOUND);
        $display("==================================================================");
        reset_all();

        case (scen)

        // (a) baseline -----------------------------------------------------------------------------
        "a": begin
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            for (int L = 0; L < NUM_CONNS; L++) begin
                submit_batch(L, 4, 3000, o);
                if (!o) begin verdict = "CONFIG STALL"; dump("a"); break; end
            end
            if (verdict == "") begin
                wait_drain(400000, ok);
                if (!ok) begin verdict = "HANG"; dump("a"); end
                else if (n_err) begin verdict = "FAIL"; dump("a"); end
                else verdict = "PASS";
            end
        end

        // (a1) probe: one request per batch, several batches ---------------------------------------
        "a1": begin
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            for (int r = 0; r < 4; r++)
                for (int L = 0; L < NUM_CONNS; L++) begin
                    submit_batch(L, 1, 3000, o);
                    if (!o) begin verdict = "CONFIG STALL"; dump("a1"); end
                end
            wait_drain(400000, ok);
            if (!ok) begin verdict = "HANG"; dump("a1"); end
            else if (n_err) begin verdict = "FAIL"; dump("a1"); end
            else verdict = "PASS";
        end

        // (a2) probe: a single batch of 2 -----------------------------------------------------------
        "a2": begin
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            submit_batch(0, 2, 3000, o);
            wait_drain(400000, ok);
            if (!ok) begin verdict = "HANG"; dump("a2"); end
            else if (n_err) begin verdict = "FAIL"; dump("a2"); end
            else verdict = "PASS";
        end

        // (a3) probe: second response starts on a 64-byte BEAT boundary, same packet -----------------
        "a3": begin
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            net_coalesce = 1'b1;
            submit_batch(0, 2, 3007, o);       // 65-byte header + 3007 = 3072 = 48 beats exactly
            wait_drain(400000, ok);
            if (!ok) begin verdict = "HANG"; dump("a3"); end
            else if (n_err) begin verdict = "FAIL"; dump("a3"); end
            else verdict = "PASS";
        end

        // (a4) probe: each response written by its own send(), so it starts a fresh TCP segment -------
        "a4": begin
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            submit_batch(0, 4, 3000, o);
            submit_batch(1, 4, 3000, o);
            wait_drain(400000, ok);
            if (!ok) begin verdict = "HANG"; dump("a4"); end
            else if (n_err) begin verdict = "FAIL"; dump("a4"); end
            else verdict = "PASS";
        end

        // (a5) probe: responses SHARE a segment (server coalesces) -----------------------------------
        "a5": begin
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            net_coalesce = 1'b1;
            submit_batch(0, 4, 3000, o);
            wait_drain(400000, ok);
            if (!ok) begin verdict = "HANG"; dump("a5"); end
            else if (n_err) begin verdict = "FAIL"; dump("a5"); end
            else verdict = "PASS";
        end

        // (a8) probe: strictly serialised -- one request, drained, then the next -------------------
        "a8": begin
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            for (int r = 0; r < 3; r++) begin
                submit_batch(0, 1, 3000, o);
                wait_drain(100000, ok);
                $display("  round %0d: drained=%0b done=%0d/%0d bytes=%0d",
                         r, ok, ln[0].resp_done, ln[0].planned_total, ln[0].bytes_in);
                if (!ok) break;
            end
            if (!ok) begin verdict = "HANG"; dump("a8"); end
            else if (n_err) verdict = "FAIL";
            else verdict = "PASS";
        end

        // (a9) probe: two responses in one batch, but the SECOND is held off the wire until the
        //      FIRST has fully drained out of the body stream ---------------------------------------
        "a9": begin
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            net_allow = 1;                       // only the first response may reach the wire
            submit_batch(0, 2, 3000, o);
            t0 = cyc;
            while (ln[0].resp_done < 1 && (cyc - t0) < 100000) @(posedge clk);
            $display("  first response framed=%0d at cycle %0d; waiting then releasing the second",
                     ln[0].resp_done, cyc);
            begin int dly; dly = 0; void'($value$plusargs("DLY=%d", dly)); wait_cycles(dly); end
            $display("  [cyc=%0d] releasing the second response (stall=%08h st=%0d)", cyc, stallWord, state_debug);
            net_allow = 1000000000;
            wait_drain(200000, ok);
            $display("  final: done=%0d/%0d bytes=%0d", ln[0].resp_done, ln[0].planned_total, ln[0].bytes_in);
            if (!ok) begin verdict = "HANG"; dump("a9"); end
            else if (n_err) verdict = "FAIL";
            else verdict = "PASS";
        end

        // (a10) probe: ONE column chunk of 6000 bytes fetched as TWO ranged GETs of 3000 ------------
        "a10": begin
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            submit_split(0, 2, 3000, 1, 6000, o);
            // one chunk -> one tlast after 6000 body bytes
            ln[0].expq = {};
            wait_cycles(2);
            t0 = cyc;
            while ((cyc - t0) < 200000 && ln[0].bytes_in < 6000) @(posedge clk);
            $display("  bytes=%0d tlasts=%0d (expected 6000 bytes, 1 tlast)",
                     ln[0].bytes_in, ln[0].resp_done);
            verdict = (ln[0].bytes_in == 6000) ? "PASS (chunk split across GETs works)"
                                               : "HANG (second GET's body never arrived)";
            if (ln[0].bytes_in != 6000) dump("a10");
        end

        // ---- SERIALISED variants -------------------------------------------------------------------
        // These keep exactly ONE response outstanding per lane, deliberately.  They were written
        // that way because handler_multi could only ever frame one response per transfer arm, so
        // the drain and containment questions could not otherwise be asked of it at all; that
        // limitation is fixed (the read stage in handler_multi re-arms per response, and a2/a9/a10
        // and the p* scenarios now pass pipelined).  They are kept because a serialised control is
        // still the cleanest way to separate a receive-path fault from a pipelining one: if s_d or
        // s_e fails while its pipelined twin passes, the pipelining is not what broke.

        "s_base": begin                     // serialised baseline, both lanes
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            for (int r = 0; r < 4; r++)
                for (int L = 0; L < NUM_CONNS; L++) begin
                    submit_batch(L, 1, 3000 + r*811, o);
                    if (!o) begin verdict = "CONFIG STALL"; dump("s_base"); end
                    wait_drain(200000, ok);
                    if (!ok) begin verdict = "HANG"; dump("s_base"); end
                end
            if (verdict == "") verdict = (n_err == 0) ? "PASS" : "FAIL";
        end

        "s_g": begin                        // boundaries: exact packet multiples and heavy splitting
            submit_batch(0, 1, 4096, o); wait_drain(200000, ok);      // body == 1 MSS exactly
            if (ok) begin submit_batch(1, 1, 8192, o); wait_drain(200000, ok); end
            if (ok) begin mss = 64;  submit_batch(0, 1, 4096, o); wait_drain(400000, ok); end
            if (ok) begin mss = 3000; submit_batch(1, 1, 12000, o); wait_drain(400000, ok); end
            if (!ok) begin verdict = "HANG"; dump("s_g"); end
            else verdict = (n_err == 0) ? "PASS" : "FAIL";
        end

        "s_d": begin                        // TRANSIENT back-pressure on lane 0, then it resumes
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            submit_batch(0, 1, 3000, o); wait_drain(200000, ok);
            submit_batch(1, 1, 3000, o); wait_drain(200000, ok);
            $display("  [cyc=%0d] warm-up drained=%0b", cyc, ok);
            body_ready_ctl[0] = 1'b0;                 // lane 0's decoder stops
            submit_batch(0, 1, 400000, o);            // more than lane 0's rx fifo can hold
            submit_batch(1, 1, 3000, o);
            wait_cycles(60000);
            $display("  [cyc=%0d] during the stall: L0=%0d bytes L1=%0d/%0d done, readPkgs=%0d outstanding=%0d gf=%0d",
                     cyc, ln[0].bytes_in, ln[1].resp_done, ln[1].planned_total,
                     rp_issued, outst.size(), gfifo.size());
            body_ready_ctl[0] = 1'b1;                 // the transient clears
            wait_drain(1500000, ok);
            if (!ok) begin verdict = "HANG (no recovery)"; dump("s_d"); end
            else verdict = (n_err == 0) ? "PASS (recovered)" : "FAIL";
        end

        "s_e": begin                        // PERMANENT stop on lane 0 -- the containment question
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            submit_batch(0, 1, 3000, o); wait_drain(200000, ok);
            submit_batch(1, 1, 3000, o); wait_drain(200000, ok);
            $display("  [cyc=%0d] warm-up drained=%0b  L0=%0d L1=%0d bytes",
                     cyc, ok, ln[0].bytes_in, ln[1].bytes_in);
            body_ready_ctl[0] = 1'b0;                 // lane 0's decoder stops FOREVER
            submit_batch(0, 1, 400000, o);            // enough to overfill lane 0's rx fifo
            wait_cycles(30000);
            $display("  [cyc=%0d] lane 0 is now wedged: bytes=%0d readPkgs=%0d outstanding=%0d gf=%0d",
                     cyc, ln[0].bytes_in, rp_issued, outst.size(), gfifo.size());
            b1 = ln[1].resp_done;
            // Can the OTHER lane still be served at all?
            submit_batch(1, 1, 3000, o);
            if (!o) begin
                $display("  lane 1's config beat was REFUSED while lane 0 is wedged");
                verdict = "NOT CONTAINED (config port blocked by the dead lane)";
                dump("s_e");
            end else begin
                wait_drain(200000, ok);
                $display("  [cyc=%0d] lane 1 after the wedge: %0d responses (was %0d), drained=%0b",
                         cyc, ln[1].resp_done, b1, ok);
                dump("s_e");
                if (ln[1].resp_done > b1) verdict = "CONTAINED (lane 1 still served)";
                else                      verdict = "NOT CONTAINED (whole receive path died with lane 0)";
            end
        end

        "s_f": begin                        // reconnect with entries queued / a transfer armed
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            submit_batch(0, 1, 3000, o); wait_drain(200000, ok);
            submit_batch(1, 1, 3000, o); wait_drain(200000, ok);
            $display("  [cyc=%0d] warm-up drained=%0b, lane0 session=%0d", cyc, ok, ln[0].sid);
            // arm lane 0, then FIN its peer before the response comes back
            net_allow = 0;                            // hold the response off the wire
            submit_batch(0, 1, 3000, o);
            wait_cycles(300);
            peer_close(ln[0].sid);
            net_allow = 1000000000;
            wait_cycles(20000);
            $display("  [cyc=%0d] after the FIN with a transfer armed: L0 done=%0d/%0d opens=%0d closes=%0d",
                     cyc, ln[0].resp_done, ln[0].planned_total, n_open_rsp, n_close_req);
            // the other lane must still be servable
            submit_batch(1, 1, 3000, o);
            if (!o) begin verdict = "CONFIG STALL (other lane blocked)"; dump("s_f"); end
            else begin
                wait_drain(300000, ok);
                $display("  [cyc=%0d] lane 1 drained=%0b (%0d responses)", cyc, ok, ln[1].resp_done);
                dump("s_f");
                verdict = ok ? "PASS (other lane unaffected)" : "HANG";
            end
        end

        // ---- PIPELINED ARMS: the shape the board actually runs -------------------------------------
        // One chunk entry + one GET per arm (batching off, chunk splitting off), several arms
        // outstanding at once, and NO draining between them.

        "p1": begin                        // one lane, depth swept by +DEPTH
            int depth, nresp, blen;
            depth = 4; nresp = 400; blen = 4096;
            void'($value$plusargs("DEPTH=%d", depth));
            void'($value$plusargs("NRESP=%d", nresp));
            void'($value$plusargs("BLEN=%d",  blen));
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            pipeline(1, depth, nresp, blen, ok);
            report_pipeline("p1 pipelined arms, one lane", 1, depth, ok);
            if (!ok) verdict = $sformatf("STOPPED after %0d responses / %0d bytes at cycle %0d",
                                         stop_resp, stop_bytes, stop_cycle);
            else verdict = (n_err == 0) ? "PASS" : "FAIL (byte/framing errors)";
        end

        "p3": begin                        // two lanes, both pipelined, arms interleaved
            int depth, nresp, blen;
            depth = 4; nresp = 200; blen = 4096;
            void'($value$plusargs("DEPTH=%d", depth));
            void'($value$plusargs("NRESP=%d", nresp));
            void'($value$plusargs("BLEN=%d",  blen));
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            pipeline(2, depth, nresp, blen, ok);
            report_pipeline("p3 pipelined arms, two lanes interleaved", 2, depth, ok);
            if (!ok) verdict = $sformatf("STOPPED after %0d responses / %0d bytes at cycle %0d",
                                         stop_resp, stop_bytes, stop_cycle);
            else verdict = (n_err == 0) ? "PASS" : "FAIL (byte/framing errors)";
        end

        "p4": begin                        // THE BOARD'S SHAPE: lane 1 opened but never armed
            int depth, nresp, blen;
            depth = 4; nresp = 400; blen = 4096;
            void'($value$plusargs("DEPTH=%d", depth));
            void'($value$plusargs("NRESP=%d", nresp));
            void'($value$plusargs("BLEN=%d",  blen));
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            wait_cycles(600);              // let both lanes' connections come up
            $display("  [cyc=%0d] connections opened: %0d (lane 1 will never be armed)", cyc, n_open_rsp);
            pipeline(1, depth, nresp, blen, ok);
            report_pipeline("p4 board shape, lane 1 idle", 1, depth, ok);
            if (!ok) verdict = $sformatf("STOPPED after %0d responses / %0d bytes at cycle %0d",
                                         stop_resp, stop_bytes, stop_cycle);
            else verdict = (n_err == 0) ? "PASS" : "FAIL (byte/framing errors)";
        end

        "p5": begin                        // p4 plus a FIN on the idle lane's session, mid-run
            int depth, nresp, blen, idle_sid, fire_at;
            depth = 4; nresp = 400; blen = 4096; fire_at = 60;
            void'($value$plusargs("DEPTH=%d", depth));
            void'($value$plusargs("NRESP=%d", nresp));
            void'($value$plusargs("BLEN=%d",  blen));
            void'($value$plusargs("FIREAT=%d", fire_at));
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            wait_cycles(600);
            idle_sid = find_idle_session();
            $display("  [cyc=%0d] opens=%0d, idle (never-armed) session is %0d", cyc, n_open_rsp, idle_sid);
            fork
                begin : finner
                    while (ln[0].resp_done < fire_at) @(posedge clk);
                    $display("  [cyc=%0d] lane 0 has done %0d responses; FINning the idle session %0d",
                             cyc, ln[0].resp_done, idle_sid);
                    b1 = ln[0].resp_done;
                    t0 = cyc;
                    if (idle_sid >= 0) peer_close(idle_sid);
                    wait_cycles(30000);
                    $display("  [cyc=%0d] 30k cycles after the idle FIN: lane 0 advanced %0d responses; opens=%0d closes=%0d",
                             cyc, ln[0].resp_done - b1, n_open_rsp, n_close_req);
                    if (ln[0].resp_done == b1)
                        err("the working lane made no progress across the idle lane's reconnect");
                end
            join_none
            pipeline(1, depth, nresp, blen, ok);
            report_pipeline("p5 board shape + idle-session FIN and reconnect", 1, depth, ok);
            $display("     opens=%0d closes=%0d (a reconnect of the idle lane would raise both)",
                     n_open_rsp, n_close_req);
            if (!ok) verdict = $sformatf("STOPPED after %0d responses / %0d bytes at cycle %0d",
                                         stop_resp, stop_bytes, stop_cycle);
            else verdict = (n_err == 0) ? "PASS" : "FAIL (byte/framing errors)";
        end

        // (b) long multi-packet stream on one lane; the idle lane's peer closes, then reconnects ----
        "b": begin
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            submit_batch(0, 2, 2000, o);                 // bring lane 0 up
            submit_batch(1, 6, 24000, o);                // lane 1: long, many packets each
            wait_drain(100000, ok);                      // let the first exchanges establish
            $display("  [cyc=%0d] warm-up drained=%0b lane0=%0d bytes lane1=%0d bytes",
                     cyc, ok, ln[0].bytes_in, ln[1].bytes_in);
            submit_batch(1, 8, 24000, o);                // lane 1 keeps streaming
            wait_cycles(2000);
            b1 = ln[1].bytes_in;
            peer_close(ln[0].sid);                       // the IDLE lane's peer goes away
            wait_cycles(20000);
            $display("  [cyc=%0d] 20k cycles after the idle peer's FIN: lane1 advanced %0d bytes",
                     cyc, ln[1].bytes_in - b1);
            if (ln[1].bytes_in == b1)
                err("the busy lane made no progress after the idle lane's peer closed");
            submit_batch(0, 3, 2000, o);                 // lane 0 reconnects
            if (!o) verdict = "CONFIG STALL";
            else begin
                wait_drain(600000, ok);
                if (!ok) begin verdict = "HANG"; dump("b"); end
                else if (n_err) begin verdict = "FAIL"; dump("b"); end
                else verdict = "PASS";
            end
        end

        // (c) close while notifications for that session are queued and un-issued -------------------
        "c": begin
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            submit_batch(0, 3, 6000, o);
            submit_batch(1, 3, 6000, o);
            wait_drain(200000, ok);
            $display("  [cyc=%0d] warm-up drained=%0b", cyc, ok);
            // stop lane 0's consumer so its notifications pile up UN-ISSUED, then FIN the session
            body_ready_ctl[0] = 1'b0;
            submit_batch(0, 4, 6000, o);
            submit_batch(1, 4, 6000, o);
            wait_cycles(4000);
            $display("  [cyc=%0d] before the FIN: outstanding=%0d readPkgs=%0d lane1 bytes=%0d",
                     cyc, outst.size(), rp_issued, ln[1].bytes_in);
            peer_close(ln[0].sid);
            wait_cycles(2000);
            body_ready_ctl[0] = 1'b1;                    // lane 0's consumer comes back
            wait_drain(600000, ok);
            dump("c");
            if (!ok) verdict = "HANG";
            else if (n_err) verdict = "FAIL (routing/framing violated)";
            else verdict = "PASS";
        end

        // (d) transient back-pressure on one lane, then it resumes ----------------------------------
        "d": begin
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            submit_batch(0, 6, 12000, o);
            submit_batch(1, 6, 12000, o);
            wait_cycles(500);
            body_ready_ctl[0] = 1'b0;                    // lane 0's decoder stops...
            wait_cycles(60000);                          // ...for a long but FINITE time
            $display("  [cyc=%0d] during the stall: lane0=%0d lane1=%0d readPkgs=%0d outstanding=%0d",
                     cyc, ln[0].bytes_in, ln[1].bytes_in, rp_issued, outst.size());
            body_ready_ctl[0] = 1'b1;                    // and resumes
            wait_drain(800000, ok);
            if (!ok) begin verdict = "HANG (did not recover)"; dump("d"); end
            else if (n_err) begin verdict = "FAIL"; dump("d"); end
            else begin verdict = "PASS"; dump("d"); end
        end

        // (e) one lane's consumer stops PERMANENTLY -- the containment question ---------------------
        "e": begin
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            submit_batch(0, 2, 4000, o);
            submit_batch(1, 2, 4000, o);
            wait_drain(200000, ok);
            $display("  [cyc=%0d] warm-up drained=%0b lane0=%0d lane1=%0d",
                     cyc, ok, ln[0].bytes_in, ln[1].bytes_in);
            // Arm BOTH lanes before stopping lane 0, so the measurement isolates the receive path
            // from the config port.  Lane 0 gets far more than its rx fifo can hold.
            submit_batch(0, 40, 8192, o);
            submit_batch(1, 20, 8192, o);
            body_ready_ctl[0] = 1'b0;                    // lane 0's decoder stops forever
            b1 = ln[1].bytes_in;
            t0 = cyc;
            wait_cycles(150000);
            $display("  [cyc=%0d] 150k cycles with lane 0's consumer stopped:", cyc);
            $display("     lane 0: %0d bytes, %0d/%0d responses     lane 1: %0d bytes (+%0d), %0d/%0d responses",
                     ln[0].bytes_in, ln[0].resp_done, ln[0].planned_total,
                     ln[1].bytes_in, ln[1].bytes_in - b1, ln[1].resp_done, ln[1].planned_total);
            $display("     readPkgs=%0d  outstanding notifications=%0d  shared FIFO depth=%0d",
                     rp_issued, outst.size(), gfifo.size());
            dump("e");
            if (ln[1].resp_done == ln[1].planned_total)
                verdict = "CONTAINED (the dead lane did not stop the other)";
            else if (ln[1].bytes_in > b1)
                verdict = "PARTIAL (lane 1 advanced then stopped)";
            else
                verdict = "NOT CONTAINED (the whole receive path died with the lane)";
        end

        // (f) reconnect requested with chunk entries queued / a transfer armed -----------------------
        "f": begin
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            submit_batch(0, 3, 5000, o);
            submit_batch(1, 3, 5000, o);
            wait_drain(200000, ok);
            $display("  [cyc=%0d] warm-up drained=%0b", cyc, ok);
            // queue entries + an arm for lane 0, then FIN its peer before the responses come back
            submit_batch(0, 5, 5000, o);
            if (!o) begin verdict = "CONFIG STALL (entries)"; dump("f"); end
            else begin
                wait_cycles(300);
                peer_close(ln[0].sid);
                wait_cycles(3000);
                $display("  [cyc=%0d] after the FIN with entries queued: lane0 done=%0d/%0d, readPkgs=%0d",
                         cyc, ln[0].resp_done, ln[0].planned_total, rp_issued);
                submit_batch(1, 3, 5000, o);            // the other lane must still be servable
                if (!o) begin verdict = "CONFIG STALL (other lane blocked by the reconnect)"; dump("f"); end
                else begin
                    submit_batch(0, 3, 5000, o);        // and lane 0 reconnects
                    if (!o) begin verdict = "CONFIG STALL (reconnect arm)"; dump("f"); end
                    else begin
                        wait_drain(600000, ok);
                        dump("f");
                        if (!ok) verdict = "HANG";
                        else if (n_err) verdict = "FAIL";
                        else verdict = "PASS";
                    end
                end
            end
        end

        // (g) response boundaries exactly on packet boundaries, and bodies split across many packets -
        "g": begin
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 1024;
            // 1024-byte bodies: header + body straddles, then exact multiples
            submit_batch(0, 4, 1024, o);
            submit_batch(1, 4, 16384, o);               // 16 packets per body
            wait_drain(600000, ok);
            if (!ok) begin verdict = "HANG"; dump("g"); end
            else if (n_err) begin verdict = "FAIL"; dump("g"); end
            else begin
                mss = 64;                                // one beat per packet: maximum fragmentation
                submit_batch(0, 2, 512, o);
                submit_batch(1, 2, 512, o);
                wait_drain(600000, ok);
                if (!ok) begin verdict = "HANG (at mss=64)"; dump("g"); end
                else if (n_err) begin verdict = "FAIL"; dump("g"); end
                else verdict = "PASS";
            end
        end

        // (h) back-to-back responses, >= 64 notifications in flight ---------------------------------
        "h": begin
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            net_paced = 1'b0;                            // no gap between packets at all
            submit_batch(0, 40, 4096, o);
            submit_batch(1, 40, 4096, o);
            if (!o) begin verdict = "CONFIG STALL"; dump("h"); end
            else begin
                wait_drain(1500000, ok);
                dump("h");
                if (!ok) verdict = "HANG";
                else if (n_err) verdict = "FAIL";
                else verdict = "PASS";
            end
        end

        default: begin $display("unknown scenario '%s'", scen); $finish; end
        endcase

        wait_cycles(50);
        check_sticky();
        $display("\n------------------------------------------------------------------");
        $display("lane_drain_tb '%s' (NUM_CONNS=%0d): %s", scen, NUM_CONNS, verdict);
        $display("  errors=%0d  liveness_failed=%0b(cyc %0d)  config_stalled=%0b(cyc %0d)",
                 n_err, liveness_failed, liveness_cycle, cfg_stalled, cfg_stall_cycle);
        for (int i = 0; i < NUM_CONNS; i++)
            $display("  lane %0d: %0d/%0d responses framed, %0d body bytes, session %0d",
                     i, ln[i].resp_done, ln[i].planned_total, ln[i].bytes_in, ln[i].sid);
        $display("  readPkgs=%0d notifications=%0d outstanding=%0d sharedFIFO=%0d opens=%0d closes=%0d",
                 rp_issued, n_notif_sent, outst.size(), gfifo.size(), n_open_rsp, n_close_req);
        $display("------------------------------------------------------------------\n");
        $finish;
    end

    initial begin
        wait (rst_n === 1'b1);
        repeat (MAX_CYCLES) @(posedge clk);
        $display("!!! global watchdog fired at %0d cycles", cyc);
        dump("watchdog");
        $display("lane_drain_tb '%s': WATCHDOG", scen);
        $finish;
    end

endmodule
