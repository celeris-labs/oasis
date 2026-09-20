`timescale 1ns / 1ps

import lynxTypes::*;

// =================================================================================================
// Per-decoder slot reader: pulls one HTTP response at a time out of a connection's card-memory slot
// and feeds it to that decoder's strip_http. One instance per decoder. ARCHITECTURE.md, ADR-5.
//
// WHAT IT IS FOR
// --------------
// slot_writer decouples the TOE from the decoders by putting every arriving segment in HBM. This is
// the other half: the thing that decides, per decoder, WHICH connection's bytes are fed into the
// framer next, and that never asks the receive path to slow down while it does so. A decoder that
// is 16x slower than the wire now costs exactly one decoder's throughput, not everybody's -- which
// is the coupling ADR-5 exists to remove and the number the bench reports.
//
// THE ENTRY QUEUE
// ---------------
// The host queues work for decoder d in the order it wants the decoder to see it -- ONE ENTRY PER
// ARMED GET, pushed by handler_slots on the transfer arm. An entry names the connection whose slot
// the response will land in, and carries the two per-response facts the framer needs:
//
//     {conn, chunk_bytes, body_last}
//
// `body_last` is the host's REQ_FLAGS bit 0 and drives strip_http's `body_last`: a logical column
// chunk may be fetched as several ranged GETs and only the last of them may end the decoder stream.
// `chunk_bytes` is the column chunk this response belongs to; nothing here gates on it (the tlast
// that matters downstream is axis_rewrite_last's, by byte count, exactly as in build-119) and it is
// exported as `head_chunk_bytes` so a waveform says which chunk a stalled reader is serving.
//
// This module serves the HEAD ENTRY ONLY, and it serves it to completion: the framer keeps mid-beat
// residue across responses (strip_http's res_data_q/res_cur_q), so switching connections mid-response
// would splice one connection's bytes into another's parse -- the corruption class that killed builds
// 90/91/92 on the TOE side. Depth 1 per connection is what makes "serve the head to completion"
// sufficient: there is never a second response queued behind the first in the same slot. If the host
// breaks that rule the residue check below catches it -- `residue_err` is exactly "bytes landed in
// this slot that belong to no response I was told about".
//
// FLUSH -- ABANDONING A RESPONSE
// ------------------------------
// A connection can die (fatal) or be reconnected while its slot holds half a response. There is then
// no resp_done coming and the entry at the head will never retire, so handler_slots raises `flush`
// (it holds it for as long as the connection is down, the same level that holds strip_http in
// `clear`). Flushing means: issue nothing more, SWALLOW whatever the card path still owes us from
// reads already issued -- those beats are in flight in the shell and arrive whether we want them or
// not -- and only when the last of them has landed drop the head entry and zero the cursors.
//
// `flush_busy` is what says the swallow has finished. handler_slots waits for it, AND for
// slot_writer's `conn_quiet`, before it pulses conn_release: releasing while either side still has
// bytes moving is what would put the next response at the wrong slot offset.
//
// Entries QUEUED BEHIND the head are deliberately NOT dropped. That mirrors handler_multi, whose
// chunk queue in axis_rewrite_last also survives a lane going fatal: the connection is out of the
// game until the host reissues the batch, and the host is the only thing that knows what to reissue.
//
// A head entry whose connection has landed NOTHING yet simply waits. That is the normal case -- the
// entry is queued when the GET is armed, and the bytes arrive milliseconds later -- and it is not an
// error. It is also the one head-of-line cost this design keeps (ADR-5's third risk): a late
// response at the head delays the ones behind it on the SAME decoder. The host orders entries by
// issue time so the wait is the transfer, not a stall.
//
// READS
// -----
// While the head's connection has bytes we have not asked for (`landed[c] > rd_cursor`) and fewer
// than 2 reads are outstanding, issue one for `min(landed[c] - rd_cursor, RD_MAX)` bytes. Two
// outstanding is enough to cover the request->data latency of the card path without making the
// residue check at the end ambiguous; RD_MAX stops a single 4 MiB response from owning the channel
// for the whole of its transfer.
//
// `landed[c]` is the ONLY thing that orders a read behind the write that produced its bytes: it is
// advanced by the write channel's ack, and the ack fires when the data is committed
// (cq_wr on the last bvalid, cdma_u/axi_dma_wr.sv:443). Reading one byte beyond it is a read of
// whatever the last tenant of that HBM line left behind. The card DMA model in
// unit-tests/card_dma fails any test that does it.
//
// THE END OF A RESPONSE
// ---------------------
// strip_http raises `resp_done` when the body has reached its Content-Length and drained. At that
// moment, by depth 1, the slot must be exactly empty: no read outstanding, and every landed byte
// asked for. If it is not, there are bytes in the slot that belong to no response -- a residue --
// and `residue_err` latches. Otherwise `conn_release[c]` pulses (slot_writer zeroes that
// connection's cursors), `resp_ack` retires the framer's resp_done, `entry_done` pulses for the
// host's credit accounting, and the entry is popped.
//
// DESIGN FOR SYNTHESIS
// --------------------
// The request is computed over four registered stages, so that nothing walks from `landed[]` (a
// 32-way mux) through a subtract, a min() and a 48-bit adder into `rd_req_valid` in one cycle, and
// so that no `resp_done` reaches a cursor compare and a request in the same cycle either. Four
// cycles per request is free: even the smallest read here is a ~600 byte header (10 beats), and the
// body reads are RD_MAX.
//   S_CALC1  landed[head_conn] -> register              (the 32:1 mux, alone)
//   S_CALC2  - rd_cursor, and slot_base + {conn,cursor} (the subtract and the 48-bit adder)
//   S_CALC3  min(avail, RD_MAX), and the go decision    (the compare)
//   S_ISSUE  drive the request
// The expected longest path is S_CALC2's 48-bit vaddr adder, and it is a plain carry chain from
// registers to a register.
// =================================================================================================
module slot_reader #(
    parameter int N_CONNS     = 4,
    parameter int SLOT_LOG2   = 22,
    parameter int RD_MAX      = 65536,   // bytes; the most one read may ask for
    parameter int ENTRY_DEPTH = 64,

    localparam int CONN_BITS  = (N_CONNS > 1) ? $clog2(N_CONNS) : 1,
    localparam int OFF_BITS   = SLOT_LOG2 + 1,
    localparam int KEEP_BITS  = AXI_DATA_BITS/8
) (
    input  logic clk,
    input  logic rst_n,

    // -- entry queue push, from the host's transfer arm. One entry per armed GET.
    input  logic                       entry_valid,
    output logic                       entry_ready,
    input  logic [CONN_BITS-1:0]       entry_conn,
    input  logic [31:0]                entry_chunk_bytes,
    input  logic                       entry_body_last,

    // -- abandon the response in progress: the connection is down. See the header.
    input  logic                       flush,
    output logic                       flush_busy,

    // -- from slot_writer: committed bytes per connection, and the slot base (CSR).
    input  logic [N_CONNS-1:0][SLOT_LOG2:0] landed,
    input  logic [VADDR_BITS-1:0]      slot_base,

    // -- card DMA read channel (req_t{LOCAL_READ, STRM_CARD, dest 1+d, last=0} later)
    output logic                       rd_req_valid,
    input  logic                       rd_req_ready,
    output logic [VADDR_BITS-1:0]      rd_req_vaddr,
    output logic [LEN_BITS-1:0]        rd_req_len,
    output logic                       rd_req_last,

    input  logic                       s_axis_tvalid,
    output logic                       s_axis_tready,
    input  logic [AXI_DATA_BITS-1:0]   s_axis_tdata,
    input  logic [KEEP_BITS-1:0]       s_axis_tkeep,
    input  logic                       s_axis_tlast,

    // -- to strip_http. tlast is dropped: the framer delimits by Content-Length and a card-read
    //    tlast would only say where a READ ended, which is not where a response ends.
    output logic                       m_axis_tvalid,
    input  logic                       m_axis_tready,
    output logic [AXI_DATA_BITS-1:0]   m_axis_tdata,
    output logic [KEEP_BITS-1:0]       m_axis_tkeep,
    output logic                       m_axis_tlast,

    // -- framer handshake
    input  logic                       resp_done,
    output logic                       resp_ack,
    output logic                       body_last,     // head entry's, straight to strip_http

    // -- outputs
    output logic [N_CONNS-1:0]         conn_release,  // pulse: slot c is drained, reset its cursors
    output logic                       entry_done,    // pulse: one entry retired
    output logic                       residue_err,   // sticky: the slot was not empty at resp_done

    // -- visibility
    // There is still something of the head entry to fetch or to receive: bytes have landed that we
    // have not asked for, or a read is in flight. This is the slots equivalent of tcp_read's
    // `parser_quiet_w`, and it exists for the same reason: a connection whose peer has FINed may
    // only be declared failed once there is genuinely nothing left, or a response that was about
    // to complete out of bytes already in the slot is aborted instead (lane_drain `c`).
    output logic                       rd_pending,
    output logic [31:0]                head_chunk_bytes,
    output logic                       busy,          // an entry is being served or is queued
    output logic [7:0]                 entry_occ,     // entries queued, saturating
    output logic [3:0]                 state_debug
);

    localparam int EPTR_BITS = $clog2(ENTRY_DEPTH);
    localparam int ECNT_BITS = $clog2(ENTRY_DEPTH+1);

    // ---------------------------------------------------------------------------------------------
    // Entry queue
    // ---------------------------------------------------------------------------------------------
    logic [CONN_BITS-1:0] eq_conn  [ENTRY_DEPTH];
    logic [31:0]          eq_chunk [ENTRY_DEPTH];
    logic                 eq_last  [ENTRY_DEPTH];
    logic [EPTR_BITS-1:0] eq_head_q, eq_tail_q;
    logic [ECNT_BITS-1:0] eq_cnt_q;

    assign entry_ready = (eq_cnt_q != ECNT_BITS'(ENTRY_DEPTH));

    logic eq_push_w;
    assign eq_push_w = entry_valid && entry_ready;

    // The head is latched into head_* once, so the queue memory is never in a timing path.
    logic                 head_valid_q;
    logic [CONN_BITS-1:0] head_conn_q;
    logic [31:0]          head_chunk_q;
    logic                 head_last_q;

    assign head_chunk_bytes = head_chunk_q;
    assign body_last        = head_last_q;
    assign busy             = head_valid_q || (eq_cnt_q != '0);
    assign entry_occ        = (eq_cnt_q > ECNT_BITS'(255)) ? 8'd255 : 8'(eq_cnt_q);

    // ---------------------------------------------------------------------------------------------
    // Data path: straight through, except while flushing, when it is swallowed.
    //
    // Bytes only ever arrive because we asked for them, and we only ever ask for the head entry's,
    // so there is nothing to route. `swallow_q` is REGISTERED rather than taken from `flush`
    // directly: it keeps the tready that faces the card path off the handler's combinational cone,
    // and the flush window is milliseconds of connection teardown, so a cycle of latency is free.
    //
    // Dropping m_axis_tvalid on the cycle swallow_q rises can retract an offer the framer had not
    // taken. That is safe HERE and only here: handler_slots holds strip_http in `clear` for the
    // whole flush window -- the two come from the same conn_up level -- so there is no framer state
    // left for a retracted beat to be missing from.
    // ---------------------------------------------------------------------------------------------
    logic swallow_q;

    assign m_axis_tvalid = s_axis_tvalid && !swallow_q;
    assign m_axis_tdata  = s_axis_tdata;
    assign m_axis_tkeep  = s_axis_tkeep;
    assign m_axis_tlast  = 1'b0;
    assign s_axis_tready = swallow_q ? 1'b1 : m_axis_tready;

    logic in_beat_w;
    assign in_beat_w = s_axis_tvalid && s_axis_tready;

    // ---------------------------------------------------------------------------------------------
    // Outstanding reads. Tracked by counting bytes rather than by an ack, because a read is issued
    // with last=0 and Coyote sends no cq_rd for a last=0 request (req_t, lynx_pkg: "Only if last is
    // high ... no acknowledgement will be sent"). Every beat but the last of a read is full, so the
    // remaining count needs no popcount.
    // ---------------------------------------------------------------------------------------------
    localparam int BPB = AXI_DATA_BITS/8;   // 64
    logic [1:0]           n_out_q;
    logic [OFF_BITS-1:0]  rem0_q, rem1_q;   // bytes still to arrive for the 2 reads in flight

    logic rd_complete_w;
    assign rd_complete_w = in_beat_w && (n_out_q != 2'd0) && (rem0_q <= OFF_BITS'(BPB));

    // ---------------------------------------------------------------------------------------------
    // Request pipeline
    // ---------------------------------------------------------------------------------------------
    localparam logic [3:0] S_IDLE  = 4'd0,
                           S_CALC1 = 4'd1,
                           S_CALC2 = 4'd2,
                           S_CALC3 = 4'd3,
                           S_ISSUE = 4'd4,
                           S_DONE0 = 4'd5,
                           S_DONE1 = 4'd6,
                           S_DONE2 = 4'd7,
                           S_FLUSH = 4'd8;
    logic [3:0] st_q;
    assign state_debug = st_q;

    logic [OFF_BITS-1:0]   rd_cursor_q;    // bytes of this response already REQUESTED
    logic [OFF_BITS-1:0]   landed_sel_q;   // landed[head_conn], registered
    logic [OFF_BITS-1:0]   avail_q;        // landed_sel_q - rd_cursor_q
    logic [VADDR_BITS-1:0] vaddr_q;
    logic [OFF_BITS-1:0]   len_q;
    logic                  go_q;

    assign rd_req_valid = (st_q == S_ISSUE) && go_q;
    assign rd_req_vaddr = vaddr_q;
    assign rd_req_len   = LEN_BITS'(len_q);
    // last=0: the framer wants one continuous byte stream, and a tlast per READ would say nothing
    // about where the response ends. It also means no cq_rd, which is why the byte counter above
    // exists instead.
    assign rd_req_last  = 1'b0;

    logic req_fire_w;
    assign req_fire_w = rd_req_valid && rd_req_ready;

    logic [OFF_BITS-1:0] landed_head_w;
    assign landed_head_w = landed[head_conn_q];

    logic residue_err_q;
    assign residue_err = residue_err_q;

    logic done_ok_w;
    assign done_ok_w = (n_out_q == 2'd0) && (rd_cursor_q == landed_sel_q);

    // Registered, off `landed_sel_q` rather than off the 32-way `landed` mux: the pipeline refreshes
    // landed_sel_q every few cycles even when it has nothing to issue, so this is at most a handful
    // of cycles stale, and the only thing that reads it is a 1024-cycle watchdog.
    logic rd_pending_q;
    assign rd_pending = rd_pending_q;

    // The flush has finished when nothing of ours is left moving: no read outstanding, no entry
    // being served, and the pipeline back at rest. handler_slots gates conn_release on this.
    assign flush_busy = (st_q == S_FLUSH) ||
                        (flush && (head_valid_q || (n_out_q != 2'd0) || (st_q != S_IDLE)));

    // The queue pops on a normal retire and on the flush that abandons the head.
    logic eq_pop_w;
    assign eq_pop_w = (st_q == S_DONE2) ||
                      ((st_q == S_FLUSH) && (n_out_q == 2'd0) && head_valid_q);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            eq_head_q     <= '0;
            eq_tail_q     <= '0;
            eq_cnt_q      <= '0;
            head_valid_q  <= 1'b0;
            head_conn_q   <= '0;
            st_q          <= S_IDLE;
            rd_cursor_q   <= '0;
            landed_sel_q  <= '0;
            avail_q       <= '0;
            vaddr_q       <= '0;
            len_q         <= '0;
            go_q          <= 1'b0;
            n_out_q       <= '0;
            rem0_q        <= '0;
            rem1_q        <= '0;
            conn_release  <= '0;
            entry_done    <= 1'b0;
            resp_ack      <= 1'b0;
            residue_err_q <= 1'b0;
            head_chunk_q  <= '0;
            head_last_q   <= 1'b0;
            swallow_q     <= 1'b0;
            rd_pending_q  <= 1'b0;
        end else begin
            conn_release <= '0;
            entry_done   <= 1'b0;
            resp_ack     <= 1'b0;
            swallow_q    <= flush || (st_q == S_FLUSH);
            rd_pending_q <= head_valid_q &&
                            ((landed_sel_q > rd_cursor_q) || (n_out_q != 2'd0));

            // -- entry queue push. Allowed while flushing: the queue belongs to the host, and the
            //    host is the only thing that may decide an entry is not wanted any more.
            if (eq_push_w) begin
                eq_conn[eq_tail_q]  <= entry_conn;
                eq_chunk[eq_tail_q] <= entry_chunk_bytes;
                eq_last[eq_tail_q]  <= entry_body_last;
                eq_tail_q           <= (eq_tail_q == EPTR_BITS'(ENTRY_DEPTH-1)) ? '0 : eq_tail_q + 1'b1;
            end

            // -- take the head -------------------------------------------------------------------
            if (!head_valid_q && (eq_cnt_q != '0) && !flush) begin
                head_conn_q  <= eq_conn[eq_head_q];
                head_chunk_q <= eq_chunk[eq_head_q];
                head_last_q  <= eq_last[eq_head_q];
                head_valid_q <= 1'b1;
                rd_cursor_q  <= '0;
            end

            // -- read byte accounting --------------------------------------------------------------
            if (in_beat_w && (n_out_q != 2'd0)) begin
                if (rem0_q <= OFF_BITS'(BPB)) begin
                    rem0_q <= rem1_q;
                end else begin
                    rem0_q <= rem0_q - OFF_BITS'(BPB);
                end
            end

            // -- request pipeline -------------------------------------------------------------------
            case (st_q)
                S_IDLE: begin
                    // A flush with anything still moving goes to S_FLUSH; a flush with nothing
                    // moving simply parks here, which is where a down connection belongs.
                    if (flush) begin
                        if (head_valid_q || (n_out_q != 2'd0)) st_q <= S_FLUSH;
                    end
                    else if (head_valid_q && resp_done)  st_q <= S_DONE0;
                    else if (head_valid_q)               st_q <= S_CALC1;
                end
                S_CALC1: begin
                    landed_sel_q <= landed_head_w;
                    st_q         <= flush ? S_FLUSH : (resp_done ? S_DONE1 : S_CALC2);
                end
                S_CALC2: begin
                    avail_q <= landed_sel_q - rd_cursor_q;
                    vaddr_q <= slot_base
                             + VADDR_BITS'({head_conn_q, rd_cursor_q[SLOT_LOG2-1:0]});
                    st_q    <= flush ? S_FLUSH : S_CALC3;
                end
                S_CALC3: begin
                    len_q <= (avail_q > OFF_BITS'(RD_MAX)) ? OFF_BITS'(RD_MAX) : avail_q;
                    go_q  <= (avail_q != '0) && (n_out_q < 2'd2) && !resp_done && !flush;
                    st_q  <= S_ISSUE;
                end
                // A request already offered is seen through to its ready, flush or not: retracting
                // rd_req_valid would break the card path's handshake, and one more read of bytes we
                // are about to throw away costs nothing.
                S_ISSUE: begin
                    if (!go_q) begin
                        st_q <= flush ? S_FLUSH : S_IDLE;
                    end else if (rd_req_ready) begin
                        rd_cursor_q <= rd_cursor_q + len_q;
                        go_q        <= 1'b0;
                        st_q        <= flush ? S_FLUSH : S_IDLE;
                    end
                end
                // The response is framed. Two settling cycles before the residue check so that the
                // last beat's byte accounting has certainly retired (resp_done is raised after the
                // final body beat has drained through strip_http's two-deep skid).
                S_DONE0: st_q <= S_DONE1;
                S_DONE1: begin
                    landed_sel_q <= landed_head_w;
                    st_q         <= S_DONE2;
                end
                S_DONE2: begin
                    if (!done_ok_w) residue_err_q <= 1'b1;
                    conn_release[head_conn_q] <= 1'b1;
                    entry_done                <= 1'b1;
                    resp_ack                  <= 1'b1;
                    head_valid_q              <= 1'b0;
                    rd_cursor_q               <= '0;
                    landed_sel_q              <= '0;
                    eq_head_q <= (eq_head_q == EPTR_BITS'(ENTRY_DEPTH-1)) ? '0 : eq_head_q + 1'b1;
                    st_q      <= S_IDLE;
                end

                // Swallow what the card path still owes us, then abandon the head entry. No
                // conn_release from here: on this path handler_slots owns the release, because it
                // is the only thing that also knows when slot_writer has gone quiet.
                S_FLUSH: begin
                    if (n_out_q == 2'd0) begin
                        if (head_valid_q) begin
                            eq_head_q <= (eq_head_q == EPTR_BITS'(ENTRY_DEPTH-1)) ? '0
                                                                                  : eq_head_q + 1'b1;
                            head_valid_q <= 1'b0;
                        end
                        rd_cursor_q  <= '0;
                        landed_sel_q <= '0;
                        st_q         <= S_IDLE;
                    end
                end
                default: st_q <= S_IDLE;
            endcase

            // -- in-flight read bookkeeping. Written after the fsm so a request issued this cycle
            //    is counted, and a read completing this cycle is uncounted, exactly once.
            if (req_fire_w && !rd_complete_w) begin
                if (n_out_q == 2'd0) rem0_q <= len_q; else rem1_q <= len_q;
                n_out_q <= n_out_q + 2'd1;
            end else if (!req_fire_w && rd_complete_w) begin
                n_out_q <= n_out_q - 2'd1;
            end else if (req_fire_w && rd_complete_w) begin
                // One retires and one starts in the same cycle: the count is unchanged, and the
                // new read takes the slot the retiring one just freed.
                if (n_out_q == 2'd1) rem0_q <= len_q; else rem1_q <= len_q;
            end

            // -- entry count ------------------------------------------------------------------------
            case ({eq_push_w, eq_pop_w})
                2'b10:   eq_cnt_q <= eq_cnt_q + 1'b1;
                2'b01:   eq_cnt_q <= eq_cnt_q - 1'b1;
                default: ;
            endcase
        end
    end

endmodule
