`timescale 1ns / 1ps
// =================================================================================================
// lane_drain_tb -- INDEPENDENT black-box liveness bench for handler_multi AND handler_slots.
//
// Written from the external contract only.  Nothing below handler_multi's or rx_dispatch's port
// list was read, and none of the RTL author's benches were consulted.
//
// TWO DUTs, ONE BENCH
// -------------------
// DUT_SLOTS selects which handler is instantiated.  Everything outside it -- the TOE, the origin
// server, the host and the decoder sinks -- is IDENTICAL, which is the point: the scenarios are the
// contract, and the contract did not change when the datapath moved into HBM.  With DUT_SLOTS=1 the
// bench also instantiates unit-tests/card_dma/card_dma_model.sv, so the card path is modelled with
// its real rules (byte-granular vaddr/len, normalised keep, acks in issue order, and a FAIL on any
// read of a byte that was never written or that overlaps an un-acked write).
//
// WHAT THE HOST HAS TO DO DIFFERENTLY, AND WHY
// --------------------------------------------
// handler_slots takes ONE GET PER ARM (each arm is one reader entry), so in slots mode a batch of N
// GETs becomes N arms of one GET each, issued by a per-lane FEEDER process.  Since CSR revision 4
// the hardware no longer holds a second arm on a connection until its slot is empty (revision 3
// did, "depth 1"); the feeder therefore keeps the two host rules software keeps: at most +HDEPTH
// GETs outstanding per connection (4; HDEPTH=1 reproduces revision 3's pacing), and the bytes armed
// since CONN_DRAINED was last seen set must fit in the slot.  +SRVLAT gives the origin a
// request->response latency so pipelining has something to hide; +COALESCE lets responses share
// TCP segments.
//
// The feeder is asynchronous on purpose.  submit_batch returns as soon as the work is queued rather
// than when the last GET has been armed, so a scenario that says "queue six responses on this lane
// and then stop its decoder" still means that -- if submit_batch blocked until the sixth arm was
// accepted, the whole batch would have drained before the scenario got to stop anything, and d, e,
// s_d and s_e would all quietly stop testing what they were written to test.
//
// handler_multi's runs are unaffected: with DUT_SLOTS=0 the host model is exactly what it was.
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
    // handler_multi's connect watchdog, in cycles: it raises the sticky conn_stall bit and, with it,
    // gives BR_OPEN its only escape. Left at the DUT's own default for every scenario but 'lz2',
    // which has to WAIT for it -- 2^28 cycles is a second of wall clock on the board and a week in
    // xsim, so that one scenario gets its own snapshot with a small value.
    parameter int STALL_CYCLES  = 268435456,

    // 0 = handler_multi (build-119, the control arm).  1 = handler_slots + the card DMA model.
    parameter int DUT_SLOTS = 0,
    // log2 of one connection's slot, slots DUT only.  19 = 512 KiB, so the host's biggest legal GET
    // is 512 - 64 = 448 KiB.  That is small enough to keep the model's card memory and the bench's
    // byte-by-byte checking cheap, and big enough that s_d's 400000-byte response -- the one that
    // is deliberately larger than build-119's whole lane fifo -- still fits in a slot.  The `ovf`
    // scenario gets its own snapshot with a small value so the overflow happens quickly.
    parameter int SLOT_LOG2 = 19,
    // handler_slots' CSR revision. 5 = stage 2 (the arm names its connection in req_conn); 4 = the
    // revision-4 decoding, conn == decoder. With NUM_DEC == NUM_CONNS both run the same scenarios.
    parameter int CSR_REV = 5,
    // Decoders ("lanes" everywhere below). 0 = NUM_CONNS, the stage-1 shape every scenario was
    // written for: lane L = connection L = decoder L. A smaller value is STAGE 2 (slots DUT,
    // revision 5 only): the host model then places every GET on a connection of its own choosing
    // -- see "STAGE-2 HOST MODEL" -- and the s2* scenarios apply.
    parameter int NUM_DEC = 0,
    // 1 = handler_toe (the TOE with a receive ring per session, RX_DDR_BYPASS = 0), against the
    // NON-BYPASS TOE MODEL below instead of the shared-fifo one. Needs DUT_SLOTS = 0.
    parameter int DUT_TOE = 0,
    // handler_toe's FIN settle, exposed so a mutant can be run (fin_overtake must fail at ~200).
    parameter int TOE_CLOSE_SETTLE = 4096,
    // handler_toe's FRAMER_SLICE, exposed so the variant without the 61ad533 slice can be run.
    parameter bit TOE_FRAMER_SLICE = 1'b1
);
    localparam int  NL     = (NUM_DEC > 0) ? NUM_DEC : NUM_CONNS;
    localparam bit  STAGE2 = (NL != NUM_CONNS);
    initial if (STAGE2 && (DUT_SLOTS == 0 || CSR_REV < 5))
        $fatal(1, "lane_drain_tb: NUM_DEC < NUM_CONNS needs DUT_SLOTS=1 and CSR_REV >= 5");
    initial if (DUT_TOE != 0 && (DUT_SLOTS != 0 || STAGE2))
        $fatal(1, "lane_drain_tb: DUT_TOE=1 needs DUT_SLOTS=0 and NUM_DEC=0");
    // The host model for handler_slots AND handler_toe: one GET per arm, through the feeder.
    localparam bit FEEDER = (DUT_SLOTS != 0) || (DUT_TOE != 0);

    localparam int BPB            = AXI_DATA_BITS/8;
    localparam longint TOE_RING   = longint'(1) << 20;   // the non-bypass TOE's ring per session
    localparam int LIVENESS_BOUND = 100000;   // cycles without a readPkg while work is queued
    // Variables rather than localparams since the `feed` scenario (unit-tests/decoder_feed): at the
    // real time scale a host can legitimately wait longer than 200k cycles for a connection (MinIO
    // holds one for ~2.5 ms = 600k cycles), and a run is longer than 4M cycles. +CFGBOUND= +MAXCYC=.
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

    // -- slots DUT only: the card DMA side, and the revision-3 readback ----------------------------
    localparam longint unsigned SLOT_BYTES = longint'(1) << SLOT_LOG2;
    // A deliberately non-zero base, so a slot_base that was dropped somewhere reads as a model
    // "outside the modelled card memory" FAIL rather than working by accident at address 0.
    localparam longint unsigned SLOT_BASE  = 64'h0000_0000_4000_0000;

    logic [VADDR_BITS-1:0]      slot_base_w;
    assign slot_base_w = VADDR_BITS'(SLOT_BASE);

    logic                       cw_req_valid, cw_req_ready, cw_req_last, cw_ack;
    logic [VADDR_BITS-1:0]      cw_req_vaddr;
    logic [LEN_BITS-1:0]        cw_req_len;
    logic                       cw_tvalid, cw_tready, cw_tlast;
    logic [AXI_DATA_BITS-1:0]   cw_tdata;
    logic [AXI_DATA_BITS/8-1:0] cw_tkeep;

    // The most one card read may ask for. 16 KiB since 2026-09-22, when the per-decoder card read
    // channels became one shared one; it also sizes slot_rd_share's receive fifos at 2 x this.
    localparam int RD_MAX_BYTES = 16384;

    // Reader side: one port per decoder, into slot_rd_share.
    logic                       cr_req_valid [NL];
    logic                       cr_req_ready [NL];
    logic [VADDR_BITS-1:0]      cr_req_vaddr [NL];
    logic [LEN_BITS-1:0]        cr_req_len   [NL];
    logic                       cr_req_last  [NL];
    logic                       cr_tvalid [NL];
    logic                       cr_tready [NL];
    logic [AXI_DATA_BITS-1:0]   cr_tdata  [NL];
    logic [AXI_DATA_BITS/8-1:0] cr_tkeep  [NL];
    logic                       cr_tlast  [NL];

    // Channel side: the one read half of the one card channel.
    logic                       sh_req_valid, sh_req_ready, sh_req_last;
    logic [VADDR_BITS-1:0]      sh_req_vaddr;
    logic [LEN_BITS-1:0]        sh_req_len;
    logic                       sh_tvalid, sh_tready, sh_tlast;
    logic [AXI_DATA_BITS-1:0]   sh_tdata;
    logic [AXI_DATA_BITS/8-1:0] sh_tkeep;
    logic                       share_order_err, share_fifo_err, share_len_err;

    // ...as the model's one-element port arrays want it.
    logic                       m_rd_req_valid [1];
    logic                       m_rd_req_ready [1];
    logic [VADDR_BITS-1:0]      m_rd_req_vaddr [1];
    logic [LEN_BITS-1:0]        m_rd_req_len   [1];
    logic                       m_rd_req_last  [1];
    logic                       m_rd_tvalid [1];
    logic                       m_rd_tready [1];
    logic [AXI_DATA_BITS-1:0]   m_rd_tdata  [1];
    logic [AXI_DATA_BITS/8-1:0] m_rd_tkeep  [1];
    logic                       m_rd_tlast  [1];
    logic                       m_rd_ack    [1];

    logic       dma_fail;
    int         dma_errors;
    logic [3:0][63:0] connOccWord;
    logic [1:0][63:0] connReadyWord;
    logic [3:0][63:0] connErrWord;
    logic      [63:0] connDrainedWord, slotPolicyWord;
    logic [5:0][63:0] connExtWord;   // revision 5, read ids 33..38

    // CONN_DRAINED, register 31: [c] the slot is empty and nothing is armed on it (revision 4: the
    // host's byte-budget reset; revision 3: the depth-1 credit). The feeder budgets on it.
    function automatic bit conn_drained(input int c); return connDrainedWord[c]; endfunction
    function automatic bit conn_overflowed(input int c); return connDrainedWord[32 + c]; endfunction

    // Revision 5 (stage 2). DEC_STATE (33) per decoder, CONN_MAP (34..37) per connection, CONN_CAUSE
    // (38). See the map in http_config.sv.
    function automatic bit dec_arm_ok(input int d);    return connExtWord[0][8*d + 0]; endfunction
    function automatic bit dec_entry_ok(input int d);  return connExtWord[0][8*d + 1]; endfunction
    function automatic bit dec_tainted(input int d);   return connExtWord[0][8*d + 2]; endfunction
    function automatic int conn_pend(input int c);     return int'(connExtWord[1 + c/8][8*(c%8) + 4 +: 4]); endfunction
    function automatic int conn_curdec(input int c);   return int'(connExtWord[1 + c/8][8*(c%8) +: 3]); endfunction
    function automatic bit conn_is_tail(input int c);  return connExtWord[1 + c/8][8*(c%8) + 3]; endfunction
    function automatic bit conn_tainter(input int c);  return connExtWord[5][32 + c]; endfunction
    function automatic bit conn_fatal(input int c);    return connReadyWord[c/16][4*(c%16) + 3]; endfunction
    function automatic bit conn_is_up(input int c);    return connReadyWord[c/16][4*(c%16) + 2]; endfunction

    generate
    if (DUT_TOE != 0) begin : g_toe

    assign dma_fail        = 1'b0;
    assign dma_errors      = 0;
    assign share_order_err = 1'b0;
    assign share_fifo_err  = 1'b0;
    assign share_len_err   = 1'b0;
    assign connOccWord = '0; assign connReadyWord = '0; assign connErrWord = '0;
    assign connDrainedWord = '0; assign slotPolicyWord = '0; assign connExtWord = '0;

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

    end else if (DUT_SLOTS == 0) begin : g_multi

    assign dma_fail        = 1'b0;
    assign dma_errors      = 0;
    assign share_order_err = 1'b0;
    assign share_fifo_err  = 1'b0;
    assign share_len_err   = 1'b0;
    assign connOccWord = '0; assign connReadyWord = '0; assign connErrWord = '0;
    assign connDrainedWord = '0; assign slotPolicyWord = '0; assign connExtWord = '0;

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

    end else begin : g_slots   // ------------------------------------------------------------------

    handler_slots #(
        .N_CONNS        (NUM_CONNS),
        .N_DECODERS     (NL),
        .QUEUE_DEPTH    (QUEUE_DEPTH),
        .ENTRY_DEPTH    (QUEUE_DEPTH),
        .SLOT_LOG2      (SLOT_LOG2),
        .SLOT_FIFO_DEPTH(1024),
        .RD_MAX         (RD_MAX_BYTES),
        .STALL_CYCLES   (STALL_CYCLES),
        .CSR_REV        (CSR_REV)
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
        // What the host writes to SLOT_BASE_LO/HI, and what it must have offloaded to the card.
        .slot_base(slot_base_w),
        .s_axis_req_TVALID(rq_tvalid), .s_axis_req_TREADY(rq_tready),
        .s_axis_req_TDATA (rq_tdata),  .s_axis_req_TKEEP (rq_tkeep),
        .s_axis_req_TLAST (rq_tlast),
        .m_axis_body_tvalid(bd_tvalid), .m_axis_body_tready(bd_tready),
        .m_axis_body_tdata (bd_tdata),  .m_axis_body_tkeep (bd_tkeep),
        .m_axis_body_tlast (bd_tlast),

        .wr_req_valid(cw_req_valid), .wr_req_ready(cw_req_ready),
        .wr_req_vaddr(cw_req_vaddr), .wr_req_len(cw_req_len), .wr_req_last(cw_req_last),
        .m_axis_card_tvalid(cw_tvalid), .m_axis_card_tready(cw_tready),
        .m_axis_card_tdata (cw_tdata),  .m_axis_card_tkeep (cw_tkeep),
        .m_axis_card_tlast (cw_tlast),
        .wr_ack(cw_ack),

        .rd_req_valid(cr_req_valid), .rd_req_ready(cr_req_ready),
        .rd_req_vaddr(cr_req_vaddr), .rd_req_len(cr_req_len), .rd_req_last(cr_req_last),
        .s_axis_card_tvalid(cr_tvalid), .s_axis_card_tready(cr_tready),
        .s_axis_card_tdata (cr_tdata),  .s_axis_card_tkeep (cr_tkeep),
        .s_axis_card_tlast (cr_tlast),

        .totalWord(totalWord), .inflightWord(inflightWord), .queueDepthWord(queueDepthWord),
        .stallWord(stallWord), .respWord(respWord), .contentLengthWord(contentLengthWord),
        .bodyRemainingWord(bodyRemainingWord), .state_debug(state_debug),
        .laneOccWord(laneOccWord), .laneReadyWord(laneReadyWord), .laneStateWord(laneStateWord),
        .laneErrWord(laneErrWord), .lanePolicyWord(lanePolicyWord),
        .connOccWord(connOccWord), .connReadyWord(connReadyWord), .connErrWord(connErrWord),
        .connDrainedWord(connDrainedWord), .slotPolicyWord(slotPolicyWord),
        .connExtWord(connExtWord)
    );

    // The REAL topology since 2026-09-22: every decoder's reader reaches ONE card read channel
    // through slot_rd_share, which holds their receive fifos and the credit. build-123 failed
    // route_design with five card AXI streams, so this -- and not a channel per decoder -- is what
    // the black-box scenarios have to be true of. `thr` and `dmabp` are the ones that would notice:
    // a shared stream back-pressured by a slow decoder is exactly the coupling they test for.
    slot_rd_share #(
        .N_RD  (NL),
        .RD_MAX(RD_MAX_BYTES)
    ) rdshare (
        .clk(clk), .rst_n(rst_n),
        .rd_req_valid(cr_req_valid), .rd_req_ready(cr_req_ready),
        .rd_req_vaddr(cr_req_vaddr), .rd_req_len(cr_req_len), .rd_req_last(cr_req_last),
        .rd_tvalid(cr_tvalid), .rd_tready(cr_tready),
        .rd_tdata (cr_tdata),  .rd_tkeep (cr_tkeep), .rd_tlast(cr_tlast),
        .ch_req_valid(sh_req_valid), .ch_req_ready(sh_req_ready),
        .ch_req_vaddr(sh_req_vaddr), .ch_req_len(sh_req_len), .ch_req_last(sh_req_last),
        .ch_tvalid(sh_tvalid), .ch_tready(sh_tready),
        .ch_tdata (sh_tdata),  .ch_tkeep (sh_tkeep), .ch_tlast(sh_tlast),
        .order_err(share_order_err), .fifo_err(share_fifo_err), .len_err(share_len_err),
        .credit_ok(), .oq_occ()
    );

    assign m_rd_req_valid[0] = sh_req_valid;
    assign sh_req_ready      = m_rd_req_ready[0];
    assign m_rd_req_vaddr[0] = sh_req_vaddr;
    assign m_rd_req_len[0]   = sh_req_len;
    assign m_rd_req_last[0]  = sh_req_last;
    assign sh_tvalid         = m_rd_tvalid[0];
    assign m_rd_tready[0]    = sh_tready;
    assign sh_tdata          = m_rd_tdata[0];
    assign sh_tkeep          = m_rd_tkeep[0];
    assign sh_tlast          = m_rd_tlast[0];

    // Coyote's card path, with its real rules. MEM_BASE/MEM_BYTES bound the window exactly to the
    // slots this configuration owns, so a vaddr that is wrong by a slot is an error rather than a
    // silent write into a neighbour.
    card_dma_model #(
        .N_RD     (1),
        .MEM_BASE (SLOT_BASE),
        .MEM_BYTES(longint'(NUM_CONNS) * SLOT_BYTES)
    ) cdma (
        .clk(clk), .rst_n(rst_n),
        .wr_req_valid(cw_req_valid), .wr_req_ready(cw_req_ready),
        .wr_req_vaddr(cw_req_vaddr), .wr_req_len(cw_req_len), .wr_req_last(cw_req_last),
        .wr_tvalid(cw_tvalid), .wr_tready(cw_tready),
        .wr_tdata (cw_tdata),  .wr_tkeep (cw_tkeep), .wr_tlast(cw_tlast),
        .wr_ack(cw_ack),
        .rd_req_valid(m_rd_req_valid), .rd_req_ready(m_rd_req_ready),
        .rd_req_vaddr(m_rd_req_vaddr), .rd_req_len(m_rd_req_len), .rd_req_last(m_rd_req_last),
        .rd_tvalid(m_rd_tvalid), .rd_tready(m_rd_tready),
        .rd_tdata (m_rd_tdata),  .rd_tkeep (m_rd_tkeep), .rd_tlast(m_rd_tlast),
        .rd_ack(m_rd_ack),
        .model_fail(dma_fail), .model_errors(dma_errors)
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
        // Sequence number the slots-mode feeder has reached. Separate from next_seq because the
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
    // (RX_DDR_BYPASS = 0, patches 0007/0008). From the contract in oasis-debug/2026-10-11/
    // toe-buffer/WP1.md, not from the RTL:
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
    initial begin : open_svc
        Sess s; int lat, sid;
        os_tvalid = 1'b0; os_tdata = '0;
        forever begin
            @(posedge clk);
            if (rst_n && !open_hang && openq.size() > 0) begin
                void'(openq.pop_front());
                lat = 40 + ($urandom_range(0, 240));      // tens..hundreds of cycles
                repeat (lat) @(posedge clk);
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
                $display("  [cyc=%0d] TOE: opened session %0d (open request #%0d)", cyc, sid, n_open_rsp);
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
                // segment after a real-scale MinIO time to first byte (0.8 ms = 200k cycles,
                // decoder_feed). A wedge keeps a notification outstanding, so it still counts.
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

    // ORIGIN PACING (decoder_feed). Three knobs, all off by default so every older scenario is
    // byte for byte what it was:
    //   +SRVSER      the origin answers the requests of ONE connection ONE AT A TIME, the way Go's
    //                net/http (MinIO) serves pipelined GETs: request k+1's time to first byte
    //                (SRVLAT + 0..SRVJIT) starts when response k has left, or when k+1 arrived if
    //                that is later. Pipelining then hides the request round trip, not the TTFB.
    //   +SRVRATE=    per-connection send rate, milli-bytes per cycle (920 = 230 MB/s at 250 MHz):
    //                a token bucket per session that fills only while it has bytes to send (at most
    //                two segments) and, under SRVSER, starts EMPTY at each response -- idle credit
    //                would send the first 8 KiB of every response the instant its TTFB ends.
    //   +LINKBPC=    the shared wire in bytes per cycle (64 = the old line rate; 50 = 100 Gb/s).
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
        if (!STAGE2) begin
            r = ln[lane].plan.pop_front();
        end else begin
            // Stage 2: a lane's GETs travel on several connections, so they reach the origin in no
            // particular order. Find this one by its sequence number; its place on the body stream
            // was fixed when it was ARMED (s2_arm), not here.
            int k; k = -1;
            foreach (ln[lane].plan[j]) if (k < 0 && ln[lane].plan[j].seq == seq) k = j;
            if (k < 0) begin
                err($sformatf("lane %0d: request seq %0d is not in the plan (duplicate GET?)", lane, seq));
                return;
            end
            r = ln[lane].plan[k];
            ln[lane].plan.delete(k);
        end
        len = r.len;
        hdr = resp_header(len);
        if (!STAGE2) ln[lane].expq.push_back(r);
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
                        if (STAGE2) begin
                            // A connection carries whichever lane it was armed for; no binding.
                            s.lane = lane;
                            ln[lane].sid = sid;
                        end else if (s.lane < 0) begin
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
    // A peer that has stopped sending. Scenarios that kill a connection use it to stop the origin
    // queueing MORE bytes for a session that is about to go away -- see the note in `ovf`.
    int  mute_sid = -1;
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
                    if (k != mute_sid && k != hold_sid && k != hold2_sid && sess[k].pending.size() > 0 && rate_ok(k) &&
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
    // THROTTLE_DIV cycles, which is the exact shape of the experiment that exposed the coupling in
    // build-117's model (unit-tests/rx_perf, SLOW=1 SLOWDIV=4): 16 bytes per cycle is a quarter of
    // line rate, and 4 bytes per cycle at SLOWDIV=16.
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
    // decoder at once, which is the question decoder_feed asks.
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

    // =============================================================================================
    // DECODER-FEED MEASUREMENT (scenario `feed`; unit-tests/decoder_feed/run.sh)
    //
    // Over a steady-state window (fmeas), per decoder:
    //   * the model's WORK: busy% = work / window, exact (in 1/1024-cycle units, so a decoder that
    //     finishes a beat half way through a cycle and then has nothing is 50% busy that cycle);
    //   * the hardware StreamProfiler's four counters, same semantics as
    //     parcore/libstf/hardware/src/hdl/util/stream_profiler.sv: handshake (valid & ready),
    //     stalled (valid & !ready), starved (!valid INSIDE a chunk: after the first beat, before the
    //     tlast), idle (!valid between chunks). With a 1.28 GB/s decoder a handshake is at most 1 cycle
    //     in 12.5, so a decoder-bound lane shows ~8% handshake and ~92% STALLED, and starved+idle is
    //     what the decoder lost;
    //   * every lost 1/1024-cycle CLASSIFIED by what the receive path was doing at that moment (dcls,
    //     set by g_feedstat from the DUT's own state -- slots DUT only):
    //       EMPTY    the reader has no entry at all: the host has not queued work for this decoder
    //                (lane depth, dispatcher, connection placement)
    //       SWITCH   the per-response TURNAROUND: the reader is retiring / releasing / taking the
    //                next entry, or the next response's bytes are in HBM or in the read path but not
    //                one body byte of it has reached the decoder yet -- the first card read of a new
    //                connection (after the empty-slot release) and strip_http's byte-serial parse of
    //                the next header (on a switch AND on a same-connection continue)
    //       CONNECT  the head's connection is not up
    //       RDPATH   mid-response, the head's bytes are in HBM / the shared card read channel /
    //                slot_rd_share / the framer but not at the decoder
    //       WRPATH   the head's next bytes are between the TOE and HBM (rx_dispatch, the writer
    //                fifo, an un-acked card write)
    //       HOL      the head waits for the network while a LATER entry of this decoder already has
    //                bytes in its slot: head-of-line on a slow response
    //       SERVER   the head waits for the network and nothing behind it has arrived either
    //       SHORT    a beat too small to cover a cycle (a response's last bytes); not a stall
    // =============================================================================================
    localparam int FC_N = 9;
    localparam int FC_EMPTY = 1, FC_SWITCH = 2, FC_CONNECT = 3, FC_RDPATH = 4, FC_WRPATH = 5,
                   FC_HOL = 6, FC_SERVER = 7, FC_SHORT = 8;
    bit     fmeas = 1'b0;
    longint f_cyc = 0;
    longint f_work [NL], f_lost [NL], f_bytes [NL];
    longint f_hs [NL], f_stall [NL], f_starv [NL], f_idle [NL];
    longint f_cls  [NL][FC_N];
    longint f_pops [NL], f_rels [NL];
    bit     f_inchunk [NL];
    int     dcls [NL];
    // connection time over the ACTIVE connections: free (the host may place a GET on it), waiting
    // (a GET is armed and its bytes have not all landed), held (every byte armed on it has landed
    // and the slot waits for its reader to consume and release it)
    longint f_cfree = 0, f_cwait = 0, f_cheld = 0;
    // the card channels: beats moved, and the most writes ever outstanding
    longint f_wr_beats = 0, f_rd_beats = 0;
    int     f_wr_out_max = 0;
    task automatic feed_stats_clear();
        f_cyc = 0; f_cfree = 0; f_cwait = 0; f_cheld = 0; f_wr_beats = 0; f_rd_beats = 0;
        f_wr_out_max = 0;
        for (int L = 0; L < NL; L++) begin
            f_work[L] = 0; f_lost[L] = 0; f_bytes[L] = 0; f_hs[L] = 0; f_stall[L] = 0;
            f_starv[L] = 0; f_idle[L] = 0; f_pops[L] = 0; f_rels[L] = 0;
            for (int k = 0; k < FC_N; k++) f_cls[L][k] = 0;
        end
    endtask

    always @(posedge clk) begin
        if (fmeas) f_cyc = f_cyc + 1;
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
            if (fmeas && dec_cost > 0) begin
                f_work[L] = f_work[L] + w;
                f_lost[L] = f_lost[L] + (1024 - w);
                if (w < 1024) begin
                    if (bd_tvalid[L]) f_cls[L][FC_SHORT] = f_cls[L][FC_SHORT] + (1024 - w);
                    else              f_cls[L][dcls[L]]  = f_cls[L][dcls[L]]  + (1024 - w);
                end
                if (hs) begin
                    f_hs[L] = f_hs[L] + 1;
                    f_bytes[L] = f_bytes[L] + longint'(nb);
                end
                else if (bd_tvalid[L]) f_stall[L] = f_stall[L] + 1;
                else if (f_inchunk[L]) f_starv[L] = f_starv[L] + 1;
                else                   f_idle[L]  = f_idle[L] + 1;
            end
            if (!rst_n)                  f_inchunk[L] = 1'b0;
            else if (hs && bd_tlast[L])  f_inchunk[L] = 1'b0;
            else if (bd_tvalid[L])       f_inchunk[L] = 1'b1;
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
        // Stage-1 shape: lane L's connection is L (revision 5 reads it; revision 4 ignores it).
        c.req_conn        = 5'(dest);
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
    // DEPTH-1 HOST MODEL (slots DUT)
    //
    // handler_slots allows one outstanding GET per connection and says so at the config port:
    // ARM_READY is low until the slot has been released. So a batch of N GETs becomes N arms of one
    // GET each, and the pacing is the hardware's credit rather than a delay the bench chose.
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
    // Host-side pipelining state for the slots DUT (CSR revision 4). +HDEPTH=1 reproduces what the
    // revision-3 hardware enforced by itself.
    localparam int HDR_ALLOW = 256;
    bit  allow_overflow = 0;   // `ovf`: a slot is overrun on purpose
    int  hdepth = 4;
    int  armed_n     [NL];
    int  ent_n_lane  [NL];   // chunk entries pushed
    int  armed_bytes [NL];
    // The LANE's chunk depth: hdepth in stage 1 (lane = connection), and in stage 2 enough to
    // keep every connection of the lane's share busy (+LDEPTH overrides).
    int  ldepth;
    initial begin
        void'($value$plusargs("HDEPTH=%d", hdepth));
        ldepth = STAGE2 ? hdepth * ((NUM_CONNS + NL - 1) / NL) : hdepth;
        void'($value$plusargs("LDEPTH=%d", ldepth));
        for (int c = 0; c < NL; c++) begin armed_n[c] = 0; armed_bytes[c] = 0; ent_n_lane[c] = 0; end
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

    // In stage 2 a lane is a decoder, and its admission half is DEC_STATE's (the per-connection
    // nibble describes a connection's current decoder, which is not the lane's).
    function automatic bit lane_arm_ready(input int L);
        return STAGE2 ? dec_arm_ok(L) : laneReadyWord[4*L + 0];
    endfunction
    function automatic bit lane_entry_ready(input int L);
        return STAGE2 ? dec_entry_ok(L) : laneReadyWord[4*L + 1];
    endfunction

    // =============================================================================================
    // STAGE-2 HOST MODEL (NUM_DEC < NUM_CONNS)
    //
    // What software/oasis does on a revision-5 bitstream, reduced to the rule the hardware checks:
    // every GET goes on a connection the host picks, and an arm for connection c on decoder L is
    // only admitted if c is FREE (CONN_DRAINED and nothing pending) or c is L's TAIL (the last
    // connection L took an arm for, still with entries). The model prefers a free connection --
    // spreading GETs over connections is the whole point of stage 2 -- round robin over the first
    // +S2CONNS (default all), and falls back to pipelining on the tail up to +HDEPTH GETs, each
    // connection's armed bytes kept under the slot as in revision 4.
    //
    // The choice and the beat are made under cfg_lock, so two lanes' feeders can never pick the same
    // free connection. The hardware words it reads are REGISTERED (a cycle or two stale), so a
    // connection this model armed less than S2_SETTLE cycles ago is not trusted to be free yet.
    // =============================================================================================
    localparam int S2_SETTLE = 8;
    int  s2_conns      = NUM_CONNS;
    int  s2_rr         = 0;
    int  s2_tail  [NL];
    int  s2_armcyc[NUM_CONNS];
    int  s2_hpend [NUM_CONNS];       // host view: armed on c since it was last seen free
    longint s2_bytes[NUM_CONNS];
    int  s2_used  [NUM_CONNS];       // GETs ever armed on c
    int  s2_lane_of_last[NUM_CONNS]; // the lane c's last GET was armed on
    bit  s2_ever_lane[NUM_CONNS][NL];
    int  s2_max_busy   = 0;          // most connections with entries pending at once (CONN_MAP)
    int  s2_n_tail     = 0, s2_n_free = 0;
    // decoder_feed: the exact response bytes (header + body) armed on c since it was last free, so
    // the measurement can tell "every byte of it has landed" from "still arriving"; and how long the
    // host sleeps between two failed picks (pick_conn polls every 20 us; 1 = every cycle, the old
    // behaviour).
    longint s2_exp [NUM_CONNS];
    int  s2_poll       = 1;
    longint h_noconn_cyc = 0;        // cycles (in the window) the host spent polling for a connection
    longint h_noadm_cyc  = 0;        // ...of them, with the DECODER half refusing (DEC_STATE arm_ok low)
    function automatic int resp_hdr_len(input int len);
        string h;
        h = resp_header(len);
        return h.len();
    endfunction
    initial begin
        void'($value$plusargs("S2CONNS=%d", s2_conns));
        for (int L = 0; L < NL; L++) s2_tail[L] = -1;
        for (int c = 0; c < NUM_CONNS; c++) begin
            s2_armcyc[c] = -1000; s2_hpend[c] = 0; s2_bytes[c] = 0; s2_used[c] = 0; s2_exp[c] = 0;
            s2_lane_of_last[c] = -1;
            for (int L = 0; L < NL; L++) s2_ever_lane[c][L] = 0;
        end
    end
    always @(posedge clk) if (rst_n && STAGE2) begin
        int n; n = 0;
        for (int c = 0; c < NUM_CONNS; c++) if (conn_pend(c) != 0) n = n + 1;
        if (n > s2_max_busy) s2_max_busy = n;
    end

    function automatic bit s2_hw_settled(input int c); return (cyc - s2_armcyc[c]) > S2_SETTLE; endfunction
    function automatic bit s2_free(input int c);
        return s2_hw_settled(c) && conn_drained(c) && (conn_pend(c) == 0) && !conn_fatal(c);
    endfunction

    // Pick a connection for one GET of `need` bytes on lane L; -1 if none can take it right now.
    function automatic int s2_pick(input int L, input longint need);
        int t;
        for (int k = 0; k < s2_conns; k++) begin
            automatic int c = (s2_rr + k) % s2_conns;
            if (s2_free(c)) begin s2_rr = (c + 1) % s2_conns; return c; end
        end
        t = s2_tail[L];
        if (t >= 0 && !conn_fatal(t) && s2_hw_settled(t) && conn_pend(t) != 0 && conn_curdec(t) == L &&
            conn_is_tail(t) && conn_pend(t) < hdepth &&
            (allow_overflow || (s2_bytes[t] + need) <= longint'(SLOT_BYTES)))
            return t;
        return -1;
    endfunction

    // One arm of stage 2: pick, then the beat, both under the port lock. `r` is this GET's response.
    task automatic s2_arm(input int L, input http_config_t cfg0, input int need, input Resp r,
                          output bit ok);
        int t0, guard, c;
        http_config_t cfg;
        t0 = cyc; ok = 1'b0;
        while ((cyc - t0) < CFG_BOUND && !ok) begin
            cfg_lock.get(1);
            c = lane_arm_ready(L) ? s2_pick(L, need) : -1;
            if (c >= 0) begin
                if (s2_free(c)) begin s2_bytes[c] = 0; s2_hpend[c] = 0; s2_exp[c] = 0; s2_n_free++; end
                else s2_n_tail++;
                cfg = cfg0; cfg.req_conn = 5'(c);
                @(posedge clk);
                req_data <= cfg; req_valid <= 1'b1;
                guard = 0;
                while (guard < 16 && !ok) begin
                    @(posedge clk);
                    if (req_ready) ok = 1'b1;
                    guard = guard + 1;
                end
                req_valid <= 1'b0;
                if (ok) begin
                    // The response is expected on L's body stream in ARM order (the decoder's queue
                    // order), whatever order the connections deliver in.
                    ln[L].expq.push_back(r);
                    s2_armcyc[c] = cyc; s2_hpend[c]++; s2_bytes[c] += need; s2_used[c]++;
                    s2_exp[c] += longint'(resp_hdr_len(r.len) + r.len);
                    s2_tail[L] = c; s2_lane_of_last[c] = L; s2_ever_lane[c][L] = 1;
                    if ($test$plusargs("FDBG"))
                        $display("  [cyc=%0d] FDBG s2 lane %0d arms seq %0d on conn %0d", cyc, L, r.seq, c);
                end
            end
            cfg_lock.put(1);
            if (!ok) begin
                if (fmeas && c < 0) h_noconn_cyc = h_noconn_cyc + s2_poll;
                if (fmeas && c < 0 && !lane_arm_ready(L)) h_noadm_cyc = h_noadm_cyc + s2_poll;
                repeat (s2_poll) @(posedge clk);
            end
        end
        arm_n = arm_n + 1; arm_wait_sum = arm_wait_sum + (cyc - t0);
        if ((cyc - t0) > arm_wait_max) arm_wait_max = cyc - t0;
        if (!ok && !cfg_stalled) begin
            cfg_stalled = 1'b1; cfg_stall_cycle = cyc;
            $display("  [cyc=%0d] *** CONFIG STALL: stage-2 lane %0d found no connection / was never admitted in %0d cycles (DEC_STATE=0x%016h drained=0x%08h)",
                     cyc, L, CFG_BOUND, connExtWord[0], connDrainedWord[31:0]);
        end
    endtask

    // =============================================================================================
    // decoder_feed: what the receive path is doing while a decoder has nothing to do (dcls, see
    // "DECODER-FEED MEASUREMENT"), and how the active connections spend their time. Sampled at the
    // NEGEDGE, where every DUT register holds the value the posedge accounting sees. Slots DUT only:
    // it reads handler_slots' internals by name.
    // =============================================================================================
    generate if (DUT_SLOTS != 0) begin : g_feedstat
        for (genvar gd = 0; gd < NL; gd++) begin : g_fd
            always @(negedge clk) if (fmeas) begin
                automatic logic [3:0] st = g_slots.dut.gen_dec[gd].inst_slot_reader.st_q;
                automatic bit         hv = g_slots.dut.gen_dec[gd].inst_slot_reader.head_valid_q;
                automatic int         n  = int'(g_slots.dut.gen_dec[gd].inst_slot_reader.eq_cnt_q);
                automatic int         hd = int'(g_slots.dut.gen_dec[gd].inst_slot_reader.eq_head_q);
                automatic int         h  = int'(g_slots.dut.gen_dec[gd].inst_slot_reader.head_conn_q);
                automatic bit         behind = 1'b0;
                if (g_slots.dut.gen_dec[gd].inst_slot_reader.pop) f_pops[gd] = f_pops[gd] + 1;
                if (|g_slots.dut.gen_dec[gd].inst_slot_reader.conn_release) f_rels[gd] = f_rels[gd] + 1;
                if (!hv && n == 0)
                    dcls[gd] = FC_EMPTY;
                else if (!hv || st == 4'd5 || st == 4'd6 || st == 4'd7 || st == 4'd9)
                    dcls[gd] = FC_SWITCH;                         // S_DONE0/1/2, S_ACKW, or taking
                else if (!g_slots.dut.conn_up_q[h])
                    dcls[gd] = FC_CONNECT;
                else if ((g_slots.dut.landed[h] > g_slots.dut.gen_dec[gd].inst_slot_reader.rd_cursor_q) ||
                         (g_slots.dut.gen_dec[gd].inst_slot_reader.n_out_q != 0) ||
                         (g_slots.rdshare.committed_q[gd] != 0))
                    // bytes of the head are in HBM or on their way to the decoder; between two
                    // responses at the decoder that is the turnaround, inside one it is the read path
                    dcls[gd] = ln[gd].active ? FC_RDPATH : FC_SWITCH;
                else if (!g_slots.dut.conn_quiet_w[h] || g_slots.dut.rxd_has_pending[h])
                    dcls[gd] = FC_WRPATH;
                else begin
                    for (int k = 1; k < n; k++) begin
                        automatic int c2 = int'(g_slots.dut.gen_dec[gd].inst_slot_reader.eq_conn[(hd + k) % QUEUE_DEPTH]);
                        if (c2 != h && g_slots.dut.landed[c2] != 0) behind = 1'b1;
                    end
                    dcls[gd] = behind ? FC_HOL : FC_SERVER;
                end
            end
        end
        // +FEEDTRACE=n: the first n response turnarounds of decoder 0 inside the window, as a
        // timeline relative to the decoder taking the previous response's LAST beat: framer done,
        // reader pop, next head taken, first card read issued, first byte back from the card, first
        // body byte of the new response at the decoder. The decomposition of the SWITCH class.
        int tr_n = 0, tr_max = 0;
        int ev_last = -1, ev_done = -1, ev_pop = -1, ev_take = -1, ev_req = -1, ev_data = -1;
        int ev_conn = -1; longint ev_landed = 0; bit ev_same = 0, prev_act = 0, prev_done = 0, prev_hv = 0;
        initial void'($value$plusargs("FEEDTRACE=%d", tr_max));
        always @(negedge clk) if (fmeas && tr_n < tr_max) begin
            automatic bit hv = g_slots.dut.gen_dec[0].inst_slot_reader.head_valid_q;
            automatic bit pp = g_slots.dut.gen_dec[0].inst_slot_reader.pop;
            if (g_slots.dut.sh_resp_done[0] && !prev_done) ev_done = cyc;
            if (pp) begin
                ev_pop  = cyc;
                ev_same = g_slots.dut.gen_dec[0].inst_slot_reader.nxt_same_q;
            end
            // the next head: taken after a release, or carried on in place (CONTINUE)
            if ((hv && !prev_hv) || (pp && ev_same)) begin
                ev_take   = cyc; ev_req = -1; ev_data = -1;
                ev_conn   = int'(g_slots.dut.gen_dec[0].inst_slot_reader.head_conn_q);
                if (pp && ev_same) ev_conn = int'(g_slots.dut.gen_dec[0].inst_slot_reader.head_conn_q);
                else ev_conn = int'(g_slots.dut.gen_dec[0].inst_slot_reader.eq_conn[g_slots.dut.gen_dec[0].inst_slot_reader.eq_head_q]);
                ev_landed = longint'(g_slots.dut.landed[ev_conn]);
            end
            if (ev_take >= 0 && ev_req < 0 && cr_req_valid[0] && cr_req_ready[0]) ev_req = cyc;
            if (ev_req >= 0 && ev_data < 0 && cr_tvalid[0] && cr_tready[0]) ev_data = cyc;
            if (bd_tvalid[0] && bd_tready[0] && bd_tlast[0]) ev_last = cyc;
            if (ln[0].active && !prev_act && ev_last >= 0 && ev_take >= 0) begin
                $display("  FEEDTRACE dec0 %s conn %0d (%0d B landed at take), cycles vs the decoder taking the previous response's last beat: framer done %0d, pop %0d, next head %0d, card read %0d, card data %0d, first body byte %0d",
                         ev_same ? "CONTINUE" : "SWITCH  ", ev_conn, ev_landed,
                         ev_done - ev_last, ev_pop - ev_last, ev_take - ev_last,
                         (ev_req  < 0) ? 99999 : ev_req  - ev_last,
                         (ev_data < 0) ? 99999 : ev_data - ev_last, cyc - ev_last);
                tr_n = tr_n + 1;
            end
            prev_act  = ln[0].active;
            prev_done = g_slots.dut.sh_resp_done[0];
            prev_hv   = hv;
        end
        always @(negedge clk) if (fmeas) begin
            for (int c = 0; c < NUM_CONNS && c < s2_conns; c++) begin
                if (g_slots.dut.pend_q[c] == 0 && g_slots.dut.conn_drained_q[c])
                    f_cfree = f_cfree + 1;
                else if (g_slots.dut.pend_q[c] != 0 && longint'(g_slots.dut.landed[c]) < s2_exp[c])
                    f_cwait = f_cwait + 1;
                else
                    f_cheld = f_cheld + 1;
            end
            if (g_slots.cdma.w_outst_q > f_wr_out_max) f_wr_out_max = g_slots.cdma.w_outst_q;
            if (cw_tvalid && cw_tready) f_wr_beats = f_wr_beats + 1;
            if (sh_tvalid) f_rd_beats = f_rd_beats + 1;
        end
    end endgenerate

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
                        // entry-queue room). Since CSR revision 4 the hardware no longer holds a
                        // second arm on a connection, so the two host rules software keeps are
                        // kept HERE, exactly as configuration.cpp keeps them:
                        //   * at most `hdepth` CHUNKS outstanding on the lane (+HDEPTH, 4; checked
                        //     before the entries, above), and at HDEPTH=1 one GET per slot;
                        //   * the bytes armed since the slot was last seen empty (CONN_DRAINED)
                        //     plus this GET's must fit in the slot. HDR_ALLOW covers the origin's
                        //     response header. `ovf` overruns a slot on purpose and skips it.
                        for (int i = 0; i < w.nreq && o !== 1'b0 && STAGE2; i++) begin
                            Resp r;
                            r = new(); r.lane = gl; r.seq = seq0 + i; r.len = w.body_len;
                            build_text(gl, 1, seq0 + i, txt);
                            s2_arm(gl, mk_cfg(w.chunk_len, gl, txt.size()), w.body_len + HDR_ALLOW, r, o);
                            if (!o) break;
                            armed_n[gl] = armed_n[gl] + 1;
                            bl = new(); bl.d = txt;
                            ln[gl].txq.push_back(bl);
                        end
                        for (int i = 0; i < w.nreq && o !== 1'b0 && !STAGE2; i++) begin
                            int need, tw;
                            need = w.body_len + HDR_ALLOW;
                            tw   = 0;
                            // handler_toe: no slot to budget; the GET credit is the hardware's
                            // ARM_READY (push_cfg_mt waits on it), and the bench's GETs keep the
                            // window rule by size (win_bad breaks it on purpose).
                            forever begin
                                bit too_deep, too_big;
                                if (DUT_TOE != 0) break;
                                // HDEPTH=1 is revision 3's pacing exactly: the next GET waits for
                                // the slot to be empty (a chunk split into several GETs retires
                                // only one tlast, so counting chunks cannot pace it).
                                too_deep = (hdepth == 1) && !conn_drained(gl);
                                too_big  = !allow_overflow && !conn_drained(gl) &&
                                           ((longint'(armed_bytes[gl]) + longint'(need)) > longint'(SLOT_BYTES));
                                if (!(too_deep || too_big) || tw >= CFG_BOUND) break;
                                @(posedge clk);
                                tw = tw + 1;
                            end
                            if ($test$plusargs("FDBG")) $display("  [cyc=%0d] FDBG lane %0d host wait %0d cyc before arm", cyc, gl, tw);
                            if (conn_drained(gl)) armed_bytes[gl] = 0;
                            build_text(gl, 1, seq0 + i, txt);
                            push_cfg_mt(mk_cfg(w.chunk_len, gl, txt.size()), gl, 1'b1, o);
                            if (!o) break;
                            armed_n[gl]     = armed_n[gl] + 1;
                            if ($test$plusargs("FDBG"))
                                $display("  [cyc=%0d] FDBG lane %0d arm #%0d accepted, %0d outstanding, %0d bytes budgeted",
                                         cyc, gl, armed_n[gl], armed_n[gl] - ln[gl].resp_done, armed_bytes[gl] + need);
                            armed_bytes[gl] = armed_bytes[gl] + need;
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

    // decoder_feed: ONE GET for decoder `lane`, the way emit_batch_slots does it on revision 5 -- the
    // chunk-length entry, then pick_conn + the arm (s2_arm), then the request text. Synchronous: the
    // software's dispatcher is one thread and does not move on until the arm has been taken.
    task automatic feed_get(input int lane, input int len, output bit ok);
        Resp r, re; Blob bl; byte unsigned txt[$];
        r = new(); r.lane = lane; r.seq = ln[lane].next_seq; r.len = len;
        ln[lane].plan.push_back(r);
        ln[lane].next_seq      = ln[lane].next_seq + 1;
        ln[lane].planned_total = ln[lane].planned_total + 1;
        push_cfg_mt(mk_cfg(len, lane, 0), lane, 1'b0, ok);
        if (!ok) return;
        ent_n_lane[lane] = ent_n_lane[lane] + 1;
        re = new(); re.lane = lane; re.seq = r.seq; re.len = len;
        build_text(lane, 1, r.seq, txt);
        s2_arm(lane, mk_cfg(len, lane, txt.size()), len + HDR_ALLOW, re, ok);
        if (!ok) return;
        armed_n[lane] = armed_n[lane] + 1;
        ln[lane].feed_seq = r.seq + 1;
        bl = new(); bl.d = txt;
        ln[lane].txq.push_back(bl);
    endtask

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
            // Work the depth-1 feeder has not finished arming is work that has not drained.
            if (feed_busy[i] != 0) ok = 0;
        end
        foreach (live_sids[k]) if (sess[live_sids[k]].pending.size() != 0) ok = 0;
        // Stage 2: the last body byte reaches the sink a few cycles before its reader entry
        // retires, and a connection is only reusable once it has. Drained means both.
        if (STAGE2) for (int c = 0; c < NUM_CONNS; c++) if (conn_pend(c) != 0 && !conn_fatal(c)) ok = 0;
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
    //   [25] rx_fifo_stall    the per-lane decoupling fifo refused the producer, i.e. back-pressure
    //                         reached the TCP stack again, which is the thing the fifo exists to
    //                         prevent.
    //   [24] rxd_overflow     an announcement was dropped.  The bytes it named stay in the TOE's
    //                         shared fifo with nobody left to ask for them, so every packet behind
    //                         them waits forever -- data loss that presents as a hang much later,
    //                         and the reason (s_d) ended 3864 bytes short of 400000.
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
    // The slots DUT adds three bits at 29..31, which were a literal zero in build-119:
    //   [29] space_stall   the shared writer fifo throttled rx_dispatch's readPkg issue. NOT a
    //                      failure -- it is the elastic fifo doing its job, and it fires routinely
    //                      in `dmabp`, where the modelled DMA is slower than this bench's TOE (the
    //                      bench delivers at 64 B/cycle; the board delivers ~0.2-0.8 GB/s per
    //                      connection). Reported, never fatal.
    //   [30] slot_overflow expected, and asserted on, only in `ovf`.
    //   [31] residue_err   bytes in a slot belonging to no response. Always a failure.
    // (allow_overflow is declared with the feeder, which reads it.)

    task automatic check_sticky();
        string why;
        why = "";
        if (stallWord[28]) why = {why, " route_stall(28)"};
        if (stallWord[27]) why = {why, " rwl_starved(27)"};
        if (stallWord[25]) why = {why, " rx_fifo_stall(25)"};
        if (stallWord[24]) why = {why, " rxd_overflow(24)"};
        if (stallWord[7])  why = {why, " status_bad(7)"};
        if (DUT_SLOTS != 0) begin
            if (stallWord[29]) $display("  NOTE slots: space_stall(29) set -- the writer throttled the readPkg issue");
            if (stallWord[31]) why = {why, " residue_err(31)"};
            if (stallWord[30] && !allow_overflow) why = {why, " slot_overflow(30)"};
            if (dma_fail) begin
                $display("  CARD DMA MODEL reported %0d contract violation(s)", dma_errors);
                why = {why, $sformatf(" card_dma_model(%0d)", dma_errors)};
            end
            // The shared read channel's own invariants. None can be true of a correct
            // configuration: a beat that belonged to no outstanding request, a receive fifo that
            // refused one (the credit is then wrong), a read longer than RD_MAX.
            if (share_order_err) why = {why, " share_order_err"};
            if (share_fifo_err)  why = {why, " share_fifo_err"};
            if (share_len_err)   why = {why, " share_len_err"};
        end
        if (why != "") begin
            $display("  STICKY stall bits set:%s   (stallWord=0x%08h)", why, stallWord);
            if (verdict.len() >= 4 && verdict.substr(0, 3) == "PASS") begin
                verdict = $sformatf("FAIL (data ok, sticky stall bits:%s)", why);
                dump("sticky");
            end
        end
    endtask

    // Stage-2 bookkeeping, printed at the end of an s2 scenario. Returns connections used.
    function automatic int s2_report(string tag);
        int used, pend_now;
        used = 0; pend_now = 0;
        for (int c = 0; c < NUM_CONNS; c++) begin
            if (s2_used[c] > 0) used++;
            if (conn_pend(c) != 0) pend_now++;
        end
        $display("");
        $display("  == %s: %0d connections, %0d decoders ==", tag, NUM_CONNS, NL);
        for (int L = 0; L < NL; L++)
            $display("     lane %0d: %0d/%0d responses, %0d body bytes%s", L, ln[L].resp_done,
                     ln[L].planned_total, ln[L].bytes_in, dec_tainted(L) ? "  TAINTED" : "");
        $display("     connections used %0d, busy at once (max) %0d, pending now %0d; arms on a free conn %0d, pipelined on the tail %0d",
                 used, s2_max_busy, pend_now, s2_n_free, s2_n_tail);
        for (int c = 0; c < NUM_CONNS; c++)
            if (conn_pend(c) != 0)
                $display("     conn %0d: %0d entries pending on decoder %0d%s drained=%0b", c, conn_pend(c),
                         conn_curdec(c), conn_is_tail(c) ? " (tail)" : "", conn_drained(c));
        $display("     opens=%0d closes=%0d readPkgs=%0d  DEC_STATE=0x%016h  CONN_CAUSE=0x%016h",
                 n_open_rsp, n_close_req, rp_issued, connExtWord[0], connExtWord[5]);
        return used;
    endfunction

    function automatic string s2_any_fatal();
        string r; r = "";
        for (int c = 0; c < NUM_CONNS; c++) if (conn_fatal(c)) r = {r, $sformatf(" conn %0d fatal", c)};
        for (int L = 0; L < NL; L++) if (dec_tainted(L)) r = {r, $sformatf(" decoder %0d tainted", L)};
        return r;
    endfunction

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
        mute_sid = -1;
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

    // (thr_hbm) one decoder throttled to one beat in 16 cycles, holding a 4 MiB column chunk fetched
    // as 18 GETs of ~228 KiB (the stage-1 host's split, GET_CREDIT outstanding). Its bytes wait in
    // its ring, so the others must keep >= 90 % of their solo rate. Phase A: lanes 1.. alone.
    // Phase B: lane 0's chunk armed and throttled first, its first GETs landed (the ring is full to
    // the credit), then the same work on lanes 1.. -- both windows 60k cycles.
    task automatic toe_thr_hbm();
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
        $display("  == thr_hbm: lane 0 at 1 beat per 16 cycles with a 4 MiB chunk in flight, %0d fast lane(s) ==", NL - 1);
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
        if (!ok) begin verdict = "HANG (did not drain after the throttle)"; dump("thr_hbm"); end
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
                // signal or a mis-indexed slot produces.
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
                end else if (DUT_SLOTS == 0) begin
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
                end else begin
                    // THE ASSERTION INVERTS, and that inversion IS the result.
                    //
                    // In build-119 a decoder that stops for good blocks the head of rx_dispatch's
                    // arrival-ordered queue, the HOL watchdog eventually kills that lane, and
                    // "contained" means "the watchdog did its job". Here the stopped decoder's
                    // bytes go into its slot in HBM and the shared receive path never notices, so
                    // NO connection may be declared dead at all -- if one is, the coupling ADR-5
                    // exists to remove is still there.
                    for (int L = 0; L < NL; L++) begin
                        if (lane_dead_sticky(L)) begin
                            $display("  conn %0d was declared dead by the HOL watchdog: the shared receive path is still coupled to a decoder",
                                     L);
                            verdict = $sformatf("FAIL (conn %0d declared dead; slots must not couple)", L);
                        end
                    end
                    $display("  [cyc=%0d] slots: connDrained=0x%016h (conn 0 must read 0: its slot is still held)",
                             cyc, connDrainedWord);
                    if (conn_drained(0)) begin
                        $display("  conn 0's slot reads DRAINED while its decoder has taken nothing");
                        verdict = "FAIL (depth-1 credit returned on an undrained slot)";
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
        // (2026-09-24, the reader->framer register slice of 9811956.) Lane 0's decoder stops, then
        // one small response lands and the origin closes the session straight after it (what a
        // `Connection: close` or a max-requests origin does). Every byte of the response is in the
        // handler, so nothing is owed by the network and the response must complete the moment
        // the decoder comes back. FSBLEN sizes the body so the response's LAST beats wait in the
        // slice in front of the framer rather than in slot_rd_share's receive fifo: there the old
        // datapath counted them through rd_pending and held the FIN drain; if the drain does not
        // count the slice, it expires (CLOSE_SETTLE) and aborts a finished response.
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
            $display("  [cyc=%0d] after: lane0 done=%0d/%0d conn0 fatal=%0b lane0 fatal=%0b",
                     cyc, ln[0].resp_done, ln[0].planned_total,
                     (DUT_SLOTS != 0) ? conn_fatal(0) : 1'b0, lane_is_fatal(0));
            if (!ok) begin verdict = "HANG (the finished response never reached the decoder)"; dump("fsfin"); end
            else if (n_err) begin verdict = "FAIL (routing/framing violated)"; dump("fsfin"); end
            else if (lane_is_fatal(0) || ((DUT_SLOTS != 0) && conn_fatal(0)))
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

        // ---- LAZY OPEN -----------------------------------------------------------------------------
        //
        // (lz1) An idle lane whose peer FINs must STAY DOWN, and the next batch on it must open a
        // fresh session by itself.
        //
        // MinIO closes a connection idle for ~30 s, and with N lanes a lane sits idle that long
        // routinely.  Reconnecting the instant the FIN arrives puts a brand-new session where one
        // whose announcements were still in flight used to be, and the reader then waits out its
        // ~2 s watchdog for a notification that can never come -- measured on the board as a flat
        // ~4.7 s on four of the 22 TPC-H queries, and the origin of every lane wedge seen.  The
        // contract asked for here is the one that removes the race entirely:
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
        // SLOTS-ONLY SCENARIOS. Each of them asks a question that only exists because the buffer
        // moved into HBM, and each is meaningless against handler_multi -- big is larger than its
        // whole lane fifo, ovf and dmabp name hardware it does not have, and thr's expected answer
        // is the opposite of what build-119 does.
        // =========================================================================================

        // (big) the host's largest legal GET, on every connection at once ---------------------------
        //
        // SLOT_BYTES - 64 KiB is the contract in ADR-5: one GET per connection, sized so the header
        // and the alignment slack cannot push the body past the end of the slot. Doing it on every
        // connection simultaneously is what makes it a test of the SHARED writer rather than of one
        // slot -- one descriptor per segment, N connections' worth, through one channel.
        "big": begin
            int blen;
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            if (DUT_TOE != 0) begin
                // handler_toe: the stage-1 host's whole window budget on every lane at once --
                // GET_CREDIT (4) GETs of the 236 KiB cap each.
                blen = 236 * 1024;
                $display("  toe: 4 GETs of %0d bytes on each of %0d lane(s)", blen, NL);
                for (int L = 0; L < NL; L++) submit_batch(L, 4, blen, o);
            end else begin
                blen = int'(SLOT_BYTES) - 65536;
                $display("  slot = %0d bytes, GET = %0d bytes on each of %0d connection(s)",
                         SLOT_BYTES, blen, NL);
                for (int L = 0; L < NL; L++) submit_batch(L, 1, blen, o);
            end
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
        // 4 B/cycle at 16 -- while every other connection runs flat out. In build-119 this is what
        // starves the neighbours: the slow lane's fifo fills, conn_space_ok drops, the head of the
        // arrival-ordered queue blocks and everyone waits (measured on the rx_perf model: the other
        // lane lost 20%, 33.90 -> 27.26 B/cycle). Here the slow decoder's bytes are in its slot and
        // the shared path never sees it.
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
                $display("     stall bits: route_stall(28)=%0b rx_fifo_stall(25)=%0b space_stall(29)=%0b",
                         stallWord[28], stallWord[25], stallWord[29]);
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

        // (dmabp) the card path is slow and lumpy ---------------------------------------------------
        //
        // +DMA_WR_BP=50 +DMA_RD_GAP=40 go to card_dma_model, so the write data channel refuses half
        // the cycles and four beats in ten come back with a gap behind them. Nothing about the
        // handler may change: every byte still arrives, in order, and the rx side is still never
        // refused. space_stall(29) IS expected here -- the modelled DMA is slower than this bench's
        // TOE, which is the whole point of an elastic fifo -- and it is reported, not failed.
        "dmabp": begin
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            for (int L = 0; L < NL; L++) submit_batch(L, 6, 16384, o);
            wait_drain(3000000, ok);
            for (int L = 0; L < NL; L++)
                $display("     conn %0d: %0d/%0d responses, %0d body bytes",
                         L, ln[L].resp_done, ln[L].planned_total, ln[L].bytes_in);
            $display("     stall bits: route_stall(28)=%0b rx_fifo_stall(25)=%0b space_stall(29)=%0b",
                     stallWord[28], stallWord[25], stallWord[29]);
            if (!ok) begin verdict = "HANG"; dump("dmabp"); end
            else if (n_err) begin verdict = "FAIL"; dump("dmabp"); end
            else verdict = "PASS";
        end

        // (ovf) one connection overruns its slot; the others must not notice ------------------------
        //
        // Runs on a snapshot with a small SLOT_LOG2 so the overrun happens in a few thousand cycles
        // rather than after half a megabyte. The host contract (GET <= SLOT - 64 KiB) says this can
        // never happen; the point is what the hardware does when it does. Connection 0 must go
        // FATAL with SLOT_OVERFLOW set and nothing else may be disturbed.
        "ovf": begin
            int blen;
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            allow_overflow = 1;
            lane_ignore[0] = 1;
            blen = int'(SLOT_BYTES) + 8192;          // deliberately past the end of the slot
            $display("  slot = %0d bytes; conn 0 asks for %0d", SLOT_BYTES, blen);
            for (int L = 1; L < NL; L++) submit_batch(L, 2, 3000, o);
            wait_drain(400000, ok);
            $display("  [cyc=%0d] warm-up drained=%0b", cyc, ok);
            if (!ok) begin verdict = "HANG (warm-up)"; dump("ovf"); end
            else begin
                submit_batch(0, 1, blen, o);
                // Wait for the writer to report the overrun, then take conn 0's PEER off the wire.
                //
                // The rest of a response that cannot be stored is not interesting here, and
                // leaving it queued at the origin tests something else: segments that arrive
                // AFTER the session has been released. rx_dispatch reads those as orphans and
                // throws them away -- `cuovf` is that scenario. This one is about CONTAINMENT of
                // a slot overrun.
                t0 = cyc;
                while ((cyc - t0) < 400000 && !conn_overflowed(0)) @(posedge clk);
                mute_sid = ln[0].sid;
                if (sess.exists(ln[0].sid)) begin
                    sess[ln[0].sid].pending = {};
                    sess[ln[0].sid].wr      = {};
                end
                while ((cyc - t0) < 400000 && !lane_is_fatal(0)) @(posedge clk);
                $display("  [cyc=%0d] conn 0: fatal=%0b slot_overflow=%0b connErr=0x%016h",
                         cyc, lane_is_fatal(0), conn_overflowed(0), connErrWord[0]);
                if (!conn_overflowed(0))
                    verdict = "FAIL (the overrun was not reported on conn 0)";
                else if (!lane_is_fatal(0))
                    verdict = "FAIL (conn 0 overran its slot and was not declared fatal)";
                else begin
                    // and now the whole point: everyone else still works
                    for (int L = 1; L < NL; L++) begin
                        if (conn_overflowed(L))
                            verdict = $sformatf("FAIL (conn %0d reports an overflow it never had)", L);
                        if (lane_is_fatal(L))
                            verdict = $sformatf("FAIL (conn %0d went fatal over conn 0's overflow)", L);
                    end
                    if (verdict == "") begin
                        b1 = 0;
                        for (int L = 1; L < NL; L++) b1 = b1 + ln[L].resp_done;
                        for (int L = 1; L < NL; L++) submit_batch(L, 2, 3000, o);
                        // conn 0 will never drain, so wait on the survivors rather than on everything
                        t0 = cyc;
                        forever begin
                            int done_now;
                            @(posedge clk);
                            done_now = 0;
                            for (int L = 1; L < NL; L++) done_now = done_now + ln[L].resp_done;
                            if (done_now >= b1 + 2*(NL-1)) break;
                            if ((cyc - t0) > 600000) break;
                        end
                        for (int L = 1; L < NL; L++)
                            $display("     conn %0d: %0d responses, %0d body bytes",
                                     L, ln[L].resp_done, ln[L].bytes_in);
                        b0 = 0;
                        for (int L = 1; L < NL; L++) b0 = b0 + ln[L].resp_done;
                        dump("ovf");
                        if (b0 < b1 + 2*(NL-1))
                            verdict = "FAIL (the survivors stopped after conn 0 overran its slot)";
                        else if (n_err)
                            verdict = "FAIL (byte/framing errors on a surviving connection)";
                        else
                            verdict = "PASS (contained: conn 0 fatal, the others byte-exact)";
                    end
                end
            end
        end

        // (refatal) a connection is torn down with bytes still in its slot -----------------------
        //
        // The teardown order this checks is the reason BR_DRAIN exists: the session is released
        // first so nothing new can enter the slot, then BOTH halves of the datapath are waited out
        // (slot_writer's conn_quiet, slot_reader's flush_busy), and only then are the cursors
        // zeroed. Get it wrong and the next response on that connection is read out of the slot at
        // the wrong offset -- which shows up as a byte mismatch on a response that is otherwise
        // completely ordinary, or as the stale bytes being parsed as its header.
        //
        // TWO PHASES, because the architecture has two answers and both matter:
        //
        //   B/C  a CLEAN reconnect with a dirty slot. The connection is idle -- its response has
        //        drained -- but the origin has put bytes in its slot that belong to no response,
        //        and then its peer FINs. That is the ordinary MinIO idle-close, and the connection
        //        must come back and be BYTE-EXACT. Without the release it would read the stale
        //        bytes as the next response's status line.
        //
        //   D    a FATAL mid-response teardown, which is what a FIN with work outstanding is in
        //        this design and in build-119 alike: the request text has been consumed and cannot
        //        be replayed, so the connection stays down and the host reissues elsewhere. What is
        //        asserted here is that the teardown is CLEAN -- the session closed, the slot handed
        //        back (CONN_DRAINED returns), slot_writer's "release with segments in flight"
        //        assertion silent, and the other connections untouched.
        "refatal": begin
            int sid0, stale, rfn, rfb, rfp;
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            for (int L = 0; L < NL; L++) submit_batch(L, 1, 3000, o);
            wait_drain(400000, ok);
            $display("  [cyc=%0d] warm-up drained=%0b, conn 0 session=%0d", cyc, ok, ln[0].sid);
            if (!ok) begin verdict = "HANG (warm-up)"; dump("refatal"); end
            else begin
                // -- B: leave bytes in conn 0's slot that belong to no response, then FIN it -------
                sid0  = ln[0].sid;
                stale = 5000;
                for (int i = 0; i < stale; i++) sess[sid0].pending.push_back(byte'(8'hA5));
                sess[sid0].wr.push_back(stale);
                t0 = cyc;
                while ((cyc - t0) < 200000 && sess[sid0].pending.size() > 0) @(posedge clk);
                wait_cycles(2000);
                $display("  [cyc=%0d] %0d stale bytes are in conn 0's slot; FINning its idle peer (drained=%0b)",
                         cyc, stale, conn_drained(0));
                peer_close(sid0);
                // -- C: it must reconnect by itself and the next response must be byte-exact ------
                t0 = cyc;
                while ((cyc - t0) < 300000 && n_open_rsp < 1 + NUM_CONNS) @(posedge clk);
                $display("  [cyc=%0d] after the idle FIN: opens=%0d closes=%0d conn0 up=%0b fatal=%0b drained=%0b",
                         cyc, n_open_rsp, n_close_req, lane_conn_up(0), lane_is_fatal(0),
                         conn_drained(0));
                if (lane_is_fatal(0))
                    verdict = "FAIL (an idle FIN with a dirty slot made conn 0 fatal)";
                else begin
                    b1 = ln[0].bytes_in;
                    for (int L = 0; L < NL; L++) submit_batch(L, 2, 5000, o);
                    wait_drain(800000, ok);
                    $display("  [cyc=%0d] after the reconnect: drained=%0b conn0 +%0d bytes, %0d/%0d responses",
                             cyc, ok, ln[0].bytes_in - b1, ln[0].resp_done, ln[0].planned_total);
                    if (!ok) begin
                        verdict = "HANG (the connection never came back after the idle FIN)";
                        dump("refatal");
                    end else if (n_err) begin
                        verdict = "FAIL (the response after the reconnect was not byte-exact: the slot was not released)";
                        dump("refatal");
                    end
                end

                // -- D: now kill it mid-response and check the teardown itself --------------------
                if (verdict == "") begin
                    sid0 = ln[0].sid;
                    b0   = pkt_taken;
                    lane_ignore[0] = 1;              // its response is being cut on purpose
                    net_allow = b0 + 3;
                    // +RFP puts exactly that many packets on the wire before the cut (net_allow is
                    // a budget, so the default above lets b0 + 3 through, not 3).
                    if ($value$plusargs("RFP=%d", rfp)) net_allow = rfp;
                    // +RFN GETs are armed before the cut (revision 4: several outstanding on one
                    // connection when it dies -- the stale entries behind the head must neither
                    // wedge the teardown nor leak into anybody else).
                    if (!$value$plusargs("RFN=%d", rfn)) rfn = 1;
                    // +RFB sets their body size and +RFP the packets let through; RFB=20000 RFP=7
                    // (MSS 4096) completes the first response and cuts the SECOND one: the reader has
                    // CONTINUEd onto the next entry with its cursor mid-slot, and the flush then
                    // abandons a head that never started from offset 0.
                    if (!$value$plusargs("RFB=%d", rfb)) rfb = (rfn > 1) ? 100000 : 120000;
                    submit_batch(0, rfn, rfb, o);
                    t0 = cyc;
                    while ((cyc - t0) < 200000 && pkt_taken < b0 + 3) @(posedge clk);
                    wait_cycles(2000);
                    $display("  [cyc=%0d] conn 0's slot is half written (%0d packets, %0d body bytes); FINning its peer mid-response",
                             cyc, pkt_taken - b0, ln[0].bytes_in - b1);
                    // The peer that FINs has stopped sending. Leaving the rest queued would strand
                    // it in the TOE's shared fifo (see the note in `ovf`), which is a different
                    // question from whether this teardown is clean.
                    mute_sid = sid0;
                    if (sess.exists(sid0)) begin sess[sid0].pending = {}; sess[sid0].wr = {}; end
                    peer_close(sid0);
                    net_allow = 1000000000;
                    t0 = cyc;
                    while ((cyc - t0) < 400000 && !(lane_is_fatal(0) && !lane_conn_up(0)))
                        @(posedge clk);
                    // The session going away is BR_CLOSE; the slot coming back is BR_DRAIN, which
                    // is deliberately later -- it waits for the writer and the reader to let go
                    // first. Sampling the credit on the same cycle as conn_up would be reading the
                    // answer before the question had been asked.
                    t0 = cyc;
                    while ((cyc - t0) < 200000 && !conn_drained(0)) @(posedge clk);
                    $display("  [cyc=%0d] mid-response FIN: conn 0 fatal=%0b up=%0b drained=%0b closes=%0d connErr=0x%016h",
                             cyc, lane_is_fatal(0), lane_conn_up(0), conn_drained(0), n_close_req,
                             connErrWord[0]);
                    // The connection stays down -- the request text is gone and only the host can
                    // reissue -- but its SLOT must have come back, and nobody else may be hurt.
                    if (!lane_is_fatal(0))
                        verdict = "FAIL (a mid-response FIN with work outstanding left conn 0 alive)";
                    else if (lane_conn_up(0))
                        verdict = "FAIL (conn 0 is fatal but still holds its session)";
                    else if (!conn_drained(0))
                        verdict = "FAIL (conn 0's slot was never released: BR_DRAIN did not complete)";
                    else begin
                        for (int L = 1; L < NL; L++)
                            if (lane_is_fatal(L))
                                verdict = $sformatf("FAIL (conn %0d went fatal over conn 0's teardown)", L);
                    end
                    if (verdict == "") begin
                        // and the survivors are still byte-exact and still complete work
                        ln[0].planned_total = ln[0].resp_done;
                        ln[0].plan = {}; ln[0].expq = {};
                        ln[0].active = 0; ln[0].must_end = 0;
                        n_err = 0;                   // the cut stream is the scenario, not a defect
                        b1 = 0;
                        for (int L = 1; L < NL; L++) b1 = b1 + ln[L].resp_done;
                        for (int L = 1; L < NL; L++) submit_batch(L, 2, 4000, o);
                        wait_drain(800000, ok);
                        for (int L = 1; L < NL; L++)
                            $display("     conn %0d: %0d/%0d responses, %0d body bytes",
                                     L, ln[L].resp_done, ln[L].planned_total, ln[L].bytes_in);
                        dump("refatal");
                        if (!ok)
                            verdict = "HANG (the survivors stopped after conn 0's mid-response teardown)";
                        else if (n_err)
                            verdict = "FAIL (byte/framing errors on a surviving connection)";
                        else
                            verdict = "PASS (slot released on both paths; reconnect byte-exact, fatal contained)";
                    end
                end
            end
        end

        // =========================================================================================
        // STAGE-2 SCENARIOS (NUM_DEC < NUM_CONNS, revision 5). Lanes are decoders; the host model
        // places every GET on a connection (see "STAGE-2 HOST MODEL").
        // =========================================================================================

        // (s2mix) every lane, many GETs of mixed sizes, spread over all the connections, answered
        // out of queue order (+SRVJIT) and coalesced (+COALESCE) -- byte-exact per decoder stream.
        "s2mix": begin
            int nreq, bmax, minused, used;
            nreq = 3 * ((NUM_CONNS + NL - 1) / NL); bmax = 20000; minused = NUM_CONNS;
            void'($value$plusargs("NREQ=%d", nreq));
            void'($value$plusargs("BMAX=%d", bmax));
            void'($value$plusargs("S2MINUSED=%d", minused));
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            if (!STAGE2) verdict = "SKIP (stage-2 scenario)";
            else begin
                for (int i = 0; i < nreq; i++)
                    for (int L = 0; L < NL; L++)
                        submit_batch(L, 1, 64 + ((L*7919 + i*3571 + 13) % bmax), o);
                wait_drain(3000000, ok);
                used = s2_report("s2mix");
                if (!ok) begin verdict = "HANG"; dump("s2mix"); end
                else if (n_err) verdict = "FAIL (byte/framing errors)";
                else if (s2_any_fatal() != "") verdict = {"FAIL (", s2_any_fatal(), ")"};
                else if (used < minused)
                    verdict = $sformatf("FAIL (only %0d connections carried GETs, wanted %0d)", used, minused);
                else verdict = $sformatf("PASS (%0d GETs over %0d connections, %0d busy at once)",
                                         nreq*NL, used, s2_max_busy);
            end
        end

        // (s2arm) EVERY connection armed at once: one GET per connection, held at the origin by
        // +SRVLAT, so all NUM_CONNS have an entry pending simultaneously; then all of it drains.
        "s2arm": begin
            int per;
            per = (NUM_CONNS + NL - 1) / NL;
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            if (!STAGE2) verdict = "SKIP (stage-2 scenario)";
            else begin
                for (int L = 0; L < NL; L++)
                    for (int i = 0; i < per && (L*per + i) < NUM_CONNS; i++) submit_batch(L, 1, 6000 + 101*i, o);
                wait_drain(2000000, ok);
                void'(s2_report("s2arm"));
                if (!ok) begin verdict = "HANG"; dump("s2arm"); end
                else if (n_err) verdict = "FAIL (byte/framing errors)";
                else if (s2_any_fatal() != "") verdict = {"FAIL (", s2_any_fatal(), ")"};
                else if (s2_max_busy < NUM_CONNS)
                    verdict = $sformatf("FAIL (at most %0d of %0d connections were armed at once)",
                                        s2_max_busy, NUM_CONNS);
                else verdict = $sformatf("PASS (all %0d connections armed at once)", NUM_CONNS);
            end
        end

        // (s2fatal) one connection dies with GETs of decoder 0 pending on it. Asserted:
        //   * exactly that connection goes FATAL and it alone is recorded as having tainted a
        //     decoder, and exactly decoder 0 is TAINTED;
        //   * every OTHER connection -- including those whose entries were queued on decoder 0
        //     behind the dead one's (the stale-entry fix) -- drains to nothing pending;
        //   * the other decoders finish byte-exact, and then take new work spread over the
        //     surviving connections, some of which were decoder 0's.
        "s2fatal": begin
            int per, victim_sid, victim, nfatal, b_used[NUM_CONNS], reused;
            bit bad;
            per = (NUM_CONNS + NL - 1) / NL;
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            if (!STAGE2) verdict = "SKIP (stage-2 scenario)";
            else begin
                // -- A: warm-up on every lane
                for (int L = 0; L < NL; L++) for (int i = 0; i < per; i++) submit_batch(L, 1, 3000, o);
                wait_drain(1500000, ok);
                $display("  [cyc=%0d] warm-up drained=%0b", cyc, ok);
                // -- B: long responses queued everywhere, then kill a connection holding lane 0's
                if (ok) begin
                    for (int L = 0; L < NL; L++) for (int i = 0; i < per; i++) submit_batch(L, 1, 40000, o);
                    t0 = cyc;
                    while ((cyc - t0) < 400000 && feed_busy[0] != 0) @(posedge clk);
                    wait_cycles(200);
                    victim_sid = -1;
                    foreach (live_sids[k])
                        if (victim_sid < 0 && sess[live_sids[k]].alive && sess[live_sids[k]].lane == 0 &&
                            (sess[live_sids[k]].pending.size() > 0 || sess[live_sids[k]].last_rel > cyc))
                            victim_sid = live_sids[k];
                    if (victim_sid < 0) begin verdict = "FAIL (no session with lane-0 work in flight to kill)"; ok = 0; end
                end
                if (ok) begin
                    $display("  [cyc=%0d] killing session %0d mid-response (it carries lane 0)", cyc, victim_sid);
                    lane_ignore[0] = 1;
                    mute_sid = victim_sid;
                    sess[victim_sid].pending = {}; sess[victim_sid].wr = {};
                    peer_close(victim_sid);
                    t0 = cyc;
                    while ((cyc - t0) < 600000 && !dec_tainted(0)) @(posedge clk);
                    // Everyone else drains: other lanes complete, and every surviving connection
                    // ends with nothing pending -- including the ones queued on decoder 0.
                    t0 = cyc;
                    forever begin
                        bit done; done = 1;
                        @(posedge clk);
                        for (int L = 1; L < NL; L++) if (ln[L].resp_done != ln[L].planned_total) done = 0;
                        for (int c = 0; c < NUM_CONNS; c++) if (!conn_fatal(c) && conn_pend(c) != 0) done = 0;
                        if (done || (cyc - t0) > 1500000) break;
                    end
                    victim = -1; nfatal = 0; bad = 0;
                    for (int c = 0; c < NUM_CONNS; c++) if (conn_fatal(c)) begin nfatal++; victim = c; end
                    $display("  [cyc=%0d] after the kill: DEC_STATE=0x%016h fatal conns=%0d (conn %0d) CONN_CAUSE=0x%016h",
                             cyc, connExtWord[0], nfatal, victim, connExtWord[5]);
                    for (int c = 0; c < NUM_CONNS; c++)
                        if (!conn_fatal(c) && conn_pend(c) != 0) begin
                            $display("     conn %0d still has %0d entries pending (curdec %0d)", c, conn_pend(c), conn_curdec(c));
                            bad = 1;
                        end
                    if (!dec_tainted(0)) verdict = "FAIL (decoder 0 lost a response and was not tainted)";
                    else if (nfatal != 1) verdict = $sformatf("FAIL (%0d connections fatal, expected exactly 1)", nfatal);
                    else if (!conn_tainter(victim) || s2_lane_of_last[victim] != 0)
                        verdict = $sformatf("FAIL (the fatal connection %0d is not recorded as decoder 0's tainter)", victim);
                    else if (bad) verdict = "FAIL (a surviving connection's entries were never retired: stale entries block the decoder)";
                    else begin
                        for (int L = 1; L < NL; L++) if (dec_tainted(L)) verdict = $sformatf("FAIL (decoder %0d tainted too)", L);
                        for (int c = 0; c < NUM_CONNS; c++) if (c != victim && conn_tainter(c))
                            verdict = $sformatf("FAIL (conn %0d recorded as a tainter)", c);
                    end
                    // -- C: the survivors take new work, spread over every live connection
                    if (verdict == "") begin
                        for (int c = 0; c < NUM_CONNS; c++) b_used[c] = s2_used[c];
                        for (int i = 0; i < 2*per; i++) for (int L = 1; L < NL; L++) submit_batch(L, 1, 2500 + 97*i, o);
                        t0 = cyc;
                        forever begin
                            bit done; done = 1;
                            @(posedge clk);
                            for (int L = 1; L < NL; L++) if (ln[L].resp_done != ln[L].planned_total || feed_busy[L] != 0) done = 0;
                            for (int c = 0; c < NUM_CONNS; c++) if (!conn_fatal(c) && conn_pend(c) != 0) done = 0;
                            if (done || (cyc - t0) > 1500000 || cfg_stalled) break;
                        end
                        reused = 0;
                        for (int c = 0; c < NUM_CONNS; c++)
                            if (c != victim && s2_ever_lane[c][0] && s2_used[c] > b_used[c]) reused++;
                        void'(s2_report("s2fatal"));
                        for (int L = 1; L < NL; L++)
                            if (ln[L].resp_done != ln[L].planned_total)
                                verdict = $sformatf("HANG (lane %0d: %0d of %0d after the kill)", L, ln[L].resp_done, ln[L].planned_total);
                        if (verdict == "") begin
                            if (n_err) verdict = "FAIL (byte/framing errors on a surviving decoder)";
                            else if (reused == 0) verdict = "FAIL (no connection of the tainted decoder was reused elsewhere)";
                            else verdict = $sformatf("PASS (conn %0d fatal, decoder 0 tainted, %0d of its other connections reused)",
                                                     victim, reused);
                        end
                    end
                    if (verdict != "" && verdict.substr(0, 3) != "PASS") dump("s2fatal");
                end
            end
        end

        // (s2idle) the origin idle-closes most connections (MinIO does after ~minutes). Each must
        // reconnect by itself (clean: nothing pending), none may go fatal, and the next work over
        // all of them is byte-exact.
        "s2idle": begin
            int per, nfin, o0, k;
            per = (NUM_CONNS + NL - 1) / NL;
            if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
            if (!STAGE2) verdict = "SKIP (stage-2 scenario)";
            else begin
                for (int L = 0; L < NL; L++) for (int i = 0; i < per; i++) submit_batch(L, 1, 3000, o);
                wait_drain(1500000, ok);
                wait_cycles(2000);
                nfin = (NUM_CONNS > 22) ? 20 : NUM_CONNS - 2;
                o0 = n_open_rsp; k = 0;
                foreach (live_sids[j]) if (k < nfin && sess[live_sids[j]].alive) begin
                    peer_close(live_sids[j]); k++;
                end
                t0 = cyc;
                while ((cyc - t0) < 400000 && n_open_rsp < o0 + nfin) @(posedge clk);
                wait_cycles(3000);
                $display("  [cyc=%0d] %0d idle sessions FINned: opens %0d -> %0d, fatal=%s", cyc, nfin, o0, n_open_rsp, s2_any_fatal());
                if (!ok) verdict = "HANG (warm-up)";
                else if (s2_any_fatal() != "") verdict = {"FAIL (idle close made a connection fatal: ", s2_any_fatal(), ")"};
                else if (n_open_rsp < o0 + nfin) verdict = $sformatf("FAIL (%0d of %0d idle-closed connections reopened)", n_open_rsp - o0, nfin);
                else begin
                    for (int i = 0; i < 2*per; i++) for (int L = 0; L < NL; L++) submit_batch(L, 1, 1000 + 77*i + 5*L, o);
                    wait_drain(2000000, ok);
                    void'(s2_report("s2idle"));
                    if (!ok) begin verdict = "HANG (after the idle closes)"; dump("s2idle"); end
                    else if (n_err) verdict = "FAIL (byte/framing errors after the reconnects)";
                    else if (s2_any_fatal() != "") verdict = {"FAIL (", s2_any_fatal(), ")"};
                    else verdict = $sformatf("PASS (%0d idle closes, all reopened, byte-exact after)", nfin);
                end
            end
        end


        // =========================================================================================
        // (feed) DOES THE RECEIVE PATH KEEP EVERY DECODER BUSY? unit-tests/decoder_feed/run.sh
        // sweeps it; its header has the time scale and the two origin profiles.
        //
        // THE HOST is the software's ONE dispatcher thread, per GET:
        //   Scheduler::PlaceOnLane      the least-occupied decoder whose CONN_OCC + 1 <= lane depth
        //                               (conn depth x ceil(active conns / decoders), configuration.cpp
        //                               lane_depth_limit), round robin on ties; none -> sleep
        //                               kLaneRetry (100 us) and look again
        //   emit_batch_slots            one chunk = one GET: the chunk-length entry, then
        //   HTTPReadConfig::pick_conn   a FREE connection round robin over the active ones, else this
        //                               decoder's tail if it has < conn depth pending; none -> sleep
        //                               20 us and poll again, with the dispatcher held (no other decoder
        //                               gets work meanwhile -- that is the software's shape)
        //   arm_transfer + the text DMA
        // plus a fixed host cost per GET (CSR writes, the arm handshake, the DMA invoke). An endless
        // supply of column chunks, sizes uniform in [GETMIN, GETMAX].
        //
        // The window starts WARMCYC cycles in and lasts MEASCYC; after it the host stops and everything
        // must drain byte-exact (the checker never stops). Verdict: PASS/FAIL is correctness; the
        // decoder-feed judgement is its own line, FEEDVERDICT.
        // =========================================================================================
        "feed": begin
            string  origin;
            int     scale, ttfb_ns, jit_ns, rate_mbs, decrate, gmin, gmax;
            int     hostget_ns, poll_ns, retry_ns, hostget, retry, ldep;
            int     warm, meas, drainb, t0m, t1m, rr, pick, occ, best, len, avg, tlife, hdr;
            int     nget, nget0, npops, nrels, hdrb;
            real    q0, q3;
            longint qwork [4];
            longint tot_bytes, tot_work, hn0, hr0;
            real    ceil_bpc, dem_bpc, conn_bpc, gbps, minb, meanb, b, cyc_r;
            real    lost_pct [FC_N];
            longint h_nolane_cyc;
            if (!STAGE2 || DUT_SLOTS == 0) verdict = "SKIP (feed needs the stage-2 slots DUT)";
            else begin
                origin = "minio";
                void'($value$plusargs("ORIGIN=%s", origin));
                scale = 10;          void'($value$plusargs("SCALE=%d", scale));
                if (origin == "fast") begin ttfb_ns = 120000; jit_ns = 20000;  rate_mbs = 750; hdrb = 200; end
                else                  begin ttfb_ns = 800000; jit_ns = 200000; rate_mbs = 230; hdrb = 600; end
                if (!$value$plusargs("HDRBYTES=%d", srv_hdr_bytes)) srv_hdr_bytes = hdrb;
                void'($value$plusargs("TTFB_NS=%d",  ttfb_ns));
                void'($value$plusargs("JIT_NS=%d",   jit_ns));
                void'($value$plusargs("RATE_MBS=%d", rate_mbs));
                decrate = 1280;      void'($value$plusargs("DECRATE=%d", decrate));
                gmin = 279 * 1024;   void'($value$plusargs("GETMIN=%d", gmin));
                gmax = 424 * 1024;   void'($value$plusargs("GETMAX=%d", gmax));
                hostget_ns = 10000;  void'($value$plusargs("HOSTGET_NS=%d", hostget_ns));
                poll_ns    = 20000;  void'($value$plusargs("POLL_NS=%d",    poll_ns));
                retry_ns   = 100000; void'($value$plusargs("RETRY_NS=%d",   retry_ns));
                if (!$value$plusargs("MSS=%d", mss_arg)) mss = 4096;
                if (!$value$plusargs("LINKBPC=%d", link_bpc)) link_bpc = 50;   // 100 Gb/s

                // Everything that is a TIME on the host or the origin is divided by SCALE, and so is
                // every GET: latency : transfer : decode stay in proportion. Rates (bytes/cycle) and
                // everything inside the FPGA (segment size, RD_MAX, card latency) do NOT scale, so
                // the per-response fixed costs of the RTL weigh SCALE times more here than on the
                // board -- conservative.
                // +SRVOVERLAP: the origin processes pipelined requests CONCURRENTLY (TTFB counted
                // from each request's arrival, bytes still in order at the per-connection rate) --
                // the optimistic bound, for comparison with the serial (Go/MinIO) default.
                srv_ser     = !$test$plusargs("SRVOVERLAP");
                srv_lat     = ttfb_ns / 4 / scale;
                srv_jit     = jit_ns  / 4 / scale;
                srv_rate_mb = rate_mbs * 4;                    // MB/s -> milli-bytes per cycle
                dec_cost    = (1024 * 250) / decrate;          // 1/1024-cycles per byte
                gmin        = gmin / scale;
                gmax        = gmax / scale;
                hostget     = hostget_ns / 4 / scale; if (hostget < 1) hostget = 1;
                s2_poll     = poll_ns / 4 / scale;    if (s2_poll < 1) s2_poll = 1;
                retry       = retry_ns / 4 / scale;   if (retry < 1) retry = 1;
                ldep        = hdepth * ((s2_conns + NL - 1) / NL);
                void'($value$plusargs("LDEPTH=%d", ldep));
                avg         = (gmin + gmax) / 2;
                hdr         = resp_hdr_len(avg);
                tlife       = srv_lat + srv_jit/2 + int'(real'(avg + hdr) * 1000.0 / real'(srv_rate_mb));
                // A slow origin builds a backlog in the slots at start-up (every connection streams at
                // once) that the decoders then eat into only at the small surplus, so a server-bound
                // run takes many connection lifetimes to settle; the quarters printed below show it.
                warm        = 12 * tlife + 20000;
                meas        = 40 * int'(real'(avg) * real'(dec_cost) / 1024.0);
                if (meas < 8 * tlife) meas = 8 * tlife;
                void'($value$plusargs("WARMCYC=%d", warm));
                void'($value$plusargs("MEASCYC=%d", meas));
                drainb      = 30 * tlife + 200000;
                // A host may wait a whole connection lifetime for a free one; the global watchdog
                // has to cover the run. Both only if not given explicitly.
                if (!$test$plusargs("CFGBOUND")) CFG_BOUND  = 20 * tlife + 200000;
                if (!$test$plusargs("MAXCYC"))   MAX_CYCLES = cyc + warm + meas + drainb + CFG_BOUND + 100000;

                // What the ORIGIN could deliver if every active connection were always busy and
                // re-armed the instant it finished: conns x size / (TTFB + size / rate), capped by
                // the wire. Anything a decoder loses beyond this is lost inside the FPGA or the host.
                conn_bpc = real'(avg + hdr) / (real'(srv_lat) + real'(srv_jit)/2.0 +
                                               real'(avg + hdr) * 1000.0 / real'(srv_rate_mb));
                ceil_bpc = real'(s2_conns) * conn_bpc;
                if (ceil_bpc > real'(link_bpc)) ceil_bpc = real'(link_bpc);
                dem_bpc  = real'(NL) * 1024.0 / real'(dec_cost);

                $display("  feed: origin=%s scale=1/%0d conns=%0d/%0d decoders=%0d conn_depth=%0d lane_depth=%0d",
                         origin, scale, s2_conns, NUM_CONNS, NL, hdepth, ldep);
                $display("  feed: TTFB %0d+0..%0d cyc, %0d mB/cyc per conn, link %0d B/cyc, decoder %0d MB/s (%0d/1024 cyc/B)",
                         srv_lat, srv_jit, srv_rate_mb, link_bpc, decrate, dec_cost);
                $display("  feed: GET %0d..%0d B + %0d B header, host %0d cyc/GET, pick poll %0d cyc, lane retry %0d cyc; warm %0d, window %0d cyc",
                         gmin, gmax, resp_hdr_len(avg), hostget, s2_poll, retry, warm, meas);
                $display("  feed: origin ceiling %0.2f B/cyc vs decoder demand %0.2f B/cyc = %0.1f%%",
                         ceil_bpc, dem_bpc, 100.0 * ceil_bpc / dem_bpc);

                t0m = cyc + warm; t1m = t0m + meas;
                // progress, so a long run can be watched
                fork begin
                    while (cyc < t1m) begin
                        repeat (100000) @(posedge clk);
                        $display("  [cyc=%0d] feed progress: %0d responses framed (%s), window %0d..%0d",
                                 cyc, ln[0].resp_done + ln[NL-1].resp_done, "dec 0 + last", t0m, t1m);
                    end
                end join_none
                // the window, with four quarter snapshots of the work to show it is steady
                fork begin
                    while (cyc < t0m) @(posedge clk);
                    feed_stats_clear(); h_noconn_cyc = 0; h_noadm_cyc = 0;
                    fmeas = 1'b1;
                    for (int q = 0; q < 4; q++) begin
                        while (cyc < t0m + ((q + 1) * meas) / 4) @(posedge clk);
                        qwork[q] = 0;
                        for (int L = 0; L < NL; L++) qwork[q] = qwork[q] + f_work[L];
                    end
                    fmeas = 1'b0;
                end join_none

                // THE DISPATCHER
                rr = 0; nget = 0; nget0 = -1; h_nolane_cyc = 0;
                while (cyc < t1m && !cfg_stalled && !liveness_failed) begin
                    pick = -1; best = 1 << 30;
                    for (int i = 0; i < NL; i++) begin
                        automatic int sl = (rr + i) % NL;
                        occ = int'(connOccWord[sl / 8][8 * (sl % 8) +: 8]);
                        if (!dec_tainted(sl) && (occ + 1) <= ldep && occ < best) begin
                            pick = sl; best = occ;
                        end
                    end
                    if (pick < 0) begin
                        if (fmeas) h_nolane_cyc = h_nolane_cyc + retry;
                        repeat (retry) @(posedge clk);
                        continue;
                    end
                    rr  = (pick + 1) % NL;
                    len = gmin + $urandom_range(0, gmax - gmin);
                    repeat (hostget) @(posedge clk);
                    if (fmeas && nget0 < 0) nget0 = nget;
                    feed_get(pick, len, o);
                    if (!o) break;
                    nget++;
                end
                $display("  [cyc=%0d] feed: host stopped after %0d GETs (%0d in the window)", cyc, nget,
                         (nget0 < 0) ? 0 : nget - nget0);
                wait (fmeas == 1'b0);
                wait_drain(drainb, ok);

                // ---- report -------------------------------------------------------------------------
                cyc_r = real'(f_cyc);
                if (f_cyc == 0) begin
                    $display("  feed: the measurement window never opened (the run stopped at cycle %0d)", cyc);
                    cyc_r = 1.0;
                end
                tot_bytes = 0; tot_work = 0; minb = 1000.0; meanb = 0.0;
                for (int k = 0; k < FC_N; k++) lost_pct[k] = 0.0;
                $display("");
                $display("  == feed: %s, %0d of %0d connections, conn depth %0d, 1/%0d scale, window %0d cycles ==",
                         origin, s2_conns, NUM_CONNS, hdepth, scale, f_cyc);
                $display("     dec  busy%%   hs%%  stall%%  starv%%  idle%%   MB/s  resp  rel | lost%%: empty switch conn rdpath wrpath   hol server short");
                for (int L = 0; L < NL; L++) begin
                    b = 100.0 * real'(f_work[L]) / (1024.0 * cyc_r);
                    if (b < minb) minb = b;
                    meanb = meanb + b / real'(NL);
                    tot_bytes = tot_bytes + f_bytes[L];
                    $display("     %3d %6.2f %5.2f %6.2f %6.2f %6.2f %6.0f %5d %4d |        %5.2f  %5.2f %4.2f  %5.2f  %5.2f %5.2f  %5.2f %5.2f",
                             L, b, 100.0*real'(f_hs[L])/cyc_r, 100.0*real'(f_stall[L])/cyc_r,
                             100.0*real'(f_starv[L])/cyc_r, 100.0*real'(f_idle[L])/cyc_r,
                             real'(f_bytes[L]) * 250.0 / cyc_r, f_pops[L], f_rels[L],
                             100.0*real'(f_cls[L][FC_EMPTY])/(1024.0*cyc_r),  100.0*real'(f_cls[L][FC_SWITCH])/(1024.0*cyc_r),
                             100.0*real'(f_cls[L][FC_CONNECT])/(1024.0*cyc_r), 100.0*real'(f_cls[L][FC_RDPATH])/(1024.0*cyc_r),
                             100.0*real'(f_cls[L][FC_WRPATH])/(1024.0*cyc_r), 100.0*real'(f_cls[L][FC_HOL])/(1024.0*cyc_r),
                             100.0*real'(f_cls[L][FC_SERVER])/(1024.0*cyc_r), 100.0*real'(f_cls[L][FC_SHORT])/(1024.0*cyc_r));
                    for (int k = 0; k < FC_N; k++)
                        lost_pct[k] = lost_pct[k] + 100.0*real'(f_cls[L][k])/(1024.0*cyc_r)/real'(NL);
                end
                gbps = real'(tot_bytes) / cyc_r * 0.25;
                npops = 0; nrels = 0;
                for (int L = 0; L < NL; L++) begin npops = npops + f_pops[L]; nrels = nrels + f_rels[L]; end
                $display("     aggregate %0.3f GB/s (decoders could take %0.3f); busy min %0.2f%% mean %0.2f%%; quarters %0.1f/%0.1f/%0.1f/%0.1f%%",
                         gbps, dem_bpc * 0.25, minb, meanb,
                         100.0*real'(qwork[0])/(1024.0*real'(NL)*real'(meas/4)),
                         100.0*real'(qwork[1]-qwork[0])/(1024.0*real'(NL)*real'(meas/4)),
                         100.0*real'(qwork[2]-qwork[1])/(1024.0*real'(NL)*real'(meas/4)),
                         100.0*real'(qwork[3]-qwork[2])/(1024.0*real'(NL)*real'(meas/4)));
                $display("     connections (%0d active): free %0.1f%%  waiting on the origin %0.1f%%  held for the reader %0.1f%%",
                         s2_conns, 100.0*real'(f_cfree)/(cyc_r*real'(s2_conns)),
                         100.0*real'(f_cwait)/(cyc_r*real'(s2_conns)), 100.0*real'(f_cheld)/(cyc_r*real'(s2_conns)));
                $display("     host: waiting for lane credit %0.1f%%, polling for a connection %0.1f%% of the window (decoder admission refusing %0.1f%%); arms free/tail %0d/%0d",
                         100.0*real'(h_nolane_cyc)/cyc_r, 100.0*real'(h_noconn_cyc)/cyc_r,
                         100.0*real'(h_noadm_cyc)/cyc_r, s2_n_free, s2_n_tail);
                $display("     card: write channel %0.1f%% busy (max %0d writes outstanding), shared read channel %0.1f%% busy; space_stall(29)=%0b",
                         100.0*real'(f_wr_beats)/cyc_r, f_wr_out_max, 100.0*real'(f_rd_beats)/cyc_r, stallWord[29]);
                $display("FEEDRESULT origin=%s conns=%0d depth=%0d scale=%0d ldepth=%0d busy_min=%0.2f busy_mean=%0.2f gbps=%0.3f ceil=%0.1f empty=%0.2f switch=%0.2f connect=%0.2f rdpath=%0.2f wrpath=%0.2f hol=%0.2f server=%0.2f short=%0.2f cfree=%0.1f cwait=%0.1f cheld=%0.1f hnolane=%0.1f hnoconn=%0.1f hnoadm=%0.1f rdch=%0.1f wrch=%0.1f wrout=%0d pops=%0d rels=%0d",
                         origin, s2_conns, hdepth, scale, ldep, minb, meanb, gbps, 100.0*ceil_bpc/dem_bpc,
                         lost_pct[FC_EMPTY], lost_pct[FC_SWITCH], lost_pct[FC_CONNECT], lost_pct[FC_RDPATH],
                         lost_pct[FC_WRPATH], lost_pct[FC_HOL], lost_pct[FC_SERVER], lost_pct[FC_SHORT],
                         100.0*real'(f_cfree)/(cyc_r*real'(s2_conns)), 100.0*real'(f_cwait)/(cyc_r*real'(s2_conns)),
                         100.0*real'(f_cheld)/(cyc_r*real'(s2_conns)),
                         100.0*real'(h_nolane_cyc)/cyc_r, 100.0*real'(h_noconn_cyc)/cyc_r, 100.0*real'(h_noadm_cyc)/cyc_r,
                         100.0*real'(f_rd_beats)/cyc_r, 100.0*real'(f_wr_beats)/cyc_r, f_wr_out_max,
                         npops, nrels);
                q0 = 100.0*real'(qwork[0])/(1024.0*real'(NL)*real'(meas/4));
                q3 = 100.0*real'(qwork[3]-qwork[2])/(1024.0*real'(NL)*real'(meas/4));
                $display("FEEDVERDICT %s (every decoder busy >= 95%%: min %0.2f%%)%s",
                         (minb >= 95.0) ? "DECODER-BOUND" : "STARVED", minb,
                         ((q0 - q3) > 2.0 || (q3 - q0) > 2.0) ? " NOT-STEADY (first and last quarter differ by > 2 points)" : "");
                if (!ok) begin verdict = "HANG (did not drain after the window)"; dump("feed"); end
                else if (n_err) verdict = "FAIL (byte/framing errors)";
                else if (s2_any_fatal() != "") verdict = {"FAIL (", s2_any_fatal(), ")"};
                else verdict = $sformatf("PASS (byte-exact, drained; decoders %0.1f%% busy, %0.3f GB/s)", meanb, gbps);
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

        // (cuovf) the same on handler_slots: conn 0 overruns its slot -> fatal -> BR_CLOSE releases
        // the session, while the origin still has +LATE segments in flight for it; they land between
        // two of conn 1's segments. Runs on the SLOT_LOG2=16 snapshot, like `ovf`.
        "cuovf": if (DUT_TOE != 0) toe_cu(1'b1); else begin
            int sid0, sid1, c0, late, blen, p0;
            if (!$value$plusargs("LATE=%d", late)) late = 1;
            allow_overflow = 1;
            lane_ignore[0] = 1;
            blen = int'(SLOT_BYTES) + 8192;
            for (int L = 1; L < NL; L++) submit_batch(L, 2, 3000, o);
            wait_drain(400000, ok);
            $display("  [cyc=%0d] warm-up drained=%0b", cyc, ok);
            submit_batch(0, 1, blen, o);
            t0 = cyc;
            while ((cyc - t0) < 400000 && !conn_overflowed(0)) @(posedge clk);
            sid0 = ln[0].sid; sid1 = ln[1].sid;
            hold_sid = sid0;                           // the rest of conn 0's response is "in flight"
            $display("  [cyc=%0d] conn 0 (sid %0d) overflowed; origin holds its remaining %0d bytes",
                     cyc, sid0, sess[sid0].pending.size());
            c0 = n_close_req; t0 = cyc;
            while ((cyc - t0) < 400000 && n_close_req == c0) @(posedge clk);
            $display("  [cyc=%0d] handler closed sid %0d (closes=%0d) conn0 fatal=%0b", cyc, sid0, n_close_req, lane_is_fatal(0));
            ln[0].planned_total = ln[0].resp_done; ln[0].plan = {}; ln[0].expq = {};
            ln[0].active = 0; ln[0].must_end = 0;
            hold_pend_trim(sid0, late * mss);
            b1 = ln[1].resp_done;
            hold2_sid = sid1;
            submit_batch(1, 1, 20000, o);
            t0 = cyc;
            while ((cyc - t0) < 400000 && sess[sid1].pending.size() < 20000) @(posedge clk);
            p0 = sess[sid1].pending.size();
            hold2_sid = -1;                            // two of conn 1's segments...
            while ((cyc - t0) < 400000 && sess[sid1].pending.size() > p0 - 8192) @(posedge clk);
            hold2_sid = sid1;
            hold_sid  = -1;                            // ...the closed session's late bytes...
            while ((cyc - t0) < 400000 && sess[sid0].pending.size() > 0) @(posedge clk);
            $display("  [cyc=%0d] origin: 2 conn-1 segments, then sid %0d's late segment, then the rest of conn 1", cyc, sid0);
            hold2_sid = -1;                            // ...the rest of conn 1
            wait_drain(400000, ok);
            dump("cuovf");
            $display("  conn 1: %0d -> %0d responses (planned %0d), errors=%0d, readPkgs that popped another session's packet: %0d, conn1 fatal=%0b",
                     b1, ln[1].resp_done, ln[1].planned_total, n_err, n_meta_mismatch, lane_is_fatal(1));
            if (n_err)      verdict = $sformatf("CORRUPT (%0d checker errors on the surviving connection)", n_err);
            else if (!ok)   verdict = "HANG (the surviving connection never completed)";
            else            verdict = "PASS";
        end

        "fin_overtake": if (DUT_TOE != 0) toe_fin_overtake(); else verdict = "SKIP (handler_toe scenario)";
        "win_ok":       if (DUT_TOE != 0) toe_scen_win(1'b0);      else verdict = "SKIP (handler_toe scenario)";
        "win_bad":      if (DUT_TOE != 0) toe_scen_win(1'b1);      else verdict = "SKIP (handler_toe scenario)";
        "sidreuse":     if (DUT_TOE != 0) toe_scen_sidreuse();     else verdict = "SKIP (handler_toe scenario)";
        "thr_hbm":      if (DUT_TOE != 0) toe_thr_hbm();      else verdict = "SKIP (handler_toe scenario)";

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
        // Re-read every cycle rather than `repeat (MAX_CYCLES)`, so a scenario may raise it (feed).
        while ((cyc - c0) < MAX_CYCLES) @(posedge clk);
        $display("!!! global watchdog fired at %0d cycles", cyc);
        dump("watchdog");
        $display("lane_drain_tb '%s': WATCHDOG", scen);
        $finish;
    end

endmodule
