`timescale 1ns / 1ps

import lynxTypes::*;
import http_types::*;

// =================================================================================================
// HTTP client handler, HBM-SLOT variant. N TCP connections, one card-memory slot each, drained by
// one reader per decoder. ARCHITECTURE.md, ADR-5.
//
// WHY THIS IS A NEW MODULE AND NOT AN EDIT OF handler_multi
// ---------------------------------------------------------
// handler_multi is the sealed build-119 baseline. It is what every measurement on record was taken
// on, and the A/B that justifies this work is "the same bench, the same scenarios, the two handlers
// side by side". An in-place rewrite would destroy the control arm, so handler_multi stays byte for
// byte as it is and this is built beside it. lane_drain runs both (`run.sh --dut slots`).
//
// WHAT CHANGES, AND WHAT DOES NOT
// -------------------------------
// The SESSION side is copied as it is: one tcp_init sequenced across connections, open/bind/
// reconnect/fatal per connection, response-keyed re-arm, dead-connection discard, an idle close
// staying down. Those behaviours are the residue of a dozen board failures and none of them is
// about the datapath.
//
// The DATAPATH is replaced outright:
//
//   build-119                             this
//   ---------                             ----
//   rx_dispatch -> tcp_read[L]            rx_dispatch -> slot_writer -> card memory
//     (128 KiB BRAM fifo + framer                       (1 shared 64 KiB fifo,
//      + readPkg loop, ONE PER LANE)                     per-conn slot cursors)
//   -> strip_http[L] (inside tcp_read)    card memory -> slot_reader[d] -> strip_http[d]
//   -> axis_rewrite_last[L] -> decoder    -> axis_rewrite_last[d] -> decoder
//
// `tcp_read` leaves the datapath entirely. Everything downstream of the framer is unchanged, which
// is deliberate: strip_http and axis_rewrite_last are where the silent-corruption bugs live, and
// this work package changes neither.
//
// THE POINT OF THE EXERCISE
// -------------------------
// In build-119 a lane's fifo filling drops `conn_space_ok`, which blocks the head of rx_dispatch's
// arrival-ordered queue, which starves EVERY other lane (ADR-5's measurement table: a faster origin
// is a net loss at 2 lanes and fatal at 3). Here `conn_space_ok` is the SHARED writer fifo's, and
// that fifo is drained by the card DMA at HBM speed rather than by a decoder. A decoder that stops
// for good now costs exactly its own connection: its slot fills, its reader stops, and nothing it
// does reaches rx_dispatch at all. lane_drain's `thr` scenario is that claim, measured.
//
// PIPELINED GETs PER CONNECTION (CSR revision 4, 2026-09-23)
// ---------------------------------------------------------
// Revision 3 held ARM_READY low until the connection's slot had been released, i.e. one GET per
// connection in flight, and every connection idled through each request round trip (MinIO ~0.7 ms;
// build-124 measured -26%..-15% against build-119's depth-4 lanes). Since revision 4 an arm only
// needs room in the reader's entry queue: slot_reader treats one connection's slot as a continuous
// byte stream and only releases it when the connection runs dry (see its header, "PIPELINED GETs").
// strip_http keeps mid-beat residue across responses, which is exactly what makes that correct on
// ONE connection; it is also why a reader still only switches connections at a released slot.
//
// The one rule that moves to the host: the bytes armed on a connection since its slot was last
// released (response headers included) must fit in 2^SLOT_LOG2, because the slot is a bump
// allocator, not a ring. `conn_drained` (CONN_DRAINED[c]) is that release, exported for the host:
// it falls when an arm is accepted and rises when the slot is released with no entry queued and no
// arm in that cycle (or by a teardown), so a host that READS it set knows the slot is empty and
// nothing is armed on it. Overrunning the slot
// is caught, not corrupting: slot_writer drops the segment and the connection goes fatal.
//
// STAGE 2: N_CONNS > N_DECODERS (CSR revision 5, 2026-09-23)
// ------------------------------------------------------------
// Stage 1 fixed connection c to decoder c. Since revision 5 the ARM beat names its connection
// (REQ_CHUNK_BYTES[44:40], `req_conn`) as well as its decoder, and any connection can feed any
// decoder; revision 4 and below take conn = decoder, which is stage 1 exactly (CSR_REV < 5 requires
// N_CONNS == N_DECODERS). Everything per DECODER stays per decoder -- request streamer, reader,
// framer, chunk queue -- so an extra connection costs only its session state and its slot cursors.
//
// THE ONE RULE THAT MAKES A SHARED FRAMER CORRECT. strip_http keeps mid-beat residue across the
// responses of one connection (that is how pipelined GETs are framed), so a reader may only switch
// connections where that residue is provably empty. The hardware guarantees it at the config port:
// an arm on connection c for decoder d is admitted only if
//     c is DRAINED   (nothing armed on it, slot released -- CONN_DRAINED[c]), or
//     c is the TAIL  of d's entry queue (the last arm d accepted named c, and c still has entries),
// so a connection's entries are always contiguous in ONE decoder's queue, and the reader's "next
// entry names another connection" means "this connection has nothing more armed". slot_reader then
// releases the slot, checks the framer is idle and clears it. No per-connection framer state, no
// re-reads. The admission is monotone in the host's favour as before (only the host arms; the reader
// only ever drains), so poll-then-write stays race free. `cur_dec_q[c]`, `pend_q[c]` (entries armed
// and not yet retired or dropped) and `tail_conn_q[d]` are the state behind it.
//
// A FATAL CONNECTION IN STAGE 2. Its queued entries are dropped as they reach the head (slot_reader,
// "FLUSH"), so they cannot block the healthy connections behind them. But a fatal with entries still
// pending means a response the decoder's chunk queue is counting on will never come -- the decoder's
// byte stream has a hole -- so that decoder is TAINTED: its body output is cut off after the framer
// (responses of healthy connections still queued on it are framed and retired, so those connections
// drain and stay usable on the other decoders), arms for it are refused, and the host sees it as a
// fatal lane (DEC_STATE, read id 33). In stage 1 that is exactly the old "fatal lane".
//
// ERROR SEMANTICS
// ---------------
// Three failures are new with the slots, and all three are mapped onto the per-connection reporting
// that already exists rather than onto a new channel. The containment rule is build-119's: one
// connection's error never touches another's data.
//
//   * SLOT OVERFLOW (slot_writer `slot_poison[c]`) -- a segment would have run past the end of
//     connection c's slot, so it was dropped whole and everything c sends is dropped until it is
//     released. The response has a hole in it and only the host can reissue, so c goes FATAL and
//     its session is torn down. ERR bit 7. The shared path is untouched: the dropped segment is
//     still drained out of the shared fifo (slot_writer's O_DISCARD), so it costs the other
//     connections a fifo slot for a few cycles and nothing else.
//
//   * RESIDUE (slot_reader `residue_err`) -- when the connection ran dry (its last queued response
//     was framed) the slot was not exactly empty, i.e. bytes landed that belong to no response this
//     decoder was told about. Either the host sent more GETs than it armed (two in one arm's request
//     text) or a server sent more than its Content-Length. Those bytes would
//     be spliced into the front of the next response, so c goes FATAL. Reported as ERR bit 3
//     (RESP_ERR) -- same class, same host action, reissue -- with `residue` also OR-folded into
//     stallWord[31] so the two causes are still distinguishable from one register.
//
//   * A CONNECTION THAT DIES WITH A PARTLY FILLED SLOT -- fatal or a plain reconnect. The slot must
//     be released, and slot_writer ASSERTS that nothing of c is in flight when it is. That is why
//     the bring-up FSM has a state build-119 does not: BR_DRAIN. The order is
//
//         BR_CLOSE   close the session, release it in rx_dispatch (later packets for c are dropped
//                    there, so nothing new can enter the slot), conn_up_q[c] falls -- which is the
//                    same level that holds strip_http[d] in `clear` and slot_reader[d] in `flush`
//         BR_DRAIN   wait for slot_writer's conn_quiet[c] AND slot_reader[d]'s flush_busy to be
//                    clear, continuously, for RELEASE_SETTLE cycles
//         release    pulse conn_release[c] -- cursors, landed and the poison all go to zero
//         BR_OPEN    only now may a new session be bound
//
//     Doing the release before the drain is the bug this state exists to prevent: a segment still
//     on its way in would land at offset 0 of a slot the reader believes is empty, and the next
//     response would be read out with another response's head spliced onto it.
//
// DESIGN FOR SYNTHESIS
// --------------------
//   * no combinational path from a DMA ack or from resp_done through a cursor compare into a
//     request valid -- that is slot_reader's four-stage request pipeline and slot_writer's
//     registered descriptor, both unchanged here;
//   * the CSR readback muxes are REGISTERED (see the readback section). 32 connections x five words
//     is a wide OR tree and it feeds an AXI-Lite read, which has no timing requirement worth a
//     path;
//   * the body output keeps build-119's two-deep register slice, inlined here rather than
//     instantiated, so this module elaborates from a clean checkout (see gen_dec).
// =================================================================================================
module handler_slots #(
    // Connections: one TCP session, one session FSM and one card-memory slot each.
    parameter int N_CONNS    = 4,
    // Decoders: one slot_reader, one framer, one chunk queue and one decoder each.
    parameter int N_DECODERS = 4,
    // Column chunks queued ahead of the data, per DECODER (axis_rewrite_last).
    parameter int QUEUE_DEPTH = 64,
    // Armed GETs queued ahead of the data, per DECODER (slot_reader's entry queue).
    parameter int ENTRY_DEPTH = 64,
    // log2 of one connection's slot in card memory. 28 = 256 MiB, so N_CONNS = 4 fills the 1 GiB
    // slot page; stage 2 (24 connections) wants 25. The host reads it back from SLOT_POLICY[29:24]
    // and budgets the bytes it arms per connection against it.
    parameter int SLOT_LOG2 = 28,
    // The SHARED elastic fifo in front of the card write channel, in 64-byte beats.
    parameter int SLOT_FIFO_DEPTH = 1024,
    // The most one card read may ask for, in bytes. 16 KiB since 2026-09-22: every reader now
    // shares ONE card read channel (build-123 failed route_design at five card AXI streams --
    // slot_dma_shell.sv), so this is also the longest one decoder can make another wait for its
    // turn, and it sizes slot_rd_share's per-decoder receive fifo at 2 x RD_MAX.
    parameter int RD_MAX = 16384,
    parameter int TX_CHUNK_BYTES = 4096,
    parameter int STALL_CYCLES = 268435456,
    // How long one connection may hold up the shared receive path before rx_dispatch declares it
    // dead. It should now never fire -- the shared fifo is drained by the DMA, not by a decoder --
    // which is exactly why it is still here: if it does fire, the premise of ADR-5 is wrong.
    parameter int LANE_STALL_CYCLES = 65536,
    // Cycles of no progress on a decoder with an entry outstanding before its connection is
    // declared failed. 2^29 is ~2.1 s at 250 MHz, the same figure tcp_read used.
    parameter int READ_WDOG_BITS = 29,
    // Cycles of continuous quiet on both sides before a torn-down connection's slot is released.
    // One TCP segment is 66 beats; this is four of them.
    parameter int RELEASE_SETTLE = 256,
    // 5 here (stage 2); 4 keeps revision 4's conn == decoder arm decoding. Parameterised so the
    // value is stated once and reaches both the readback words and HttpConfig, which gates its
    // register map on it.
    parameter int CSR_REV = 5,

    localparam int CONN_BITS = (N_CONNS    > 1) ? $clog2(N_CONNS)    : 1,
    localparam int DEC_BITS  = (N_DECODERS > 1) ? $clog2(N_DECODERS) : 1
) (
    input  logic ap_clk,
    input  logic ap_rst_n,

    // -- TCP connection management (shared; opens are sequenced) ----------------------------------
    output logic                              m_axis_open_connection_TVALID,
    input  logic                              m_axis_open_connection_TREADY,
    output logic [TCP_OPEN_CONN_REQ_BITS-1:0] m_axis_open_connection_TDATA,
    input  logic                              s_axis_open_status_TVALID,
    output logic                              s_axis_open_status_TREADY,
    input  logic [TCP_OPEN_CONN_RSP_BITS-1:0] s_axis_open_status_TDATA,
    output logic                              m_axis_close_connection_TVALID,
    input  logic                              m_axis_close_connection_TREADY,
    output logic [TCP_CLOSE_CONN_REQ_BITS-1:0] m_axis_close_connection_TDATA,

    // -- TCP receive (shared, demultiplexed by rx_dispatch) ---------------------------------------
    input  logic                       s_axis_notifications_TVALID,
    output logic                       s_axis_notifications_TREADY,
    input  logic [TCP_NOTIFY_BITS-1:0] s_axis_notifications_TDATA,
    output logic                           m_axis_read_package_TVALID,
    input  logic                           m_axis_read_package_TREADY,
    output logic [TCP_RD_PKG_REQ_BITS-1:0] m_axis_read_package_TDATA,
    input  logic                        s_axis_rx_metadata_TVALID,
    output logic                        s_axis_rx_metadata_TREADY,
    input  logic [TCP_RX_META_BITS-1:0] s_axis_rx_metadata_TDATA,
    input  logic                       s_axis_rx_data_TVALID,
    output logic                       s_axis_rx_data_TREADY,
    input  logic [AXI_DATA_BITS-1:0]   s_axis_rx_data_TDATA,
    input  logic [AXI_DATA_BITS/8-1:0] s_axis_rx_data_TKEEP,
    input  logic                       s_axis_rx_data_TLAST,

    // -- TCP transmit (shared, arbitrated) --------------------------------------------------------
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

    // -- config -----------------------------------------------------------------------------------
    input  logic         req_valid,
    output logic         req_ready,
    input  http_config_t req_data,

    // -- base of the slot array in card memory (CSR SLOT_BASE_LO/HI, revision 3) -------------------
    input  logic [VADDR_BITS-1:0] slot_base,

    // -- per-DECODER request text from the host ---------------------------------------------------
    input  logic [N_DECODERS-1:0]      s_axis_req_TVALID,
    output logic [N_DECODERS-1:0]      s_axis_req_TREADY,
    input  logic [AXI_DATA_BITS-1:0]   s_axis_req_TDATA  [N_DECODERS],
    input  logic [AXI_DATA_BITS/8-1:0] s_axis_req_TKEEP  [N_DECODERS],
    input  logic [N_DECODERS-1:0]      s_axis_req_TLAST,

    // -- per-DECODER framed body out --------------------------------------------------------------
    output logic [N_DECODERS-1:0]      m_axis_body_tvalid,
    input  logic [N_DECODERS-1:0]      m_axis_body_tready,
    output logic [AXI_DATA_BITS-1:0]   m_axis_body_tdata [N_DECODERS],
    output logic [AXI_DATA_BITS/8-1:0] m_axis_body_tkeep [N_DECODERS],
    output logic [N_DECODERS-1:0]      m_axis_body_tlast,

    // =============================================================================================
    // CARD DMA. Flat ports on purpose: slot_dma_shell wraps them in Coyote's metaIntf/req_t (a
    // MetaIntfArbiter over {OutputWriter, this} on sq_wr in vfpga_top, a cq_wr duplicator filtered
    // by strm/dest, and slot_rd_share onto the one sq_rd). Keeping the shell types out of here is
    // what lets the whole module run in xsim against unit-tests/card_dma/card_dma_model.
    // =============================================================================================
    // ONE write channel -> axis_card_send[0], LOCAL_WRITE / STRM_CARD / dest 0 / last=1.
    output logic                       wr_req_valid,
    input  logic                       wr_req_ready,
    output logic [VADDR_BITS-1:0]      wr_req_vaddr,
    output logic [LEN_BITS-1:0]        wr_req_len,
    output logic                       wr_req_last,
    output logic                       m_axis_card_tvalid,
    input  logic                       m_axis_card_tready,
    output logic [AXI_DATA_BITS-1:0]   m_axis_card_tdata,
    output logic [AXI_DATA_BITS/8-1:0] m_axis_card_tkeep,
    output logic                       m_axis_card_tlast,
    input  logic                       wr_ack,          // cq_wr, one per request, in issue order

    // N_DECODERS read request ports. They do NOT reach the shell one per decoder any more: since
    // 2026-09-22 slot_rd_share multiplexes all of them onto the one card read channel
    // (axis_card_recv[0], LOCAL_READ / STRM_CARD / dest 0 / last=0), giving each decoder a receive
    // fifo and a credit so a slow one cannot stall the shared stream. Nothing here changes: this
    // module never learned which stream its bytes came from.
    // There is no ack: a last=0 request draws no cq_rd, and the readers count bytes instead.
    output logic                       rd_req_valid [N_DECODERS],
    input  logic                       rd_req_ready [N_DECODERS],
    output logic [VADDR_BITS-1:0]      rd_req_vaddr [N_DECODERS],
    output logic [LEN_BITS-1:0]        rd_req_len   [N_DECODERS],
    output logic                       rd_req_last  [N_DECODERS],
    input  logic                       s_axis_card_tvalid [N_DECODERS],
    output logic                       s_axis_card_tready [N_DECODERS],
    input  logic [AXI_DATA_BITS-1:0]   s_axis_card_tdata  [N_DECODERS],
    input  logic [AXI_DATA_BITS/8-1:0] s_axis_card_tkeep  [N_DECODERS],
    input  logic                       s_axis_card_tlast  [N_DECODERS],

    // -- readback, CSR revision 1/2 positions (unchanged meanings) ---------------------------------
    output logic [31:0] totalWord,
    output logic [31:0] inflightWord,
    output logic [31:0] queueDepthWord,
    output logic [31:0] stallWord,
    output logic [31:0] respWord,
    output logic [31:0] contentLengthWord,
    output logic [31:0] bodyRemainingWord,
    output logic [3:0]  state_debug,

    // -- per-lane readback, CSR revision 2 (connections/decoders 0..7) ------------------------------
    output logic [63:0] laneOccWord,
    output logic [63:0] laneReadyWord,
    output logic [63:0] laneStateWord,
    output logic [63:0] laneErrWord,
    output logic [63:0] lanePolicyWord,

    // -- per-connection readback, CSR revision 3 (up to 32) -----------------------------------------
    output logic [3:0][63:0] connOccWord,      // chunk entries per decoder, one byte each
    output logic [1:0][63:0] connReadyWord,    // one nibble per connection
    output logic [3:0][63:0] connErrWord,      // one byte per connection
    output logic      [63:0] connDrainedWord,  // [c] drained credit, [32+c] slot overflowed
    output logic      [63:0] slotPolicyWord,

    // -- CSR revision 5, read ids 33..38 (see http_config.sv) --------------------------------------
    //   [0]    DEC_STATE   one byte per decoder
    //   [1..4] CONN_MAP    one byte per connection, 8 per word
    //   [5]    CONN_CAUSE  [c] residue at a release, [32+c] went fatal with entries pending
    output logic [5:0][63:0] connExtWord
);

    initial begin
        if (N_CONNS < 1 || N_CONNS > 32)
            $error("handler_slots: N_CONNS must be 1..32");
        if (N_DECODERS < 1 || N_DECODERS > 32)
            $error("handler_slots: N_DECODERS must be 1..32");
        // Below revision 5 the arm carries no connection and conn == decoder is assumed.
        if (CSR_REV < 5 && N_CONNS != N_DECODERS)
            $error("handler_slots: CSR_REV %0d requires N_CONNS == N_DECODERS (got %0d and %0d)",
                   CSR_REV, N_CONNS, N_DECODERS);
        if (N_DECODERS > 8)
            $error("handler_slots: DEC_STATE/CONN_MAP address at most 8 decoders");
        if (CSR_REV < 3)
            $error("handler_slots: CSR_REV must be >= 3 (the slot registers do not exist below it)");
    end

    localparam logic [7:0] CSR_REVISION = 8'(CSR_REV);

    // =============================================================================================
    // Config beat decode. Every beat names a DECODER in req_chunk_dest, exactly as build-119 does.
    // =============================================================================================
    logic [DEC_BITS-1:0] cfg_dec;
    assign cfg_dec = req_data.req_chunk_dest[DEC_BITS-1:0];

    logic cfg_is_arm_w, cfg_is_entry_w;
    assign cfg_is_arm_w   = req_valid && (req_data.req_total_bytes != 32'd0);
    assign cfg_is_entry_w = req_valid && (req_data.req_total_bytes == 32'd0);

    // The connection an ARM names. Revision 5 carries it in REQ_CHUNK_BYTES[44:40]; below that the
    // decoder IS the connection. An index past N_CONNS is never admitted (req_ready stays low), which
    // is the same answer the host gets for a decoder that does not exist.
    logic [CONN_BITS-1:0] cfg_conn;
    logic                 cfg_conn_ok;
    generate
        if (CSR_REV >= 5) begin : g_cfg_conn
            assign cfg_conn    = req_data.req_conn[CONN_BITS-1:0];
            assign cfg_conn_ok = (32'(req_data.req_conn) < 32'(N_CONNS));
        end else begin : g_cfg_conn_dec
            assign cfg_conn    = CONN_BITS'(cfg_dec);
            assign cfg_conn_ok = 1'b1;
        end
    endgenerate

    logic [N_DECODERS-1:0] rwl_cfg_ready, rwl_busy, rwl_starved;
    logic [N_DECODERS-1:0] stream_busy, stream_refused, stream_bus_req, stream_bus_grant;
    logic [N_DECODERS-1:0] dec_occ_ok;
    logic [N_DECODERS-1:0] dec_arm_ready_w, dec_entry_ready_w;

    // Per-connection and per-decoder placement state (stage 2). See "STAGE 2" in the header.
    localparam int PEND_BITS = $clog2(ENTRY_DEPTH + 1);
    logic [N_CONNS-1:0]    conn_fatal_q, conn_drained_q;
    logic [PEND_BITS-1:0]  pend_q      [N_CONNS];   // entries armed on c, not yet retired/dropped
    logic [DEC_BITS-1:0]   cur_dec_q   [N_CONNS];   // the decoder c's entries are queued on
    logic [CONN_BITS-1:0]  tail_conn_q [N_DECODERS];// the connection d's last accepted arm named
    logic [N_DECODERS-1:0] dec_tainted_q;

    // THE ADMISSION CONDITIONS.
    //
    // An ENTRY waits for that decoder's chunk queue to have room (build-119's rule). An ARM waits
    // for the decoder -- the previous request text gone out, room in the reader's entry queue, not
    // tainted -- and for the CONNECTION: not fatal, and either drained or the tail of this decoder's
    // queue (the rule that keeps a shared framer correct; see "STAGE 2").
    //
    // All of it is MONOTONE IN THE HOST'S FAVOUR -- nothing but a config beat the host itself writes
    // can clear any of it (fatal and tainted never clear, and a host polls them first) -- so "poll,
    // then write" is race free and needs no retry. The one non-monotone instant is the cycle between
    // a connection's last entry retiring and CONN_DRAINED rising, where neither half is true; a beat
    // presented then simply waits one cycle.
    logic [N_CONNS-1:0] conn_free_w;       // drained with nothing pending: any decoder may take it
    always_comb begin
        for (int c = 0; c < N_CONNS; c++)
            conn_free_w[c] = conn_drained_q[c] && (pend_q[c] == '0) && !conn_fatal_q[c];
    end

    function automatic logic conn_arm_ok(input logic [CONN_BITS-1:0] c, input logic [DEC_BITS-1:0] d);
        conn_arm_ok = conn_free_w[c] ||
                      (!conn_fatal_q[c] && (pend_q[c] != '0) && (cur_dec_q[c] == d) &&
                       (tail_conn_q[d] == c));
    endfunction

    // always_comb and NOT a continuous assign: an `assign` calling a function is only sensitive to
    // the function's ARGUMENTS, so it would miss every change of the state the function reads (in
    // xsim it stayed at its time-0 X until the beat's decoder changed). always_comb follows the
    // function body's reads.
    logic arm_conn_ok_w;
    always_comb arm_conn_ok_w = cfg_conn_ok && conn_arm_ok(cfg_conn, cfg_dec);

    always_comb begin
        req_ready = 1'b0;
        for (int d = 0; d < N_DECODERS; d++) begin
            if (cfg_dec == DEC_BITS'(d)) begin
                req_ready = (req_data.req_total_bytes != 32'd0) ? (dec_arm_ready_w[d] && arm_conn_ok_w)
                                                                : dec_entry_ready_w[d];
            end
        end
    end

    // The two kinds of beat fire from their OWN admission terms rather than through req_ready.
    // Identical values -- for an ENTRY req_ready IS dec_entry_ready_w[cfg_dec], for an ARM it IS
    // dec_arm_ready_w[cfg_dec] && arm_conn_ok_w -- but the entry side (the chunk queues,
    // dec_occ_q) no longer sits behind the arm side's connection placement cone (pend_q,
    // cur_dec_q, tail_conn_q, a 32:1 select on cfg_conn), which it never depended on. build-127
    // timing: pend_q -> axis_rewrite_last len_mem was -3.2 ns.
    logic                  arm_fire_w;
    logic [N_DECODERS-1:0] entry_fire_w;
    logic                  arm_dec_ready_w;
    always_comb begin
        arm_dec_ready_w = 1'b0;
        for (int d = 0; d < N_DECODERS; d++)
            if (cfg_dec == DEC_BITS'(d)) arm_dec_ready_w = dec_arm_ready_w[d];
    end
    assign arm_fire_w = cfg_is_arm_w && arm_dec_ready_w && arm_conn_ok_w;
    for (genvar d = 0; d < N_DECODERS; d++) begin : gen_entry_fire
        assign entry_fire_w[d] = cfg_is_entry_w && (cfg_dec == DEC_BITS'(d)) && dec_entry_ready_w[d];
    end

    // =============================================================================================
    // Connection bring-up. ONE tcp_init, sequenced across connections, plus BR_DRAIN.
    // =============================================================================================
    logic [31:0] server_ip_q, server_port_q;
    logic        any_armed_q;

    localparam logic [2:0] BR_IDLE  = 3'd0;
    localparam logic [2:0] BR_OPEN  = 3'd1;
    localparam logic [2:0] BR_NEXT  = 3'd2;
    localparam logic [2:0] BR_DONE  = 3'd3;
    localparam logic [2:0] BR_CLOSE = 3'd4;
    localparam logic [2:0] BR_DRAIN = 3'd5;   // new: see the header

    logic [2:0]           br_q, br_d;
    logic [CONN_BITS-1:0] bring_conn_q, bring_conn_d;
    logic                 bringing_up_q;
    logic [N_CONNS-1:0]   conn_up_q;
    logic [15:0]          conn_sid_q [N_CONNS];

    logic        init_done, init_error;
    logic [15:0] init_session_id;
    logic [3:0]  init_state_debug;

    localparam int RETRY_BITS = 16;
    logic [RETRY_BITS-1:0] retry_wait_q;
    logic [7:0]            reconn_cnt_q;

    tcp_init inst_tcp_init (
        .clk(ap_clk), .rst_n(ap_rst_n),
        .start(br_q == BR_OPEN),
        .serverIpAddress(server_ip_q),
        .serverPort(server_port_q),
        .m_axis_open_connection_TVALID(m_axis_open_connection_TVALID),
        .m_axis_open_connection_TREADY(m_axis_open_connection_TREADY),
        .m_axis_open_connection_TDATA (m_axis_open_connection_TDATA),
        .s_axis_open_status_TVALID(s_axis_open_status_TVALID),
        .s_axis_open_status_TREADY(s_axis_open_status_TREADY),
        .s_axis_open_status_TDATA (s_axis_open_status_TDATA),
        .done(init_done), .error(init_error),
        .session_id(init_session_id), .state_debug(init_state_debug)
    );

    logic                 bind_en_w;
    logic [CONN_BITS-1:0] bind_conn_w;
    logic [15:0]          bind_sid_w;
    logic                 release_en_w;
    logic [CONN_BITS-1:0] release_conn_w;

    // The slot release, which is NOT the session release -- see the header for why they are two
    // events with a drain between them.
    logic                 slot_rel_en_w;
    logic [CONN_BITS-1:0] slot_rel_conn_w;

    logic [N_CONNS-1:0] conn_idle_w, conn_want_reconn_w, conn_must_die_w, conn_want_close_w;
    logic               reconn_pending_w, close_pending_w;
    logic [CONN_BITS-1:0] reconn_conn_w, close_conn_w;
    logic                 close_only_q, close_only_d;

    // =============================================================================================
    // Receive: one dispatcher, one shared writer, N slots.
    // =============================================================================================
    logic [N_CONNS-1:0]         conn_tvalid, conn_tready, conn_space_ok, conn_closed;
    logic [N_CONNS-1:0]         conn_pkg_issued;
    logic [AXI_DATA_BITS-1:0]   conn_tdata;
    logic [AXI_DATA_BITS/8-1:0] conn_tkeep;
    logic                       conn_tlast;
    logic [N_CONNS-1:0]         rxd_has_pending, rxd_conn_dead;
    logic                       rxd_overflow, rxd_route_stall;

    rx_dispatch #(
        .NUM_CONNS       (N_CONNS),
        .NOTIFY_DEPTH    (64),
        .HOL_STALL_CYCLES(LANE_STALL_CYCLES)
    ) inst_rx_dispatch (
        .clk(ap_clk), .rst_n(ap_rst_n),
        .s_axis_notifications_TVALID(s_axis_notifications_TVALID),
        .s_axis_notifications_TREADY(s_axis_notifications_TREADY),
        .s_axis_notifications_TDATA (s_axis_notifications_TDATA),
        .bind_en(bind_en_w), .bind_conn(bind_conn_w), .bind_sid(bind_sid_w),
        .release_en(release_en_w), .release_conn(release_conn_w),
        .m_axis_read_package_TVALID(m_axis_read_package_TVALID),
        .m_axis_read_package_TREADY(m_axis_read_package_TREADY),
        .m_axis_read_package_TDATA (m_axis_read_package_TDATA),
        .s_axis_rx_metadata_TVALID(s_axis_rx_metadata_TVALID),
        .s_axis_rx_metadata_TREADY(s_axis_rx_metadata_TREADY),
        .s_axis_rx_metadata_TDATA (s_axis_rx_metadata_TDATA),
        .s_axis_rx_data_TVALID(s_axis_rx_data_TVALID),
        .s_axis_rx_data_TREADY(s_axis_rx_data_TREADY),
        .s_axis_rx_data_TDATA (s_axis_rx_data_TDATA),
        .s_axis_rx_data_TKEEP (s_axis_rx_data_TKEEP),
        .s_axis_rx_data_TLAST (s_axis_rx_data_TLAST),
        .conn_tvalid(conn_tvalid), .conn_tready(conn_tready),
        .conn_tdata (conn_tdata),  .conn_tkeep(conn_tkeep), .conn_tlast(conn_tlast),
        .conn_space_ok(conn_space_ok), .conn_closed(conn_closed),
        .conn_pkg_issued(conn_pkg_issued),
        .dbg_has_pending(rxd_has_pending),
        .dbg_overflow   (rxd_overflow),
        .dbg_route_stall(rxd_route_stall),
        .dbg_lane_dead  (rxd_conn_dead)
    );

    logic [N_CONNS-1:0][SLOT_LOG2:0] landed;
    logic [N_CONNS-1:0] conn_release_w, conn_quiet_w, slot_poison_w, slot_overflow_w;
    logic               wr_route_stall, wr_fifo_stall, wr_space_stall;

    slot_writer #(
        .N_CONNS   (N_CONNS),
        .SLOT_LOG2 (SLOT_LOG2),
        .FIFO_DEPTH(SLOT_FIFO_DEPTH)
    ) inst_slot_writer (
        .clk(ap_clk), .rst_n(ap_rst_n),
        .conn_tvalid(conn_tvalid), .conn_tready(conn_tready),
        .conn_tdata (conn_tdata),  .conn_tkeep(conn_tkeep), .conn_tlast(conn_tlast),
        .conn_pkg_issued(conn_pkg_issued),
        .conn_space_ok  (conn_space_ok),
        .slot_base      (slot_base),
        .conn_release   (conn_release_w),
        // A connection with no session cannot be reserved for: rx_dispatch will read and discard
        // whatever is announced for it, so those beats never reach the writer.
        .conn_down      (~conn_up_q),
        .wr_req_valid(wr_req_valid), .wr_req_ready(wr_req_ready),
        .wr_req_vaddr(wr_req_vaddr), .wr_req_len(wr_req_len), .wr_req_last(wr_req_last),
        .m_axis_tvalid(m_axis_card_tvalid), .m_axis_tready(m_axis_card_tready),
        .m_axis_tdata (m_axis_card_tdata),  .m_axis_tkeep (m_axis_card_tkeep),
        .m_axis_tlast (m_axis_card_tlast),
        .wr_ack(wr_ack),
        .landed(landed),
        .conn_quiet(conn_quiet_w),
        .slot_poison(slot_poison_w),
        .slot_overflow(slot_overflow_w),
        .route_stall(wr_route_stall),
        .fifo_stall (wr_fifo_stall),
        .space_stall(wr_space_stall)
    );

    // =============================================================================================
    // Transmit arbitration: N_DECODERS request streams, one TOE transmit path. Unchanged from
    // build-119 -- the request-text path is deliberately byte-identical in this work package, and
    // the plan's {conn, text_len} prefix beat belongs to WP5 with the rest of the N_CONNS > N_DEC
    // generalisation.
    // =============================================================================================
    logic [DEC_BITS-1:0] tx_sel;
    logic                tx_busy;

    tx_arbiter #(.N(N_DECODERS)) inst_tx_arbiter (
        .clk(ap_clk), .rst_n(ap_rst_n),
        .req(stream_bus_req), .grant(stream_bus_grant),
        .sel(tx_sel), .busy(tx_busy)
    );

    logic [N_DECODERS-1:0]       dec_meta_valid, dec_data_valid, dec_data_last, dec_stat_ready;
    logic [TCP_TX_META_BITS-1:0] dec_meta_data [N_DECODERS];
    logic [AXI_DATA_BITS-1:0]    dec_data_data [N_DECODERS];
    logic [AXI_DATA_BITS/8-1:0]  dec_data_keep [N_DECODERS];

    assign m_axis_tx_meta_TVALID = tx_busy && dec_meta_valid[tx_sel];
    assign m_axis_tx_meta_TDATA  = dec_meta_data[tx_sel];
    assign m_axis_tx_data_TVALID = tx_busy && dec_data_valid[tx_sel];
    assign m_axis_tx_data_TDATA  = dec_data_data[tx_sel];
    assign m_axis_tx_data_TKEEP  = dec_data_keep[tx_sel];
    assign m_axis_tx_data_TLAST  = dec_data_last[tx_sel];
    assign s_axis_tx_status_TREADY = tx_busy && dec_stat_ready[tx_sel];

    // =============================================================================================
    // The decoders
    // =============================================================================================
    logic [N_DECODERS-1:0] sh_resp_done, sh_resp_dirty, sh_resp_error, sh_status_ok;
    logic [23:0]           sh_status_ascii [N_DECODERS];
    logic [31:0]           sh_content_len  [N_DECODERS];
    logic [31:0]           sh_body_remain  [N_DECODERS];

    logic [N_DECODERS-1:0] rdr_busy, rdr_flush_busy, rdr_entry_done, rdr_residue_err, rdr_entry_ready;
    logic [N_DECODERS-1:0] rdr_rd_pending, rdr_residue_ev, rdr_pop, rdr_head_valid, rdr_fr_clear;
    logic [CONN_BITS-1:0]  rdr_head_conn [N_DECODERS];
    logic [CONN_BITS-1:0]  rdr_done_conn [N_DECODERS];
    logic [3:0]            rdr_state [N_DECODERS];
    logic [7:0]            rdr_entry_occ [N_DECODERS];
    logic [3:0]            dec_tx_state [N_DECODERS];
    logic [N_DECODERS-1:0] rdr_progress_w;
    logic [N_CONNS-1:0]    rdr_release [N_DECODERS];
    logic [N_DECODERS-1:0] sh_idle, sh_fs_idle;
    logic [N_DECODERS-1:0] fs_busy;   // the reader->framer slice of decoder d holds a beat

    logic [31:0]           dec_occ_q [N_DECODERS];
    logic [N_DECODERS-1:0] body_pop_q;   // a chunk's last beat left for decoder d, one cycle ago

    // The connection whose request text decoder d's streamer is sending (latched on the arm; the
    // streamer takes no second arm until the text is out, so it cannot change under a transfer).
    logic [CONN_BITS-1:0]  stream_conn_q [N_DECODERS];

    // head_is[d][c]: decoder d's reader is serving an entry of connection c right now. Everything a
    // decoder observes about a response -- framing errors, the watchdog, dirtiness -- belongs to
    // THIS connection, and nothing else.
    logic [N_CONNS-1:0]    head_is [N_DECODERS];
    always_comb begin
        for (int d = 0; d < N_DECODERS; d++)
            for (int c = 0; c < N_CONNS; c++)
                head_is[d][c] = rdr_head_valid[d] && (rdr_head_conn[d] == CONN_BITS'(c));
    end

    // What the readers need to know about every connection. `dead` is fatal: never comes back, so
    // its entries are dropped. `up` is a live session; a head entry on a connection that is neither
    // waits (bring-up / reconnect in progress).
    logic [N_CONNS-1:0] rdr_conn_up_w;
    assign rdr_conn_up_w = conn_up_q & ~conn_fatal_q;

    for (genvar d = 0; d < N_DECODERS; d++) begin : gen_dec

        // -- request text out ---------------------------------------------------------------------
        //
        // One streamer per DECODER. Its session is the one the arm named; the text of one arm is
        // sent to completion before the next arm for this decoder is admitted (stream_busy), so
        // the latched connection is stable for the whole transfer.
        logic [CONN_BITS-1:0] sc;
        assign sc = stream_conn_q[d];

        http_req_stream #(.CHUNK_BYTES(TX_CHUNK_BYTES)) inst_req_stream (
            .clk(ap_clk), .rst_n(ap_rst_n),
            .conn_up   (conn_up_q[sc] && !conn_fatal_q[sc]),
            .session_id(conn_sid_q[sc]),
            .req_total_bytes(req_data.req_total_bytes),
            .req_start      (arm_fire_w && (cfg_dec == DEC_BITS'(d))),

            .s_axis_req_TVALID(s_axis_req_TVALID[d]),
            .s_axis_req_TREADY(s_axis_req_TREADY[d]),
            .s_axis_req_TDATA (s_axis_req_TDATA[d]),
            .s_axis_req_TKEEP (s_axis_req_TKEEP[d]),
            .s_axis_req_TLAST (s_axis_req_TLAST[d]),

            .m_axis_tx_meta_TVALID(dec_meta_valid[d]),
            .m_axis_tx_meta_TREADY(m_axis_tx_meta_TREADY && tx_busy && (tx_sel == DEC_BITS'(d))),
            .m_axis_tx_meta_TDATA (dec_meta_data[d]),
            .m_axis_tx_data_TVALID(dec_data_valid[d]),
            .m_axis_tx_data_TREADY(m_axis_tx_data_TREADY && tx_busy && (tx_sel == DEC_BITS'(d))),
            .m_axis_tx_data_TDATA (dec_data_data[d]),
            .m_axis_tx_data_TKEEP (dec_data_keep[d]),
            .m_axis_tx_data_TLAST (dec_data_last[d]),
            .s_axis_tx_status_TVALID(s_axis_tx_status_TVALID && tx_busy && (tx_sel == DEC_BITS'(d))),
            .s_axis_tx_status_TREADY(dec_stat_ready[d]),
            .s_axis_tx_status_TDATA (s_axis_tx_status_TDATA),

            .bus_req(stream_bus_req[d]), .bus_grant(stream_bus_grant[d]),
            .busy(stream_busy[d]), .refused_sticky(stream_refused[d]),
            .tx_space(), .state_debug(dec_tx_state[d])
        );

        // -- read this decoder's responses back out of the slots ------------------------------------
        logic                       rdr_m_tvalid, rdr_m_tready;
        logic [AXI_DATA_BITS-1:0]   rdr_m_tdata;
        logic [AXI_DATA_BITS/8-1:0] rdr_m_tkeep;
        logic                       rdr_m_tlast;
        logic                       rdr_resp_ack, rdr_body_last;

        slot_reader #(
            .N_CONNS    (N_CONNS),
            .SLOT_LOG2  (SLOT_LOG2),
            .RD_MAX     (RD_MAX),
            .ENTRY_DEPTH(ENTRY_DEPTH)
        ) inst_slot_reader (
            .clk(ap_clk), .rst_n(ap_rst_n),
            // One entry per ARM. The arm is the host saying "a GET is on its way out for this
            // decoder": exactly one response, in the slot named here, behind any still queued.
            .entry_valid      (arm_fire_w && (cfg_dec == DEC_BITS'(d))),
            .entry_ready      (rdr_entry_ready[d]),
            .entry_conn       (cfg_conn),
            .entry_chunk_bytes(req_data.req_chunk_bytes),
            .entry_body_last  (req_data.req_flags[0]),

            .conn_up    (rdr_conn_up_w),
            .conn_dead  (conn_fatal_q),
            .flush_busy (rdr_flush_busy[d]),
            .framer_idle(sh_fs_idle[d]),   // the framer and the slice in front of it
            .framer_clear(rdr_fr_clear[d]),

            .landed   (landed),
            .slot_base(slot_base),

            .rd_req_valid(rd_req_valid[d]), .rd_req_ready(rd_req_ready[d]),
            .rd_req_vaddr(rd_req_vaddr[d]), .rd_req_len(rd_req_len[d]),
            .rd_req_last (rd_req_last[d]),

            .s_axis_tvalid(s_axis_card_tvalid[d]), .s_axis_tready(s_axis_card_tready[d]),
            .s_axis_tdata (s_axis_card_tdata[d]),  .s_axis_tkeep (s_axis_card_tkeep[d]),
            .s_axis_tlast (s_axis_card_tlast[d]),

            .m_axis_tvalid(rdr_m_tvalid), .m_axis_tready(rdr_m_tready),
            .m_axis_tdata (rdr_m_tdata),  .m_axis_tkeep (rdr_m_tkeep),
            .m_axis_tlast (rdr_m_tlast),

            .resp_done(sh_resp_done[d]), .resp_ack(rdr_resp_ack), .body_last(rdr_body_last),

            .conn_release(rdr_release[d]),
            .entry_done  (rdr_entry_done[d]),
            .residue_err (rdr_residue_err[d]),
            .residue_ev  (rdr_residue_ev[d]),
            .done_conn   (rdr_done_conn[d]),
            .pop         (rdr_pop[d]),
            .head_valid  (rdr_head_valid[d]),
            .head_conn   (rdr_head_conn[d]),
            .rd_pending  (rdr_rd_pending[d]),
            .head_chunk_bytes(),
            .busy       (rdr_busy[d]),
            .entry_occ  (rdr_entry_occ[d]),
            .state_debug(rdr_state[d])
        );

        // Anything moving on this decoder's read path counts as progress for the watchdog. A
        // decoder throttled to one beat every sixteen cycles is SLOW, not dead, and must never be
        // declared failed -- which is the whole claim the `thr` scenario measures.
        //
        // REGISTERED (2026-09-24, build-127 timing): the two MOVEMENT terms are the handshakes of
        // two other modules -- the beat into the framer (on build-127 strip_http's slave ready, a
        // byte-cursor subtract, a 32-bit compare and a consumed==avail compare deep; now the slice
        // below) and slot_rd_share's arbiter grant -- and they went on through all 32 connections'
        // close-drain counters and this decoder's 29-bit watchdog (-3.4 ns on build-127). They are
        // taken one cycle late; resp_done is a flop and stays exact. Both consumers are quiet TIMERS -- 1024 cycles
        // (CLOSE_SETTLE) and 2^READ_WDOG_BITS cycles -- and the late terms cannot change a verdict:
        // the close drain also requires !rdr_rd_pending, which is the reader's registered "no read
        // outstanding and nothing landed unread" of the cycle before, and with that true neither a
        // beat into the framer (it belongs to an outstanding read) nor a read request (it needs
        // landed bytes not yet asked for) can happen in the next cycle either -- so a movement the
        // late copy has not reported yet was already stopping the count through rd_pending. The
        // watchdog is 2^29 cycles long.
        logic rdr_move_q;
        always_ff @(posedge ap_clk) begin
            if (!ap_rst_n) rdr_move_q <= 1'b0;
            else           rdr_move_q <= (rdr_m_tvalid && rdr_m_tready) ||
                                         (rd_req_valid[d] && rd_req_ready[d]);
        end
        assign rdr_progress_w[d] = rdr_move_q || sh_resp_done[d];

        // -- register slice between the reader and the framer ---------------------------------------
        //
        // (2026-09-24, build-127 timing.) strip_http's slave ready is a deep function of its byte
        // cursor, and without this slice it ran on through the reader into slot_rd_share's receive
        // fifo (its BRAM read, level and credit) and the reader's byte accounting -- on build-127
        // across an SLR boundary for decoders 0 and 2, whose framers sat in SLR2 with the readers in
        // SLR1 (-2.7 ns into the fifo, -2.0 ns into rem0_q). The same two-deep skid as the body
        // output below: its tready is a function of its own two valid flops, so both ends of that
        // cone now stop at a register. It costs one cycle of latency on the card-read data and
        // changes nothing else:
        //   * it is part of the FRAMER as far as the reader is concerned: `framer_idle` is the
        //     framer's idle AND this slice empty, so a byte waiting here at a release is a residue
        //     exactly as a byte in the framer's residue register is;
        //   * `framer_clear` empties it together with the framer.
        logic                       fs_tmp_v_q,  fs_ovr_v_q;
        logic [AXI_DATA_BITS-1:0]   fs_tmp_d_q,  fs_ovr_d_q;
        logic [AXI_DATA_BITS/8-1:0] fs_tmp_k_q,  fs_ovr_k_q;
        logic                       fs_m_tvalid, fs_m_tready;
        logic [AXI_DATA_BITS-1:0]   fs_m_tdata;
        logic [AXI_DATA_BITS/8-1:0] fs_m_tkeep;

        assign rdr_m_tready = !fs_tmp_v_q || !fs_ovr_v_q;

        always_ff @(posedge ap_clk) begin
            if (!ap_rst_n || rdr_fr_clear[d]) begin
                fs_tmp_v_q <= 1'b0;
                fs_ovr_v_q <= 1'b0;
            end else begin
                if (rdr_m_tready) fs_tmp_v_q <= rdr_m_tvalid;
                if (!fs_ovr_v_q && !fs_m_tready) fs_ovr_v_q <= fs_tmp_v_q;
                if (fs_m_tready)                 fs_ovr_v_q <= 1'b0;
            end
        end

        // Data registers carry no reset and no clear: they are only ever read under their valid.
        always_ff @(posedge ap_clk) begin
            if (rdr_m_tready) begin
                fs_tmp_d_q <= rdr_m_tdata;
                fs_tmp_k_q <= rdr_m_tkeep;
            end
            if (!fs_ovr_v_q) begin
                fs_ovr_d_q <= fs_tmp_d_q;
                fs_ovr_k_q <= fs_tmp_k_q;
            end
        end

        assign fs_m_tvalid = fs_tmp_v_q || fs_ovr_v_q;
        assign fs_m_tdata  = fs_ovr_v_q ? fs_ovr_d_q : fs_tmp_d_q;
        assign fs_m_tkeep  = fs_ovr_v_q ? fs_ovr_k_q : fs_tmp_k_q;
        assign fs_busy[d]    = fs_tmp_v_q || fs_ovr_v_q;
        assign sh_fs_idle[d] = sh_idle[d] && !fs_busy[d];

        // -- framing --------------------------------------------------------------------------------
        logic                       raw_tvalid, raw_tready;
        logic [AXI_DATA_BITS-1:0]   raw_tdata;
        logic [AXI_DATA_BITS/8-1:0] raw_tkeep;

        strip_http inst_strip_http (
            .clk(ap_clk), .rst_n(ap_rst_n),
            // While the reader flushes a head whose connection went away, and for one cycle after
            // every slot release, so no byte of one connection can survive in the framer into the
            // next connection's response. Between the responses of ONE connection it is NOT
            // cleared: there the residue holds the next header (pipelined GETs).
            .clear (rdr_fr_clear[d]),
            .enable(1'b1),
            .body_last(rdr_body_last),
            .resp_ack (rdr_resp_ack),

            .s_axis_tvalid(fs_m_tvalid), .s_axis_tready(fs_m_tready),
            .s_axis_tdata (fs_m_tdata),  .s_axis_tkeep (fs_m_tkeep),
            .s_axis_tlast (1'b0),        // the reader never sets one; framing is by length

            .m_axis_tvalid(raw_tvalid), .m_axis_tready(raw_tready),
            .m_axis_tdata (raw_tdata),  .m_axis_tkeep (raw_tkeep),
            .m_axis_tlast (),

            .out_w0(), .out_w1(), .out_w0_valid(), .out_w1_valid(),
            .resp_done (sh_resp_done[d]),
            .resp_dirty(sh_resp_dirty[d]),
            .resp_error(sh_resp_error[d]),
            .status_ascii (sh_status_ascii[d]),
            .status_ok    (sh_status_ok[d]),
            .content_length(sh_content_len[d]),
            .body_remaining(sh_body_remain[d]),
            .out_payload_idx(),
            .idle(sh_idle[d])
        );

        // -- register slice between the framer and the chunk counter ------------------------------
        //
        // (2026-09-26, build-133 timing.) strip_http's output skid went straight into
        // axis_rewrite_last's popcount of tkeep, its 32-bit `remaining <= beat_bytes` compare and
        // the remaining counter's clear, and the counter's ready went straight back into the
        // skid's ~1150 clock enables. On build-133 the framers of decoders 1 and 3 were placed in
        // SLR2 with their chunk counters in SLR1, and that cone was -2.02 ns (strip_http[1]
        // skid_keep_q -> rewrite_last remaining_q; -1.89 ns on to the body slice's tlast). The same
        // two-deep skid as the other slices here: both of its ends are flops, so an SLR cut on
        // either side of it lands on a register-to-register path. One cycle of body latency;
        // order and throughput are unchanged. It is DOWNSTREAM of the framer: strip_http's
        // resp_done says a response's last beat has left the framer, which it has once it is in
        // here, and `framer_clear` does not empty it -- a beat in here belongs to a response that
        // is already complete in the framer (exactly as a beat in the body slice below does), and
        // clearing it at the release after that response would drop body bytes.
        logic                       rl_tmp_v_q,  rl_ovr_v_q;
        logic [AXI_DATA_BITS-1:0]   rl_tmp_d_q,  rl_ovr_d_q;
        logic [AXI_DATA_BITS/8-1:0] rl_tmp_k_q,  rl_ovr_k_q;
        logic                       rl_m_tvalid, rl_m_tready;
        logic [AXI_DATA_BITS-1:0]   rl_m_tdata;
        logic [AXI_DATA_BITS/8-1:0] rl_m_tkeep;

        assign raw_tready = !rl_tmp_v_q || !rl_ovr_v_q;

        always_ff @(posedge ap_clk) begin
            if (!ap_rst_n) begin
                rl_tmp_v_q <= 1'b0;
                rl_ovr_v_q <= 1'b0;
            end else begin
                if (raw_tready) rl_tmp_v_q <= raw_tvalid;
                if (!rl_ovr_v_q && !rl_m_tready) rl_ovr_v_q <= rl_tmp_v_q;
                if (rl_m_tready)                 rl_ovr_v_q <= 1'b0;
            end
        end

        always_ff @(posedge ap_clk) begin
            if (raw_tready) begin
                rl_tmp_d_q <= raw_tdata;
                rl_tmp_k_q <= raw_tkeep;
            end
            if (!rl_ovr_v_q) begin
                rl_ovr_d_q <= rl_tmp_d_q;
                rl_ovr_k_q <= rl_tmp_k_q;
            end
        end

        assign rl_m_tvalid = rl_tmp_v_q || rl_ovr_v_q;
        assign rl_m_tdata  = rl_ovr_v_q ? rl_ovr_d_q : rl_tmp_d_q;
        assign rl_m_tkeep  = rl_ovr_v_q ? rl_ovr_k_q : rl_tmp_k_q;

        // -- a TAINTED decoder's output is cut here -------------------------------------------------
        //
        // Its byte stream lost a response (see "STAGE 2" in the header), so nothing more of it may
        // reach the decoder: the framer keeps running -- responses of healthy connections queued on
        // this decoder must still be framed and retired so those connections drain -- and its body
        // beats are dropped. The flop keeps the new term out of the slice's ready path. The cut is
        // AFTER the slice above, so beats waiting in it when the cut rises are dropped too, as
        // beats waiting in the framer's skid were before the slice existed.
        logic taint_cut_q;
        always_ff @(posedge ap_clk) begin
            if (!ap_rst_n) taint_cut_q <= 1'b0;
            else           taint_cut_q <= dec_tainted_q[d];
        end

        logic rwl_s_tvalid, rwl_s_tready;
        assign rwl_s_tvalid = rl_m_tvalid && !taint_cut_q;
        assign rl_m_tready  = taint_cut_q ? 1'b1 : rwl_s_tready;

        // -- chunk boundaries by byte count ---------------------------------------------------------
        //
        // CFG_REG (2026-09-26, build-128/133 timing): the entry admission (entry_fire_w: the host's
        // config beat, dec_occ_q's compare and this queue's own cfg_ready) reaches the length
        // queue through a register instead of straight into its write enable, and cfg_ready
        // counts the length still in that register (see axis_rewrite_last). A chunk length enters
        // the queue one cycle later; the admission itself is unchanged. The body data reaches it a
        // cycle later too (the slice above), so the two keep their relative timing.
        logic                       rwl_tvalid, rwl_tready, rwl_tlast;
        logic [AXI_DATA_BITS-1:0]   rwl_tdata;
        logic [AXI_DATA_BITS/8-1:0] rwl_tkeep;

        axis_rewrite_last #(
            .CFG_DEPTH(QUEUE_DEPTH), .NUM_DEST(1), .DEST_BITS(1), .CFG_REG(1'b1)
        ) inst_rewrite_last (
            .clk(ap_clk), .rst_n(ap_rst_n),
            .cfg_valid(entry_fire_w[d]),
            .cfg_ready(rwl_cfg_ready[d]),
            .cfg_len  (req_data.req_chunk_bytes),
            .cfg_dest (1'b0),
            .s_tvalid(rwl_s_tvalid), .s_tready(rwl_s_tready),
            .s_tdata (rl_m_tdata), .s_tkeep (rl_m_tkeep),
            .m_tvalid(rwl_tvalid), .m_tready(rwl_tready),
            .m_tdata (rwl_tdata),  .m_tkeep (rwl_tkeep),
            .m_tlast (rwl_tlast),
            .m_tdest (),
            .busy(rwl_busy[d]), .starved(rwl_starved[d]), .remaining_dbg()
        );

        // -- register slice on the body output -------------------------------------------------------
        //
        // build-119 puts a full two-deep skid here and the timing report says why: strip_http's
        // skid_keep_q -> axis_rewrite_last's popcount+compare -> tlast was one combinational cone
        // ending in 45 paths into the occupancy counter's clock enable and 24 out through the
        // DataNormalizer's offset register, at -0.77 ns on build-117. The slice ends that cone at a
        // register and ends the decoder's tready chain at one flop.
        //
        // It is written out here rather than instantiated from axis_skid.sv because that file is
        // UNTRACKED (see the note in the report): a new module must elaborate from a clean checkout
        // of the repository, and twenty lines are cheaper than a dependency that is not there.
        // Behaviour is identical -- same two registers, same update rules.
        logic                       sk_tmp_v_q,  sk_ovr_v_q;
        logic [AXI_DATA_BITS-1:0]   sk_tmp_d_q,  sk_ovr_d_q;
        logic [AXI_DATA_BITS/8-1:0] sk_tmp_k_q,  sk_ovr_k_q;
        logic                       sk_tmp_l_q,  sk_ovr_l_q;

        assign rwl_tready = !sk_tmp_v_q || !sk_ovr_v_q;

        always_ff @(posedge ap_clk) begin
            if (!ap_rst_n) begin
                sk_tmp_v_q <= 1'b0;
                sk_ovr_v_q <= 1'b0;
            end else begin
                if (rwl_tready) sk_tmp_v_q <= rwl_tvalid;
                if (!sk_ovr_v_q && !m_axis_body_tready[d]) sk_ovr_v_q <= sk_tmp_v_q;
                if (m_axis_body_tready[d])                 sk_ovr_v_q <= 1'b0;
            end
        end

        always_ff @(posedge ap_clk) begin
            if (rwl_tready) begin
                sk_tmp_d_q <= rwl_tdata;
                sk_tmp_k_q <= rwl_tkeep;
                sk_tmp_l_q <= rwl_tlast;
            end
            if (!sk_ovr_v_q) begin
                sk_ovr_d_q <= sk_tmp_d_q;
                sk_ovr_k_q <= sk_tmp_k_q;
                sk_ovr_l_q <= sk_tmp_l_q;
            end
        end

        assign m_axis_body_tvalid[d] = sk_tmp_v_q || sk_ovr_v_q;
        assign m_axis_body_tdata[d]  = sk_ovr_v_q ? sk_ovr_d_q : sk_tmp_d_q;
        assign m_axis_body_tkeep[d]  = sk_ovr_v_q ? sk_ovr_k_q : sk_tmp_k_q;
        assign m_axis_body_tlast[d]  = sk_ovr_v_q ? sk_ovr_l_q : sk_tmp_l_q;

        // A chunk's last beat leaving for the decoder retires one entry of dec_occ_q. REGISTERED
        // (2026-09-24, build-127 timing): m_axis_body_tready is the decoder's own input ready, a
        // long cone inside parcore, and it went on into dec_occ_q's 32-bit up/down counter
        // (-2.6 ns). Counting the pop one cycle late means the occupancy reads one entry HIGH for
        // one cycle, i.e. an ENTRY beat for a full queue is admitted one cycle later than before;
        // nothing is ever admitted that was not admitted before. (CONN_OCC reads it back through a
        // register anyway.)
        logic pop_q;
        always_ff @(posedge ap_clk) begin
            if (!ap_rst_n) pop_q <= 1'b0;
            else           pop_q <= m_axis_body_tvalid[d] && m_axis_body_tready[d] &&
                                    m_axis_body_tlast[d];
        end
        assign body_pop_q[d] = pop_q;

        assign dec_occ_ok[d] = (dec_occ_q[d] < 32'(QUEUE_DEPTH));

        assign dec_entry_ready_w[d] = rwl_cfg_ready[d] && dec_occ_ok[d];
        // The DECODER half of an arm's admission; the connection half is conn_arm_ok().
        assign dec_arm_ready_w[d]   = !stream_busy[d] && rdr_entry_ready[d] && !dec_tainted_q[d];
    end

    // Every reader's release, folded per connection. A connection's entries live in one decoder's
    // queue at a time, so at most one reader drives a given bit; the OR is a wire per bit.
    logic [N_CONNS-1:0] rdr_release_any_w, rdr_residue_conn_w, rdr_pop_conn_w;
    always_comb begin
        rdr_release_any_w  = '0;
        rdr_residue_conn_w = '0;
        rdr_pop_conn_w     = '0;
        for (int d = 0; d < N_DECODERS; d++) begin
            rdr_release_any_w = rdr_release_any_w | rdr_release[d];
            if (rdr_residue_ev[d]) rdr_residue_conn_w = rdr_residue_conn_w | rdr_release[d];
            if (rdr_pop[d]) rdr_pop_conn_w[rdr_head_conn[d]] = 1'b1;
        end
    end

    always_comb begin
        conn_release_w = rdr_release_any_w;
        if (slot_rel_en_w) conn_release_w[slot_rel_conn_w] = 1'b1;
    end

    // =============================================================================================
    // Per-connection failure state
    //
    // build-119's shape: an abort that is CLEAN and leaves nothing outstanding is a reconnect; an
    // abort that is dirty, or one with work the hardware cannot replay, is fatal and the host
    // reissues. What a decoder observes is attributed to the connection at its reader's head.
    // =============================================================================================
    logic [N_CONNS-1:0] conn_abort_q, conn_abort_dirty_q;
    logic [N_CONNS-1:0] conn_err_now_w, conn_err_dirty_now_w;
    logic [N_DECODERS-1:0] rd_timeout_q;

    // THE PEER FINed WITH A RESPONSE STILL OWED.
    //
    // build-119 got this from tcp_read: rx_closed took it to ST_DRAIN, which waited for the parser
    // to go quiet and then aborted, and the handler turned the abort into a reconnect or a fatal
    // lane. There is no tcp_read here, so the same judgement is made directly, and for the same
    // reason it was a DRAIN there rather than an immediate abort: one notification can carry both
    // the last segment of a response and the FIN, so declaring failure the moment `closed` is seen
    // would abort responses that are about to complete out of bytes already in the slot.
    //
    // So it counts only while EVERYTHING is quiet -- no announcement queued for this connection, no
    // segment of it in the writer, its decoder's reader AT this connection with no movement, and no
    // response waiting to retire -- and any of those restarts it. A connection whose entries are
    // still queued behind another connection's on its decoder does not count at all yet: its bytes
    // are in the slot, unread, and the judgement waits until the reader gets there.
    localparam int CLOSE_SETTLE = 1024;
    localparam int CDRAIN_BITS  = $clog2(CLOSE_SETTLE + 1);
    logic [CDRAIN_BITS-1:0] close_drain_q [N_CONNS];
    logic [N_CONNS-1:0]     close_abort_q;
    logic [N_CONNS-1:0]     close_quiet_w;

    always_comb begin
        for (int c = 0; c < N_CONNS; c++) begin
            automatic logic [DEC_BITS-1:0] d = cur_dec_q[c];
            close_quiet_w[c] = conn_up_q[c] && conn_closed[c] && (pend_q[c] != '0) &&
                               head_is[d][c] &&
                               !rxd_has_pending[c] && conn_quiet_w[c] &&
                               !rdr_progress_w[d] && !sh_resp_done[d] &&
                               // ...and nothing left in the slot to read and no read in flight.
                               //
                               // This is tcp_read's `parser_quiet_w` and it is deliberately the
                               // SAME question: "is there anything left between the source of the
                               // bytes and the parser", not "is the parser finished". Asking the
                               // stronger question (body_remaining == 0) means a peer that FINs
                               // mid-body never settles at all and the connection hangs for ever
                               // (lane_drain `refatal`); asking the weaker one (dropping this term)
                               // aborts a response that was about to complete out of bytes already
                               // in the slot (lane_drain `c`). Both failures were measured.
                               !rdr_rd_pending[d] &&
                               // ...and nothing waiting in the register slice in front of the
                               // framer (9811956): those beats used to wait in slot_rd_share's
                               // receive fifo, where rd_pending counted them. Without this term a
                               // stalled decoder lets the slice take a response's last beats, the
                               // drain expires and a response that is complete in the handler is
                               // aborted (lane_drain `fsfin`). fs_busy is two flops, so the slice
                               // keeps its point: no framer ready reaches close_drain_q.
                               !fs_busy[d];
        end
    end

    always_comb begin
        conn_err_now_w       = '0;
        conn_err_dirty_now_w = '0;
        for (int c = 0; c < N_CONNS; c++) begin
            automatic logic [DEC_BITS-1:0] d = cur_dec_q[c];
            automatic logic at_head = head_is[d][c];
            // Five ways a response on this connection cannot be completed. The decoder-side ones
            // count only while this connection is at its reader's head. All of them hold until the
            // connection is torn down (or, for the residue, are latched by conn_abort_q), which is
            // what makes latching them into conn_abort_q below idempotent.
            conn_err_now_w[c] = (at_head && sh_resp_error[d])   // no Content-Length: unframeable
                              | rdr_residue_conn_w[c]           // bytes in the slot belonging to no response
                              | (at_head && rd_timeout_q[d])    // nothing arrived for READ_WDOG_BITS cycles
                              | close_abort_q[c]                // the peer FINed with a response still owed
                              | slot_poison_w[c];               // a segment ran past the end of the slot
            // Dirty means body bytes of THIS response already reached the decoder, so a replay
            // would duplicate them. A slot overflow needs no help from this bit to be fatal: the
            // entry is still outstanding, so conn_idle_w is low and conn_must_die_w fires anyway.
            conn_err_dirty_now_w[c] = conn_err_now_w[c] && at_head && sh_resp_dirty[d];
        end
    end

    // Whether any decoder's streamer is sending (or about to send) this connection's request text.
    logic [N_CONNS-1:0] conn_tx_busy_w;
    always_comb begin
        conn_tx_busy_w = '0;
        for (int d = 0; d < N_DECODERS; d++)
            if (stream_busy[d]) conn_tx_busy_w[stream_conn_q[d]] = 1'b1;
    end

    for (genvar c = 0; c < N_CONNS; c++) begin : gen_reconn_want
        // Nothing to replay: no GET of this connection armed and unretired, none of its request text
        // in flight, and the slot credit back. (build-119 asked the lane's chunk queue as well;
        // chunk entries belong to a DECODER now and say nothing about one connection.)
        assign conn_idle_w[c] = (pend_q[c] == '0) && !conn_tx_busy_w[c] && conn_drained_q[c];

        assign conn_want_reconn_w[c] = conn_up_q[c] && !conn_fatal_q[c] && conn_idle_w[c] &&
                                       ((conn_abort_q[c] && !conn_abort_dirty_q[c]) || conn_closed[c]);

        assign conn_must_die_w[c] = conn_abort_q[c] && (conn_abort_dirty_q[c] || !conn_idle_w[c]);

        assign conn_want_close_w[c] = conn_up_q[c] && conn_fatal_q[c];
    end

    always_comb begin
        reconn_pending_w = 1'b0;
        reconn_conn_w    = '0;
        close_pending_w  = 1'b0;
        close_conn_w     = '0;
        for (int i = N_CONNS - 1; i >= 0; i--) begin
            if (conn_want_reconn_w[i]) begin
                reconn_pending_w = 1'b1;
                reconn_conn_w    = CONN_BITS'(i);
            end
            if (conn_want_close_w[i]) begin
                close_pending_w = 1'b1;
                close_conn_w    = CONN_BITS'(i);
            end
        end
    end

    // THE PICK IS REGISTERED, AND RE-CHECKED WHERE IT IS ACTED ON (2026-09-24, build-127 timing).
    // The two 32-way priority encoders above sat between the request streamers' `busy` (a 32-bit
    // OR in http_req_stream, through conn_tx_busy_w and conn_idle_w) and bring_conn_q (-2.3 ns on
    // build-127). BR_DONE now acts on LAST cycle's pick, and only if that connection still wants
    // it by this cycle's registers:
    //   * close: conn_want_close_w itself (conn_up_q && conn_fatal_q, two flops);
    //   * reconnect: the same condition as conn_want_reconn_w with the streamer term left out. That
    //     is exact: the pick says the full condition held last cycle, i.e. no streamer was busy
    //     with this connection then, and a streamer can only BECOME busy with it through an arm,
    //     which has raised pend_q -- a register checked here -- by this cycle.
    // So BR_DONE never acts on a stale choice; it acts one cycle later than before, and when
    // several connections want a teardown in the same cycle they are served in last cycle's order.
    // Fatal teardowns still go first: a reconnect is only taken while no close is pending at all.
    logic                 close_pick_v_q, reconn_pick_v_q;
    logic [CONN_BITS-1:0] close_pick_q,   reconn_pick_q;
    always_ff @(posedge ap_clk) begin
        if (!ap_rst_n) begin
            close_pick_v_q  <= 1'b0;
            reconn_pick_v_q <= 1'b0;
            close_pick_q    <= '0;
            reconn_pick_q   <= '0;
        end else begin
            close_pick_v_q  <= close_pending_w;
            reconn_pick_v_q <= reconn_pending_w;
            close_pick_q    <= close_conn_w;
            reconn_pick_q   <= reconn_conn_w;
        end
    end

    logic close_go_w, reconn_go_w;
    always_comb begin
        automatic logic [CONN_BITS-1:0] r = reconn_pick_q;
        close_go_w  = close_pick_v_q && conn_want_close_w[close_pick_q];
        reconn_go_w = reconn_pick_v_q && !close_pending_w &&
                      conn_up_q[r] && !conn_fatal_q[r] && (pend_q[r] == '0) && conn_drained_q[r] &&
                      ((conn_abort_q[r] && !conn_abort_dirty_q[r]) || conn_closed[r]);
    end

    // =============================================================================================
    // The bring-up FSM
    // =============================================================================================
    localparam int SETTLE_BITS = $clog2(RELEASE_SETTLE + 1);
    logic [SETTLE_BITS-1:0] settle_q;
    logic                   drain_quiet_w;

    // Both sides of the connection being torn down have stopped moving bytes. conn_quiet is
    // slot_writer's (nothing of c between rx_dispatch and the ack); on the read side no reader may
    // still hold an entry of c at its head -- a head of a down or dead connection is being flushed,
    // and it is let go only once the last beat of its outstanding reads has been swallowed.
    // (Entries of a dead connection further back in a queue are dropped without a read, so they
    // do not have to be waited for.)
    logic rdr_holds_bring_w;
    always_comb begin
        rdr_holds_bring_w = 1'b0;
        for (int d = 0; d < N_DECODERS; d++)
            if (head_is[d][bring_conn_q]) rdr_holds_bring_w = 1'b1;
    end
    assign drain_quiet_w = conn_quiet_w[bring_conn_q] && !rdr_holds_bring_w;

    always_comb begin
        br_d          = br_q;
        bring_conn_d  = bring_conn_q;
        close_only_d  = close_only_q;
        bind_en_w     = 1'b0;
        bind_conn_w   = bring_conn_q;
        bind_sid_w    = init_session_id;
        release_en_w  = 1'b0;
        release_conn_w = bring_conn_q;
        slot_rel_en_w  = 1'b0;
        slot_rel_conn_w = bring_conn_q;

        m_axis_close_connection_TVALID = 1'b0;
        m_axis_close_connection_TDATA  = conn_sid_q[bring_conn_q][TCP_CLOSE_CONN_REQ_BITS-1:0];

        case (br_q)
            // The first arm starts the bring-up at connection 0. An open that FAILS during the
            // bring-up comes back here and, after the backoff, retries THE SAME connection:
            // bring_conn_q is left where it is. (It used to restart at 0, which re-opened every
            // connection already bound -- a second session for the same conn, the first one leaked
            // in the TOE; with 32 opens in a row a failure somewhere is no longer unlikely.)
            BR_IDLE: begin
                if (any_armed_q && (retry_wait_q == '0)) begin
                    br_d = BR_OPEN;
                end
            end
            BR_OPEN: begin
                if (init_done) begin
                    if (init_error) br_d = bringing_up_q ? BR_IDLE : BR_DONE;
                    else begin
                        bind_en_w = 1'b1;
                        br_d      = bringing_up_q ? BR_NEXT : BR_DONE;
                    end
                end
            end
            BR_NEXT: begin
                if (int'(bring_conn_q) == N_CONNS - 1) br_d = BR_DONE;
                else begin
                    bring_conn_d = bring_conn_q + 1'b1;
                    br_d         = BR_OPEN;
                end
            end

            // A fatal connection's teardown goes FIRST: it needs no tcp_init, and making it wait
            // behind a reconnect that retry_wait_q can hold off for 65535 cycles would leave a dead
            // slot occupied for the whole backoff.
            BR_DONE: begin
                if (close_go_w) begin
                    bring_conn_d = close_pick_q;
                    close_only_d = 1'b1;
                    br_d         = BR_CLOSE;
                end else if (reconn_go_w && (retry_wait_q == '0)) begin
                    bring_conn_d = reconn_pick_q;
                    close_only_d = 1'b0;
                    br_d         = BR_CLOSE;
                end
            end

            // Drop the session. The release must reach rx_dispatch in the same breath: an unbound
            // session id stops matching, so a late notification for the dead connection is dropped
            // instead of becoming a readPkg for a session the TOE has forgotten.
            BR_CLOSE: begin
                m_axis_close_connection_TVALID = 1'b1;
                if (m_axis_close_connection_TREADY) begin
                    release_en_w   = 1'b1;
                    release_conn_w = bring_conn_q;
                    br_d           = BR_DRAIN;
                end
            end

            // Wait for both halves of the datapath to let go of this connection, THEN release its
            // slot. See the header: releasing early puts the next response at the wrong offset.
            BR_DRAIN: begin
                if (drain_quiet_w && (settle_q == '0)) begin
                    slot_rel_en_w   = 1'b1;
                    slot_rel_conn_w = bring_conn_q;
                    br_d            = close_only_q ? BR_DONE : BR_OPEN;
                end
            end

            default: br_d = BR_IDLE;
        endcase
    end

    // =============================================================================================
    // State
    // =============================================================================================
    logic [N_CONNS-1:0]    conn_init_err_q, conn_resp_err_q, conn_status_bad_q;
    logic [N_CONNS-1:0]    conn_dead_q, conn_dirty_q, conn_ovf_q;
    logic [N_DECODERS-1:0] residue_seen_q;
    logic [N_CONNS-1:0]    conn_rd_timeout_q, conn_tx_refused_q, conn_residue_q, conn_taint_q;
    logic [N_DECODERS-1:0] stream_refused_prev_q;
    logic                  conn_stall_q;
    localparam int STALL_BITS = $clog2(STALL_CYCLES) + 1;
    logic [STALL_BITS-1:0] conn_cnt_q;

    logic [READ_WDOG_BITS-1:0] rd_wdog_q [N_DECODERS];

    always_ff @(posedge ap_clk) begin
        if (!ap_rst_n) begin
            br_q          <= BR_IDLE;
            bring_conn_q  <= '0;
            close_only_q  <= 1'b0;
            bringing_up_q <= 1'b1;
            conn_up_q     <= '0;
            reconn_cnt_q  <= '0;
            any_armed_q   <= 1'b0;
            server_ip_q   <= '0;
            server_port_q <= '0;
            retry_wait_q  <= '0;
            settle_q      <= SETTLE_BITS'(RELEASE_SETTLE);
            conn_fatal_q  <= '0;
            // Every slot starts empty and nothing is armed.
            conn_drained_q <= '1;
            conn_abort_q       <= '0;
            conn_abort_dirty_q <= '0;
            conn_init_err_q    <= '0;
            conn_resp_err_q    <= '0;
            conn_status_bad_q  <= '0;
            conn_dead_q        <= '0;
            conn_dirty_q       <= '0;
            conn_ovf_q         <= '0;
            residue_seen_q     <= '0;
            rd_timeout_q       <= '0;
            close_abort_q      <= '0;
            for (int c = 0; c < N_CONNS; c++) close_drain_q[c] <= CDRAIN_BITS'(CLOSE_SETTLE);
            conn_stall_q  <= 1'b0;
            conn_cnt_q    <= '0;
            for (int c = 0; c < N_CONNS; c++) begin
                conn_sid_q[c] <= 16'd0;
                pend_q[c]     <= '0;
                // A connection's "home" decoder until its first arm: c mod N_DECODERS, which is c
                // itself in stage 1. CONN_READY's arm/entry bits describe this decoder.
                cur_dec_q[c]  <= DEC_BITS'(c % N_DECODERS);
            end
            conn_rd_timeout_q     <= '0;
            conn_tx_refused_q     <= '0;
            conn_residue_q        <= '0;
            conn_taint_q          <= '0;
            dec_tainted_q         <= '0;
            stream_refused_prev_q <= '0;
            for (int d = 0; d < N_DECODERS; d++) begin
                dec_occ_q[d]     <= '0;
                rd_wdog_q[d]     <= '0;
                tail_conn_q[d]   <= '0;
                stream_conn_q[d] <= '0;
            end
        end else begin
            br_q         <= br_d;
            bring_conn_q <= bring_conn_d;
            close_only_q <= close_only_d;
            if (br_q == BR_NEXT && int'(bring_conn_q) == N_CONNS - 1) bringing_up_q <= 1'b0;

            // The settle counter. Reloaded everywhere but BR_DRAIN, and reloaded inside it for as
            // long as either side is still moving, so only continuous quiet counts.
            if ((br_q == BR_DRAIN) && drain_quiet_w && (settle_q != '0)) settle_q <= settle_q - 1'b1;
            else if (br_q != BR_DRAIN || !drain_quiet_w) settle_q <= SETTLE_BITS'(RELEASE_SETTLE);

            if (arm_fire_w) begin
                server_ip_q   <= req_data.server_ip;
                server_port_q <= req_data.server_port;
                any_armed_q   <= 1'b1;
            end

            if (release_en_w) begin
                conn_up_q[release_conn_w] <= 1'b0;
                if (!close_only_q && (reconn_cnt_q != 8'hFF)) reconn_cnt_q <= reconn_cnt_q + 8'd1;
            end
            if (bind_en_w) begin
                conn_sid_q[bind_conn_w] <= bind_sid_w;
                conn_up_q[bind_conn_w]  <= 1'b1;
            end

            if (retry_wait_q != '0) retry_wait_q <= retry_wait_q - 1'b1;
            if ((br_q == BR_OPEN) && init_done && init_error) begin
                retry_wait_q                  <= '1;
                conn_init_err_q[bring_conn_q] <= 1'b1;
            end

            // -- the slot-drained bit, and the abort latch, per connection ----------------------
            for (int c = 0; c < N_CONNS; c++) begin
                // PLACEMENT. An arm charges its connection one pending entry and records which
                // decoder it is queued on; a reader retiring or dropping an entry of c returns one.
                automatic logic arm_c = arm_fire_w && (cfg_conn == CONN_BITS'(c));
                automatic logic pop_c = rdr_pop_conn_w[c];
                if (arm_c && !pop_c)      pend_q[c] <= pend_q[c] + 1'b1;
                else if (!arm_c && pop_c) pend_q[c] <= pend_q[c] - 1'b1;
                if (arm_c) cur_dec_q[c] <= cfg_dec;

                // A release -- the reader's when the connection ran dry, or the teardown's -- says
                // the slot is empty. An ARM on this connection says it is not, and WINS a tie: the
                // bit must never read "empty, nothing armed" while an arm is outstanding, because
                // that is when the host resets its byte budget for the slot. A reader's release
                // counts only when no entry of c is left (pend_q already reflects the pop that
                // came with the release, a cycle earlier): an arm that slipped in after the reader
                // decided to release is queued behind it and starts from the empty slot.
                if (arm_c)
                    conn_drained_q[c] <= 1'b0;
                else if ((rdr_release_any_w[c] && (pend_q[c] == '0)) ||
                         (slot_rel_en_w && (slot_rel_conn_w == CONN_BITS'(c))))
                    conn_drained_q[c] <= 1'b1;

                // A connection that goes fatal with entries still pending leaves a hole in the byte
                // stream of the decoder they are queued on: that decoder is TAINTED for good.
                if (conn_fatal_q[c] && (pend_q[c] != '0)) begin
                    dec_tainted_q[cur_dec_q[c]] <= 1'b1;
                    conn_taint_q[c]             <= 1'b1;
                end
                if (rdr_residue_conn_w[c]) conn_residue_q[c] <= 1'b1;

                // The abort latch is cleared by the SLOT release rather than by the session
                // release: slot_poison[c] lives until the slot goes, so clearing it at BR_CLOSE
                // would see the poison again on the very next cycle and make every torn-down
                // connection permanently fatal.
                // The FIN drain timer. Reloaded by any sign of life, and only a full CLOSE_SETTLE
                // cycles of complete quiet on a closed connection that still owes a response turns
                // into an abort.
                if (!close_quiet_w[c]) begin
                    close_drain_q[c] <= CDRAIN_BITS'(CLOSE_SETTLE);
                end else if (close_drain_q[c] != '0) begin
                    close_drain_q[c] <= close_drain_q[c] - 1'b1;
                end else begin
                    close_abort_q[c] <= 1'b1;
                end

                if (slot_rel_en_w && (slot_rel_conn_w == CONN_BITS'(c))) begin
                    conn_abort_q[c]       <= 1'b0;
                    conn_abort_dirty_q[c] <= 1'b0;
                    close_abort_q[c]      <= 1'b0;
                end else if (conn_err_now_w[c]) begin
                    conn_abort_q[c] <= 1'b1;
                    if (conn_err_dirty_now_w[c]) conn_abort_dirty_q[c] <= 1'b1;
                end

                // A connection that fails stops. It cannot recover on its own: streamed request
                // text is consumed as it is sent and the hardware cannot reproduce it, so
                // reconnecting would reopen a session with nothing to ask for. The host still holds
                // the text and reissues.
                //
                // The third way in is not a read failure at all: rx_dispatch declares a connection
                // dead once it has held the head of the announcement queue for LANE_STALL_CYCLES
                // while accepting nothing, and from then on reads its packets and throws them away.
                // Bytes have been lost out of the middle of a response by then.
                if (conn_must_die_w[c] || rxd_conn_dead[c]) conn_fatal_q[c] <= 1'b1;

                // Per-connection causes, latched where they are true.
                if (rxd_conn_dead[c])   conn_dead_q[c]  <= 1'b1;
                if (slot_overflow_w[c]) conn_ovf_q[c]   <= 1'b1;
                if (conn_err_dirty_now_w[c]) conn_dirty_q[c] <= 1'b1;
            end

            // -- per-decoder accounting ----------------------------------------------------------
            stream_refused_prev_q <= stream_refused;
            for (int d = 0; d < N_DECODERS; d++) begin
                automatic logic push = entry_fire_w[d];
                automatic logic pop  = body_pop_q[d];
                automatic logic [CONN_BITS-1:0] h = rdr_head_conn[d];
                case ({push, pop})
                    2'b10: dec_occ_q[d] <= dec_occ_q[d] + 1'b1;
                    2'b01: dec_occ_q[d] <= (dec_occ_q[d] == '0) ? '0 : dec_occ_q[d] - 1'b1;
                    default: ;
                endcase

                if (arm_fire_w && (cfg_dec == DEC_BITS'(d))) begin
                    tail_conn_q[d]   <= cfg_conn;
                    stream_conn_q[d] <= cfg_conn;
                end

                if (rdr_head_valid[d] && sh_resp_error[d]) conn_resp_err_q[h] <= 1'b1;
                if (rdr_residue_err[d])                    residue_seen_q[d]  <= 1'b1;
                if (stream_refused[d] && !stream_refused_prev_q[d])
                    conn_tx_refused_q[stream_conn_q[d]] <= 1'b1;

                // Status is only meaningful while the framer that produced it still exists, and it
                // is sampled on the RETIREMENT of a response (entry_done) rather than on a level:
                // strip_http latches status at the header LF of the response it is about to frame,
                // so this is provably that response's code and not the next one's.
                if (conn_up_q[rdr_done_conn[d]] && rdr_entry_done[d] && !sh_status_ok[d])
                    conn_status_bad_q[rdr_done_conn[d]] <= 1'b1;

                // Progress watchdog, per decoder. Counts only while the reader holds an entry of a
                // healthy connection at its head; any movement on the read path reloads it. The
                // timeout is pinned on that connection (conn_err_now_w) and cleared again once the
                // reader has let go of the head -- by then the connection is fatal and flushed, and
                // the next head is somebody else's.
                if (!rdr_head_valid[d] || !conn_up_q[h] || conn_fatal_q[h] || rdr_progress_w[d]) begin
                    rd_wdog_q[d] <= '0;
                end else if (rd_wdog_q[d] != '1) begin
                    rd_wdog_q[d] <= rd_wdog_q[d] + 1'b1;
                end else begin
                    rd_timeout_q[d] <= 1'b1;
                end
                if (rd_timeout_q[d] && rdr_head_valid[d]) conn_rd_timeout_q[h] <= 1'b1;
                if (rdr_flush_busy[d] || !rdr_head_valid[d]) rd_timeout_q[d] <= 1'b0;
            end

            if (br_q == BR_OPEN) begin
                if (conn_cnt_q == STALL_BITS'(STALL_CYCLES)) conn_stall_q <= 1'b1;
                else                                          conn_cnt_q <= conn_cnt_q + 1'b1;
            end else conn_cnt_q <= '0;
        end
    end

    // =============================================================================================
    // Readback -- revision 1/2 field positions kept exactly, so the bench's sticky gate and an
    // existing host read the same things in the same places.
    // =============================================================================================
    logic [7:0] occ_sat, depth_sat;
    always_comb begin
        automatic logic [31:0] occ_max = '0;
        for (int d = 0; d < N_DECODERS; d++) if (dec_occ_q[d] > occ_max) occ_max = dec_occ_q[d];
        occ_sat = (occ_max > 32'd255) ? 8'd255 : 8'(occ_max);
    end
    assign depth_sat = (QUEUE_DEPTH > 255) ? 8'd255 : 8'(QUEUE_DEPTH);

    assign totalWord = {8'd0,
                        rxd_overflow,
                        (|rwl_busy) || tx_busy,
                        |stream_refused, |conn_fatal_q, 1'b0, (&conn_up_q),
                        6'd0,
                        rdr_state[0], init_state_debug, 4'd0};

    // [23:20] is four bits wide (revision 1): 15 means "15 or more", and read id 20 / 32 carry the
    // real count.
    localparam logic [3:0] N_CONNS_NIB = (N_CONNS > 15) ? 4'd15 : 4'(N_CONNS);
    assign inflightWord = {CSR_REVISION, N_CONNS_NIB, req_ready, (&conn_up_q),
                           |conn_closed, |rxd_has_pending,
                           depth_sat, occ_sat};

    // EXACTLY 32 BITS. Positions 0..28 are build-119's; 29..31 are new in revision 3 and were a
    // literal 3'd0 there, so a host that predates them reads what it always read.
    //   [28] route_stall   a routed beat was refused -- a beat rx_dispatch had already taken off
    //                      the shared bus was DROPPED. Data loss. Never expected.
    //   [27] rwl_starved   body bytes with no chunk length configured.
    //   [26] read_timeout  a decoder's progress watchdog expired.
    //   [25] rx_fifo_stall the SHARED writer fifo refused its producer (same event as [28], from
    //                      the fifo's own side). In build-119 this was the per-lane fifo.
    //   [24] rxd_overflow  an announcement was dropped.
    //   [29] space_stall   the writer throttled rx_dispatch's readPkg issue because the shared fifo
    //                      was filling. NOT a failure: it is the design working, and it is the
    //                      first sign the card path is not keeping up with the wire.
    //   [30] slot_overflow some connection's response ran past the end of its slot.
    //   [31] residue_err   some decoder found bytes in a slot belonging to no response.
    assign stallWord = {|residue_seen_q, |conn_ovf_q, wr_space_stall, wr_route_stall || rxd_route_stall,
                        |rwl_starved, |rd_timeout_q, wr_fifo_stall, rxd_overflow,
                        8'd0, reconn_cnt_q,
                        |conn_status_bad_q, |conn_fatal_q, |conn_resp_err_q,
                        |stream_refused, |conn_init_err_q,
                        1'b0, 1'b0, conn_stall_q};

    assign queueDepthWord    = 32'(QUEUE_DEPTH);
    assign respWord          = {5'd0, |sh_resp_dirty, |sh_resp_error, (&sh_status_ok),
                                sh_status_ascii[0]};
    assign contentLengthWord = sh_content_len[0];
    assign bodyRemainingWord = sh_body_remain[0];
    assign state_debug       = rdr_state[0];

    // =============================================================================================
    // PER-CONNECTION READBACK
    //
    // Registers 16..20 keep revision 2's shape and stride so a host built against a 4-lane
    // build-119 reads sensible values here for connections 0..7; the revision-3 words below carry
    // the same fields for up to 32. Both are REGISTERED: 32 connections x five words is a wide mux
    // feeding an AXI-Lite read, which has no latency requirement worth spending a timing path on,
    // and build-117's report already had this module's occupancy counters in its violation list.
    // =============================================================================================
    logic [7:0] conn_occ_byte  [32];
    logic [3:0] conn_ready_nib [32];
    logic [3:0] conn_rd_nib    [32];
    logic [3:0] conn_tx_nib    [32];
    logic [7:0] conn_err_byte  [32];
    logic [31:0] drained_vec_w, overflow_vec_w;

    always_comb begin
        for (int i = 0; i < 32; i++) begin
            conn_occ_byte[i]  = 8'd0;
            conn_ready_nib[i] = 4'd0;
            conn_rd_nib[i]    = 4'd0;
            conn_tx_nib[i]    = 4'd0;
            conn_err_byte[i]  = 8'd0;
        end
        drained_vec_w  = '0;
        overflow_vec_w = '0;
        for (int d = 0; d < N_DECODERS; d++) begin
            conn_occ_byte[d] = (dec_occ_q[d] > 32'd255) ? 8'd255 : 8'(dec_occ_q[d]);
            conn_rd_nib[d]   = rdr_state[d];
            conn_tx_nib[d]   = dec_tx_state[d];
        end
        for (int c = 0; c < N_CONNS; c++) begin
            // ARM/ENTRY describe the connection's CURRENT decoder (cur_dec_q: where its entries
            // are queued, or its home decoder c mod N_DECODERS before its first arm) -- which in
            // stage 1 is decoder c, exactly revision 3/4's meaning. A drained connection may also
            // be armed on any other decoder; DEC_STATE (read id 33) has their halves.
            automatic logic [DEC_BITS-1:0] d = cur_dec_q[c];
            conn_ready_nib[c] = {conn_fatal_q[c], conn_up_q[c],
                                 dec_entry_ready_w[d],
                                 dec_arm_ready_w[d] && conn_arm_ok(CONN_BITS'(c), d)};
            conn_err_byte[c]  = {conn_ovf_q[c], conn_rd_timeout_q[c], conn_tx_refused_q[c],
                                 conn_status_bad_q[c], conn_resp_err_q[c], conn_init_err_q[c],
                                 conn_dirty_q[c], conn_dead_q[c]};
            drained_vec_w[c]  = conn_drained_q[c];
            overflow_vec_w[c] = conn_ovf_q[c];
        end
    end

    always_ff @(posedge ap_clk) begin
        for (int w = 0; w < 4; w++) begin
            for (int k = 0; k < 8; k++) begin
                connOccWord[w][8*k +: 8] <= conn_occ_byte[8*w + k];
                connErrWord[w][8*k +: 8] <= conn_err_byte[8*w + k];
            end
        end
        for (int w = 0; w < 2; w++) begin
            for (int k = 0; k < 16; k++) connReadyWord[w][4*k +: 4] <= conn_ready_nib[16*w + k];
        end
        connDrainedWord <= {overflow_vec_w, drained_vec_w};

        // Revision 5, read ids 33..38.
        connExtWord <= '0;
        for (int d = 0; d < N_DECODERS; d++)
            connExtWord[0][8*d +: 8] <= {rdr_state[d], stream_busy[d], dec_tainted_q[d],
                                         dec_entry_ready_w[d], dec_arm_ready_w[d]};
        for (int c = 0; c < N_CONNS; c++) begin
            connExtWord[1 + c/8][8*(c%8) +: 8] <=
                {(pend_q[c] > PEND_BITS'(15)) ? 4'd15 : 4'(pend_q[c]),
                 (pend_q[c] != '0) && (tail_conn_q[cur_dec_q[c]] == CONN_BITS'(c)),
                 3'(cur_dec_q[c])};
            connExtWord[5][c]      <= conn_residue_q[c];
            connExtWord[5][32 + c] <= conn_taint_q[c];
        end

        laneOccWord   <= connOccWord[0];
        laneErrWord   <= connErrWord[0];
        laneReadyWord <= {32'd0, connReadyWord[0][31:0]};
        for (int k = 0; k < 8; k++) begin
            laneStateWord[4*k      +: 4] <= conn_rd_nib[k];
            laneStateWord[32 + 4*k +: 4] <= conn_tx_nib[k];
        end
    end

    localparam int          POLICY_STALL_LOG2 = $clog2(LANE_STALL_CYCLES);
    localparam logic [23:0] POLICY_STALL_CYC =
        (LANE_STALL_CYCLES > 24'hFF_FFFF) ? 24'hFF_FFFF : 24'(LANE_STALL_CYCLES);
    localparam logic [15:0] POLICY_QDEPTH =
        (QUEUE_DEPTH > 16'hFFFF) ? 16'hFFFF : 16'(QUEUE_DEPTH);
    localparam logic [15:0] POLICY_EDEPTH =
        (ENTRY_DEPTH > 16'hFFFF) ? 16'hFFFF : 16'(ENTRY_DEPTH);

    //   [7:0]   CSR revision (3)     [15:8]  N_CONNS
    //   [31:16] QUEUE_DEPTH          [55:32] LANE_STALL_CYCLES   [61:56] log2 of it
    assign lanePolicyWord = {2'd0, 6'(POLICY_STALL_LOG2), POLICY_STALL_CYC,
                             POLICY_QDEPTH, 8'(N_CONNS), CSR_REVISION};

    //   [7:0]   CSR revision (3..5)  [15:8]  N_CONNS             [23:16] N_DECODERS
    //   [29:24] SLOT_LOG2            [35:30] log2(RD_MAX)        [51:36] ENTRY_DEPTH
    //   [63:52] log2(SLOT_FIFO_DEPTH), zero above
    assign slotPolicyWord = {6'd0, 6'($clog2(SLOT_FIFO_DEPTH)), POLICY_EDEPTH,
                             6'($clog2(RD_MAX)), 6'(SLOT_LOG2),
                             8'(N_DECODERS), 8'(N_CONNS), CSR_REVISION};

endmodule
