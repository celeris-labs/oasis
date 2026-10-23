`timescale 1ns / 1ps
// =================================================================================================
// lane_drain_tb -- black-box liveness bench for handler_multi AND handler_toe.
//
// Written against the external contract: the handlers' ports, the TOE's interfaces and the CSR
// map. Nothing below the port list is modelled or assumed.
//
// TWO DUTs, ONE BENCH
// -------------------
// DUT_TOE selects which handler is instantiated: handler_multi against the bypass TOE model (one
// shared packet FIFO, below), or handler_toe against the NON-BYPASS TOE MODEL (a receive ring per
// session).  The origin server, the host and the decoder sinks are IDENTICAL, which is the point:
// the scenarios are the contract.
//
// WHAT THE HOST HAS TO DO DIFFERENTLY, AND WHY
// --------------------------------------------
// handler_toe takes ONE GET PER ARM, so with DUT_TOE=1 a batch of N GETs becomes N arms of one GET
// each, issued by a per-lane FEEDER process that keeps at most +HDEPTH chunks (4) outstanding on
// its lane.  +SRVLAT gives the origin a request->response latency so pipelining has something to
// hide; +COALESCE lets responses share TCP segments.
//
// The feeder is asynchronous on purpose.  submit_batch returns as soon as the work is queued rather
// than when the last GET has been armed, so a scenario that says "queue six responses on this lane
// and then stop its decoder" still means that -- if submit_batch blocked until the sixth arm was
// accepted, the whole batch would have drained before the scenario got to stop anything, and d, e,
// s_d and s_e would all quietly stop testing what they were written to test.
//
// handler_multi's runs are unaffected: with DUT_TOE=0 the host model is exactly what it was.
//
// The bench is the whole outside world:
//   * TOE  : connection opens, a shared notification interface, and ONE shared packet FIFO
//            delivered in GLOBAL ARRIVAL ORDER.  One readPkg pops one packet, whatever session it
//            belongs to, and rx_metadata ECHOES THE READPKG'S session id, unchecked -- as the real
//            one does (rx_app_stream_if.cpp writes the request's rxSar.sessionID).  A readPkg that
//            pops another session's packet therefore hands it over labelled as the requester's;
//            every such pop is counted as an error.  Data never stalls.
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
    parameter int RX_FIFO_DEPTH = 2048,
    // The handler's connect watchdog, in cycles: it raises the sticky conn_stall bit. Left at the
    // DUT's own default for every scenario but 'lz2', which has to WAIT for it -- 2^28 cycles is a
    // second of wall clock on the board and a week in xsim, so that one scenario gets its own
    // snapshot with a small value.
    parameter int STALL_CYCLES  = 268435456,

    // 1 = handler_toe (the TOE with a receive ring per session, RX_DDR_BYPASS = 0), against the
    // NON-BYPASS TOE MODEL below instead of the shared-fifo one.
    parameter int DUT_TOE = 0,
    // handler_toe's FIN settle, exposed so a mutant can be run (fin_overtake must fail at ~200).
    parameter int TOE_CLOSE_SETTLE = 4096,
    // handler_toe's FRAMER_SLICE, exposed so the variant without the framer slice can be run.
    parameter bit TOE_FRAMER_SLICE = 1'b1
);
    localparam int  NL     = NUM_CONNS;   // lanes: lane L = connection L = decoder L
    // The host model for handler_toe: one GET per arm, through the feeder.
    localparam bit FEEDER = (DUT_TOE != 0);

    localparam int BPB            = AXI_DATA_BITS/8;
    localparam longint TOE_RING   = longint'(1) << 20;   // the non-bypass TOE's ring per session
    localparam int LIVENESS_BOUND = 100000;   // cycles without a readPkg while work is queued
    // Variables rather than localparams: at the real time scale a host can legitimately wait longer
    // than 200k cycles for a connection (MinIO holds one for ~2.5 ms = 600k cycles), and a run is
    // longer than 4M cycles. +CFGBOUND= +MAXCYC=.
    int CFG_BOUND  = 200000;                  // cycles waiting for req_ready
    int MAX_CYCLES = 4000000;
    initial begin
        void'($value$plusargs("CFGBOUND=%d", CFG_BOUND));
        void'($value$plusargs("MAXCYC=%d",   MAX_CYCLES));
    end
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

    logic [NL-1:0]       rq_tvalid, rq_tready, rq_tlast;
    logic [AXI_DATA_BITS-1:0]   rq_tdata [NL];
    logic [AXI_DATA_BITS/8-1:0] rq_tkeep [NL];

    logic [NL-1:0]       bd_tvalid, bd_tready, bd_tlast;
    logic [AXI_DATA_BITS-1:0]   bd_tdata [NL];
    logic [AXI_DATA_BITS/8-1:0] bd_tkeep [NL];

    logic [31:0] totalWord, inflightWord, queueDepthWord, stallWord, respWord,
                 contentLengthWord, bodyRemainingWord;
    logic [3:0]  state_debug;
    // Per-lane readback, CSR revision 2. See the map in http_config.sv.
    logic [63:0] laneOccWord, laneReadyWord, laneStateWord, laneErrWord, lanePolicyWord;

    // laneErrWord[8L+0]: rx_dispatch's head-of-line watchdog killed lane L. Latched in
    // handler_multi rather than read from rx_dispatch, because the handler's response to a dead
    // lane is to release the session -- which clears rx_dispatch's own dead bit.
    function automatic bit lane_dead_sticky(input int L); return laneErrWord[8*L + 0]; endfunction

    // laneReadyWord nibble per lane: {fatal, conn_up, entry_ready, arm_ready}. conn_up is the bit
    // the lazy-open scenarios ask about -- "does this lane hold a TCP session right now" is not
    // otherwise visible from outside, and it is the whole difference between a lane that was
    // reconnected behind the host's back and one that is honestly down waiting for work.
    function automatic bit lane_conn_up(input int L);  return laneReadyWord[4*L + 2]; endfunction
    function automatic bit lane_is_fatal(input int L); return laneReadyWord[4*L + 3]; endfunction
    // laneErrWord[8L+2]: an open on lane L was refused (openStatus success = 0), sticky.
    function automatic bit lane_init_err(input int L); return laneErrWord[8*L + 2]; endfunction

    generate
    if (DUT_TOE != 0) begin : g_toe

    handler_toe #(
        .NUM_CONNS    (NL),
        .QUEUE_DEPTH  (QUEUE_DEPTH),
        .RX_FIFO_DEPTH(RX_FIFO_DEPTH),
        .STALL_CYCLES (STALL_CYCLES),
        .CLOSE_SETTLE (TOE_CLOSE_SETTLE),
        .FRAMER_SLICE (TOE_FRAMER_SLICE)
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
        .bodyRemainingWord(bodyRemainingWord), .state_debug(state_debug),
        .laneOccWord(laneOccWord), .laneReadyWord(laneReadyWord), .laneStateWord(laneStateWord),
        .laneErrWord(laneErrWord), .lanePolicyWord(lanePolicyWord)
    );

    end else begin : g_multi

    handler_multi #(
        .NUM_CONNS    (NL),
        .QUEUE_DEPTH  (QUEUE_DEPTH),
        .RX_FIFO_DEPTH(RX_FIFO_DEPTH),
        .STALL_CYCLES (STALL_CYCLES)
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
        .bodyRemainingWord(bodyRemainingWord), .state_debug(state_debug),
        .laneOccWord(laneOccWord), .laneReadyWord(laneReadyWord), .laneStateWord(laneStateWord),
        .laneErrWord(laneErrWord), .lanePolicyWord(lanePolicyWord)
    );

    end
    endgenerate

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
    class SReq;  int lane; int seq; int len; int arrive; endclass   // +SRVSER: a request the origin holds

    class Sess;
        int  sid;
        bit  alive;
        int  lane;                 // discovered from the GET path; -1 until then
        byte unsigned rx[$];       // request bytes received from the DUT
        int  scanp;
        byte unsigned pending[$];  // response bytes waiting to go on the wire
        int  wr[$];                // sizes of the server's individual send() calls
        int  wr_left;
        int  last_rel;             // +SRVLAT: cycle the previous response was released
        // +SRVSER: requests received and not yet answered, served ONE AT A TIME (see srv_ser).
        SReq srvq[$];
        int  ttfb_due;             // cycle the head request's first byte is due; 0 = not scheduled
        bit  busy_resp;            // a released response still has bytes waiting for the wire
        int  idle_since;           // cycle the previous response finished leaving
        longint credit;            // +SRVRATE token bucket, milli-bytes
        // -- NON-BYPASS TOE MODEL (DUT_TOE) only ------------------------------------------------
        byte unsigned ring[$];     // bytes in the session's receive ring, not yet read out
        longint occ;               // ring occupancy: written and not yet released (fix #12: a read's
                                   // bytes are released when its last beat leaves the TOE)
        longint occ_max;
        longint notified;          // bytes announced to the DUT (at the notification handshake)
        longint requested;         // bytes the DUT asked for with readPkg
        longint snd_off;           // the peer's stream offset (bytes it has sent)
        longint snd_limit;         // ...and the right edge of the window it last saw
        bit     zero_win;          // the window closed with bytes still to send
        int     closed_at;         // cycle the DUT asked the TOE to close it, -1 = open
        int     rq_out;            // readPkgs of it the TOE has not answered yet
        int     n_after_close;     // readPkgs of it after its close
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
        // Sequence number the feeder has reached. Separate from next_seq because the
        // scenario allocates sequence numbers when it QUEUES work and the feeder consumes them
        // later, one arm at a time.
        int   feed_seq;
    endclass

    Pkt   gfifo[$];
    Notif nq[$];
    Notif outst[$];
    RPkg  unmatched[$];
    Sess  sess[int];
    int   live_sids[$];
    Lane  ln[NL];

    int rp_issued = 0, pkt_taken = 0;
    int rp_sid_q[$];            // session id of every readPkg, in issue order: what the TOE echoes
    int n_meta_mismatch = 0;    // readPkgs that popped another session's packet
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
    // NON-BYPASS TOE MODEL (DUT_TOE=1): the TOE with a 1 MiB receive ring per session
    // (RX_DDR_BYPASS = 0, patches 0007/0008). Modelled on the TOE's interface contract (the same
    // one toe_rx.sv's header states), not on its RTL:
    //   * a segment the peer sends goes into its session's ring; its DATA NOTIFICATION follows after
    //     a random latency through ONE in-order delay fifo (+NLAT: due = now + NLAT/2..NLAT, never
    //     before the previous one); a FIN notification (peer_close) BYPASSES it, so it can overtake;
    //   * readPkg(sid, len): len 0 = error; len > notified - requested for that session =
    //     OVER-READ = test failure; a session the TOE never opened, or one the DUT closed more than a
    //     few cycles ago = error. Answered in issue order: rx_meta = sid two cycles after the
    //     readPkg, the data after +RDLAT cycles -- exactly len bytes from the ring as ceil(len/64)
    //     beats, keep low-aligned, tlast on the last; the DUT may not drop TREADY on either;
    //   * WINDOW: the peer sends no further than the right edge of the window it last saw, which is
    //     (stream offset + 1 MiB - 16 - occupancy) at every segment it gets ACKed and at every
    //     segment the DUT sends on that session -- NOT when the DUT reads (no window update on app
    //     reads). Occupancy drops when a read's last beat leaves the TOE. A window of 0 with bytes
    //     still to send freezes the session (zero_win; an ERROR except where a scenario breaks the
    //     window rule on purpose);
    //   * +SIDREUSE: an open takes the lowest session id the DUT has closed whose notifications
    //     and readPkgs have all drained (the real TOE would wait out TIME_WAIT on top).
    // =============================================================================================
    class DNote; int sid; int len; int due; endclass
    DNote toe_dq[$];                 // data notifications in the TOE's delay fifo
    int   toe_nlat     = 100;        // +NLAT
    int   toe_rdlat    = 40;         // +RDLAT
    int   toe_last_due = 0;
    bit   toe_sidreuse = 0;          // +SIDREUSE
    int   n_sid_reused = 0;
    bit   zero_win_ok  = 0;          // win_bad: the rule is broken on purpose
    int   n_zero_win   = 0;
    int   n_overread   = 0;
    class TRp; int sid; int len; int at; endclass
    TRp   toe_mq[$], toe_rq[$];      // readPkgs awaiting their meta / their data, in issue order
    initial begin
        void'($value$plusargs("NLAT=%d", toe_nlat));
        void'($value$plusargs("RDLAT=%d", toe_rdlat));
        if ($test$plusargs("SIDREUSE")) toe_sidreuse = 1;
    end

    function automatic longint toe_win(input int sid);
        return sess[sid].snd_limit - sess[sid].snd_off;
    endfunction

    // The ACK the TOE sends (for a segment it took, or piggybacked on a segment the DUT sends)
    // carries the window of that moment; the right edge never moves left.
    function automatic void toe_ack(input int sid);
        longint e;
        e = sess[sid].snd_off + (TOE_RING - 16 - sess[sid].occ);
        if (e > sess[sid].snd_limit) sess[sid].snd_limit = e;
    endfunction

    function automatic int toe_reuse_sid();
        if (DUT_TOE == 0 || !toe_sidreuse) return -1;
        foreach (sess[k]) begin
            bit busy; busy = 0;
            if (sess[k].closed_at < 0 || (cyc - sess[k].closed_at) < 16 || sess[k].rq_out != 0) continue;
            foreach (toe_dq[i]) if (toe_dq[i].sid == k) busy = 1;
            foreach (nq[i])     if (nq[i].sid == k)     busy = 1;
            if (!busy) return k;
        end
        return -1;
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
            if (sess.exists(int'(cc_tdata[15:0]))) begin
                sess[int'(cc_tdata[15:0])].alive = 1'b0;
                if (sess[int'(cc_tdata[15:0])].closed_at < 0) sess[int'(cc_tdata[15:0])].closed_at = cyc;
            end
        end
    end

    // 1 = the TOE takes the open request and never answers it. This is a real Coyote failure and
    // the one tcp_init calls out: an ephemeral port reused against the peer's TIME_WAIT gives no
    // openStatus at all, success or failure. The request stays queued, so clearing the bit lets the
    // TOE answer late -- which is also what the real one does.
    bit open_hang = 1'b0;
    // Open requests (1-based, in the order the DUT sent them) the TOE answers with success = 0:
    // a connect the peer refused. No session is created for them.
    int open_refuse[$];
    int n_open_ans = 0, n_open_refused = 0;
    function automatic bit open_refused_here(input int k);
        foreach (open_refuse[i]) if (open_refuse[i] == k) return 1'b1;
        return 1'b0;
    endfunction
    initial begin : open_svc
        Sess s; int lat, sid;
        os_tvalid = 1'b0; os_tdata = '0;
        forever begin
            @(posedge clk);
            if (rst_n && !open_hang && openq.size() > 0) begin
                void'(openq.pop_front());
                n_open_ans = n_open_ans + 1;
                lat = 40 + ($urandom_range(0, 240));      // tens..hundreds of cycles
                repeat (lat) @(posedge clk);
                if (open_refused_here(n_open_ans)) begin
                    os_tdata  <= pack_open_rsp(0, 1'b0);
                    os_tvalid <= 1'b1;
                    do @(posedge clk); while (!os_tready);
                    os_tvalid <= 1'b0;
                    n_open_refused = n_open_refused + 1;
                    $display("  [cyc=%0d] TOE: REFUSED open request #%0d (openStatus success = 0)", cyc, n_open_ans);
                end else begin
                    sid = toe_reuse_sid();
                    if (sid < 0) begin sid = next_sid; next_sid = next_sid + 1; end
                    else begin
                        n_sid_reused = n_sid_reused + 1;
                        $display("  [cyc=%0d] TOE: session id %0d REUSED", cyc, sid);
                    end
                    s = new(); s.sid = sid; s.alive = 1'b1; s.lane = -1; s.scanp = 0;
                    s.occ = 0; s.occ_max = 0; s.notified = 0; s.requested = 0; s.snd_off = 0;
                    s.snd_limit = TOE_RING - 16; s.zero_win = 0; s.closed_at = -1; s.rq_out = 0;
                    s.n_after_close = 0;
                    if (!sess.exists(sid)) live_sids.push_back(sid);
                    sess[sid] = s;
                    os_tdata  <= pack_open_rsp(sid, 1'b1);
                    os_tvalid <= 1'b1;
                    do @(posedge clk); while (!os_tready);
                    os_tvalid <= 1'b0;
                    n_open_rsp = n_open_rsp + 1;
                    $display("  [cyc=%0d] TOE: opened session %0d (open request #%0d)", cyc, sid, n_open_ans);
                end
            end
        end
    end

    // the delay fifo, in order
    always @(posedge clk) if (rst_n && DUT_TOE != 0) begin
        while (toe_dq.size() > 0 && toe_dq[0].due <= cyc) begin
            Notif nn; DNote d;
            d = toe_dq.pop_front();
            nn = new(); nn.sid = d.sid; nn.len = d.len; nn.closed = 1'b0;
            nq.push_back(nn);
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
                if (DUT_TOE == 0) outst.push_back(nn);
                else if (sess.exists(nn.sid)) sess[nn.sid].notified += nn.len;
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
            if (rp_tvalid && rp_tready && DUT_TOE != 0) begin
                automatic int sid = rp_sid(rp_tdata), len = rp_len(rp_tdata);
                TRp t;
                rp_issued = rp_issued + 1; idle_since_rp = 0;
                if (len == 0) err($sformatf("readPkg with length 0 (sid=%0d)", sid));
                if (!sess.exists(sid)) err($sformatf("readPkg for session %0d, which the TOE never opened", sid));
                else begin
                    if (sess[sid].closed_at >= 0) begin
                        sess[sid].n_after_close++;
                        // A readPkg granted in the very cycle the DUT released the session may still
                        // reach the TOE just after the close (it was already in the issue register).
                        if ((cyc - sess[sid].closed_at) > 8 || sess[sid].n_after_close > 1)
                            err($sformatf("readPkg(sid=%0d,len=%0d) %0d cycles after the DUT closed that session",
                                          sid, len, cyc - sess[sid].closed_at));
                    end
                    if (sess[sid].requested + len > sess[sid].notified) begin
                        n_overread = n_overread + 1;
                        err($sformatf("OVER-READ: readPkg(sid=%0d,len=%0d) with %0d notified and %0d already requested -- the real TOE would corrupt the session",
                                      sid, len, sess[sid].notified, sess[sid].requested));
                    end
                    sess[sid].requested += len;
                    sess[sid].rq_out++;
                end
                t = new(); t.sid = sid; t.len = len; t.at = cyc;
                toe_mq.push_back(t); toe_rq.push_back(t);
            end else if (rp_tvalid && rp_tready) begin
                rp_issued = rp_issued + 1; idle_since_rp = 0;
                if (rp_len(rp_tdata) == 0)
                    err($sformatf("readPkg with length 0 (sid=%0d): the real TOE's datamover hangs on this",
                                  rp_sid(rp_tdata)));
                r = new(); r.sid = rp_sid(rp_tdata); r.len = rp_len(rp_tdata); r.at = cyc;
                unmatched.push_back(r);
                rp_sid_q.push_back(r.sid);
            end else if (DUT_TOE != 0) begin
                if (toe_owed(1'b0) == 0) idle_since_rp = 0;
                else                     idle_since_rp = idle_since_rp + 1;
            end else if (outst_data() == 0 && unmatched.size() == 0) begin
                // Nothing is owed a readPkg, so there is nothing for the DUT to be late with. The
                // property is "a readPkg within LIVENESS_BOUND cycles WHILE a notification is
                // outstanding"; counting through an idle origin as well tripped it on the first
                // segment after a real-scale MinIO time to first byte (0.8 ms = 200k cycles).
                // A wedge keeps a notification outstanding, so it still counts.
                idle_since_rp = 0;
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
        Pkt p; int i, nb, k, msid;
        logic [AXI_DATA_BITS-1:0] dw; logic [AXI_DATA_BITS/8-1:0] kw;
        rm_tvalid = 0; rm_tdata = '0; rd_tvalid = 0; rd_tdata = '0; rd_tkeep = '0; rd_tlast = 0;
        forever begin
            @(posedge clk);
            if (rst_n && DUT_TOE == 0 && (rp_issued - pkt_taken) > 0 && gfifo.size() > 0) begin
                p = gfifo.pop_front(); pkt_taken = pkt_taken + 1;
                msid = rp_sid_q.pop_front();
                if (msid != p.sid) begin
                    n_meta_mismatch = n_meta_mismatch + 1;
                    err($sformatf("TOE: the readPkg for session %0d popped session %0d's packet (%0d B) and labels it %0d",
                                  msid, p.sid, p.d.size(), msid));
                end
                deliver_lane = (sess.exists(p.sid)) ? sess[p.sid].lane : -1;
                rm_tdata <= TCP_RX_META_BITS'(msid); rm_tvalid <= 1'b1;
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

    // ---- the non-bypass TOE's readPkg answers (DUT_TOE) -----------------------------------------
    // rx_meta: in issue order, two cycles after the readPkg (rx_app_stream_if answers at once).
    initial begin : toe_meta_engine
        TRp t;
        forever begin
            @(posedge clk);
            if (rst_n && DUT_TOE != 0 && toe_mq.size() > 0 && cyc >= toe_mq[0].at + 2) begin
                t = toe_mq.pop_front();
                rm_tdata <= TCP_RX_META_BITS'(t.sid); rm_tvalid <= 1'b1;
                @(posedge clk);
                if (!rm_tready) begin
                    err("TOE: the DUT dropped rx_meta TREADY");
                    while (!rm_tready) @(posedge clk);
                end
                rm_tvalid <= 1'b0;
            end
        end
    end

    // data: in issue order, +RDLAT after the readPkg, exactly len bytes out of the ring; the read's
    // bytes are released (occupancy drops) when its last beat has left.
    initial begin : toe_data_engine
        TRp t; int i, nb, k;
        logic [AXI_DATA_BITS-1:0] dw; logic [AXI_DATA_BITS/8-1:0] kw;
        forever begin
            @(posedge clk);
            if (rst_n && DUT_TOE != 0 && toe_rq.size() > 0 && cyc >= toe_rq[0].at + toe_rdlat) begin
                t = toe_rq.pop_front();
                pkt_taken = pkt_taken + 1;
                deliver_lane = (sess.exists(t.sid)) ? sess[t.sid].lane : -1;
                i = 0;
                while (i < t.len) begin
                    nb = (t.len - i > BPB) ? BPB : (t.len - i);
                    dw = '0; kw = '0;
                    for (k = 0; k < nb; k++) begin
                        if (sess.exists(t.sid) && sess[t.sid].ring.size() > 0) begin
                            dw[k*8 +: 8] = sess[t.sid].ring.pop_front();
                        end else begin
                            dw[k*8 +: 8] = 8'hEE;   // an over-read: already an error at the readPkg
                        end
                        kw[k] = 1'b1;
                    end
                    rd_tdata <= dw; rd_tkeep <= kw;
                    rd_tlast <= ((i + nb) >= t.len); rd_tvalid <= 1'b1;
                    @(posedge clk);
                    if (!rd_tready) begin
                        err("TOE: the DUT dropped rx_data TREADY in the middle of a packet");
                        while (!rd_tready) @(posedge clk);
                    end
                    i = i + nb;
                end
                rd_tvalid <= 1'b0; rd_tlast <= 1'b0;
                if (sess.exists(t.sid)) begin
                    sess[t.sid].occ -= t.len;
                    sess[t.sid].rq_out--;
                end
            end
        end
    end

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
                // a segment the DUT sends carries the TOE's current window
                if (DUT_TOE != 0 && sess.exists(tm_sid(tm_tdata))) toe_ack(tm_sid(tm_tdata));
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
    int srv_lat = 0;   // +SRVLAT, cycles; see serve()
    int srv_jit = 0;   // +SRVJIT, extra 0..N cycles per response: connections answer out of order
    initial void'($value$plusargs("SRVLAT=%d", srv_lat));
    initial void'($value$plusargs("SRVJIT=%d", srv_jit));

    // ORIGIN PACING. Three knobs, all off by default so every older scenario is
    // byte for byte what it was:
    //   +SRVSER      the origin answers the requests of ONE connection ONE AT A TIME, the way Go's
    //                net/http (MinIO) serves pipelined GETs: request k+1's time to first byte
    //                (SRVLAT + 0..SRVJIT) starts when response k has left, or when k+1 arrived if
    //                that is later. Pipelining then hides the request round trip, not the TTFB.
    //   +SRVRATE=    per-connection send rate, milli-bytes per cycle (920 = 230 MB/s at 250 MHz):
    //                a token bucket per session that fills only while it has bytes to send (at most
    //                two segments) and, under SRVSER, starts EMPTY at each response -- idle credit
    //                would send the first 8 KiB of every response the instant its TTFB ends.
    //   +LINKBPC=    the shared wire in bytes per cycle (64 = one beat per cycle; 50 = 100 Gb/s).
    bit srv_ser     = 1'b0;
    int srv_rate_mb = 0;
    int link_bpc    = 64;
    // +HDRBYTES: make every response header about this long (0 = the minimal 90-byte one), with
    // extra header lines after the status line, as a real origin sends (MinIO ~600 bytes: Accept-
    // Ranges, Content-Range, ETag, Last-Modified, Server, the X-Amz-* ids, ...). It matters for
    // throughput because strip_http parses headers ONE BYTE PER CYCLE.
    int srv_hdr_bytes = 0;
    initial void'($value$plusargs("HDRBYTES=%d", srv_hdr_bytes));
    function automatic string resp_header(input int len);
        string base, pad, line; int need, k;
        base = $sformatf("Content-Length: %0d\015\012Connection: keep-alive\015\012\015\012", len);
        pad  = "";
        need = srv_hdr_bytes - (30 + base.len());
        k    = 0;
        while (need > 12) begin
            int n; n = (need > 72) ? 60 : need - 12;
            line = $sformatf("X-Pad-%0d: ", k % 10);
            for (int i = 0; i < n; i++) line = {line, "a"};
            line = {line, "\015\012"};
            pad  = {pad, line};
            need = need - line.len();
            k    = k + 1;
        end
        return {"HTTP/1.1 206 Partial Content\015\012", pad, base};
    endfunction
    initial begin
        if ($test$plusargs("SRVSER")) srv_ser = 1'b1;
        void'($value$plusargs("SRVRATE=%d", srv_rate_mb));
        void'($value$plusargs("LINKBPC=%d", link_bpc));
    end

    task automatic serve(int sid, int lane, int seq);
        Resp r; string hdr; int len; int i;
        if (ln[lane].plan.size() == 0) begin
            err($sformatf("lane %0d transmitted request seq %0d that the host never planned", lane, seq));
            return;
        end
        r = ln[lane].plan.pop_front();
        len = r.len;
        hdr = resp_header(len);
        ln[lane].expq.push_back(r);
        if (srv_ser) begin
            // +SRVSER: queue it; srv_ser_engine answers it when this connection is free.
            SReq q;
            q = new(); q.lane = lane; q.seq = r.seq; q.len = len; q.arrive = cyc;
            sess[sid].srvq.push_back(q);
            return;
        end
        if (srv_lat == 0) begin
            for (i = 0; i < hdr.len(); i++) sess[sid].pending.push_back(byte'(hdr.getc(i)));
            for (i = 0; i < len; i++) sess[sid].pending.push_back(body_byte(lane, r.seq, i));
            sess[sid].wr.push_back(hdr.len() + len);
        end else begin
            // +SRVLAT: a request->response LATENCY, in order per session but not serialised (the
            // round trip plus the origin's time to first byte). A depth-1 host pays it on every
            // GET; pipelined GETs overlap it with the transfer of the responses before them.
            automatic int lat_k = srv_lat + ((srv_jit > 0) ? $urandom_range(0, srv_jit) : 0);
            automatic int t_rel = ((cyc + lat_k) > sess[sid].last_rel) ? (cyc + lat_k)
                                                                         : (sess[sid].last_rel + 1);
            automatic int a_sid = sid, a_lane = lane, a_seq = r.seq, a_len = len;
            automatic string a_hdr = hdr;
            sess[sid].last_rel = t_rel;
            fork begin
                while (cyc < t_rel) @(posedge clk);
                if (sess.exists(a_sid)) begin
                    for (int q = 0; q < a_hdr.len(); q++) sess[a_sid].pending.push_back(byte'(a_hdr.getc(q)));
                    for (int q = 0; q < a_len; q++) sess[a_sid].pending.push_back(body_byte(a_lane, a_seq, q));
                    sess[a_sid].wr.push_back(a_hdr.len() + a_len);
                end
            end join_none
        end
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
                    if (lane < 0 || lane >= NL) begin
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

    // +SRVSER: one response at a time per connection (see srv_ser).
    initial begin : srv_ser_engine
        forever begin
            @(posedge clk);
            if (rst_n && srv_ser) foreach (live_sids[k]) begin
                Sess s; int base;
                s = sess[live_sids[k]];
                if (s.busy_resp && s.pending.size() == 0) begin s.busy_resp = 1'b0; s.idle_since = cyc; end
                if (!s.busy_resp && s.srvq.size() > 0 && s.ttfb_due == 0) begin
                    base = (s.srvq[0].arrive > s.idle_since) ? s.srvq[0].arrive : s.idle_since;
                    s.ttfb_due = base + srv_lat + ((srv_jit > 0) ? $urandom_range(0, srv_jit) : 0);
                    if (s.ttfb_due <= 0) s.ttfb_due = 1;
                end
                if (s.ttfb_due != 0 && cyc >= s.ttfb_due && s.alive) begin
                    SReq q; string h;
                    q = s.srvq.pop_front();
                    h = resp_header(q.len);
                    for (int i = 0; i < h.len(); i++) s.pending.push_back(byte'(h.getc(i)));
                    for (int i = 0; i < q.len; i++)   s.pending.push_back(body_byte(q.lane, q.seq, i));
                    s.wr.push_back(h.len() + q.len);
                    s.busy_resp = 1'b1;
                    s.ttfb_due  = 0;
                    s.credit    = 0;   // the rate applies from the first byte, not from idle credit
                end
            end
        end
    end

    // +SRVRATE: every session earns srv_rate_mb milli-bytes a cycle, up to two segments.
    always @(posedge clk) if (rst_n && srv_rate_mb > 0) foreach (live_sids[k]) if (sess[live_sids[k]].pending.size() > 0) begin
        longint cap;
        cap = 2 * longint'(mss) * 1000;
        sess[live_sids[k]].credit = sess[live_sids[k]].credit + srv_rate_mb;
        if (sess[live_sids[k]].credit > cap) sess[live_sids[k]].credit = cap;
    end
    function automatic bit rate_ok(input int sid);
        int want;
        if (srv_rate_mb <= 0) return 1'b1;
        want = (sess[sid].pending.size() > mss) ? mss : sess[sid].pending.size();
        return sess[sid].credit >= 1000 * longint'(want);
    endfunction

    // =============================================================================================
    // Network: segment pending response bytes into packets, in round-robin arrival order.
    // Emission is paced at one 512-bit beat per cycle, i.e. line rate for this link.
    // =============================================================================================
    int  net_rr = 0;
    // Sessions whose remaining bytes the origin holds back for now -- still "in flight" -- so a
    // scenario can choose exactly when they reach the wire (cu, cuovf).
    int  hold_sid  = -1;
    int  hold2_sid = -1;
    bit  net_paced = 1'b1;
    int  net_allow = 1000000000;   // packets the network may still put on the wire
    bit  net_coalesce = 1'b0;   // 1 = let one TCP segment carry the tail of one response and the head of the next
    // +COALESCE turns it on for any scenario: pipelined responses then share segments and beats.
    initial if ($test$plusargs("COALESCE")) net_coalesce = 1'b1;
    initial begin : net_engine
        Pkt p; Notif nn; int i, k, sid, n, tries;
        forever begin
            @(posedge clk);
            if (rst_n && live_sids.size() > 0 && net_allow > 0) begin
                sid = -1;
                for (tries = 0; tries < live_sids.size(); tries++) begin
                    k = live_sids[(net_rr + tries) % live_sids.size()];
                    if (k != hold_sid && k != hold2_sid && sess[k].pending.size() > 0 && rate_ok(k) &&
                        (DUT_TOE == 0 || toe_win(k) > 0)) begin
                        sid = k; net_rr = (net_rr + tries + 1); break;
                    end
                end
                if (sid >= 0) begin
                    if (!net_coalesce) begin
                        if (sess[sid].wr_left == 0 && sess[sid].wr.size() > 0)
                            sess[sid].wr_left = sess[sid].wr.pop_front();
                    end
                    n = (sess[sid].pending.size() > mss) ? mss : sess[sid].pending.size();
                    if (!net_coalesce && sess[sid].wr_left > 0 && n > sess[sid].wr_left)
                        n = sess[sid].wr_left;
                    // The non-bypass TOE: never past the window the peer last saw.
                    if (DUT_TOE != 0 && longint'(n) > toe_win(sid)) n = int'(toe_win(sid));
                    if (!net_coalesce) sess[sid].wr_left = sess[sid].wr_left - n;
                    net_allow = net_allow - 1;
                    if (DUT_TOE != 0) begin
                        // into the session's ring, ACKed with the window of this moment; the data
                        // notification follows through the delay fifo
                        DNote d;
                        for (i = 0; i < n; i++) sess[sid].ring.push_back(sess[sid].pending.pop_front());
                        sess[sid].occ += n;
                        if (sess[sid].occ > sess[sid].occ_max) sess[sid].occ_max = sess[sid].occ;
                        sess[sid].snd_off += n;
                        toe_ack(sid);
                        d = new(); d.sid = sid; d.len = n;
                        d.due = cyc + $urandom_range(toe_nlat / 2, toe_nlat);
                        if (d.due < toe_last_due) d.due = toe_last_due;
                        toe_last_due = d.due;
                        toe_dq.push_back(d);
                    end else begin
                        p = new(); p.sid = sid;
                        for (i = 0; i < n; i++) p.d.push_back(sess[sid].pending.pop_front());
                        gfifo.push_back(p);
                        nn = new(); nn.sid = sid; nn.len = n; nn.closed = 1'b0;
                        nq.push_back(nn);
                    end
                    if (srv_rate_mb > 0) sess[sid].credit = sess[sid].credit - 1000 * longint'(n);
                    if (net_paced) repeat ((n + link_bpc - 1)/link_bpc) @(posedge clk);
                end
            end
        end
    end

    // A session whose window closed with bytes still to send: frozen (the TOE sends no window update
    // on app reads; only an ACK for a probe, >= 200 ms on Linux, or a segment the DUT sends on it).
    always @(posedge clk) if (rst_n && DUT_TOE != 0) begin
        foreach (live_sids[k]) begin
            automatic int sk = live_sids[k];
            if (sess[sk].pending.size() > 0 && toe_win(sk) <= 0 && !sess[sk].zero_win && sess[sk].closed_at < 0) begin
                sess[sk].zero_win = 1'b1;
                n_zero_win = n_zero_win + 1;
                if (zero_win_ok)
                    $display("  [cyc=%0d] TOE: ZERO WINDOW on sid %0d (occupancy %0d) -- expected here", cyc, sk, sess[sk].occ);
                else
                    err($sformatf("TOE: ZERO WINDOW on sid %0d (occupancy %0d): the session is frozen", sk, sess[sk].occ));
            end
        end
    end

    // Keep only the first n of a held session's pending bytes: what the peer still had in flight
    // when the connection was torn down.
    task automatic hold_pend_trim(int sid, int n);
        if (!sess.exists(sid)) return;
        while (sess[sid].pending.size() > n) void'(sess[sid].pending.pop_back());
        sess[sid].wr = {}; sess[sid].wr_left = 0;
        $display("  [cyc=%0d] origin: %0d late byte(s) of sid %0d go on the wire after the close",
                 cyc, sess[sid].pending.size(), sid);
    endtask

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
    // Measurement window and the byte-check mask, both driven by the scenarios. Declared here
    // because the checker below reads them.
    bit meas_on = 0;
    int meas_beats  [NL];
    int meas_bytes  [NL];
    bit lane_ignore [NL];

    genvar gl;
    generate
        for (gl = 0; gl < NL; gl++) begin : g_body
            always @(posedge clk) begin : chk
                int b; byte unsigned got, want; Resp r;
                if (rst_n && bd_tvalid[gl] && bd_tready[gl]) begin
                    // Beats and bytes accepted in the measurement window, for `thr`. Counted at the
                    // PORT handshake, which is the decoder's own intake rate and nothing else.
                    if (meas_on) begin
                        meas_beats[gl] = meas_beats[gl] + 1;
                        meas_bytes[gl] = meas_bytes[gl] + $countones(bd_tkeep[gl]);
                    end
                    for (b = 0; b < BPB; b++) begin
                        if (bd_tkeep[gl][b]) begin
                            got = bd_tdata[gl][b*8 +: 8];
                            ln[gl].bytes_in = ln[gl].bytes_in + 1;
                            // `ovf` deliberately breaks one connection's response; the bytes that
                            // do arrive on it are correct and simply stop, and the scenario asks
                            // about the OTHER connections. Checking a stream that was cut on
                            // purpose would only ever report the cut.
                            if (lane_ignore[gl]) continue;
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

    // =============================================================================================
    // Decoder back-pressure, and the throughput window
    //
    // body_ready_ctl is the per-lane sink. `thr` additionally THROTTLES one lane to one beat every
    // THROTTLE_DIV cycles: 16 bytes per cycle at 4 is a quarter of line rate, and 4 bytes per cycle
    // at 16.
    // =============================================================================================
    logic [NL-1:0] body_ready_ctl;
    int throttle_lane = -1;
    int throttle_div  = 0;
    int throttle_cnt  = 0;

    always @(posedge clk) begin
        if (!rst_n) throttle_cnt <= 0;
        else if (throttle_div > 1) throttle_cnt <= (throttle_cnt + 1) % throttle_div;
    end

    // THE DECODER MODEL (+DECRATE=<MB/s>, every lane; off by default). A decoder that takes
    // DECRATE MB/s at 250 MHz: each byte it accepts is `dec_cost` 1/1024-cycles of work, it does
    // 1024 of them a cycle, and it is ready for the next beat once less than one cycle of work is
    // left. So a lane fed without a gap takes exactly DECRATE (1280 MB/s = 5.12 B/cycle = one full
    // beat per 12.5 cycles), BYTE-weighted -- the DataNormalizer in front of the real decoder packs
    // partial beats, so a short beat must not cost a whole one. Unlike `thr` it applies to every
    // decoder at once.
    int            dec_cost = 0;
    int            dec_debt [NL];
    logic [NL-1:0] dec_rdy_q = '1;
    initial begin
        int r;
        if ($value$plusargs("DECRATE=%d", r) && r > 0) dec_cost = (1024 * 250) / r;
        for (int L = 0; L < NL; L++) dec_debt[L] = 0;
    end

    always_comb begin
        bd_tready = body_ready_ctl;
        if (throttle_lane >= 0 && throttle_div > 1)
            bd_tready[throttle_lane] = body_ready_ctl[throttle_lane] && (throttle_cnt == 0);
        if (dec_cost > 0) bd_tready = bd_tready & dec_rdy_q;
    end

    always @(posedge clk) begin
        for (int L = 0; L < NL; L++) begin
            int add, tot, w, nb; bit hs;
            hs  = bd_tvalid[L] && bd_tready[L];
            nb  = hs ? $countones(bd_tkeep[L]) : 0;
            add = nb * dec_cost;
            tot = dec_debt[L] + add;
            w   = (tot > 1024) ? 1024 : tot;
            if (!rst_n || dec_cost == 0) begin
                dec_debt[L] = 0;
                dec_rdy_q[L] <= 1'b1;
            end else begin
                dec_debt[L] = tot - w;
                dec_rdy_q[L] <= (dec_debt[L] < 1024);
            end
        end
    end


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
        if (FEEDER) begin
            queue_work(lane, nchunk, chunk_len, nreq, body_len);
            return;
        end
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
    task automatic submit_batch_multi(int lane, int nreq, int len_each, output bit ok);
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

    // =============================================================================================
    // ONE-GET-PER-ARM HOST MODEL (handler_toe)
    //
    // handler_toe takes one GET per arm and says at the config port when it will take the next one
    // (ARM_READY includes its GET credit). So a batch of N GETs becomes N arms of one GET each, and
    // the pacing is the hardware's credit rather than a delay the bench chose.
    //
    // The feeder runs as its own process per lane, so submit_batch RETURNS AS SOON AS THE WORK IS
    // QUEUED. That is what keeps the scenarios meaning what they say: `d` queues six responses and
    // then stops a decoder, and if submit_batch blocked until the sixth arm was accepted the batch
    // would already have drained by the time the decoder was stopped.
    //
    // Everything else the host does is unchanged -- same config beats, same order within a GET,
    // same request text, same padding.
    // =============================================================================================
    class Work;
        int nchunk;      // chunk-length entries to push first
        int chunk_len;
        int nreq;        // GETs, one arm each
        int body_len;
    endclass

    Work feed_q [NL][$];
    // Host-side pipelining state: the LANE's chunk depth, +HDEPTH (4; +LDEPTH overrides).
    int  hdepth = 4;
    int  armed_n     [NL];
    int  ent_n_lane  [NL];   // chunk entries pushed
    int  ldepth;
    initial begin
        void'($value$plusargs("HDEPTH=%d", hdepth));
        ldepth = hdepth;
        void'($value$plusargs("LDEPTH=%d", ldepth));
        for (int c = 0; c < NL; c++) begin armed_n[c] = 0; ent_n_lane[c] = 0; end
    end
    int  feed_busy [NL];   // work items queued or in progress, for all_drained()

    // THE CONFIG PORT IS ONE PORT, AND NOW THERE ARE N WRITERS.
    //
    // handler_multi's bench drove it from the single `main` process, so push_cfg could simply hold
    // req_valid until req_ready came back. With one feeder per connection that is a race: req_ready
    // answers about the lane named in req_data, and two feeders driving req_data at once ask two
    // different questions and take each other's answers. (It shows up as rwl_starved -- a chunk
    // entry credited to the wrong lane, so body bytes arrive with no length configured.)
    //
    // The real host has the same problem and the CSR map already solves it: the admission bits are
    // monotone in the host's favour, so a host POLLS LANE_READY, and only then takes the port for
    // the single beat. That is exactly what this does, which makes the bench's host model more
    // faithful than it was rather than less.
    semaphore cfg_lock = new(1);

    function automatic bit lane_arm_ready(input int L);
        return laneReadyWord[4*L + 0];
    endfunction
    function automatic bit lane_entry_ready(input int L);
        return laneReadyWord[4*L + 1];
    endfunction

    task automatic push_cfg_mt(input http_config_t c, input int lane, input bit is_arm,
                               output bit ok);
        int t0, guard;
        t0 = cyc; ok = 1'b0;
        while ((cyc - t0) < CFG_BOUND && !ok) begin
            if (is_arm ? lane_arm_ready(lane) : lane_entry_ready(lane)) begin
                cfg_lock.get(1);
                @(posedge clk);
                req_data <= c; req_valid <= 1'b1;
                guard = 0;
                // req_ready is combinational from the lane this beat names, so it is settled on the
                // next edge. The guard only exists so a lane whose condition went away while we
                // queued for the lock gives the port back instead of holding it.
                while (guard < 16 && !ok) begin
                    @(posedge clk);
                    if (req_ready) ok = 1'b1;
                    guard = guard + 1;
                end
                req_valid <= 1'b0;
                cfg_lock.put(1);
                if (!ok) @(posedge clk);
            end else begin
                @(posedge clk);
            end
        end
        if (c.req_total_bytes != 0) begin
            arm_n = arm_n + 1; arm_wait_sum = arm_wait_sum + (cyc - t0);
            if ((cyc - t0) > arm_wait_max) arm_wait_max = cyc - t0;
        end else begin
            ent_n = ent_n + 1; ent_wait_sum = ent_wait_sum + (cyc - t0);
            if ((cyc - t0) > ent_wait_max) ent_wait_max = cyc - t0;
        end
        if (!ok && !cfg_stalled) begin
            cfg_stalled = 1'b1; cfg_stall_cycle = cyc;
            $display("  [cyc=%0d] *** CONFIG STALL: lane %0d %s never admitted in %0d cycles (laneReady=0x%016h)",
                     cyc, lane, is_arm ? "ARM" : "ENTRY", CFG_BOUND, laneReadyWord);
        end
    endtask

    task automatic queue_work(int lane, int nchunk, int chunk_len, int nreq, int body_len);
        Work w;
        w = new();
        w.nchunk = nchunk; w.chunk_len = chunk_len; w.nreq = nreq; w.body_len = body_len;
        // The server's plan is recorded HERE rather than in the feeder, so it is in place before the
        // first GET can possibly reach the origin.
        for (int i = 0; i < nreq; i++) begin
            Resp r;
            r = new(); r.lane = lane; r.seq = ln[lane].next_seq + i; r.len = body_len;
            ln[lane].plan.push_back(r);
        end
        ln[lane].next_seq = ln[lane].next_seq + nreq;
        feed_busy[lane]   = feed_busy[lane] + 1;
        feed_q[lane].push_back(w);
    endtask

    generate
        for (gl = 0; gl < NL; gl++) begin : g_feed
            initial begin : feeder
                Work w; Blob bl; byte unsigned txt[$]; bit o; int seq0;
                forever begin
                    @(posedge clk);
                    if (rst_n && FEEDER && feed_q[gl].size() > 0 && !cfg_stalled) begin
                        w    = feed_q[gl].pop_front();
                        if ($test$plusargs("FDBG")) $display("  [cyc=%0d] FDBG lane %0d pops work (%0d GETs), %0d queued", cyc, gl, w.nreq, feed_q[gl].size());
                        seq0 = ln[gl].feed_seq;
                        // Chunk-length entries first: one per COLUMN CHUNK, which is not the same
                        // number as the GETs (a10 fetches one 6000-byte chunk as two 3000-byte
                        // GETs, and that is the case axis_rewrite_last exists for).
                        o = 1'b1;
                        // The host's lane depth, in CHUNKS as software counts it
                        // (await_lane_credit: occ + needed <= max(depth, needed)); the sink's
                        // resp_done counts chunk tlasts, so it retires the same unit.
                        begin
                            int tw0; tw0 = 0;
                            forever begin
                                bit full;
                                full = (ent_n_lane[gl] - ln[gl].resp_done + w.nchunk) >
                                       ((ldepth > w.nchunk) ? ldepth : w.nchunk);
                                if (!full || tw0 >= CFG_BOUND) break;
                                @(posedge clk);
                                tw0 = tw0 + 1;
                            end
                        end
                        for (int i = 0; i < w.nchunk; i++) begin
                            push_cfg_mt(mk_cfg(w.chunk_len, gl, 0), gl, 1'b0, o);
                            if (!o) break;
                            ent_n_lane[gl] = ent_n_lane[gl] + 1;
                        end
                        // Then one arm per GET. The arm waits on ARM_READY (request text gone out,
                        // entry-queue room, the GET credit); the lane depth was kept above, in
                        // chunks, as configuration.cpp keeps it. The bench's GETs keep the window
                        // rule by size (win_bad breaks it on purpose).
                        for (int i = 0; i < w.nreq && o !== 1'b0; i++) begin
                            build_text(gl, 1, seq0 + i, txt);
                            push_cfg_mt(mk_cfg(w.chunk_len, gl, txt.size()), gl, 1'b1, o);
                            if (!o) break;
                            armed_n[gl]     = armed_n[gl] + 1;
                            if ($test$plusargs("FDBG"))
                                $display("  [cyc=%0d] FDBG lane %0d arm #%0d accepted, %0d outstanding",
                                         cyc, gl, armed_n[gl], armed_n[gl] - ln[gl].resp_done);
                            bl = new(); bl.d = txt;
                            ln[gl].txq.push_back(bl);
                        end
                        ln[gl].feed_seq = seq0 + w.nreq;
                        feed_busy[gl]   = feed_busy[gl] - 1;
                    end
                end
            end
        end
    endgenerate

    // The one entry point the scenarios use. It is the same call for both DUTs; only what happens
    // behind it differs.
    task automatic submit_batch(int lane, int nreq, int len_each, output bit ok);
        if (!FEEDER) begin
            submit_batch_multi(lane, nreq, len_each, ok);
        end else begin
            ln[lane].planned_total = ln[lane].planned_total + nreq;
            queue_work(lane, nreq, len_each, nreq, len_each);
            ok = 1'b1;
        end
    endtask

    generate
        for (gl = 0; gl < NL; gl++) begin : g_dma
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
        for (int L = nlanes; L < NL; L++)
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

    // Notified bytes the DUT owes a readPkg for: on sessions it has not closed, of lanes whose
    // decoder is taking data (a stopped decoder legitimately leaves its bytes in the ring).
    function automatic int toe_owed(input bit any_lane);
        int n; n = 0;
        foreach (sess[k])
            if (sess[k].closed_at < 0 && sess[k].lane >= 0 && sess[k].notified > sess[k].requested &&
                (any_lane || body_ready_ctl[sess[k].lane]))
                n = n + 1;
        return n;
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
        // the non-bypass TOE: nothing in the delay fifo, no readPkg unanswered, every byte notified
        // on a session the DUT still holds has been asked for
        if (DUT_TOE != 0) ok = ok && (toe_dq.size() == 0) && (toe_rq.size() == 0) && (toe_mq.size() == 0) &&
                               (toe_owed(1'b1) == 0) && !rd_tvalid;
        for (int i = 0; i < NL; i++) begin
            if (ln[i].plan.size() != 0) ok = 0;
            if (ln[i].expq.size() != 0) ok = 0;
            if (ln[i].txq.size()  != 0) ok = 0;
            if (ln[i].resp_done != ln[i].planned_total) ok = 0;
            // Work the feeder has not finished arming is work that has not drained.
            if (feed_busy[i] != 0) ok = 0;
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
        for (int i = 0; i < NL; i++)
            $display("       lane %0d: sid=%0d tready=%0b planned=%0d served-to-net=%0d awaiting-body=%0d done=%0d bytes=%0d text-blobs-queued=%0d",
                     i, ln[i].sid, body_ready_ctl[i], ln[i].planned_total,
                     ln[i].planned_total - ln[i].plan.size(), ln[i].expq.size(),
                     ln[i].resp_done, ln[i].bytes_in, ln[i].txq.size());
        foreach (live_sids[k])
            $display("       session %0d: alive=%0b lane=%0d unsegmented-bytes=%0d req-bytes-in=%0d",
                     live_sids[k], sess[live_sids[k]].alive, sess[live_sids[k]].lane,
                     sess[live_sids[k]].pending.size(), sess[live_sids[k]].rx.size());
        // CSR readback, decoded per the map documented in http_config.sv
        $display("     CSR inflight=0x%08h (occupancy=%0d depth=%0d, announce_pending=%0b peerFIN=%0b up=%0b)",
                 inflightWord, inflightWord[7:0], inflightWord[15:8],
                 inflightWord[16], inflightWord[17], inflightWord[18]);
        $display("     CSR stall=0x%08h (connect=%0b init_err=%0b tx_refused=%0b resp_err=%0b fatal=%0b bad_status=%0b reconnects=%0d bit24=%0b)",
                 stallWord, stallWord[0], stallWord[3], stallWord[4], stallWord[5], stallWord[6],
                 stallWord[7], stallWord[15:8], stallWord[24]);
        $display("     CSR stall upper (route_stall=%0b rwl_starved=%0b read_timeout=%0b rx_fifo_stall=%0b)",
                 stallWord[28], stallWord[27], stallWord[26], stallWord[25]);
        $display("     CSR resp=0x%08h  content_length=%0d  body_remaining=%0d  queue_depth=%0d  state=%0d",
                 respWord, contentLengthWord, bodyRemainingWord, queueDepthWord, state_debug);
        $display("     notif-backpressure=%0d cyc  rx_data-backpressure=%0d cyc", notif_bp_cycles, rxdata_bp_cycles);
        if (DUT_TOE != 0) begin
            $display("     TOE (non-bypass): delay-fifo=%0d readPkgs-unanswered=%0d zero-windows=%0d over-reads=%0d sids-reused=%0d",
                     toe_dq.size(), toe_rq.size(), n_zero_win, n_overread, n_sid_reused);
            foreach (sess[k])
                $display("       sid %0d: lane=%0d closed_at=%0d ring=%0d occ=%0d (max %0d) notified=%0d requested=%0d window=%0d",
                         k, sess[k].lane, sess[k].closed_at, sess[k].ring.size(), sess[k].occ, sess[k].occ_max,
                         sess[k].notified, sess[k].requested, toe_win(k));
        end
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
    //   [25] rx_fifo_stall    the per-lane decoupling fifo refused a beat routed to it, and that beat
    //                         was lost: the reservation promised room it did not have.
    //   [24] handler_multi: rx_dispatch dropped an announcement, so the bytes it named stay in
    //                         the TOE's shared fifo with nobody left to ask for them and every
    //                         packet behind them waits forever. handler_toe: the TOE broke its
    //                         contract (order or length) or a ring passed the window budget.
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
        if (stallWord[24]) why = {why, " overflow/contract(24)"};
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
        for (int i = 0; i < NL; i++) begin
            ln[i] = new();
            ln[i].sid = -1; ln[i].active = 0; ln[i].must_end = 0;
            ln[i].bytes_in = 0; ln[i].resp_done = 0; ln[i].next_seq = 0; ln[i].planned_total = 0;
            ln[i].feed_seq = 0;
            feed_busy[i]   = 0;
            feed_q[i].delete();
            meas_beats[i]  = 0;
            meas_bytes[i]  = 0;
            lane_ignore[i] = 0;
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


    // =============================================================================================
    // handler_toe SCENARIOS (DUT_TOE=1). The non-bypass TOE model is described above.
    // =============================================================================================
    int b1_g;

    // (cu / cuovf on handler_toe) late bytes for a session torn down under a fatal are never read.
    // There is no head-of-line kill to make lane 0 fatal here, so the peer FINs in the middle of a
    // big response instead (the bytes still to come are held at the origin): once the FIN has
    // settled the reader aborts dirty, the lane goes fatal and its session is closed. Then the
    // origin's late bytes land in that session's ring and are announced -- and must never draw a
    // readPkg (the model fails any readPkg for a closed session). cuovf additionally holds lane 0's
    // decoder off from before the FIN, so at the FIN its ring still holds bytes nobody has asked
    // for and readPkgs are outstanding; the decoder comes back after 20k cycles. +MIDBODY puts the
    // late bytes in the middle of one of lane 1's bodies.
    task automatic toe_cu(input bit stall_first);
        int sid0, c0, late, sent0;
        bit ok, o;
        if (!$value$plusargs("LATE=%d", late)) late = 1;
        mss = 4096;
        submit_batch(0, 1, 3000, o); submit_batch(1, 1, 3000, o); wait_drain(200000, ok);
        sid0 = ln[0].sid;
        $display("  [cyc=%0d] warm-up drained=%0b  lane0 sid=%0d lane1 sid=%0d", cyc, ok, sid0, ln[1].sid);
        lane_ignore[0] = 1;                       // its body is cut on purpose
        if (stall_first) body_ready_ctl[0] = 1'b0;
        submit_batch(0, 1, 400000, o);
        sent0 = stall_first ? 300000 : 60000;     // cuovf: more than the lane fifo holds
        begin
            int t0; t0 = cyc;
            while ((cyc - t0) < 200000 &&
                   !(sess.exists(sid0) && sess[sid0].pending.size() > 0 && sess[sid0].pending.size() < 400100 - sent0))
                @(posedge clk);
        end
        hold_sid = sid0;
        wait_cycles(500);
        $display("  [cyc=%0d] origin holds sid %0d's remaining %0d bytes; the peer FINs now (ring %0d unread)",
                 cyc, sid0, sess[sid0].pending.size(), sess[sid0].ring.size());
        peer_close(sid0);
        if (stall_first) begin
            wait_cycles(20000);
            $display("  [cyc=%0d] lane 0 (decoder held) fatal=%0b ring=%0d; its decoder comes back",
                     cyc, lane_is_fatal(0), sess[sid0].ring.size());
            body_ready_ctl[0] = 1'b1;
        end
        c0 = n_close_req;
        begin
            int t0; t0 = cyc;
            while ((cyc - t0) < 400000 && n_close_req == c0) @(posedge clk);
        end
        $display("  [cyc=%0d] handler closed sid %0d (closes=%0d) lane0 fatal=%0b", cyc, sid0, n_close_req, lane_is_fatal(0));
        if (n_close_req == c0 || !lane_is_fatal(0)) begin
            verdict = "FAIL (a FIN in the middle of a response did not make the lane fatal and close it)";
            dump("cu");
            return;
        end
        ln[0].planned_total = ln[0].resp_done; ln[0].plan = {}; ln[0].expq = {};
        ln[0].active = 0; ln[0].must_end = 0;
        b1_g = ln[1].resp_done;
        hold_pend_trim(sid0, late * mss);
        if (!$test$plusargs("MIDBODY")) begin
            hold_sid = -1;
            wait_cycles(5000);
            submit_batch(1, 3, 3000, o);
        end else begin
            automatic int sid1 = ln[1].sid;
            automatic int p0, t0;
            hold2_sid = sid1;
            submit_batch(1, 3, 20000, o);
            t0 = cyc;
            while ((cyc - t0) < 200000 && sess[sid1].pending.size() < 60000) @(posedge clk);
            p0 = sess[sid1].pending.size();
            hold2_sid = -1;
            while ((cyc - t0) < 200000 && sess[sid1].pending.size() > p0 - 8192) @(posedge clk);
            hold2_sid = sid1;
            hold_sid  = -1;
            while ((cyc - t0) < 200000 && sess[sid0].pending.size() > 0) @(posedge clk);
            $display("  [cyc=%0d] origin: 2 lane-1 segments, then sid %0d's late bytes, then the rest of lane 1", cyc, sid0);
            hold2_sid = -1;
        end
        wait_drain(300000, ok);
        wait_cycles(2000);                        // let the late notifications through the delay fifo
        dump("cu");
        $display("  lane 1: %0d -> %0d responses (planned %0d), errors=%0d; closed sid %0d: %0d late byte(s) announced and never asked for, %0d readPkg(s) after its close",
                 b1_g, ln[1].resp_done, ln[1].planned_total, n_err, sid0,
                 sess[sid0].notified - sess[sid0].requested, sess[sid0].n_after_close);
        if (n_err)      verdict = $sformatf("CORRUPT (%0d checker errors)", n_err);
        else if (!ok)   verdict = "HANG (the surviving lane never completed)";
        else if (sess[sid0].notified - sess[sid0].requested < longint'(late))
            verdict = "FAIL (no late bytes were announced for the closed session: the case tested nothing)";
        else            verdict = "PASS";
    endtask

    // (fin_overtake) the FIN notification overtakes the last data notifications. +NLAT (default
    // 3000 here) delays every data notification by 1500..3000 cycles; the origin sends a whole
    // response and FINs the moment its last byte is on the wire, so the FIN reaches the DUT while
    // the response's last notifications are still in the TOE's delay fifo. The response must
    // complete byte-exact, the lane must not go fatal, and then -- idle, its peer gone -- it
    // reconnects and serves the next batch. Needs NLAT < CLOSE_SETTLE; a reader that took the raw
    // FIN (tcp_read's 200-cycle drain alone) aborts the response.
    task automatic toe_fin_overtake();
        int sid0, o0, in_dq, t0;
        bit ok, o;
        if (!$value$plusargs("NLAT=%d", toe_nlat)) toe_nlat = 100;
        mss = 4096;
        submit_batch(0, 1, 3000, o); submit_batch(1, 1, 3000, o); wait_drain(200000, ok);
        sid0 = ln[0].sid;
        if (!$value$plusargs("NLAT=%d", toe_nlat)) toe_nlat = 3000;
        submit_batch(0, 1, 20000, o);
        t0 = cyc;
        while ((cyc - t0) < 100000 && !(ln[0].plan.size() == 0 && sess[sid0].pending.size() == 0 && sess[sid0].snd_off > 20000))
            @(posedge clk);
        in_dq = 0;
        foreach (toe_dq[i]) if (toe_dq[i].sid == sid0) in_dq++;
        o0 = n_open_rsp;
        peer_close(sid0);
        $display("  [cyc=%0d] the peer FINs sid %0d with %0d of its data notification(s) still in the TOE's delay fifo (NLAT %0d)",
                 cyc, sid0, in_dq, toe_nlat);
        wait_drain(200000, ok);
        $display("  [cyc=%0d] lane 0: %0d/%0d responses, fatal=%0b; waiting for the idle reconnect", cyc,
                 ln[0].resp_done, ln[0].planned_total, lane_is_fatal(0));
        if (!ok || lane_is_fatal(0) || n_err) begin
            verdict = lane_is_fatal(0) ? "FAIL (the overtaking FIN aborted a response that was still arriving)"
                                       : (!ok ? "HANG" : "FAIL (byte/framing errors)");
            dump("fin_overtake");
            return;
        end
        t0 = cyc;
        while ((cyc - t0) < 100000 && n_open_rsp == o0) @(posedge clk);
        toe_nlat = 100;
        wait_cycles(200);
        submit_batch(0, 2, 5000, o);
        wait_drain(200000, ok);
        if (in_dq == 0) verdict = "FAIL (the FIN overtook nothing: the case tested nothing)";
        else if (n_open_rsp == o0) verdict = "FAIL (lane 0 never reconnected after its peer's FIN)";
        else if (!ok) begin verdict = "HANG (after the reconnect)"; dump("fin_overtake"); end
        else if (n_err) verdict = "FAIL (byte/framing errors after the reconnect)";
        else verdict = $sformatf("PASS (FIN overtook %0d notification(s); response complete, lane reconnected)", in_dq);
    endtask

    // (win_ok / win_bad) THE WINDOW RULE. win_ok: lane 0's decoder is held off while the host keeps
    // its whole budget armed -- GET_CREDIT (4) GETs of the 236 KiB cap, each with a 4000-byte
    // header -- so the ring fills as far as the rule allows: the window must never reach 0, the
    // budget error must stay clear, lane 1 runs alongside, and everything drains byte-exact when
    // the decoder comes back. win_bad breaks the rule (one 1.3 MB response -- an origin that
    // ignored Range): the budget error must rise; the session's window closes (expected here) and
    // lane 1 must still be served.
    task automatic toe_scen_win(input bit bad);
        int sid0, t0;
        bit ok, o;
        longint occm;
        mss = 4096;
        if (!$value$plusargs("HDRBYTES=%d", srv_hdr_bytes)) srv_hdr_bytes = 4000;
        submit_batch(0, 1, 3000, o); submit_batch(1, 1, 3000, o); wait_drain(200000, ok);
        sid0 = ln[0].sid;
        body_ready_ctl[0] = 1'b0;
        if (!bad) begin
            // The host's own lane depth (4 chunks) would already keep 4 GETs out at most; lift it
            // so the hardware's GET credit is the only thing between 8 armed GETs and the ring.
            ldepth = 16;
            submit_batch(0, 8, 236 * 1024, o);
            submit_batch(1, 8, 32768, o);
            wait_cycles(150000);
            occm = sess[sid0].occ_max;
            $display("  [cyc=%0d] lane 0 held: ring occupancy max %0d of %0d (window min %0d), budget_err=%0b, zero windows=%0d",
                     cyc, occm, TOE_RING, TOE_RING - 16 - occm, stallWord[24], n_zero_win);
            body_ready_ctl[0] = 1'b1;
            wait_drain(1500000, ok);
            if (!ok) begin verdict = "HANG"; dump("win_ok"); end
            else if (n_err) verdict = "FAIL (errors -- see above)";
            else if (n_zero_win != 0) verdict = "FAIL (a window reached 0 under the legal budget)";
            else if (stallWord[24]) verdict = "FAIL (budget_err under the legal budget)";
            else if (occm < 4 * (236 * 1024) - 2 * 131072)
                verdict = $sformatf("FAIL (the ring only reached %0d: the case did not fill it)", occm);
            else verdict = $sformatf("PASS (ring max %0d, window never below %0d)", occm, TOE_RING - 16 - occm);
        end else begin
            zero_win_ok = 1;
            submit_batch(0, 1, 1300000, o);
            t0 = cyc;
            while ((cyc - t0) < 200000 && !stallWord[24]) @(posedge clk);
            $display("  [cyc=%0d] lane 0 held, one 1.3 MB response: occupancy %0d, budget_err=%0b, zero windows=%0d",
                     cyc, sess[sid0].occ, stallWord[24], n_zero_win);
            b1_g = ln[1].resp_done;
            submit_batch(1, 4, 20000, o);
            t0 = cyc;
            while ((cyc - t0) < 200000 && ln[1].resp_done < b1_g + 4) @(posedge clk);
            if (!stallWord[24]) verdict = "FAIL (the window rule was broken and budget_err never rose)";
            else if (ln[1].resp_done < b1_g + 4) verdict = "FAIL (lane 1 stopped behind lane 0's full ring)";
            else if (n_err) verdict = "FAIL (errors on lane 1)";
            else verdict = $sformatf("BUDGET (budget_err raised at occupancy %0d; lane 1 still served)", sess[sid0].occ);
        end
    endtask

    // (sidreuse) the TOE hands a reconnecting lane the session id it just gave up. Three rounds of
    // work on both lanes, each ended by an idle FIN on lane 0; with +SIDREUSE the model reopens on
    // the freed id (once nothing of the old session is left anywhere in the TOE). The rebound lane
    // must start from a clean count -- every response after the reuse byte-exact.
    task automatic toe_scen_sidreuse();
        int same, o0, sid_old, t0;
        bit ok, o;
        mss = 4096;
        toe_sidreuse = 1;
        same = 0;
        for (int r = 0; r < 3; r++) begin
            submit_batch(0, 2, 5000 + 333*r, o); submit_batch(1, 2, 7000, o);
            wait_drain(300000, ok);
            if (!ok) break;
            sid_old = ln[0].sid; o0 = n_open_rsp;
            peer_close(sid_old);
            t0 = cyc;
            while ((cyc - t0) < 100000 && n_open_rsp == o0) @(posedge clk);
            wait_cycles(100);
            submit_batch(0, 1, 4000, o);
            wait_drain(300000, ok);
            $display("  [cyc=%0d] round %0d: lane 0 sid %0d -> %0d%s", cyc, r, sid_old, ln[0].sid,
                     (ln[0].sid == sid_old) ? " (REUSED)" : "");
            if (ln[0].sid == sid_old) same++;
            if (!ok) break;
        end
        if (!ok) begin verdict = "HANG"; dump("sidreuse"); end
        else if (n_err) verdict = "FAIL (byte/framing errors)";
        else if (same == 0) verdict = "FAIL (no round got its session id back: the case tested nothing)";
        else verdict = $sformatf("PASS (%0d of 3 reconnects got the same session id; byte-exact)", same);
    endtask

    // (thr_ring) one decoder throttled to one beat in 16 cycles, holding a 4 MiB column chunk fetched
    // as 18 GETs of ~228 KiB (the stage-1 host's split, GET_CREDIT outstanding). Its bytes wait in
    // its ring, so the others must keep >= 90 % of their solo rate. Phase A: lanes 1.. alone.
    // Phase B: lane 0's chunk armed and throttled first, its first GETs landed (the ring is full to
    // the credit), then the same work on lanes 1.. -- both windows 60k cycles.
    task automatic toe_thr_ring();
        int solo_beats [8], both_beats [8], solo_cyc, both_cyc;
        real worst, sr, br;
        bit ok, o;
        mss = 4096;
        if (NL < 2) begin verdict = "SKIP (needs at least 2 lanes)"; return; end
        // enough work that every fast lane is busy through the whole window (~21 B/cycle each)
        for (int L = 1; L < NL; L++) submit_batch(L, 64, 32768, o);
        wait_cycles(4000);
        for (int L = 0; L < NL; L++) meas_beats[L] = 0;
        solo_cyc = cyc; meas_on = 1; wait_cycles(60000); meas_on = 0; solo_cyc = cyc - solo_cyc;
        for (int L = 0; L < NL; L++) solo_beats[L] = meas_beats[L];
        wait_drain(800000, ok);
        $display("  [cyc=%0d] phase A drained=%0b", cyc, ok);
        throttle_lane = 0; throttle_div = 16;
        submit_batch(0, 18, 233017, o);           // 4 MiB as the host splits it: 18 GETs
        wait_cycles(30000);
        $display("  [cyc=%0d] lane 0 throttled, ring occupancy %0d, %0d of its GETs armed", cyc,
                 sess[ln[0].sid].occ, armed_n[0]);
        for (int L = 1; L < NL; L++) submit_batch(L, 64, 32768, o);
        wait_cycles(4000);
        for (int L = 0; L < NL; L++) meas_beats[L] = 0;
        both_cyc = cyc; meas_on = 1; wait_cycles(60000); meas_on = 0; both_cyc = cyc - both_cyc;
        for (int L = 0; L < NL; L++) both_beats[L] = meas_beats[L];
        $display("");
        $display("  == thr_ring: lane 0 at 1 beat per 16 cycles with a 4 MiB chunk in flight, %0d fast lane(s) ==", NL - 1);
        $display("     lane 0 (throttled): %0.3f beats/cyc", real'(both_beats[0]) / real'(both_cyc));
        worst = 1.0;
        for (int L = 1; L < NL; L++) begin
            sr = real'(solo_beats[L]) / real'(solo_cyc);
            br = real'(both_beats[L]) / real'(both_cyc);
            $display("     lane %0d: solo %0.3f beats/cyc -> with the throttled neighbour %0.3f (%0.1f%%)",
                     L, sr, br, (sr > 0.0) ? 100.0 * br / sr : 0.0);
            if (sr > 0.0 && br / sr < worst) worst = br / sr;
        end
        throttle_lane = -1; throttle_div = 0;
        wait_drain(1500000, ok);
        if (!ok) begin verdict = "HANG (did not drain after the throttle)"; dump("thr_ring"); end
        else if (n_err) verdict = "FAIL (byte/framing errors)";
        else if (stallWord[28] || stallWord[25]) verdict = "FAIL (route_stall / rx_fifo_stall)";
        else if (worst < 0.90) verdict = $sformatf("FAIL (a neighbour lost %0.1f%%)", 100.0 * (1.0 - worst));
        else verdict = $sformatf("PASS (neighbours kept %0.1f%% of their solo rate)", 100.0 * worst);
    endtask

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
            for (int L = 0; L < NL; L++) begin
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
                for (int L = 0; L < NL; L++) begin
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
        // These keep exactly ONE response outstanding per lane, deliberately: a serialised control
        // is the cleanest way to separate a receive-path fault from a pipelining one. If s_d or s_e
        // fails while its pipelined twin passes, the pipelining is not what broke.

        "s_base": begin                     // serialised baseline, both lanes
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            for (int r = 0; r < 4; r++)
                for (int L = 0; L < NL; L++) begin
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

                // WHICH LANE DIED, AND OF WHAT.
                //
                // Containment is only half of what the host needs. Lane 0 was killed by the
                // head-of-line watchdog, which means bytes were discarded out of the MIDDLE of its
                // response and the batch must be reissued; a lane that failed a read it could not
                // replay wants the same reissue but says something different about the connection.
                // Both set FATAL and nothing else distinguished them, because the handler's answer
                // to a dead lane is to release the session -- and releasing it clears rx_dispatch's
                // dead bit before anyone can read it. laneErrWord[8L] is that cause, latched.
                //
                // The neighbours' bits matter as much as lane 0's: a sticky vector that set every
                // lane would be as useless as no vector at all, and is exactly what an OR-folded
                // signal or a mis-indexed field produces.
                $display("  [cyc=%0d] CSR laneErr=0x%016h  laneReady=0x%016h",
                         cyc, laneErrWord, laneReadyWord);
                if (DUT_TOE != 0) begin
                    // handler_toe: no head-of-line kill at all. The stopped decoder's bytes wait in
                    // its session's ring; the lane is neither dead nor fatal, and the rest of the
                    // response is still there to be read when the decoder comes back.
                    for (int L = 0; L < NL; L++)
                        if (lane_dead_sticky(L) || lane_is_fatal(L))
                            verdict = $sformatf("FAIL (lane %0d dead/fatal over a stalled decoder: dead=%0b fatal=%0b)",
                                                L, lane_dead_sticky(L), lane_is_fatal(L));
                    if (sess.exists(ln[0].sid))
                        $display("  [cyc=%0d] toe: sid %0d holds %0d unread byte(s) in its ring (notified %0d, asked for %0d)",
                                 cyc, ln[0].sid, sess[ln[0].sid].ring.size(), sess[ln[0].sid].notified,
                                 sess[ln[0].sid].requested);
                    if (!sess.exists(ln[0].sid) || sess[ln[0].sid].ring.size() == 0)
                        verdict = "FAIL (the stalled lane's bytes are not waiting in its ring)";
                end else begin
                    if (!lane_dead_sticky(0)) begin
                        $display("  lane 0 was killed by the HOL watchdog but its lane-dead sticky bit reads CLEAR");
                        verdict = "FAIL (lane-dead sticky bit not set on the killed lane)";
                    end
                    for (int L = 1; L < NL; L++) begin
                        if (lane_dead_sticky(L)) begin
                            $display("  lane %0d reads lane-dead, but only lane 0's consumer was stopped", L);
                            verdict = $sformatf("FAIL (lane-dead set on surviving lane %0d)", L);
                        end
                    end
                end
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

        // (fsfin) the peer FINs right behind a COMPLETE response while its decoder is stalled -----
        //
        // Lane 0's decoder stops, then one small response lands and the origin closes the session
        // straight after it (what a `Connection: close` or a max-requests origin does). Every byte
        // of the response is in the handler, so nothing is owed by the network and the response
        // must complete the moment the decoder comes back. +FSBLEN sizes the body, i.e. where its
        // LAST beats wait when the FIN arrives; if the FIN drain does not count them, it expires
        // (CLOSE_SETTLE) and aborts a finished response.
        "fsfin": begin
            int fsblen;
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            if (!$value$plusargs("FSBLEN=%d", fsblen)) fsblen = 448;
            submit_batch(0, 1, 2000, o);
            submit_batch(1, 1, 2000, o);
            wait_drain(200000, ok);
            $display("  [cyc=%0d] warm-up drained=%0b", cyc, ok);
            body_ready_ctl[0] = 1'b0;                    // lane 0's decoder stops
            submit_batch(0, 1, fsblen, o);
            wait_cycles(3000);                           // the response lands and is read out
            $display("  [cyc=%0d] before the FIN: lane0 done=%0d/%0d bytes=%0d outstanding=%0d",
                     cyc, ln[0].resp_done, ln[0].planned_total, ln[0].bytes_in, outst_data());
            peer_close(ln[0].sid);
            wait_cycles(6000);                           // > CLOSE_SETTLE, decoder still stopped
            body_ready_ctl[0] = 1'b1;                    // and it comes back
            wait_drain(200000, ok);
            $display("  [cyc=%0d] after: lane0 done=%0d/%0d lane0 fatal=%0b",
                     cyc, ln[0].resp_done, ln[0].planned_total, lane_is_fatal(0));
            if (!ok) begin verdict = "HANG (the finished response never reached the decoder)"; dump("fsfin"); end
            else if (n_err) begin verdict = "FAIL (routing/framing violated)"; dump("fsfin"); end
            else if (lane_is_fatal(0))
                verdict = "FAIL (a complete response was aborted by the FIN drain)";
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
            if (DUT_TOE != 0 && (lane_is_fatal(0) || lane_dead_sticky(0)))
                verdict = "FAIL (handler_toe: the stalled lane went fatal -- its bytes should wait in its ring)";
            else if (ln[1].resp_done == ln[1].planned_total)
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

        // ---- REFUSED OPENS ---------------------------------------------------------------------------
        //
        // (of1) The TOE refuses lane 1's first open (openStatus success = 0) during the initial
        // bring-up. The handler backs off and retries THAT lane; every lane already up keeps the
        // session it has. Expected: NL + 1 open requests (lane 1 twice, every other lane once), no
        // close, lane 1 not fatal, and every batch byte-exact. A bring-up that restarts at lane 0
        // opens lanes that are already up a second time: their sessions leak, and a lane is rebound
        // under the GETs it has already sent.
        "of1": if (NL < 2) verdict = "SKIP (needs at least 2 lanes)"; else begin
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            open_refuse.push_back(2);
            for (int L = 0; L < NL; L++) submit_batch(L, 2, 3000, o);
            wait_drain(600000, ok);
            $display("  [cyc=%0d] drained=%0b  open requests=%0d (refused %0d, sessions %0d)  closes=%0d  laneErr=0x%016h",
                     cyc, ok, n_open_req, n_open_refused, n_open_rsp, n_close_req, laneErrWord);
            if (!ok) begin verdict = "HANG"; dump("of1"); end
            else if (n_err) begin verdict = "FAIL (routing/framing errors)"; dump("of1"); end
            else if (n_open_refused != 1) verdict = "FAIL (the TOE never refused an open: the case tested nothing)";
            else if (n_open_req != NL + 1 || n_close_req != 0)
                verdict = $sformatf("FAIL (%0d open requests and %0d closes for %0d lanes and one refusal: a lane that was up was opened again)",
                                    n_open_req, n_close_req, NL);
            else if (lane_is_fatal(1)) verdict = "FAIL (a refused first open made lane 1 fatal)";
            else verdict = "PASS (only the refused lane was opened again; every other lane kept its session)";
        end

        // (of2) A reconnect whose open the TOE refuses. Lane 0's peer FINs while the lane is idle,
        // the handler closes the session and opens a new one, and the TOE answers success = 0. The
        // lane owes nothing but now has no session, so it must say so: FATAL with INIT_ERR, which
        // the host routes around. It must not keep opening, and lane 1 must be unaffected. A lane
        // left down without FATAL looks healthy to the host, and every batch placed on it waits
        // for the host's timeout.
        "of2": if (NL < 2) verdict = "SKIP (needs at least 2 lanes)"; else begin
            int o_before;
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            submit_batch(0, 2, 3000, o); submit_batch(1, 2, 3000, o); wait_drain(200000, ok);
            wait_cycles(500);
            $display("  [cyc=%0d] warm-up drained=%0b  lane0 session=%0d lane1 session=%0d  opens=%0d",
                     cyc, ok, ln[0].sid, ln[1].sid, n_open_req);
            if (!ok) begin verdict = "HANG (warm-up)"; dump("of2"); end
            else begin
                o_before = n_open_req;
                open_refuse.push_back(o_before + 1);     // the reconnect's open
                peer_close(ln[0].sid);
                t0 = cyc;
                while ((cyc - t0) < 100000 && n_open_refused == 0) @(posedge clk);
                wait_cycles(70000);                      // past the handler's open backoff
                $display("  [cyc=%0d] after the refused reconnect: opens=%0d (was %0d) closes=%0d  lane0 up=%0b fatal=%0b init_err=%0b  lane1 up=%0b fatal=%0b",
                         cyc, n_open_req, o_before, n_close_req, lane_conn_up(0), lane_is_fatal(0),
                         lane_init_err(0), lane_conn_up(1), lane_is_fatal(1));
                if (n_open_refused != 1)
                    verdict = "FAIL (the reconnect's open never reached the TOE: the case tested nothing)";
                else if (lane_conn_up(0))
                    verdict = "FAIL (lane 0 reports a session after its open was refused)";
                else if (!lane_is_fatal(0) || !lane_init_err(0))
                    verdict = $sformatf("FAIL (the refused reconnect left lane 0 down but not fatal: fatal=%0b init_err=%0b)",
                                        lane_is_fatal(0), lane_init_err(0));
                else if (n_open_req != o_before + 1)
                    verdict = $sformatf("FAIL (%0d further open request(s) after the refusal)", n_open_req - o_before - 1);
                else if (lane_is_fatal(1) || !lane_conn_up(1))
                    verdict = "FAIL (lane 1 lost its session over lane 0's refused reconnect)";
                else begin
                    submit_batch(1, 2, 3000, o);
                    if (!o) begin verdict = "CONFIG STALL (lane 1)"; dump("of2"); end
                    else begin
                        wait_drain(200000, ok);
                        if (!ok) begin verdict = "HANG (lane 1 after lane 0's refused reconnect)"; dump("of2"); end
                        else if (n_err) verdict = "FAIL (routing/framing errors)";
                        else verdict = "PASS (refused reconnect: lane 0 fatal with INIT_ERR, lane 1 unaffected)";
                    end
                end
            end
        end

        // ---- LAZY OPEN -----------------------------------------------------------------------------
        //
        // (lz1) An idle lane whose peer FINs must STAY DOWN, and the next batch on it must open a
        // fresh session by itself.
        //
        // MinIO closes a connection idle for ~30 s, and with N lanes a lane sits idle that long
        // routinely.  Reconnecting the instant the FIN arrives puts a brand-new session where one
        // whose announcements were still in flight used to be, and the reader then waits out its
        // ~2 s watchdog for a notification that can never come.  The contract asked for here is the
        // one that removes the race entirely:
        //   (a) the FIN takes the session away and NOTHING reopens it while the lane has no work;
        //   (b) a later batch on that lane opens a session by itself and completes byte-exact.
        // Both halves matter: (a) alone would be satisfied by a lane that is simply dead.
        "lz1": begin
            int o_before_fin, c_before_fin, o_before_arm;
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            submit_batch(0, 2, 3000, o); wait_drain(200000, ok);
            submit_batch(1, 2, 3000, o); wait_drain(200000, ok);
            wait_cycles(500);                            // let both lanes go quiet
            $display("  [cyc=%0d] warm-up drained=%0b  lane0 session=%0d lane1 session=%0d  opens=%0d closes=%0d",
                     cyc, ok, ln[0].sid, ln[1].sid, n_open_req, n_close_req);
            if (!ok) begin verdict = "HANG (warm-up)"; dump("lz1"); end
            else begin
                o_before_fin = n_open_req;
                c_before_fin = n_close_req;
                peer_close(ln[0].sid);                   // the IDLE lane's peer goes away
                wait_cycles(20000);                      // ~70x the longest open this TOE takes
                $display("  [cyc=%0d] 20k cycles after the idle FIN: opens=%0d (was %0d) closes=%0d (was %0d) laneReady=0x%016h",
                         cyc, n_open_req, o_before_fin, n_close_req, c_before_fin, laneReadyWord);
                // (a) no new session, and the lane says so
                if (n_open_req != o_before_fin)
                    verdict = $sformatf("FAIL (the idle FIN drew %0d new open request(s): the reconnect race is still there)",
                                        n_open_req - o_before_fin);
                else if (lane_conn_up(0))
                    verdict = "FAIL (lane 0 still reports connected after its peer FINed: the host would place work on a dead session)";
                else if (lane_is_fatal(0))
                    verdict = "FAIL (an idle peer FIN made lane 0 fatal)";
                else if (lane_conn_up(1) !== 1'b1)
                    verdict = "FAIL (lane 1 lost its session over lane 0's FIN)";
                if (verdict == "") begin
                    // lane 1 must be unaffected while lane 0 sits down
                    submit_batch(1, 2, 3000, o);
                    if (!o) begin verdict = "CONFIG STALL (lane 1 blocked by the down lane)"; dump("lz1"); end
                    else begin
                        wait_drain(300000, ok);
                        if (!ok) begin verdict = "HANG (lane 1 stopped while lane 0 was down)"; dump("lz1"); end
                    end
                end
                if (verdict == "") begin
                    // (b) the lazy open
                    o_before_arm = n_open_req;
                    submit_batch(0, 2, 3000, o);
                    if (!o) begin verdict = "CONFIG STALL (arm refused on a lane with no session)"; dump("lz1"); end
                    else begin
                        wait_drain(300000, ok);
                        $display("  [cyc=%0d] after the batch on the down lane: drained=%0b opens=%0d (was %0d) lane0 session=%0d, %0d responses",
                                 cyc, ok, n_open_req, o_before_arm, ln[0].sid, ln[0].resp_done);
                        dump("lz1");
                        if (!ok)
                            verdict = "HANG (a batch on a lane with no session never opened one)";
                        else if (n_open_req == o_before_arm)
                            verdict = "FAIL (the batch drained without an open: the lane never actually went down)";
                        else if (lane_is_fatal(0))
                            verdict = "FAIL (lane 0 went fatal serving its first batch after the FIN)";
                        else if (n_err)
                            verdict = "FAIL (routing/framing violated across the lazy open)";
                        else
                            verdict = "PASS (idle FIN stayed down; the next batch opened its own session)";
                    end
                end
            end
        end

        // (lz2) An open whose openStatus NEVER ARRIVES must time out and give the bring-up resource
        // back.
        //
        // tcp_init has no timeout of its own -- it waits in ST_WAIT for ever, and its own comment
        // names the failure that gets it there: an ephemeral port reused against the peer's
        // TIME_WAIT produces no openStatus at all, neither success nor failure.  BR_OPEN is the ONE
        // shared bring-up resource, so parking in it stops every other lane's reconnect AND every
        // other lane's TEARDOWN -- and teardown is what stops a dead lane holding the head of the
        // shared receive path.  So the assertion is about a DIFFERENT lane: lane 1's release, which
        // is queued behind the silent open, must get through, and lane 1 must then open and drain.
        //
        // Needs a snapshot with a small STALL_CYCLES; see the parameter.
        "lz2": begin
            int o_before;
            if (STALL_CYCLES > 100000) begin
                verdict = $sformatf("FAIL (scenario needs a small STALL_CYCLES snapshot; this one has %0d)",
                                    STALL_CYCLES);
            end else begin
                if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
                submit_batch(0, 1, 3000, o); wait_drain(200000, ok);
                submit_batch(1, 1, 3000, o); wait_drain(200000, ok);
                wait_cycles(500);
                $display("  [cyc=%0d] warm-up drained=%0b  connect watchdog is %0d cycles", cyc, ok, STALL_CYCLES);
                if (!ok) begin verdict = "HANG (warm-up)"; dump("lz2"); end
                else begin
                    open_hang = 1'b1;                    // from here the TOE answers no open at all
                    peer_close(ln[0].sid);
                    wait_cycles(3000);                   // lane 0 released and down
                    o_before = n_open_req;
                    submit_batch(0, 1, 3000, o);         // lane 0 wants a session -> BR_OPEN, silent
                    if (!o) begin verdict = "CONFIG STALL (arm on the down lane)"; dump("lz2"); end
                    else begin
                        t0 = cyc;
                        while (n_open_req == o_before && (cyc - t0) < 50000) @(posedge clk);
                        $display("  [cyc=%0d] lane 0's open request is out (opens=%0d) and will never be answered",
                                 cyc, n_open_req);
                        peer_close(ln[1].sid);           // lane 1's release is now queued behind it
                        wait_cycles(2000);
                        $display("  [cyc=%0d] 2k cycles later lane 1 conn_up=%0b (still held behind the silent open)",
                                 cyc, lane_conn_up(1));
                        wait_cycles(STALL_CYCLES + 2000);
                        $display("  [cyc=%0d] past the watchdog: conn_stall=%0b lane1 conn_up=%0b opens=%0d closes=%0d",
                                 cyc, stallWord[0], lane_conn_up(1), n_open_req, n_close_req);
                        if (!stallWord[0])
                            verdict = "FAIL (the connect watchdog never even counted the silent open)";
                        else if (lane_conn_up(1))
                            verdict = "FAIL (lane 1's release never got through: BR_OPEN is still holding the bring-up resource)";
                        else begin
                            open_hang = 1'b0;            // the TOE comes back
                            submit_batch(1, 1, 3000, o);
                            if (!o) begin verdict = "CONFIG STALL (lane 1 after the silent open)"; dump("lz2"); end
                            else begin
                                wait_drain(400000, ok);
                                $display("  [cyc=%0d] after the TOE came back: drained=%0b lane0=%0d/%0d lane1=%0d/%0d opens=%0d",
                                         cyc, ok, ln[0].resp_done, ln[0].planned_total,
                                         ln[1].resp_done, ln[1].planned_total, n_open_req);
                                dump("lz2");
                                if (!ok)
                                    verdict = "HANG (neither lane recovered from the silent open)";
                                else if (n_err)
                                    verdict = "FAIL (routing/framing violated after the silent open)";
                                else
                                    verdict = "PASS (silent open timed out; both lanes reopened and drained)";
                            end
                        end
                    end
                end
            end
        end

        // =========================================================================================
        // big / thr: questions for a handler whose lanes do not share a receive buffer
        // (handler_toe). Against handler_multi big is larger than its whole lane fifo, and thr's
        // expected answer is the opposite of what the arrival-ordered receive path does.
        // =========================================================================================

        // (big) the host's whole window budget, on every lane at once -------------------------------
        //
        // GET_CREDIT (4) GETs of the 236 KiB cap each, on every lane simultaneously.
        "big": if (DUT_TOE == 0) verdict = "SKIP (handler_toe scenario)"; else begin
            int blen;
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            blen = 236 * 1024;
            $display("  toe: 4 GETs of %0d bytes on each of %0d lane(s)", blen, NL);
            for (int L = 0; L < NL; L++) submit_batch(L, 4, blen, o);
            wait_drain(3000000, ok);
            for (int L = 0; L < NL; L++)
                $display("     conn %0d: %0d/%0d responses, %0d body bytes",
                         L, ln[L].resp_done, ln[L].planned_total, ln[L].bytes_in);
            if (!ok) begin verdict = "HANG"; dump("big"); end
            else if (n_err) begin verdict = "FAIL"; dump("big"); end
            else verdict = "PASS";
        end

        // (thr) THE EXPERIMENT ----------------------------------------------------------------------
        //
        // One decoder is throttled to one beat every THRDIV cycles -- 16 B/cycle at the default 4,
        // 4 B/cycle at 16 -- while every other connection runs flat out. Behind handler_multi's
        // shared receive fifo this starves the neighbours: the slow lane's fifo fills,
        // conn_space_ok drops, the head of the arrival-ordered queue blocks and everyone waits.
        // With a receive ring per session (handler_toe) the slow decoder's bytes wait in its own
        // ring and the shared path never sees it.
        //
        // Measured in two phases against the SAME bench so nothing but the throttle differs:
        //   A  the fast connections alone, conn 0 idle           -> the solo rate
        //   B  the same, with conn 0 armed and throttled         -> the coupled rate
        // PASS needs B >= 90% of A, and route_stall / rx_fifo_stall clear throughout.
        "thr": begin
            int thrdiv, blen, nfast;
            int solo_beats [4], solo_cyc, both_beats [4], both_cyc;
            real solo_rate, both_rate, worst;
            thrdiv = 4; blen = 32768;
            void'($value$plusargs("THRDIV=%d", thrdiv));
            void'($value$plusargs("BLEN=%d", blen));
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            if (NL < 2) begin
                verdict = "SKIP (needs at least 2 connections)";
            end else begin
                nfast = NL - 1;

                // -- phase A: the fast connections alone -------------------------------------------
                for (int L = 1; L < NL; L++) submit_batch(L, 8, blen, o);
                wait_cycles(4000);                    // let the connections come up and fill
                for (int L = 0; L < NL; L++) begin meas_beats[L] = 0; meas_bytes[L] = 0; end
                solo_cyc = cyc; meas_on = 1;
                wait_cycles(60000);
                meas_on = 0; solo_cyc = cyc - solo_cyc;
                for (int L = 0; L < NL; L++) solo_beats[L] = meas_beats[L];
                wait_drain(600000, ok);
                $display("  [cyc=%0d] phase A (solo) drained=%0b", cyc, ok);

                // -- phase B: conn 0 armed and throttled -------------------------------------------
                throttle_lane = 0; throttle_div = thrdiv;
                submit_batch(0, 8, blen, o);
                for (int L = 1; L < NL; L++) submit_batch(L, 8, blen, o);
                wait_cycles(4000);
                for (int L = 0; L < NL; L++) begin meas_beats[L] = 0; meas_bytes[L] = 0; end
                both_cyc = cyc; meas_on = 1;
                wait_cycles(60000);
                meas_on = 0; both_cyc = cyc - both_cyc;
                for (int L = 0; L < NL; L++) both_beats[L] = meas_beats[L];

                $display("");
                $display("  == thr: one decoder at 1 beat per %0d cycles (%0d B/cycle), %0d fast connection(s) ==",
                         thrdiv, 64/thrdiv, nfast);
                $display("     conn 0 (throttled): %0d beats in %0d cycles = %0.3f beats/cyc",
                         both_beats[0], both_cyc, real'(both_beats[0])/real'(both_cyc));
                worst = 1.0;
                for (int L = 1; L < NL; L++) begin
                    solo_rate = real'(solo_beats[L]) / real'(solo_cyc);
                    both_rate = real'(both_beats[L]) / real'(both_cyc);
                    $display("     conn %0d: solo %0.3f beats/cyc -> with the throttled neighbour %0.3f  (%0.1f%%)",
                             L, solo_rate, both_rate,
                             (solo_rate > 0.0) ? 100.0*both_rate/solo_rate : 0.0);
                    if (solo_rate > 0.0 && (both_rate/solo_rate) < worst) worst = both_rate/solo_rate;
                end
                $display("     stall bits: route_stall(28)=%0b rx_fifo_stall(25)=%0b",
                         stallWord[28], stallWord[25]);
                $display("     worst neighbour retained %0.1f%% of its solo rate", 100.0*worst);

                if (stallWord[28] || stallWord[25])
                    verdict = "FAIL (the shared receive path was stalled by the throttled decoder)";
                else if (worst < 0.90)
                    verdict = $sformatf("FAIL (a neighbour lost %0.1f%% to the throttled decoder)",
                                        100.0*(1.0-worst));
                else if (n_err)
                    verdict = "FAIL (byte/framing errors)";
                else
                    verdict = $sformatf("PASS (neighbours kept %0.1f%% of their solo rate)", 100.0*worst);
                throttle_lane = -1; throttle_div = 0;
            end
        end

        // (cu) a late segment for a session torn down under a fatal ----------------------------------
        // Lane 0's decoder stops for good with a big response armed; rx_dispatch's head-of-line
        // watchdog kills it and the handler closes and releases the session in one cycle
        // (BR_CLOSE). The origin still had +LATE segments in flight for that session, and the TOE
        // -- now in FIN_WAIT_1 -- accepts and announces them. Then lane 1 carries on. Is lane 1
        // byte-exact and complete? +MIDBODY puts the late segment in the MIDDLE of one of lane 1's
        // bodies (two of its segments, the late one, the rest) instead of before its next batch.
        "cu": if (DUT_TOE != 0) toe_cu(1'b0); else begin
            int sid0, c0, late;
            if (!$value$plusargs("LATE=%d", late)) late = 1;
            submit_batch(0, 1, 3000, o); submit_batch(1, 1, 3000, o); wait_drain(200000, ok);
            sid0 = ln[0].sid;
            $display("  [cyc=%0d] warm-up drained=%0b  lane0 sid=%0d lane1 sid=%0d", cyc, ok, sid0, ln[1].sid);
            body_ready_ctl[0] = 1'b0;                  // lane 0's decoder stops FOREVER
            lane_ignore[0]    = 1;                     // its stream is cut on purpose
            submit_batch(0, 1, 400000, o);
            // let ~200 KB out (more than lane 0's fifo holds), keep the rest at the origin
            t0 = cyc;
            while ((cyc - t0) < 200000 &&
                   !(sess.exists(sid0) && sess[sid0].pending.size() > 0 && sess[sid0].pending.size() < 200000))
                @(posedge clk);
            hold_sid = sid0;
            $display("  [cyc=%0d] origin holds sid %0d's remaining %0d bytes", cyc, sid0, sess[sid0].pending.size());
            c0 = n_close_req; t0 = cyc;
            while ((cyc - t0) < 400000 && n_close_req == c0) @(posedge clk);
            $display("  [cyc=%0d] handler closed sid %0d (closes=%0d) lane0 fatal=%0b dead-sticky=%0b",
                     cyc, sid0, n_close_req, lane_is_fatal(0), lane_dead_sticky(0));
            ln[0].planned_total = ln[0].resp_done; ln[0].plan = {}; ln[0].expq = {};
            ln[0].active = 0; ln[0].must_end = 0;
            b1 = ln[1].resp_done;
            hold_pend_trim(sid0, late * mss);
            if (!$test$plusargs("MIDBODY")) begin
                hold_sid = -1;                         // the late segment(s) go out now...
                wait_cycles(5000);
                submit_batch(1, 3, 3000, o);           // ...and lane 1 carries on
            end else begin
                automatic int sid1 = ln[1].sid;
                automatic int p0;
                hold2_sid = sid1;                      // lane 1's origin output is paced by hand
                submit_batch(1, 3, 20000, o);
                t0 = cyc;
                while ((cyc - t0) < 200000 && sess[sid1].pending.size() < 60000) @(posedge clk);
                p0 = sess[sid1].pending.size();
                hold2_sid = -1;                        // two of lane 1's segments go out...
                while ((cyc - t0) < 200000 && sess[sid1].pending.size() > p0 - 8192) @(posedge clk);
                hold2_sid = sid1;
                hold_sid  = -1;                        // ...then the closed session's late segment...
                while ((cyc - t0) < 200000 && sess[sid0].pending.size() > 0) @(posedge clk);
                $display("  [cyc=%0d] origin: 2 lane-1 segments, then sid %0d's late segment, then the rest of lane 1",
                         cyc, sid0);
                hold2_sid = -1;                        // ...then the rest of lane 1
            end
            wait_drain(300000, ok);
            dump("cu");
            $display("  lane 1: %0d -> %0d responses (planned %0d), errors=%0d, readPkgs that popped another session's packet: %0d",
                     b1, ln[1].resp_done, ln[1].planned_total, n_err, n_meta_mismatch);
            if (n_err)      verdict = $sformatf("CORRUPT (%0d checker errors on the surviving lane)", n_err);
            else if (!ok)   verdict = "HANG (the surviving lane never completed)";
            else            verdict = "PASS";
        end

        // (cuovf) handler_toe only, see toe_cu.
        "cuovf": if (DUT_TOE != 0) toe_cu(1'b1); else verdict = "SKIP (handler_toe scenario)";

        "fin_overtake": if (DUT_TOE != 0) toe_fin_overtake(); else verdict = "SKIP (handler_toe scenario)";
        "win_ok":       if (DUT_TOE != 0) toe_scen_win(1'b0);      else verdict = "SKIP (handler_toe scenario)";
        "win_bad":      if (DUT_TOE != 0) toe_scen_win(1'b1);      else verdict = "SKIP (handler_toe scenario)";
        "sidreuse":     if (DUT_TOE != 0) toe_scen_sidreuse();     else verdict = "SKIP (handler_toe scenario)";
        "thr_ring":      if (DUT_TOE != 0) toe_thr_ring();      else verdict = "SKIP (handler_toe scenario)";

        default: begin $display("unknown scenario '%s'", scen); $finish; end
        endcase

        wait_cycles(50);
        check_sticky();
        $display("\n------------------------------------------------------------------");
        $display("lane_drain_tb '%s' (NUM_CONNS=%0d): %s", scen, NUM_CONNS, verdict);
        $display("  errors=%0d  liveness_failed=%0b(cyc %0d)  config_stalled=%0b(cyc %0d)",
                 n_err, liveness_failed, liveness_cycle, cfg_stalled, cfg_stall_cycle);
        for (int i = 0; i < NL; i++)
            $display("  lane %0d: %0d/%0d responses framed, %0d body bytes, session %0d",
                     i, ln[i].resp_done, ln[i].planned_total, ln[i].bytes_in, ln[i].sid);
        $display("  readPkgs=%0d notifications=%0d outstanding=%0d sharedFIFO=%0d opens=%0d closes=%0d",
                 rp_issued, n_notif_sent, outst.size(), gfifo.size(), n_open_rsp, n_close_req);
        $display("  readPkgs that popped another session's packet: %0d", n_meta_mismatch);
        $display("------------------------------------------------------------------\n");
        $finish;
    end

    initial begin
        int c0;
        wait (rst_n === 1'b1);
        c0 = cyc;
        // Re-read every cycle rather than `repeat (MAX_CYCLES)`, so a scenario may raise it.
        while ((cyc - c0) < MAX_CYCLES) @(posedge clk);
        $display("!!! global watchdog fired at %0d cycles", cyc);
        dump("watchdog");
        $display("lane_drain_tb '%s': WATCHDOG", scen);
        $finish;
    end

endmodule
