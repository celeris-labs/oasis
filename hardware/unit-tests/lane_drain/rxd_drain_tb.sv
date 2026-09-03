`timescale 1ns / 1ps
// =================================================================================================
// rxd_drain_tb -- INDEPENDENT black-box liveness bench for rx_dispatch.
//
// Written against the external contract only.  Nothing below rx_dispatch's port list was read.
//
// TOE model, exactly as the contract describes it:
//   * ONE shared packet FIFO, delivered in GLOBAL ARRIVAL ORDER across all sessions;
//   * one readPkg pops exactly one packet -- whatever session it belongs to.  The readPkg does NOT
//     select the session; rx_metadata names the session of the packet actually delivered;
//   * the data output never stalls;
//   * the notification interface is shared and must not be held off.
//
// Invariant: while a notification is outstanding, a readPkg must appear within LIVENESS_BOUND
// cycles.  A bounded delay behind a busy lane is legal.  A permanent one is not.
// =================================================================================================
import lynxTypes::*;

module rxd_drain_tb;

    localparam int NUM_CONNS      = 2;
    localparam int NOTIFY_DEPTH   = 64;
    localparam int CONN_BITS      = (NUM_CONNS > 1) ? $clog2(NUM_CONNS) : 1;
    localparam int BPB            = AXI_DATA_BITS/8;
    localparam int LIVENESS_BOUND = 100000;
    localparam int MAX_CYCLES     = 1000000;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #2ns clk = ~clk;

    int cyc = 0;
    always @(posedge clk) cyc = cyc + 1;

    // ---------------------------------------------------------------------------------------------
    // DUT wiring
    // ---------------------------------------------------------------------------------------------
    logic                       n_tvalid;
    logic                       n_tready;
    logic [TCP_NOTIFY_BITS-1:0] n_tdata;

    logic                        bind_en;
    logic [CONN_BITS-1:0]        bind_conn;
    logic [TCP_SESSION_BITS-1:0] bind_sid;
    logic                        release_en;
    logic [CONN_BITS-1:0]        release_conn;

    logic                           rp_tvalid;
    logic                           rp_tready;
    logic [TCP_RD_PKG_REQ_BITS-1:0] rp_tdata;

    logic                        rm_tvalid;
    logic                        rm_tready;
    logic [TCP_RX_META_BITS-1:0] rm_tdata;

    logic                       rd_tvalid;
    logic                       rd_tready;
    logic [AXI_DATA_BITS-1:0]   rd_tdata;
    logic [AXI_DATA_BITS/8-1:0] rd_tkeep;
    logic                       rd_tlast;

    logic [NUM_CONNS-1:0]       conn_tvalid;
    logic [NUM_CONNS-1:0]       conn_tready;
    logic [AXI_DATA_BITS-1:0]   conn_tdata;
    logic [AXI_DATA_BITS/8-1:0] conn_tkeep;
    logic                       conn_tlast;

    logic [NUM_CONNS-1:0]       conn_space_ok;
    logic [NUM_CONNS-1:0]       conn_closed;
    logic [NUM_CONNS-1:0]       dbg_has_pending;
    logic                       dbg_overflow;
    logic                       dbg_route_stall;

    rx_dispatch #(
        .NUM_CONNS   (NUM_CONNS),
        .NOTIFY_DEPTH(NOTIFY_DEPTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_notifications_TVALID(n_tvalid),
        .s_axis_notifications_TREADY(n_tready),
        .s_axis_notifications_TDATA (n_tdata),
        .bind_en(bind_en), .bind_conn(bind_conn), .bind_sid(bind_sid),
        .release_en(release_en), .release_conn(release_conn),
        .m_axis_read_package_TVALID(rp_tvalid),
        .m_axis_read_package_TREADY(rp_tready),
        .m_axis_read_package_TDATA (rp_tdata),
        .s_axis_rx_metadata_TVALID(rm_tvalid),
        .s_axis_rx_metadata_TREADY(rm_tready),
        .s_axis_rx_metadata_TDATA (rm_tdata),
        .s_axis_rx_data_TVALID(rd_tvalid),
        .s_axis_rx_data_TREADY(rd_tready),
        .s_axis_rx_data_TDATA (rd_tdata),
        .s_axis_rx_data_TKEEP (rd_tkeep),
        .s_axis_rx_data_TLAST (rd_tlast),
        .conn_tvalid(conn_tvalid), .conn_tready(conn_tready),
        .conn_tdata (conn_tdata),  .conn_tkeep (conn_tkeep), .conn_tlast(conn_tlast),
        .conn_space_ok(conn_space_ok), .conn_closed(conn_closed),
        .dbg_has_pending(dbg_has_pending),
        .dbg_overflow(dbg_overflow), .dbg_route_stall(dbg_route_stall)
    );

    // ---------------------------------------------------------------------------------------------
    // Wire encodings.  Coyote lynx_pkg ground truth (packed struct: first member in the MSBs):
    //   tcp_notify_t : {rsrvd[5:0], opened, closed, dst_port[15:0], ip[31:0], len[15:0], sid[15:0]}
    //   tcp_rd_pkg_t : {len[15:0], sid[15:0]}
    //   rx metadata  : sid[15:0]  (TOE writes ap_uint<16> sessionID; TCP_RX_META_BITS == 16)
    // ---------------------------------------------------------------------------------------------
    function automatic logic [TCP_NOTIFY_BITS-1:0] pack_notif(int sid, int len, bit closed);
        logic [TCP_NOTIFY_BITS-1:0] w;
        w        = '0;
        w[15:0]  = 16'(sid);
        w[31:16] = 16'(len);
        w[63:32] = 32'h0A00_0001;
        w[79:64] = 16'd80;
        w[80]    = closed;
        return w;
    endfunction
    function automatic int rp_sid(logic [TCP_RD_PKG_REQ_BITS-1:0] w); return int'(w[15:0]);  endfunction
    function automatic int rp_len(logic [TCP_RD_PKG_REQ_BITS-1:0] w); return int'(w[31:16]); endfunction

    // ---------------------------------------------------------------------------------------------
    // Model state
    // ---------------------------------------------------------------------------------------------
    class Pkt;   int sid; int tag; byte unsigned d[$]; endclass
    class Notif; int sid; int len; bit closed;         endclass
    class RPkg;  int sid; int len; int at;             endclass
    class Blob;  byte unsigned d[$];                   endclass

    Pkt   gfifo[$];      // the ONE shared arrival-order packet FIFO
    Notif nq[$];         // notifications not yet presented on the wire
    Notif outst[$];      // presented, not yet answered by a readPkg
    RPkg  unmatched[$];  // readPkgs still looking for their notification

    int rp_issued  = 0;  // written only by the readPkg sink
    int pkt_taken  = 0;  // written only by the delivery engine
    int n_notif_sent = 0, n_notif_data = 0;
    int notif_bp_cycles = 0, rxdata_bp_cycles = 0;
    int idle_since_rp = 0;

    int lane_of_sid[int];
    int sid_of_lane[NUM_CONNS];
    Blob lane_exp[NUM_CONNS];
    int  lane_bytes[NUM_CONNS];

    int    n_err = 0;
    string verdict = "";
    bit    liveness_failed = 0;
    int    liveness_cycle  = 0;

    function automatic void err(string s);
        n_err = n_err + 1;
        if (n_err <= 30) $display("  [cyc=%0d] *** ERROR: %s", cyc, s);
    endfunction

    function automatic byte unsigned pbyte(int sid, int tag, int idx);
        return byte'((sid*137 + tag*29 + idx*7 + (idx/251)*61) & 32'hFF);
    endfunction

    // ---------------------------------------------------------------------------------------------
    // TOE: notification driver.  The bench never holds this interface off.
    // ---------------------------------------------------------------------------------------------
    initial begin : notif_driver
        Notif nn;
        n_tvalid = 1'b0; n_tdata = '0;
        forever begin
            @(posedge clk);
            if (!rst_n) begin
                n_tvalid <= 1'b0;
            end else if (n_tvalid && n_tready) begin
                nn = nq.pop_front();
                outst.push_back(nn);
                n_notif_sent = n_notif_sent + 1;
                if (nn.len > 0) n_notif_data = n_notif_data + 1;
                if (nq.size() > 0) begin
                    n_tdata  <= pack_notif(nq[0].sid, nq[0].len, nq[0].closed);
                    n_tvalid <= 1'b1;
                end else n_tvalid <= 1'b0;
            end else if (!n_tvalid && nq.size() > 0) begin
                n_tdata  <= pack_notif(nq[0].sid, nq[0].len, nq[0].closed);
                n_tvalid <= 1'b1;
            end
        end
    end

    always @(posedge clk) if (rst_n && n_tvalid && !n_tready) notif_bp_cycles = notif_bp_cycles + 1;

    // ---------------------------------------------------------------------------------------------
    // TOE: readPkg sink (always ready) + a matcher that tolerates same-cycle notification arrival.
    // ---------------------------------------------------------------------------------------------
    assign rp_tready = 1'b1;

    always @(posedge clk) begin : rp_sink
        RPkg r;
        int  i, hit;
        if (rst_n) begin
            if (rp_tvalid && rp_tready) begin
                rp_issued     = rp_issued + 1;
                idle_since_rp = 0;
                if (rp_len(rp_tdata) == 0)
                    err($sformatf("readPkg with length 0 (sid=%0d): the real TOE's datamover hangs on this",
                                  rp_sid(rp_tdata)));
                r = new(); r.sid = rp_sid(rp_tdata); r.len = rp_len(rp_tdata); r.at = cyc;
                unmatched.push_back(r);
            end else begin
                idle_since_rp = idle_since_rp + 1;
            end
            // match outstanding readPkgs against outstanding notifications
            i = 0;
            while (i < unmatched.size()) begin
                hit = -1;
                for (int j = 0; j < outst.size(); j++)
                    if (hit < 0 && outst[j].sid == unmatched[i].sid && outst[j].len == unmatched[i].len)
                        hit = j;
                if (hit >= 0) begin
                    outst.delete(hit);
                    unmatched.delete(i);
                end else if ((cyc - unmatched[i].at) > 100) begin
                    err($sformatf("readPkg(sid=%0d,len=%0d) matches no notification the TOE ever sent",
                                  unmatched[i].sid, unmatched[i].len));
                    unmatched.delete(i);
                end else i = i + 1;
            end
        end
    end

    // ---------------------------------------------------------------------------------------------
    // TOE: packet delivery.  One readPkg -> the HEAD of the shared FIFO, regardless of session.
    // ---------------------------------------------------------------------------------------------
    int deliver_lane = -1;

    initial begin : deliver_engine
        Pkt p; int i, nb, k;
        logic [AXI_DATA_BITS-1:0]   dw;
        logic [AXI_DATA_BITS/8-1:0] kw;
        rm_tvalid = 0; rm_tdata = '0; rd_tvalid = 0; rd_tdata = '0; rd_tkeep = '0; rd_tlast = 0;
        forever begin
            @(posedge clk);
            if (rst_n && (rp_issued - pkt_taken) > 0 && gfifo.size() > 0) begin
                p = gfifo.pop_front();
                pkt_taken = pkt_taken + 1;
                deliver_lane = lane_of_sid.exists(p.sid) ? lane_of_sid[p.sid] : -1;
                rm_tdata  <= TCP_RX_META_BITS'(p.sid);
                rm_tvalid <= 1'b1;
                do @(posedge clk); while (!rm_tready);
                rm_tvalid <= 1'b0;
                i = 0;
                while (i < p.d.size()) begin
                    nb = (p.d.size() - i > BPB) ? BPB : (p.d.size() - i);
                    dw = '0; kw = '0;
                    for (k = 0; k < nb; k++) begin dw[k*8 +: 8] = p.d[i+k]; kw[k] = 1'b1; end
                    rd_tdata <= dw; rd_tkeep <= kw;
                    rd_tlast <= ((i + nb) >= p.d.size());
                    rd_tvalid <= 1'b1;
                    do @(posedge clk); while (!rd_tready);
                    i = i + nb;
                end
                rd_tvalid <= 1'b0; rd_tlast <= 1'b0;
            end
        end
    end

    always @(posedge clk) if (rst_n && rd_tvalid && !rd_tready) rxdata_bp_cycles = rxdata_bp_cycles + 1;

    // ---------------------------------------------------------------------------------------------
    // Lane-side monitor: routing (property 2) + byte-exactness
    // ---------------------------------------------------------------------------------------------
    genvar gl;
    generate
        for (gl = 0; gl < NUM_CONNS; gl++) begin : g_mon
            always @(posedge clk) begin : mon
                int b; byte unsigned got, want;
                if (rst_n && conn_tvalid[gl] && conn_tready[gl]) begin
                    if (deliver_lane >= 0 && deliver_lane != gl)
                        err($sformatf("MISROUTE: a beat owed to lane %0d appeared on lane %0d",
                                      deliver_lane, gl));
                    for (b = 0; b < BPB; b++) begin
                        if (conn_tkeep[b]) begin
                            got = conn_tdata[b*8 +: 8];
                            lane_bytes[gl] = lane_bytes[gl] + 1;
                            if (lane_exp[gl].d.size() == 0)
                                err($sformatf("lane %0d received a byte it was not owed", gl));
                            else begin
                                want = lane_exp[gl].d.pop_front();
                                if (got !== want)
                                    err($sformatf("lane %0d byte mismatch: got %02h want %02h",
                                                  gl, got, want));
                            end
                        end
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

    // ---------------------------------------------------------------------------------------------
    // LIVENESS monitor (property 1)
    // ---------------------------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && !liveness_failed && outst_data() > 0 && idle_since_rp > LIVENESS_BOUND) begin
            liveness_failed = 1'b1;
            liveness_cycle  = cyc;
            $display("  [cyc=%0d] *** LIVENESS: %0d data notification(s) outstanding, no readPkg for %0d cycles",
                     cyc, outst_data(), idle_since_rp);
        end
    end

    // ---------------------------------------------------------------------------------------------
    // Stimulus helpers
    // ---------------------------------------------------------------------------------------------
    task automatic net_pkt(int sid, int tag, int nbytes);
        Pkt p; Notif nn; int i;
        p = new(); p.sid = sid; p.tag = tag;
        for (i = 0; i < nbytes; i++) p.d.push_back(pbyte(sid, tag, i));
        gfifo.push_back(p);
        nn = new(); nn.sid = sid; nn.len = nbytes; nn.closed = 1'b0;
        nq.push_back(nn);
        if (lane_of_sid.exists(sid))
            for (i = 0; i < nbytes; i++) lane_exp[lane_of_sid[sid]].d.push_back(p.d[i]);
    endtask

    task automatic net_close(int sid);
        Notif nn;
        nn = new(); nn.sid = sid; nn.len = 0; nn.closed = 1'b1;
        nq.push_back(nn);
    endtask

    task automatic do_bind(int lane, int sid);
        @(posedge clk);
        bind_conn <= CONN_BITS'(lane); bind_sid <= TCP_SESSION_BITS'(sid); bind_en <= 1'b1;
        @(posedge clk);
        bind_en <= 1'b0;
        lane_of_sid[sid] = lane; sid_of_lane[lane] = sid;
        @(posedge clk);
    endtask

    task automatic do_release(int lane);
        @(posedge clk);
        release_conn <= CONN_BITS'(lane); release_en <= 1'b1;
        @(posedge clk);
        release_en <= 1'b0;
        @(posedge clk);
    endtask

    task automatic wait_cycles(int n); repeat (n) @(posedge clk); endtask

    function automatic bit all_drained();
        bit ok;
        ok = (nq.size() == 0) && (outst_data() == 0) && (gfifo.size() == 0);
        for (int i = 0; i < NUM_CONNS; i++) if (lane_exp[i].d.size() != 0) ok = 0;
        return ok;
    endfunction

    task automatic wait_drain(int bound, output bit ok);
        int t0; t0 = cyc; ok = 0;
        while ((cyc - t0) < bound) begin
            @(posedge clk);
            if (all_drained())  begin ok = 1; return; end
            if (liveness_failed) begin ok = 0; return; end
        end
    endtask

    task automatic dump(string tag);
        $display("  ---- state dump [%s] at cycle %0d ----", tag, cyc);
        $display("     notifications: presented=%0d (data=%0d)  outstanding=%0d  not-yet-presented=%0d",
                 n_notif_sent, n_notif_data, outst.size(), nq.size());
        for (int i = 0; i < outst.size() && i < 8; i++)
            $display("       outstanding[%0d]: sid=%0d len=%0d closed=%0b",
                     i, outst[i].sid, outst[i].len, outst[i].closed);
        $display("     readPkgs issued=%0d  packets delivered=%0d  shared FIFO depth=%0d",
                 rp_issued, pkt_taken, gfifo.size());
        $display("     cycles since the last readPkg = %0d", idle_since_rp);
        for (int i = 0; i < NUM_CONNS; i++)
            $display("       lane %0d: sid=%0d space_ok=%0b tready=%0b closed=%0b has_pending=%0b bytes_in=%0d still_owed=%0d",
                     i, sid_of_lane[i], conn_space_ok[i], conn_tready[i], conn_closed[i],
                     dbg_has_pending[i], lane_bytes[i], lane_exp[i].d.size());
        $display("     dbg_overflow=%0b dbg_route_stall=%0b  notif-backpressure=%0d cyc  rxdata-backpressure=%0d cyc",
                 dbg_overflow, dbg_route_stall, notif_bp_cycles, rxdata_bp_cycles);
        $display("  ------------------------------------------");
    endtask

    // ---------------------------------------------------------------------------------------------
    // Scenarios
    // ---------------------------------------------------------------------------------------------
    string scen;

    task automatic reset_all();
        rst_n = 1'b0;
        bind_en = 0; bind_conn = '0; bind_sid = '0; release_en = 0; release_conn = '0;
        conn_tready = '1; conn_space_ok = '1;
        for (int i = 0; i < NUM_CONNS; i++) begin
            lane_exp[i] = new(); lane_bytes[i] = 0; sid_of_lane[i] = -1;
        end
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);
    endtask

    initial begin : main
        bit ok;
        if (!$value$plusargs("SCEN=%s", scen)) scen = "r1";
        $display("\n==================================================================");
        $display("rxd_drain_tb  scenario '%s'  NUM_CONNS=%0d  liveness bound=%0d cycles",
                 scen, NUM_CONNS, LIVENESS_BOUND);
        $display("==================================================================");

        reset_all();

        case (scen)

        "r1": begin  // baseline: two bound lanes, interleaved arrival, everything must drain
            do_bind(0, 1); do_bind(1, 2); wait_cycles(5);
            for (int r = 0; r < 8; r++) begin
                net_pkt(1, r, 4096);
                net_pkt(2, r, 4096);
            end
            wait_drain(200000, ok);
            if (!ok) begin verdict = "HANG"; dump("r1"); end
            else if (n_err) verdict = "FAIL (checker errors)";
            else verdict = "PASS";
        end

        "r2": begin
            // THE CONTAINMENT QUESTION, minimal form -- TWO external events.
            // Lane 0 can never accept another MSS.  Lane 1 is healthy.
            //   event 1: one packet arrives for lane 0's session
            //   event 2: one packet arrives for lane 1's session
            // Lane 1's packet sitting behind lane 0's is a legal DELAY.  Is it a permanent one?
            do_bind(0, 1); do_bind(1, 2); wait_cycles(5);
            conn_space_ok[0] = 1'b0;              // lane 0's fifo is full, forever
            wait_cycles(5);
            net_pkt(1, 0, 4096);                  // event 1: for the dead lane
            net_pkt(2, 0, 4096);                  // event 2: for the healthy lane
            wait_drain(LIVENESS_BOUND + 20000, ok);
            dump("r2");
            verdict = (lane_exp[1].d.size() == 0) ? "CONTAINED  (lane 1 drained anyway)"
                                                  : "NOT CONTAINED  (lane 1 permanently starved)";
        end

        "r3": begin
            // Same dead lane, but it has NO traffic at all.  Only lane 1 has packets.
            do_bind(0, 1); do_bind(1, 2); wait_cycles(5);
            conn_space_ok[0] = 1'b0;
            wait_cycles(5);
            for (int r = 0; r < 4; r++) net_pkt(2, r, 4096);
            wait_drain(200000, ok);
            dump("r3");
            verdict = (lane_exp[1].d.size() == 0) ? "PASS (an idle dead lane does not block a healthy one)"
                                                  : "HANG (an idle dead lane blocks a healthy one)";
        end

        "r4": begin  // transient block on lane 0, then it clears
            do_bind(0, 1); do_bind(1, 2); wait_cycles(5);
            conn_space_ok[0] = 1'b0;
            for (int r = 0; r < 4; r++) begin net_pkt(1, r, 4096); net_pkt(2, r, 4096); end
            wait_cycles(20000);
            $display("  during the block: lane0=%0d bytes, lane1=%0d bytes, readPkgs=%0d",
                     lane_bytes[0], lane_bytes[1], rp_issued);
            conn_space_ok[0] = 1'b1;              // transient clears
            wait_drain(200000, ok);
            if (!ok) begin verdict = "HANG (no recovery)"; dump("r4"); end
            else if (n_err) verdict = "FAIL (checker errors)";
            else begin verdict = "PASS"; dump("r4"); end
        end

        "r5": begin
            // Release a lane while notifications for its session are queued and un-issued.
            do_bind(0, 1); do_bind(1, 2); wait_cycles(5);
            conn_space_ok[0] = 1'b0;              // pile up un-issued notifications for lane 0
            net_pkt(1, 0, 4096);
            net_pkt(1, 1, 4096);
            net_pkt(2, 0, 4096);
            wait_cycles(200);
            $display("  before release: readPkgs=%0d outstanding=%0d lane1 bytes=%0d",
                     rp_issued, outst.size(), lane_bytes[1]);
            do_release(0);                        // the handler drops the session
            conn_space_ok[0] = 1'b1;
            wait_drain(200000, ok);
            $display("  after release: lane0=%0d bytes, lane1=%0d bytes (owed %0d), readPkgs=%0d",
                     lane_bytes[0], lane_bytes[1], lane_exp[1].d.size(), rp_issued);
            dump("r5");
            verdict = (lane_exp[1].d.size() == 0) ? "PASS (release freed the queue)"
                                                  : "HANG (release did not free the queue)";
        end

        "r6": begin
            // Property 2, hard.  A session is RELEASED and the lane RECONNECTED to a new session
            // while the old session's packets are still queued and un-issued in the shared FIFO.
            // Those stale bytes must not be spliced into the new connection's byte stream.
            do_bind(0, 1); do_bind(1, 2); wait_cycles(5);
            conn_space_ok[0] = 1'b0;
            net_pkt(1, 0, 4096);                  // stale data for the OLD session, un-issued
            net_pkt(1, 1, 4096);
            wait_cycles(200);
            do_release(0);
            lane_of_sid.delete(1);
            lane_exp[0].d = {};                   // lane 0 is owed nothing from the dead session
            do_bind(0, 3);                        // reconnect: lane 0 now carries session 3
            conn_space_ok[0] = 1'b1;
            net_pkt(3, 0, 4096);                  // the new connection's first packet
            net_pkt(2, 0, 4096);
            wait_drain(200000, ok);
            $display("  lane0 bytes=%0d (owed %0d), lane1 bytes=%0d (owed %0d), readPkgs=%0d",
                     lane_bytes[0], lane_exp[0].d.size(), lane_bytes[1], lane_exp[1].d.size(), rp_issued);
            dump("r6");
            if (!ok)          verdict = "HANG";
            else if (n_err)   verdict = "FAIL (stale session bytes spliced into the reconnected lane)";
            else              verdict = "PASS";
        end

        "r7": begin
            // Notification queue pressure.  A blocked lane holds the head of the queue while the
            // peer keeps sending, so more than NOTIFY_DEPTH announcements pile up.  Are any lost?
            do_bind(0, 1); do_bind(1, 2); wait_cycles(5);
            conn_space_ok[0] = 1'b0;
            for (int r = 0; r < 70; r++) net_pkt(1, r, 1024);
            wait_cycles(3000);
            $display("  while blocked: presented=%0d outstanding=%0d dbg_overflow=%0b readPkgs=%0d",
                     n_notif_sent, outst.size(), dbg_overflow, rp_issued);
            conn_space_ok[0] = 1'b1;              // the block clears
            wait_drain(300000, ok);
            $display("  after recovery: lane0 bytes=%0d (owed %0d), readPkgs=%0d, sharedFIFO=%0d",
                     lane_bytes[0], lane_exp[0].d.size(), rp_issued, gfifo.size());
            dump("r7");
            if (dbg_overflow) verdict = "OVERFLOW (announcements dropped; the shared FIFO can never drain)";
            else if (!ok)     verdict = "HANG";
            else if (n_err)   verdict = "FAIL";
            else              verdict = "PASS";
        end

        default: begin $display("unknown scenario '%s'", scen); $finish; end
        endcase

        wait_cycles(20);
        $display("\n------------------------------------------------------------------");
        $display("rxd_drain_tb '%s': %s", scen, verdict);
        $display("  errors=%0d  liveness_failed=%0b (cycle %0d)", n_err, liveness_failed, liveness_cycle);
        $display("  readPkgs=%0d  notifications=%0d (data %0d)  outstanding=%0d  sharedFIFO=%0d",
                 rp_issued, n_notif_sent, n_notif_data, outst.size(), gfifo.size());
        $display("  notif-backpressure=%0d cyc   rx_data-backpressure=%0d cyc",
                 notif_bp_cycles, rxdata_bp_cycles);
        $display("------------------------------------------------------------------\n");
        $finish;
    end

    initial begin
        wait (rst_n === 1'b1);
        repeat (MAX_CYCLES) @(posedge clk);
        $display("!!! global watchdog fired at %0d cycles", cyc);
        dump("watchdog");
        $finish;
    end

endmodule
