`timescale 1ns / 1ps

import lynxTypes::*;

// =================================================================================================
// Simulation model of Coyote's card DMA path (sq_wr / axis_card_send, sq_rd / axis_card_recv).
//
// WHY THIS EXISTS
// ---------------
// slot_writer and slot_reader talk to HBM through Coyote's `cdma_u` engines. Nothing about that
// contract is obvious from the RTL we write -- the rules live in Coyote's own simulation model
// (`parcore/libstf/coyote/sim/hw/stream_simulation.svh`, tasks run_write_queue/run_read_queue) and
// in the engines themselves (`hw/hdl/cdma/cdma_u/axi_dma_{rd,wr}.sv`). Getting one of them wrong is
// not a functional bug in our modules, it is a bug that only appears on hardware, six hours of
// synthesis and a licence away. So the rules are modelled here, with an assert on each, and every
// slot_writer / slot_reader bench runs against this model rather than against a friendly stub.
//
// THE CONTRACT, AS MODELLED (each line is an assert below)
// --------------------------------------------------------
//   * A request is {vaddr[47:0], len[27:0], last}. Byte-granular vaddr AND len are legal: the
//     unaligned engine is what build-119 compiles (cr_shell.tcl:93). len == 0 is not.
//   * WRITE: the request comes first, then exactly `len` bytes on the data stream. Every beat's
//     tkeep is all ones except the final beat, whose tkeep is the low (len % 64) bits -- Coyote's
//     model asserts `keep_bits == AXI_DATA_BYTES` on every non-final beat and
//     `keep_bits == remaining_length` on the last one (stream_simulation.svh:147,150). The data
//     stream is packed from byte 0 of the transfer regardless of how vaddr is aligned; the engine
//     does the shift. tlast on the final beat when last=1.
//   * READ: the request comes first, then `len` bytes come back the same shape. tlast only if
//     last=1 (`trs.data.last ? last : 0`, stream_simulation.svh:233).
//   * One ack per request, in issue order, per channel. A write's ack fires when the data has been
//     committed (`cq_wr` on the last bvalid, cdma_u/axi_dma_wr.sv:443) -- which is the ONE fact the
//     whole slot design rests on, because it is what makes `landed[c]` safe to read against.
//     (Coyote's OWN sim model acks a last=0 request too; the hardware does not -- `req_t.last` in
//     lynx_pkg: "Only if last is high ... no acknowledgement will be sent on the corresponding cq_*
//     interface". The model follows Coyote's sim here, and slot_reader depends on neither: it issues
//     last=0 reads and counts bytes instead of acks.)
//   * At most MAX_OUTSTANDING (8, `N_OUTSTANDING`) requests outstanding per channel; the model
//     drops req_ready rather than trusting the DUT to count.
//
// AND TWO RULES THE DUT MUST RESPECT, WHICH THE MODEL POLICES
// ----------------------------------------------------------
//   * A read of a byte that was never written is a FAIL. In the real design that is a read of
//     uninitialised HBM, which returns whatever the last tenant left there -- silent corruption.
//   * A read that overlaps a write which has been ISSUED but not yet ACKED is a FAIL. This is the
//     read-after-write rule: the reader may only read up to `landed[c]`, and `landed[c]` is only
//     advanced by a write ack. Nothing else orders the two engines.
//
// The model is deliberately hostile: LFSR back-pressure on the write data tready and LFSR gaps on
// the read data tvalid, and configurable request->data and data->ack latencies, so the benches can
// ask whether slot_writer still never refuses the rx side when the DMA is slow (the property the
// whole redesign exists for).
//
// Latencies and back-pressure are parameters, each overridable by a plusarg so a bench can sweep
// them without re-elaborating:
//   +DMA_WR_REQ_LAT= +DMA_WR_ACK_LAT= +DMA_RD_REQ_LAT= +DMA_RD_ACK_LAT= +DMA_WR_BP= +DMA_RD_GAP=
//   +DMA_SEED=
//
// +DMA_PIPE makes the request latency PIPELINED: a request's data may start REQ_LAT cycles after the
// request was ACCEPTED rather than REQ_LAT cycles after the engine finished the previous one. That is
// what a real cdma with N_OUTSTANDING requests in flight does, and it is what a throughput bench needs
// (unit-tests/decoder_feed): with a realistic HBM latency of ~100+ cycles the serialised default would
// charge it once per 4 KiB segment and understate the channel by a third. Off by default, so every
// existing bench sees exactly the engine it was written against.
//
// TWO THINGS THIS FILE HAS TO AVOID, BOTH COSTLY TO REDISCOVER
// ------------------------------------------------------------
// 1. NEVER push an assignment pattern straight into a queue. `w_q.push_back('{vaddr: ..., len:
//    ..., last: ...})` makes Vivado 2024.2's `xelab` spin forever -- 100% CPU, >1 GB RSS, no
//    output, at every optimisation level and with -debug off, and the message it stops after
//    ("Completed static elaboration") names nothing. Filling a temporary struct field by field and
//    pushing that elaborates in two seconds. Bisected 2026-09-20; it is the only construct in this
//    file that does it, and it was in both the write and the read path.
// 2. The card memory is the window [MEM_BASE, MEM_BASE+MEM_BYTES), checked explicitly by in_window()
//    on every access, so an address outside what a bench was given is an error rather than a silent
//    zero. It is STORED as associative arrays keyed by the offset (card_mem, and card_wr as the
//    "ever written" bit, i.e. `exists`). It was a flat `new[MEM_BYTES]` until 2026-09-23: xsim 2024.2
//    aliases dynamic-array indices at and above 2^29 (m[(3<<28)+5] and m[(1<<28)+5] are the same
//    byte), which corrupted every bench with 4 x 256 MiB slots -- the real stage-1 geometry.
// =================================================================================================
module card_dma_model #(
    parameter int DATA_BITS       = AXI_DATA_BITS,
    parameter int N_RD            = 1,     // read channels (dest 1+d); >= 1, tie off what you do not use
    parameter int MAX_OUTSTANDING = 8,     // Coyote's N_OUTSTANDING
    parameter int WR_REQ_LAT      = 4,     // cycles from request accepted to data being consumed
    parameter int WR_ACK_LAT      = 8,     // cycles from the last data beat to the ack pulse
    parameter int RD_REQ_LAT      = 4,
    parameter int RD_ACK_LAT      = 8,
    parameter int WR_BP_PCT       = 0,     // % of cycles the write data tready is dropped
    parameter int RD_GAP_PCT      = 0,     // % of read beats followed by an idle cycle
    parameter int SEED            = 1,
    // The window of card memory this model holds. Anything outside it is a FAIL.
    parameter longint unsigned MEM_BASE  = 0,
    parameter longint unsigned MEM_BYTES = 1 << 22
) (
    input  logic clk,
    input  logic rst_n,

    // ---- write channel (sq_wr + axis_card_send[0] + cq_wr) -------------------------------------
    input  logic                     wr_req_valid,
    output logic                     wr_req_ready,
    input  logic [VADDR_BITS-1:0]    wr_req_vaddr,
    input  logic [LEN_BITS-1:0]      wr_req_len,
    input  logic                     wr_req_last,

    input  logic                     wr_tvalid,
    output logic                     wr_tready,
    input  logic [DATA_BITS-1:0]     wr_tdata,
    input  logic [DATA_BITS/8-1:0]   wr_tkeep,
    input  logic                     wr_tlast,

    output logic                     wr_ack,      // one pulse per request, in issue order

    // ---- read channels (sq_rd + axis_card_recv[1+d] + cq_rd) -----------------------------------
    input  logic                     rd_req_valid [N_RD],
    output logic                     rd_req_ready [N_RD],
    input  logic [VADDR_BITS-1:0]    rd_req_vaddr [N_RD],
    input  logic [LEN_BITS-1:0]      rd_req_len   [N_RD],
    input  logic                     rd_req_last  [N_RD],

    output logic                     rd_tvalid [N_RD],
    input  logic                     rd_tready [N_RD],
    output logic [DATA_BITS-1:0]     rd_tdata  [N_RD],
    output logic [DATA_BITS/8-1:0]   rd_tkeep  [N_RD],
    output logic                     rd_tlast  [N_RD],

    output logic                     rd_ack    [N_RD],

    // ---- diagnostics ---------------------------------------------------------------------------
    output logic                     model_fail,
    output int                       model_errors
);

    localparam int BYTES = DATA_BITS/8;

    // ---------------------------------------------------------------------------------------------
    // Card memory: byte addressed, over [MEM_BASE, MEM_BASE+MEM_BYTES). card_wr carries the "has
    // ever been written" flag, so a read of uninitialised HBM is detectable.
    // ---------------------------------------------------------------------------------------------
    byte unsigned card_mem [longint unsigned];
    bit           card_wr  [longint unsigned];

    function automatic bit in_window(input longint unsigned a);
        in_window = (a >= MEM_BASE) && (a < (MEM_BASE + MEM_BYTES));
    endfunction

    // For benches: what is in card memory, and whether anything ever put it there.
    function automatic logic [7:0] peek(input longint unsigned a);
        peek = (in_window(a) && card_mem.exists(a - MEM_BASE)) ? card_mem[a - MEM_BASE] : 8'hxx;
    endfunction
    function automatic bit written(input longint unsigned a);
        written = in_window(a) && card_wr.exists(a - MEM_BASE);
    endfunction

    int n_err_wr = 0;
    int n_err_rd = 0;
    assign model_errors = n_err_wr + n_err_rd;
    assign model_fail   = ((n_err_wr + n_err_rd) != 0);

    task automatic ew(input string m);
        $display("card_dma_model: FAIL t=%0t wr: %s", $time, m);
        n_err_wr = n_err_wr + 1;
    endtask
    task automatic er(input string m);
        $display("card_dma_model: FAIL t=%0t rd: %s", $time, m);
        n_err_rd = n_err_rd + 1;
    endtask

    function automatic bit keep_is_bottom_justified(input logic [BYTES-1:0] k);
        int n;
        begin
            n = $countones(k);
            if (n == 0) keep_is_bottom_justified = (k == '0);
            else        keep_is_bottom_justified = (k == ({BYTES{1'b1}} >> (BYTES - n)));
        end
    endfunction

    // Runtime-overridable copies of the parameters.
    int wr_req_lat_i = WR_REQ_LAT;
    int wr_ack_lat_i = WR_ACK_LAT;
    int rd_req_lat_i = RD_REQ_LAT;
    int rd_ack_lat_i = RD_ACK_LAT;
    int wr_bp_i      = WR_BP_PCT;
    int rd_gap_i     = RD_GAP_PCT;
    int seed_i       = SEED;
    bit pipe_i       = 1'b0;

    initial begin
        void'($value$plusargs("DMA_WR_REQ_LAT=%d", wr_req_lat_i));
        void'($value$plusargs("DMA_WR_ACK_LAT=%d", wr_ack_lat_i));
        void'($value$plusargs("DMA_RD_REQ_LAT=%d", rd_req_lat_i));
        void'($value$plusargs("DMA_RD_ACK_LAT=%d", rd_ack_lat_i));
        void'($value$plusargs("DMA_WR_BP=%d",      wr_bp_i));
        void'($value$plusargs("DMA_RD_GAP=%d",     rd_gap_i));
        void'($value$plusargs("DMA_SEED=%d",       seed_i));
        if ($test$plusargs("DMA_PIPE")) pipe_i = 1'b1;
    end

    // Free-running cycle counter; the ack pipelines are scheduled against it. `int` so it starts at
    // 0 and not at X (a `time` would, and that trap has cost this repo days).
    int cyc_q = 0;
    always_ff @(posedge clk) cyc_q <= rst_n ? cyc_q + 1 : 0;

    // The latency still owed by a request accepted at `acc`, given the engine is free now.
    function automatic int lat_left(input int acc, input int lat);
        int t;
        t = pipe_i ? (acc + lat - cyc_q) : lat;
        lat_left = (t < 0) ? 0 : t;
    endfunction

    // =============================================================================================
    // WRITE CHANNEL
    // =============================================================================================
    typedef struct {
        longint unsigned vaddr;
        int              len;
        bit              last;
        int              acc;    // cycle the request was accepted (+DMA_PIPE)
    } wreq_s;

    wreq_s           w_q  [$];   // accepted, data not consumed yet
    longint unsigned ifl_lo[$];  // un-acked write ranges, half open [lo,hi)
    longint unsigned ifl_hi[$];
    int              ack_due[$]; // absolute cycle each accepted request's ack is due

    int    w_outst_q = 0;
    assign wr_req_ready = (w_outst_q < MAX_OUTSTANDING);

    wreq_s w_cur;
    wreq_s w_new;
    int    w_state = 0;          // 0 idle, 1 request latency, 2 streaming data
    int    w_dly   = 0;
    int    w_blk   = 0;
    int    w_nblk  = 0;
    bit    w_saw_last = 0;

    // LFSR for the write-data back-pressure.
    logic [15:0] w_lfsr_q = 16'hACE1;
    logic        w_bp_w;
    assign w_bp_w = (wr_bp_i > 0) && ((w_lfsr_q % 100) < wr_bp_i);

    // Set by the read side's range check; declared here because the queues live here.
    function automatic bit overlaps_unacked(input longint unsigned lo, input longint unsigned hi);
        overlaps_unacked = 1'b0;
        for (int j = 0; j < ifl_lo.size(); j++) begin
            if ((lo < ifl_hi[j]) && (hi > ifl_lo[j])) overlaps_unacked = 1'b1;
        end
    endfunction

    // Internal-state assignments are blocking (one process, read as a program); everything the DUT
    // observes -- wr_tready, wr_ack, w_outst_q -- is non-blocking.
    always @(posedge clk) begin
        bit did_accept;
        bit did_ack;
        int keep_n;
        int remaining;
        longint unsigned a;

        if (!rst_n) begin
            wr_tready  <= 1'b0;
            wr_ack     <= 1'b0;
            w_outst_q  <= 0;
            w_q.delete(); ifl_lo.delete(); ifl_hi.delete(); ack_due.delete();
            w_state = 0; w_dly = 0; w_blk = 0; w_nblk = 0; w_saw_last = 0;
            w_lfsr_q <= 16'hACE1 ^ seed_i[15:0];
        end else begin
            did_accept = 1'b0;
            did_ack    = 1'b0;
            wr_ack     <= 1'b0;
            w_lfsr_q   <= {w_lfsr_q[14:0], w_lfsr_q[15] ^ w_lfsr_q[13] ^ w_lfsr_q[12] ^ w_lfsr_q[10]};

            // -- request accept -------------------------------------------------------------------
            if (wr_req_valid && wr_req_ready) begin
                if (wr_req_len == 0) ew("write request with len == 0");
                if (!wr_req_last)    ew("write request with last == 0 (slot_writer must set last=1)");
                // Built field by field on purpose: `q.push_back('{a:..., b:...})` -- an assignment
                // pattern straight into a queue -- is what wedges xelab. See the header.
                w_new.vaddr = longint'(wr_req_vaddr);
                w_new.len   = int'(wr_req_len);
                w_new.last  = wr_req_last;
                w_new.acc   = cyc_q;
                w_q.push_back(w_new);
                ifl_lo.push_back(longint'(wr_req_vaddr));
                ifl_hi.push_back(longint'(wr_req_vaddr) + longint'(wr_req_len));
                ack_due.push_back(0);   // filled in when the data is done; placeholder keeps order
                did_accept = 1'b1;
            end

            // -- ack, in issue order, once the data has been committed ----------------------------
            //    ack_due[0] is 0 while that request's data is still outstanding, so the head is only
            //    eligible after its stream finished and stamped a real due time.
            if ((ack_due.size() > 0) && (ack_due[0] != 0) && (cyc_q >= ack_due[0])) begin
                void'(ack_due.pop_front());
                void'(ifl_lo.pop_front());
                void'(ifl_hi.pop_front());
                wr_ack  <= 1'b1;
                did_ack  = 1'b1;
            end

            // -- data engine ----------------------------------------------------------------------
            case (w_state)
                0: begin
                    if (w_q.size() > 0) begin
                        w_cur   = w_q[0];
                        w_dly   = lat_left(w_cur.acc, wr_req_lat_i);
                        w_state = 1;
                    end
                end
                1: begin
                    if (w_dly <= 0) begin
                        void'(w_q.pop_front());
                        w_blk      = 0;
                        w_nblk     = (w_cur.len + BYTES - 1) / BYTES;
                        w_saw_last = 1'b0;
                        wr_tready  <= 1'b1;
                        w_state    = 2;
                    end else begin
                        w_dly = w_dly - 1;
                    end
                end
                2: begin
                    if (wr_tvalid && wr_tready) begin
                        keep_n = $countones(wr_tkeep);
                        if (!keep_is_bottom_justified(wr_tkeep))
                            ew($sformatf("write beat tkeep %0h is not bottom justified", wr_tkeep));
                        if (w_blk < w_nblk - 1) begin
                            if (keep_n != BYTES)
                                ew($sformatf("non-final write beat %0d/%0d has %0d valid bytes, expected %0d",
                                             w_blk, w_nblk, keep_n, BYTES));
                            if (wr_tlast)
                                ew($sformatf("tlast on write beat %0d of %0d", w_blk, w_nblk));
                        end else begin
                            remaining = w_cur.len - (w_nblk - 1) * BYTES;
                            if (keep_n != remaining)
                                ew($sformatf("final write beat has %0d valid bytes, request len %0d needs %0d",
                                             keep_n, w_cur.len, remaining));
                            if (w_cur.last && !wr_tlast)
                                ew("final write beat of a last=1 request carried no tlast");
                            if (!w_cur.last && wr_tlast)
                                ew("tlast on the final beat of a last=0 request");
                            w_saw_last = 1'b1;
                        end

                        // Commit. Bytes land as they stream; what orders a read against them is the
                        // un-acked-range check, not the commit time.
                        for (int i = 0; i < BYTES; i++) begin
                            if (wr_tkeep[i]) begin
                                a = w_cur.vaddr + longint'(w_blk) * BYTES + longint'(i);
                                if (!in_window(a)) begin
                                    ew($sformatf("write to %0h is outside the modelled card memory [%0h,%0h)",
                                                 a, MEM_BASE, MEM_BASE + MEM_BYTES));
                                end else begin
                                    card_mem[a - MEM_BASE] = wr_tdata[i*8 +: 8];
                                    card_wr[a - MEM_BASE]  = 1'b1;
                                end
                            end
                        end

                        w_blk = w_blk + 1;
                        if (w_blk >= w_nblk) begin
                            // Stamp the ack due time on the oldest request without one.
                            for (int j = 0; j < ack_due.size(); j++) begin
                                if (ack_due[j] == 0) begin
                                    ack_due[j] = cyc_q + ((wr_ack_lat_i < 1) ? 1 : wr_ack_lat_i);
                                    break;
                                end
                            end
                            wr_tready <= 1'b0;
                            w_state    = 0;
                        end else begin
                            wr_tready <= !w_bp_w;
                        end
                    end else begin
                        wr_tready <= !w_bp_w;
                    end
                end
                default: w_state = 0;
            endcase

            w_outst_q <= w_outst_q + (did_accept ? 1 : 0) - (did_ack ? 1 : 0);
        end
    end

    // =============================================================================================
    // READ CHANNELS. One always block for every channel so that `card_mem` and the un-acked write queues
    // have exactly one writer (the block above) and many readers.
    // =============================================================================================
    typedef struct {
        longint unsigned vaddr;
        int              len;
        bit              last;
        int              acc;    // cycle the request was accepted (+DMA_PIPE)
    } rreq_s;

    rreq_s r_q      [N_RD][$];
    int    r_ackdue [N_RD][$];
    rreq_s r_cur    [N_RD];
    rreq_s r_new    [N_RD];
    int    r_state  [N_RD];
    int    r_dly    [N_RD];
    int    r_blk    [N_RD];
    int    r_nblk   [N_RD];
    int    r_gap    [N_RD];
    int    r_outst_q[N_RD];
    logic [15:0] r_lfsr_q [N_RD];

    function automatic void get_beat(input longint unsigned base,
                                     input int len,
                                     input int blk,
                                     output logic [DATA_BITS-1:0] d,
                                     output logic [BYTES-1:0]     k);
        int rem;
        int n;
        longint unsigned a;
        begin
            rem = len - blk * BYTES;
            n   = (rem > BYTES) ? BYTES : rem;
            d   = '0;
            k   = '0;
            for (int i = 0; i < n; i++) begin
                a = base + longint'(blk) * BYTES + longint'(i);
                d[i*8 +: 8] = written(a) ? card_mem[a - MEM_BASE] : 8'h00;
                k[i]        = 1'b1;
            end
        end
    endfunction

    genvar gd;
    generate
        for (gd = 0; gd < N_RD; gd++) begin : g_rd
            assign rd_req_ready[gd] = (r_outst_q[gd] < MAX_OUTSTANDING);

            always @(posedge clk) begin
                bit did_accept;
                bit did_ack;
                bit bad;
                longint unsigned lo, hi, a;
                logic [DATA_BITS-1:0] bd;
                logic [BYTES-1:0]     bk;

                if (!rst_n) begin
                    rd_tvalid[gd] <= 1'b0;
                    rd_tlast[gd]  <= 1'b0;
                    rd_tdata[gd]  <= '0;
                    rd_tkeep[gd]  <= '0;
                    rd_ack[gd]    <= 1'b0;
                    r_outst_q[gd] <= 0;
                    r_q[gd].delete(); r_ackdue[gd].delete();
                    r_state[gd] = 0; r_dly[gd] = 0; r_blk[gd] = 0; r_nblk[gd] = 0; r_gap[gd] = 0;
                    r_lfsr_q[gd] <= 16'hBEEF ^ (seed_i[15:0] + 16'(gd));
                end else begin
                    did_accept = 1'b0;
                    did_ack    = 1'b0;
                    rd_ack[gd] <= 1'b0;
                    r_lfsr_q[gd] <= {r_lfsr_q[gd][14:0],
                                     r_lfsr_q[gd][15] ^ r_lfsr_q[gd][13] ^ r_lfsr_q[gd][12] ^ r_lfsr_q[gd][10]};

                    // -- request accept, with the two ordering rules checked here ------------------
                    if (rd_req_valid[gd] && rd_req_ready[gd]) begin
                        lo = longint'(rd_req_vaddr[gd]);
                        hi = lo + longint'(rd_req_len[gd]);
                        if (rd_req_len[gd] == 0) er($sformatf("[%0d] read request with len == 0", gd));
                        if (overlaps_unacked(lo, hi))
                            er($sformatf("[%0d] read [%0h,%0h) overlaps a write that has been issued but not acked",
                                         gd, lo, hi));
                        else begin
                            bad = 1'b0;
                            for (a = lo; a < hi; a = a + 1) begin
                                if (!in_window(a)) begin
                                    er($sformatf("[%0d] read of %0h is outside the modelled card memory [%0h,%0h)",
                                                 gd, a, MEM_BASE, MEM_BASE + MEM_BYTES));
                                    bad = 1'b1;
                                    break;
                                end
                                if (!card_wr.exists(a - MEM_BASE)) begin
                                    er($sformatf("[%0d] read of byte %0h that was never written (request [%0h,%0h))",
                                                 gd, a, lo, hi));
                                    bad = 1'b1;
                                    break;
                                end
                            end
                        end
                        r_new[gd].vaddr = lo;
                        r_new[gd].len   = int'(rd_req_len[gd]);
                        r_new[gd].last  = rd_req_last[gd];
                        r_new[gd].acc   = cyc_q;
                        r_q[gd].push_back(r_new[gd]);
                        r_ackdue[gd].push_back(0);
                        did_accept = 1'b1;
                    end

                    // -- ack, in order --------------------------------------------------------------
                    if ((r_ackdue[gd].size() > 0) && (r_ackdue[gd][0] != 0) && (cyc_q >= r_ackdue[gd][0])) begin
                        void'(r_ackdue[gd].pop_front());
                        rd_ack[gd] <= 1'b1;
                        did_ack     = 1'b1;
                    end

                    // -- data engine ----------------------------------------------------------------
                    case (r_state[gd])
                        0: begin
                            if (r_q[gd].size() > 0) begin
                                r_cur[gd]   = r_q[gd][0];
                                r_dly[gd]   = lat_left(r_cur[gd].acc, rd_req_lat_i);
                                r_state[gd] = 1;
                            end
                        end
                        1: begin
                            if (r_dly[gd] <= 0) begin
                                void'(r_q[gd].pop_front());
                                r_blk[gd]  = 0;
                                r_nblk[gd] = (r_cur[gd].len + BYTES - 1) / BYTES;
                                r_gap[gd]  = 0;
                                get_beat(r_cur[gd].vaddr, r_cur[gd].len, 0, bd, bk);
                                rd_tdata[gd]  <= bd;
                                rd_tkeep[gd]  <= bk;
                                rd_tlast[gd]  <= r_cur[gd].last && (r_nblk[gd] == 1);
                                rd_tvalid[gd] <= 1'b1;
                                r_state[gd]    = 2;
                            end else begin
                                r_dly[gd] = r_dly[gd] - 1;
                            end
                        end
                        2: begin
                            if (r_gap[gd] > 0) begin
                                // Gap cycles are inserted BETWEEN beats: tvalid is never dropped
                                // once asserted and unhandshaken, which AXI4-Stream forbids.
                                r_gap[gd] = r_gap[gd] - 1;
                                if (r_gap[gd] == 0) begin
                                    get_beat(r_cur[gd].vaddr, r_cur[gd].len, r_blk[gd], bd, bk);
                                    rd_tdata[gd]  <= bd;
                                    rd_tkeep[gd]  <= bk;
                                    rd_tlast[gd]  <= r_cur[gd].last && (r_blk[gd] == r_nblk[gd]-1);
                                    rd_tvalid[gd] <= 1'b1;
                                end
                            end else if (rd_tvalid[gd] && rd_tready[gd]) begin
                                r_blk[gd] = r_blk[gd] + 1;
                                if (r_blk[gd] >= r_nblk[gd]) begin
                                    for (int j = 0; j < r_ackdue[gd].size(); j++) begin
                                        if (r_ackdue[gd][j] == 0) begin
                                            r_ackdue[gd][j] = cyc_q + ((rd_ack_lat_i < 1) ? 1 : rd_ack_lat_i);
                                            break;
                                        end
                                    end
                                    rd_tvalid[gd] <= 1'b0;
                                    rd_tlast[gd]  <= 1'b0;
                                    r_state[gd]    = 0;
                                end else if ((rd_gap_i > 0) && ((r_lfsr_q[gd] % 100) < rd_gap_i)) begin
                                    rd_tvalid[gd] <= 1'b0;
                                    r_gap[gd]      = 1 + int'(r_lfsr_q[gd][2:0]);
                                end else begin
                                    get_beat(r_cur[gd].vaddr, r_cur[gd].len, r_blk[gd], bd, bk);
                                    rd_tdata[gd]  <= bd;
                                    rd_tkeep[gd]  <= bk;
                                    rd_tlast[gd]  <= r_cur[gd].last && (r_blk[gd] == r_nblk[gd]-1);
                                    rd_tvalid[gd] <= 1'b1;
                                end
                            end
                        end
                        default: r_state[gd] = 0;
                    endcase

                    r_outst_q[gd] <= r_outst_q[gd] + (did_accept ? 1 : 0) - (did_ack ? 1 : 0);
                end
            end
        end
    endgenerate

endmodule
