`timescale 1ns / 1ps

import lynxTypes::*;

// =================================================================================================
// slot_writer bench.
//
// Models rx_dispatch's side of the contract (one-hot routed beats, `conn_pkg_issued` when a readPkg
// is accepted, `conn_space_ok` as the only gate) and the card DMA on the other side, and asks four
// questions of every case:
//
//   BYTE EXACTNESS  every byte of every segment is in the right connection's slot at the right
//                   offset, including after an unaligned cursor;
//   LANDED          landed[c] equals the number of bytes acked for c, and never runs ahead;
//   NEVER REFUSED   conn_tready never fell while a beat was offered (route_stall stays clear) --
//                   this is the property the whole redesign exists for, so it is checked on every
//                   case, not just the back-pressure one;
//   THE DMA CONTRACT the card DMA model's own asserts (normalised tkeep, exact length, in-order
//                   acks, no read of an un-acked or never-written byte) never fire.
//
// Bench conventions in this repo, learned the hard way: driven values are set at `negedge` and held
// past the posedge, handshakes are sampled at `posedge + #1`, counters are `int` so they do not
// start at X, and "\r" is not a SystemVerilog escape.
// =================================================================================================
module slot_writer_tb #(
    parameter int NCONNS = 4,
    parameter int SLOTL  = 22,
    parameter int FDEPTH = 1024
);
    localparam int CB    = (NCONNS > 1) ? $clog2(NCONNS) : 1;
    localparam int BYTES = AXI_DATA_BITS/8;

    localparam logic [VADDR_BITS-1:0] SLOT_BASE = 48'h0000_4000_0000;

    // ---------------------------------------------------------------------------------------------
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #2 clk = ~clk;          // 250 MHz

    int cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    // ---------------------------------------------------------------------------------------------
    // DUT
    // ---------------------------------------------------------------------------------------------
    logic [NCONNS-1:0]       conn_tvalid, conn_tready, conn_pkg_issued, conn_space_ok;
    logic [NCONNS-1:0]       conn_release, slot_overflow;
    logic [AXI_DATA_BITS-1:0] conn_tdata;
    logic [BYTES-1:0]        conn_tkeep;
    logic                    conn_tlast;
    logic [NCONNS-1:0][SLOTL:0] landed;
    logic                    route_stall;

    logic                    wr_req_valid, wr_req_ready, wr_req_last, wr_ack;
    logic [VADDR_BITS-1:0]   wr_req_vaddr;
    logic [LEN_BITS-1:0]     wr_req_len;
    logic                    w_tvalid, w_tready, w_tlast;
    logic [AXI_DATA_BITS-1:0] w_tdata;
    logic [BYTES-1:0]        w_tkeep;

    slot_writer #(
        .N_CONNS(NCONNS), .SLOT_LOG2(SLOTL), .FIFO_DEPTH(FDEPTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .conn_tvalid(conn_tvalid), .conn_tready(conn_tready),
        .conn_tdata(conn_tdata), .conn_tkeep(conn_tkeep), .conn_tlast(conn_tlast),
        .conn_pkg_issued(conn_pkg_issued), .conn_space_ok(conn_space_ok),
        .slot_base(SLOT_BASE), .conn_release(conn_release),
        // Every connection is up for the whole of this bench: the reservation leak that conn_down
        // exists for is a handler-level teardown, and lane_drain `ovf` / `refatal` are where it is
        // exercised end to end.
        .conn_down('0),
        .wr_req_valid(wr_req_valid), .wr_req_ready(wr_req_ready),
        .wr_req_vaddr(wr_req_vaddr), .wr_req_len(wr_req_len), .wr_req_last(wr_req_last),
        .m_axis_tvalid(w_tvalid), .m_axis_tready(w_tready),
        .m_axis_tdata(w_tdata), .m_axis_tkeep(w_tkeep), .m_axis_tlast(w_tlast),
        .wr_ack(wr_ack), .landed(landed),
        .conn_quiet(), .slot_poison(),
        .slot_overflow(slot_overflow), .route_stall(route_stall),
        .fifo_stall(), .space_stall()
    );

    // ---------------------------------------------------------------------------------------------
    // Card DMA model. The read channel is not used here; slot_reader's bench drives it.
    // ---------------------------------------------------------------------------------------------
    logic                    m_rd_req_valid [1];
    logic                    m_rd_req_ready [1];
    logic [VADDR_BITS-1:0]   m_rd_req_vaddr [1];
    logic [LEN_BITS-1:0]     m_rd_req_len   [1];
    logic                    m_rd_req_last  [1];
    logic                    m_rd_tvalid    [1];
    logic                    m_rd_tready    [1];
    logic [AXI_DATA_BITS-1:0] m_rd_tdata    [1];
    logic [BYTES-1:0]        m_rd_tkeep     [1];
    logic                    m_rd_tlast     [1];
    logic                    m_rd_ack       [1];
    logic                    model_fail;
    int                      model_errors;

    initial begin
        m_rd_req_valid[0] = 1'b0;
        m_rd_req_vaddr[0] = '0;
        m_rd_req_len[0]   = '0;
        m_rd_req_last[0]  = 1'b0;
        m_rd_tready[0]    = 1'b1;
    end

    card_dma_model #(
        .N_RD(1), .MEM_BASE(longint'(SLOT_BASE)), .MEM_BYTES(longint'(NCONNS) << SLOTL)
    ) u_dma (
        .clk(clk), .rst_n(rst_n),
        .wr_req_valid(wr_req_valid), .wr_req_ready(wr_req_ready),
        .wr_req_vaddr(wr_req_vaddr), .wr_req_len(wr_req_len), .wr_req_last(wr_req_last),
        .wr_tvalid(w_tvalid), .wr_tready(w_tready),
        .wr_tdata(w_tdata), .wr_tkeep(w_tkeep), .wr_tlast(w_tlast),
        .wr_ack(wr_ack),
        .rd_req_valid(m_rd_req_valid), .rd_req_ready(m_rd_req_ready),
        .rd_req_vaddr(m_rd_req_vaddr), .rd_req_len(m_rd_req_len), .rd_req_last(m_rd_req_last),
        .rd_tvalid(m_rd_tvalid), .rd_tready(m_rd_tready),
        .rd_tdata(m_rd_tdata), .rd_tkeep(m_rd_tkeep), .rd_tlast(m_rd_tlast), .rd_ack(m_rd_ack),
        .model_fail(model_fail), .model_errors(model_errors)
    );

    // ---------------------------------------------------------------------------------------------
    // Expected slot contents, per connection, for the current epoch (a release starts a new one).
    // ---------------------------------------------------------------------------------------------
    typedef byte unsigned bytes_t [];

    byte unsigned exp_mem [NCONNS][$];   // bytes expected at offset 0.. of slot c
    int           exp_len [NCONNS];      // = the landed value we expect
    int           src_idx [NCONNS];      // pattern cursor, so every byte in a run is distinct

    // Segment work list, in global arrival order.
    int     sl_conn [$];
    bytes_t sl_data [$];

    int errors = 0;
    string scen;

    task automatic err(input string m);
        $display("  ERROR t=%0t: %s", $time, m);
        errors = errors + 1;
    endtask

    function automatic byte unsigned pat(input int c, input int i);
        pat = byte'((c * 131) + (i * 17) + ((i >> 8) * 29) + (i >> 16));
    endfunction

    // Queue one segment of `n` bytes for connection c, and record where those bytes must end up.
    // `count_expected` is 0 for a segment we expect slot_writer to discard.
    task automatic queue_seg(input int c, input int n, input bit count_expected = 1'b1);
        bytes_t b;
        begin
            b = new[n];
            for (int i = 0; i < n; i++) begin
                b[i] = pat(c, src_idx[c] + i);
                if (count_expected) exp_mem[c].push_back(b[i]);
            end
            src_idx[c] = src_idx[c] + n;
            if (count_expected) exp_len[c] = exp_len[c] + n;
            sl_conn.push_back(c);
            sl_data.push_back(b);
        end
    endtask

    // A MinIO-shaped response: a ~630 byte header segment of its own, then full MSS body segments,
    // then a short tail -- which is what leaves the write cursor unaligned for everything after it.
    task automatic queue_response(input int c, input int hdr, input int body, input int mss = 4096);
        int left;
        begin
            queue_seg(c, hdr);
            left = body;
            while (left > mss) begin
                queue_seg(c, mss);
                left = left - mss;
            end
            if (left > 0) queue_seg(c, left);
        end
    endtask

    // ---------------------------------------------------------------------------------------------
    // rx_dispatch model. Two processes, as in the real thing: the readPkg is ISSUED against
    // conn_space_ok some time before its bytes arrive, so the reservation is genuinely tested.
    // ---------------------------------------------------------------------------------------------
    mailbox #(int) deliver_mbx = new(8);
    int            issued_n = 0;
    int            delivered_n = 0;
    int            toe_lat = 6;

    initial begin
        conn_tvalid     = '0;
        conn_tdata      = '0;
        conn_tkeep      = '0;
        conn_tlast      = 1'b0;
        conn_pkg_issued = '0;
        conn_release    = '0;
    end

    task automatic issuer(input int count);
        int k;
        begin
            for (k = 0; k < count; k++) begin
                @(negedge clk);
                while (!conn_space_ok[sl_conn[k]]) @(negedge clk);
                conn_pkg_issued             = '0;
                conn_pkg_issued[sl_conn[k]] = 1'b1;
                @(posedge clk); #1;
                @(negedge clk);
                conn_pkg_issued = '0;
                issued_n = issued_n + 1;
                deliver_mbx.put(k);
            end
        end
    endtask

    task automatic deliverer(input int count);
        int k, c, n, nbeat, off, nb;
        logic [AXI_DATA_BITS-1:0] d;
        logic [BYTES-1:0]         kp;
        begin
            for (int q = 0; q < count; q++) begin
                deliver_mbx.get(k);
                repeat (toe_lat) @(negedge clk);
                c     = sl_conn[k];
                n     = sl_data[k].size();
                nbeat = (n + BYTES - 1) / BYTES;
                for (int b = 0; b < nbeat; b++) begin
                    off = b * BYTES;
                    nb  = ((n - off) > BYTES) ? BYTES : (n - off);
                    d   = '0; kp = '0;
                    for (int j = 0; j < nb; j++) begin
                        d[j*8 +: 8] = sl_data[k][off + j];
                        kp[j]       = 1'b1;
                    end
                    @(negedge clk);
                    conn_tvalid     = '0;
                    conn_tvalid[c]  = 1'b1;
                    conn_tdata      = d;
                    conn_tkeep      = kp;
                    conn_tlast      = (b == nbeat-1);
                    forever begin
                        @(posedge clk); #1;
                        if (conn_tready[c]) break;
                    end
                end
                @(negedge clk);
                conn_tvalid = '0;
                conn_tlast  = 1'b0;
                delivered_n = delivered_n + 1;
            end
        end
    endtask

    task automatic run_traffic();
        int n;
        begin
            n = sl_conn.size();
            fork
                issuer(n);
                deliverer(n);
            join
        end
    endtask

    task automatic wait_landed(input int limit = 200000);
        int t;
        bit ok;
        begin
            t = 0; ok = 1'b0;
            while (!ok && (t < limit)) begin
                @(negedge clk);
                t  = t + 1;
                ok = 1'b1;
                for (int c = 0; c < NCONNS; c++)
                    if (int'(landed[c]) != exp_len[c]) ok = 1'b0;
            end
            if (!ok) begin
                for (int c = 0; c < NCONNS; c++)
                    if (int'(landed[c]) != exp_len[c])
                        err($sformatf("conn %0d: landed=%0d, expected %0d", c, landed[c], exp_len[c]));
            end
        end
    endtask

    task automatic check_slots();
        longint unsigned a;
        begin
            for (int c = 0; c < NCONNS; c++) begin
                for (int i = 0; i < exp_mem[c].size(); i++) begin
                    a = longint'(SLOT_BASE) + (longint'(c) << SLOTL) + longint'(i);
                    if (!u_dma.written(a)) begin
                        err($sformatf("conn %0d offset %0d: never written", c, i));
                        break;                     // one report per connection is enough
                    end else if (u_dma.peek(a) !== exp_mem[c][i]) begin
                        err($sformatf("conn %0d offset %0d: card has %02h, expected %02h",
                                      c, i, u_dma.peek(a), exp_mem[c][i]));
                        break;
                    end
                end
            end
        end
    endtask

    task automatic reset_seq();
        begin
            rst_n = 1'b0;
            repeat (8) @(negedge clk);
            rst_n = 1'b1;
            repeat (4) @(negedge clk);
        end
    endtask

    task automatic clear_lists();
        begin
            sl_conn.delete();
            sl_data.delete();
            issued_n    = 0;
            delivered_n = 0;
        end
    endtask

    // ---------------------------------------------------------------------------------------------
    // Cases
    // ---------------------------------------------------------------------------------------------
    int ncase;
    int hdr_len = 630;
    int body_len = 32768;

    initial begin
        for (int c = 0; c < NCONNS; c++) begin
            exp_len[c] = 0;
            src_idx[c] = 0;
        end
        if (!$value$plusargs("SCEN=%s", scen)) scen = "w1";
        void'($value$plusargs("TOELAT=%d", toe_lat));
        void'($value$plusargs("HDR=%d", hdr_len));
        void'($value$plusargs("BODY=%d", body_len));

        reset_seq();

        case (scen)
            // -- one connection, header segment then body segments then a short tail. Everything
            //    after the header lands at an offset that is not a multiple of 64.
            "w1": begin
                ncase = 1;
                queue_response(0, hdr_len, body_len);
                run_traffic();
                wait_landed();
                check_slots();
            end

            // -- four connections interleaved at segment granularity: the descriptor queue has to
            //    keep each segment's connection straight, and each cursor its own offset.
            "w4": begin
                ncase = (NCONNS < 4) ? NCONNS : 4;
                for (int r = 0; r < 4; r++)
                    for (int c = 0; c < ncase; c++)
                        queue_seg(c, (r == 0) ? hdr_len : ((r == 3) ? 1000 : 4096));
                run_traffic();
                wait_landed();
                check_slots();
            end

            // -- twenty-four connections.
            "w24": begin
                ncase = NCONNS;
                for (int r = 0; r < 3; r++)
                    for (int c = 0; c < ncase; c++)
                        queue_seg(c, (r == 0) ? hdr_len : ((r == 2) ? 777 : 4096));
                run_traffic();
                wait_landed();
                check_slots();
            end

            // -- the DMA write data channel refuses half the time. The rx side must still never be
            //    refused: that is route_stall, checked for every case at the end.
            "wbp": begin
                ncase = (NCONNS < 4) ? NCONNS : 4;
                for (int c = 0; c < ncase; c++) queue_response(c, hdr_len, body_len);
                run_traffic();
                wait_landed();
                check_slots();
            end

            // -- ack latency sweep. At 200 cycles the completion queue is the throttle, and the
            //    shared fifo has to absorb the difference without ever refusing the rx side.
            "wlat": begin
                ncase = (NCONNS < 4) ? NCONNS : 4;
                for (int c = 0; c < ncase; c++) queue_response(c, hdr_len, body_len);
                run_traffic();
                wait_landed();
                check_slots();
            end

            // -- a segment that would cross the end of its slot is discarded WHOLE, the sticky bit
            //    latches, nothing is written past the slot, and everything the connection sends
            //    afterwards is dropped too (its response has a hole in it either way).
            "wovf": begin
                int fits;
                ncase = 2;
                fits  = (1 << SLOTL) / 4096;             // full segments that fit
                for (int i = 0; i < fits; i++) queue_seg(0, 4096);
                queue_seg(2, 4096);                      // a healthy neighbour, to prove containment
                queue_seg(0, 4096, 1'b0);                // crosses the end -> discarded
                queue_seg(0, 1024, 1'b0);                // and so is everything after it
                queue_seg(2, 4096);
                run_traffic();
                wait_landed();
                check_slots();
                if (!slot_overflow[0]) err("slot_overflow[0] did not latch");
                if (slot_overflow[2])  err("slot_overflow[2] latched on the healthy connection");
                // slot 1 is untouched, and its first byte is exactly where a segment running off
                // the end of slot 0 would have landed.
                if (u_dma.written(longint'(SLOT_BASE) + (longint'(1) << SLOTL)))
                    err("a byte was written past the end of slot 0, into slot 1");
            end

            // -- two responses in a row on one connection with a release in between: the second one
            //    must land at offset 0 again, and landed must restart from 0.
            "wrel": begin
                ncase = 1;
                queue_response(0, hdr_len, 8192);
                run_traffic();
                wait_landed();
                check_slots();

                @(negedge clk);
                conn_release    = '0;
                conn_release[0] = 1'b1;
                @(posedge clk); #1;
                @(negedge clk);
                conn_release = '0;
                repeat (4) @(negedge clk);
                if (landed[0] !== '0) err($sformatf("landed[0]=%0d after release, expected 0", landed[0]));

                // new epoch
                exp_mem[0].delete();
                exp_len[0] = 0;
                clear_lists();
                queue_response(0, hdr_len, 8192);
                run_traffic();
                wait_landed();
                check_slots();
            end

            default: err($sformatf("unknown scenario '%s'", scen));
        endcase

        repeat (20) @(negedge clk);

        if (route_stall)      err("route_stall latched: a routed beat was refused");
        if (model_errors > 0) err($sformatf("card DMA model reported %0d error(s)", model_errors));
        if (scen != "wovf")
            for (int c = 0; c < NCONNS; c++)
                if (slot_overflow[c]) err($sformatf("slot_overflow[%0d] latched unexpectedly", c));

        $display("slot_writer_tb[%0s,N=%0d]: %0s  (%0d segments, %0d cycles, %0d error(s))",
                 scen, NCONNS, (errors == 0) ? "PASS" : "FAIL", delivered_n, cyc, errors);
        $finish;
    end

    // A global watchdog: a wedge must end the run, not hang the regression.
    initial begin
        #2_000_000;
        $display("slot_writer_tb[%0s,N=%0d]: FAIL  (timeout at %0t)", scen, NCONNS, $time);
        $finish;
    end

endmodule
