`timescale 1ns / 1ps

import lynxTypes::*;

// =================================================================================================
// slot_reader bench -- end to end, with the REAL strip_http behind the reader.
//
// HTTP response bytes go in at the receive side of a real slot_writer, through a real card DMA
// model, out of a real slot_reader, into a real strip_http, and the bench compares the BODY bytes
// that come out with the body bytes it put in. Nothing between the two is stubbed, which is the
// only way to catch the things that actually break here: an off-by-one in the unaligned cursor
// after the header segment, a read issued before its write was acked, a read split at RD_MAX that
// lands a beat in the wrong place, a residue left in the slot when a response is retired.
//
// ONE SHARED READ CHANNEL (2026-09-22)
// ------------------------------------
// The readers no longer have a card read channel each: build-123 failed route_design with five card
// AXI streams, so there is one, and `slot_rd_share` sits between the readers and it holding a
// receive fifo and a credit per decoder. That module is in this bench's path by DEFAULT (SHARE=1)
// precisely because it is the new risk; SHARE=0 restores the direct wiring of WP1 for a bisect.
//
// AND THE ONE MEASUREMENT THIS WORK PACKAGE EXISTS FOR
// ---------------------------------------------------
// Scenario `rslow` runs decoder 0's sink at one beat every SLOWDIV cycles while decoder 1's runs at
// one beat every FASTDIV, and prints both rates in beats per cycle. In build-119 that experiment
// kills the whole receive path: the slow lane's 128 KiB fifo fills, conn_space_ok drops,
// rx_dispatch's arrival-ordered head blocks, and every other lane starves (ADR-5, "Lanes are
// coupled head-of-line"). `rsolo` is the same run with the slow decoder absent.
//
// READ THE TWO NUMBERS TOGETHER, AND MIND WHAT FASTDIV MEANS.
// At FASTDIV=1 the fast decoder's sink asks for 16 GB/s, which is the WHOLE shared channel, so
// whatever the slow decoder legitimately takes -- its own drain rate, plus one 2 x RD_MAX fifo fill
// -- comes off the fast decoder's number. That is arithmetic about one 512-bit channel, not
// coupling, and no design with one channel can avoid it. At FASTDIV=4 (4 GB/s, still twice the
// fastest intake ADR-5 ever measured on a real decoder) both fit, and the fast decoder must then be
// EXACTLY as fast as it is alone. That equality is the property this work package has to deliver,
// and it is what the pass threshold is set against; the FASTDIV=1 pair is reported for the record.
//
// Bench conventions: values are driven at `negedge` and held past the posedge, handshakes are
// sampled at `posedge` + `#1`, counters are `int` so they never start at X, and CRLF goes in as
// 8'h0D, 8'h0A because "\r" is not a SystemVerilog escape.
// =================================================================================================
module slot_reader_tb #(
    parameter int NCONNS = 1,
    parameter int NRD    = 1,
    parameter int SLOTL  = 22,
    parameter int RDMAX  = 16384,
    // 1: the readers reach the card model through slot_rd_share on ONE channel (the real topology).
    // 0: one model read channel per reader, as WP1 wired it.
    parameter int SHARE  = 1
);
    localparam int CB    = (NCONNS > 1) ? $clog2(NCONNS) : 1;
    localparam int BYTES = AXI_DATA_BITS/8;

    localparam logic [VADDR_BITS-1:0] SLOT_BASE = 48'h0000_8000_0000;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #2 clk = ~clk;                 // 250 MHz

    int cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    int errors = 0;
    string scen;

    task automatic err(input string m);
        $display("  ERROR t=%0t: %s", $time, m);
        errors = errors + 1;
    endtask

    // ---------------------------------------------------------------------------------------------
    // slot_writer + the receive side
    // ---------------------------------------------------------------------------------------------
    logic [NCONNS-1:0]        conn_tvalid, conn_tready, conn_pkg_issued, conn_space_ok;
    logic [AXI_DATA_BITS-1:0] conn_tdata;
    logic [BYTES-1:0]         conn_tkeep;
    logic                     conn_tlast;
    logic [NCONNS-1:0]        wr_release, slot_overflow;
    logic [NCONNS-1:0][SLOTL:0] landed;
    logic                     route_stall;

    logic                     wr_req_valid, wr_req_ready, wr_req_last, wr_ack;
    logic [VADDR_BITS-1:0]    wr_req_vaddr;
    logic [LEN_BITS-1:0]      wr_req_len;
    logic                     w_tvalid, w_tready, w_tlast;
    logic [AXI_DATA_BITS-1:0] w_tdata;
    logic [BYTES-1:0]         w_tkeep;

    slot_writer #(.N_CONNS(NCONNS), .SLOT_LOG2(SLOTL), .FIFO_DEPTH(1024)) u_wr (
        .clk(clk), .rst_n(rst_n),
        .conn_tvalid(conn_tvalid), .conn_tready(conn_tready),
        .conn_tdata(conn_tdata), .conn_tkeep(conn_tkeep), .conn_tlast(conn_tlast),
        .conn_pkg_issued(conn_pkg_issued), .conn_space_ok(conn_space_ok),
        .slot_base(SLOT_BASE), .conn_release(wr_release),
        .wr_req_valid(wr_req_valid), .wr_req_ready(wr_req_ready),
        .wr_req_vaddr(wr_req_vaddr), .wr_req_len(wr_req_len), .wr_req_last(wr_req_last),
        .m_axis_tvalid(w_tvalid), .m_axis_tready(w_tready),
        .m_axis_tdata(w_tdata), .m_axis_tkeep(w_tkeep), .m_axis_tlast(w_tlast),
        .wr_ack(wr_ack), .landed(landed),
        .slot_overflow(slot_overflow), .route_stall(route_stall)
    );

    // ---------------------------------------------------------------------------------------------
    // Card DMA. ONE read channel at SHARE=1 -- the real topology since 2026-09-22 -- with
    // slot_rd_share standing between it and the readers. At SHARE=0 the model gets a channel per
    // reader and the readers are wired to it directly, which is what WP1 measured.
    // ---------------------------------------------------------------------------------------------
    localparam int MRD = SHARE ? 1 : NRD;

    // reader side (slot_reader[d] <-> slot_rd_share, or straight to the model)
    logic                     rd_req_valid [NRD];
    logic                     rd_req_ready [NRD];
    logic [VADDR_BITS-1:0]    rd_req_vaddr [NRD];
    logic [LEN_BITS-1:0]      rd_req_len   [NRD];
    logic                     rd_req_last  [NRD];
    logic                     rd_tvalid    [NRD];
    logic                     rd_tready    [NRD];
    logic [AXI_DATA_BITS-1:0] rd_tdata     [NRD];
    logic [BYTES-1:0]         rd_tkeep     [NRD];
    logic                     rd_tlast     [NRD];

    // model side
    logic                     m_rd_req_valid [MRD];
    logic                     m_rd_req_ready [MRD];
    logic [VADDR_BITS-1:0]    m_rd_req_vaddr [MRD];
    logic [LEN_BITS-1:0]      m_rd_req_len   [MRD];
    logic                     m_rd_req_last  [MRD];
    logic                     m_rd_tvalid    [MRD];
    logic                     m_rd_tready    [MRD];
    logic [AXI_DATA_BITS-1:0] m_rd_tdata     [MRD];
    logic [BYTES-1:0]         m_rd_tkeep     [MRD];
    logic                     m_rd_tlast     [MRD];
    logic                     m_rd_ack       [MRD];
    logic                     model_fail;
    int                       model_errors;

    logic            share_order_err, share_fifo_err, share_len_err;
    logic [NRD-1:0]  share_credit_ok;

    card_dma_model #(
        .N_RD(MRD), .MEM_BASE(longint'(SLOT_BASE)), .MEM_BYTES(longint'(NCONNS) << SLOTL)
    ) u_dma (
        .clk(clk), .rst_n(rst_n),
        .wr_req_valid(wr_req_valid), .wr_req_ready(wr_req_ready),
        .wr_req_vaddr(wr_req_vaddr), .wr_req_len(wr_req_len), .wr_req_last(wr_req_last),
        .wr_tvalid(w_tvalid), .wr_tready(w_tready),
        .wr_tdata(w_tdata), .wr_tkeep(w_tkeep), .wr_tlast(w_tlast), .wr_ack(wr_ack),
        .rd_req_valid(m_rd_req_valid), .rd_req_ready(m_rd_req_ready),
        .rd_req_vaddr(m_rd_req_vaddr), .rd_req_len(m_rd_req_len), .rd_req_last(m_rd_req_last),
        .rd_tvalid(m_rd_tvalid), .rd_tready(m_rd_tready),
        .rd_tdata(m_rd_tdata), .rd_tkeep(m_rd_tkeep), .rd_tlast(m_rd_tlast), .rd_ack(m_rd_ack),
        .model_fail(model_fail), .model_errors(model_errors)
    );

    generate
    if (SHARE) begin : g_share
        logic                  ch_req_valid, ch_req_ready, ch_req_last;
        logic [VADDR_BITS-1:0] ch_req_vaddr;
        logic [LEN_BITS-1:0]   ch_req_len;
        logic                  ch_tvalid, ch_tready, ch_tlast;
        logic [AXI_DATA_BITS-1:0] ch_tdata;
        logic [BYTES-1:0]         ch_tkeep;

        slot_rd_share #(.N_RD(NRD), .RD_MAX(RDMAX)) u_share (
            .clk(clk), .rst_n(rst_n),
            .rd_req_valid(rd_req_valid), .rd_req_ready(rd_req_ready),
            .rd_req_vaddr(rd_req_vaddr), .rd_req_len(rd_req_len), .rd_req_last(rd_req_last),
            .rd_tvalid(rd_tvalid), .rd_tready(rd_tready),
            .rd_tdata(rd_tdata), .rd_tkeep(rd_tkeep), .rd_tlast(rd_tlast),
            .ch_req_valid(ch_req_valid), .ch_req_ready(ch_req_ready),
            .ch_req_vaddr(ch_req_vaddr), .ch_req_len(ch_req_len), .ch_req_last(ch_req_last),
            .ch_tvalid(ch_tvalid), .ch_tready(ch_tready),
            .ch_tdata(ch_tdata), .ch_tkeep(ch_tkeep), .ch_tlast(ch_tlast),
            .order_err(share_order_err), .fifo_err(share_fifo_err), .len_err(share_len_err),
            .credit_ok(share_credit_ok), .oq_occ()
        );

        assign m_rd_req_valid[0] = ch_req_valid;
        assign ch_req_ready      = m_rd_req_ready[0];
        assign m_rd_req_vaddr[0] = ch_req_vaddr;
        assign m_rd_req_len[0]   = ch_req_len;
        assign m_rd_req_last[0]  = ch_req_last;
        assign ch_tvalid         = m_rd_tvalid[0];
        assign m_rd_tready[0]    = ch_tready;
        assign ch_tdata          = m_rd_tdata[0];
        assign ch_tkeep          = m_rd_tkeep[0];
        assign ch_tlast          = m_rd_tlast[0];
    end else begin : g_direct
        assign share_order_err = 1'b0;
        assign share_fifo_err  = 1'b0;
        assign share_len_err   = 1'b0;
        assign share_credit_ok = '1;
        for (genvar gm = 0; gm < NRD; gm++) begin : g_wire
            assign m_rd_req_valid[gm] = rd_req_valid[gm];
            assign rd_req_ready[gm]   = m_rd_req_ready[gm];
            assign m_rd_req_vaddr[gm] = rd_req_vaddr[gm];
            assign m_rd_req_len[gm]   = rd_req_len[gm];
            assign m_rd_req_last[gm]  = rd_req_last[gm];
            assign rd_tvalid[gm]      = m_rd_tvalid[gm];
            assign m_rd_tready[gm]    = rd_tready[gm];
            assign rd_tdata[gm]       = m_rd_tdata[gm];
            assign rd_tkeep[gm]       = m_rd_tkeep[gm];
            assign rd_tlast[gm]       = m_rd_tlast[gm];
        end
    end
    endgenerate

    // Latched: this reader was ever held for want of fifo room. `rstall` requires it to be true --
    // that is what "the credit bound, and the channel kept running anyway" looks like.
    logic [NRD-1:0] credit_seen_q;
    always_ff @(posedge clk) begin
        if (!rst_n) credit_seen_q <= '0;
        else        credit_seen_q <= credit_seen_q | ~share_credit_ok;
    end

    // ---------------------------------------------------------------------------------------------
    // One reader + one framer + one sink per decoder
    // ---------------------------------------------------------------------------------------------
    logic                     ent_valid [NRD];
    logic                     ent_ready [NRD];
    logic [CB-1:0]            ent_conn  [NRD];
    logic [NCONNS-1:0]        rd_release[NRD];
    logic                     entry_done[NRD];
    logic                     residue_err[NRD];

    logic                     fr_tvalid [NRD];
    logic                     fr_tready [NRD];
    logic [AXI_DATA_BITS-1:0] fr_tdata  [NRD];
    logic [BYTES-1:0]         fr_tkeep  [NRD];
    logic                     fr_tlast  [NRD];

    logic                     sh_tvalid [NRD];
    logic                     sh_tready [NRD];
    logic [AXI_DATA_BITS-1:0] sh_tdata  [NRD];
    logic [BYTES-1:0]         sh_tkeep  [NRD];
    logic                     sh_tlast  [NRD];
    logic                     sh_done   [NRD];
    logic                     sh_ack    [NRD];
    logic                     sh_error  [NRD];

    // The writer's release input is the OR of what the readers pulse: a connection belongs to
    // exactly one decoder, so at most one of them ever drives a given bit.
    always_comb begin
        wr_release = '0;
        for (int d = 0; d < NRD; d++) wr_release = wr_release | rd_release[d];
    end

    // Sink rate control, per decoder. 1 = a beat every cycle. `sink_stop` is separate from a huge
    // divider on purpose: it can be lifted in one cycle, so a decoder can be held long enough to
    // exhaust its receive credit and then let go without waiting out a counter.
    int   sink_div  [NRD];
    int   sink_ph   [NRD];
    logic sink_stop [NRD];

    byte unsigned got    [NRD][$];
    int           n_done [NRD];
    int           n_last [NRD];
    int           beats  [NRD];
    int           t_first[NRD];
    int           t_last [NRD];
    logic         sh_body_last [NRD];   // the head entry's body_last, reader -> framer

    genvar gd;
    generate
        for (gd = 0; gd < NRD; gd++) begin : g_dec
            slot_reader #(
                .N_CONNS(NCONNS), .SLOT_LOG2(SLOTL), .RD_MAX(RDMAX), .ENTRY_DEPTH(64)
            ) u_rd (
                .clk(clk), .rst_n(rst_n),
                .entry_valid(ent_valid[gd]), .entry_ready(ent_ready[gd]), .entry_conn(ent_conn[gd]),
                // The entry is {conn, chunk_bytes, body_last} now. Every response in this bench is
                // a whole decoder stream, so body_last is 1 -- which is what the framer below used
                // to be told directly, and is now told through the entry queue.
                .entry_chunk_bytes(32'd0), .entry_body_last(1'b1),
                // Nothing here tears a connection down mid-response; handler_slots' teardown is
                // what drives this, and lane_drain's `refatal` is where it is exercised.
                .flush(1'b0), .flush_busy(),
                .landed(landed), .slot_base(SLOT_BASE),
                .rd_req_valid(rd_req_valid[gd]), .rd_req_ready(rd_req_ready[gd]),
                .rd_req_vaddr(rd_req_vaddr[gd]), .rd_req_len(rd_req_len[gd]),
                .rd_req_last(rd_req_last[gd]),
                .s_axis_tvalid(rd_tvalid[gd]), .s_axis_tready(rd_tready[gd]),
                .s_axis_tdata(rd_tdata[gd]), .s_axis_tkeep(rd_tkeep[gd]), .s_axis_tlast(rd_tlast[gd]),
                .m_axis_tvalid(fr_tvalid[gd]), .m_axis_tready(fr_tready[gd]),
                .m_axis_tdata(fr_tdata[gd]), .m_axis_tkeep(fr_tkeep[gd]), .m_axis_tlast(fr_tlast[gd]),
                .resp_done(sh_done[gd]), .resp_ack(sh_ack[gd]), .body_last(sh_body_last[gd]),
                .conn_release(rd_release[gd]), .entry_done(entry_done[gd]),
                .residue_err(residue_err[gd]),
                .head_chunk_bytes(), .busy(), .entry_occ(), .state_debug()
            );

            strip_http u_sh (
                .clk(clk), .rst_n(rst_n),
                .clear(1'b0), .enable(1'b1),
                // Every response here is a whole decoder stream, so its last body beat carries
                // tlast -- which is also how the sink counts responses. It comes from the reader's
                // head entry now, exactly as it does in handler_slots.
                .body_last(sh_body_last[gd]), .resp_ack(sh_ack[gd]),
                .s_axis_tvalid(fr_tvalid[gd]), .s_axis_tdata(fr_tdata[gd]),
                .s_axis_tkeep(fr_tkeep[gd]), .s_axis_tlast(fr_tlast[gd]),
                .s_axis_tready(fr_tready[gd]),
                .m_axis_tvalid(sh_tvalid[gd]), .m_axis_tdata(sh_tdata[gd]),
                .m_axis_tkeep(sh_tkeep[gd]), .m_axis_tlast(sh_tlast[gd]),
                .m_axis_tready(sh_tready[gd]),
                .out_w0(), .out_w1(), .out_w0_valid(), .out_w1_valid(),
                .resp_done(sh_done[gd]), .resp_dirty(), .resp_error(sh_error[gd]),
                .status_ascii(), .status_ok(), .content_length(), .body_remaining(),
                .out_payload_idx()
            );

            // Decoder sink: accepts one beat every sink_div cycles and keeps every byte.
            assign sh_tready[gd] = (sink_ph[gd] == 0) && !sink_stop[gd];

            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    sink_ph[gd] <= 0;
                end else begin
                    sink_ph[gd] <= (sink_ph[gd] == 0) ? (sink_div[gd] - 1) : (sink_ph[gd] - 1);
                    if (sh_tvalid[gd] && sh_tready[gd]) begin
                        for (int i = 0; i < BYTES; i++)
                            if (sh_tkeep[gd][i]) got[gd].push_back(sh_tdata[gd][i*8 +: 8]);
                        beats[gd] <= beats[gd] + 1;
                        if (beats[gd] == 0) t_first[gd] <= cyc;
                        t_last[gd] <= cyc;
                        if (sh_tlast[gd]) n_last[gd] <= n_last[gd] + 1;
                    end
                    if (entry_done[gd]) n_done[gd] <= n_done[gd] + 1;
                end
            end
        end
    endgenerate

    // ---------------------------------------------------------------------------------------------
    // Traffic generation
    // ---------------------------------------------------------------------------------------------
    typedef byte unsigned bytes_t [];

    byte unsigned exp_body [NRD][$];     // body bytes the decoder must see, in entry order
    int           src_idx  [NCONNS];

    int     sl_conn [$];
    bytes_t sl_data [$];

    task automatic push_str(ref byte unsigned out[$], input string s);
        for (int i = 0; i < s.len(); i++) out.push_back(byte'(s[i]));
    endtask
    task automatic push_crlf(ref byte unsigned out[$]);
        out.push_back(8'h0D);
        out.push_back(8'h0A);
    endtask

    // A MinIO-shaped 206 header, padded to exactly `target` bytes so the body starts at a byte
    // offset that is not a multiple of anything convenient.
    task automatic make_header(ref byte unsigned out[$], input int body_len, input int target);
        int pad;
        begin
            push_str(out, "HTTP/1.1 206 Partial Content");           push_crlf(out);
            push_str(out, "Accept-Ranges: bytes");                   push_crlf(out);
            push_str(out, "Content-Type: application/octet-stream"); push_crlf(out);
            push_str(out, $sformatf("Content-Length: %0d", body_len)); push_crlf(out);
            push_str(out, "Server: MinIO");                          push_crlf(out);
            push_str(out, "ETag: \"0123456789abcdef0123456789abcdef\""); push_crlf(out);
            // pad: "X-Pad: " + n 'a' + CRLF, then the blank line
            pad = target - out.size() - 2 - 7 - 2;
            if (pad < 0) pad = 0;
            push_str(out, "X-Pad: ");
            for (int i = 0; i < pad; i++) out.push_back(8'h61);
            push_crlf(out);
            push_crlf(out);
        end
    endtask

    function automatic byte unsigned pat(input int c, input int i);
        pat = byte'((c * 131) + (i * 17) + ((i >> 8) * 29) + (i >> 16));
    endfunction

    task automatic queue_seg(input int c, ref byte unsigned src[$], input int from, input int n);
        bytes_t b;
        begin
            b = new[n];
            for (int i = 0; i < n; i++) b[i] = src[from + i];
            sl_conn.push_back(c);
            sl_data.push_back(b);
        end
    endtask

    // One whole response for connection c, chopped the way the TOE delivers it: the header in a
    // segment of its own, then MSS-sized body segments, then a short tail.
    task automatic queue_response(input int c, input int d, input int body_len,
                                  input int hdr_len = 630, input int mss = 4096);
        byte unsigned resp[$];
        int pos, n;
        begin
            resp.delete();
            make_header(resp, body_len, hdr_len);
            for (int i = 0; i < body_len; i++) begin
                resp.push_back(pat(c, src_idx[c] + i));
                exp_body[d].push_back(pat(c, src_idx[c] + i));
            end
            src_idx[c] = src_idx[c] + body_len;

            queue_seg(c, resp, 0, hdr_len);
            pos = hdr_len;
            while (pos < resp.size()) begin
                n = resp.size() - pos;
                if (n > mss) n = mss;
                queue_seg(c, resp, pos, n);
                pos = pos + n;
            end
        end
    endtask

    // Re-order the work list so the connections' segments arrive round robin rather than one
    // response at a time -- which is what the wire actually does with several connections open,
    // and what makes the descriptor queue keep each segment's connection straight.
    task automatic interleave();
        int     idxq [NCONNS][$];
        int     nc [$];
        bytes_t nd [$];
        bit     any;
        begin
            for (int i = 0; i < sl_conn.size(); i++) idxq[sl_conn[i]].push_back(i);
            any = 1'b1;
            while (any) begin
                any = 1'b0;
                for (int c = 0; c < NCONNS; c++) begin
                    if (idxq[c].size() > 0) begin
                        nc.push_back(sl_conn[idxq[c][0]]);
                        nd.push_back(sl_data[idxq[c][0]]);
                        void'(idxq[c].pop_front());
                        any = 1'b1;
                    end
                end
            end
            sl_conn = nc;
            sl_data = nd;
        end
    endtask

    mailbox #(int) deliver_mbx = new(8);
    int            toe_lat = 6;

    initial begin
        conn_tvalid     = '0;
        conn_tdata      = '0;
        conn_tkeep      = '0;
        conn_tlast      = 1'b0;
        conn_pkg_issued = '0;
        for (int d = 0; d < NRD; d++) begin
            ent_valid[d] = 1'b0;
            ent_conn[d]  = '0;
        end
    end

    task automatic issuer(input int count);
        begin
            for (int k = 0; k < count; k++) begin
                @(negedge clk);
                while (!conn_space_ok[sl_conn[k]]) @(negedge clk);
                conn_pkg_issued             = '0;
                conn_pkg_issued[sl_conn[k]] = 1'b1;
                @(posedge clk); #1;
                @(negedge clk);
                conn_pkg_issued = '0;
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
                    conn_tvalid    = '0;
                    conn_tvalid[c] = 1'b1;
                    conn_tdata     = d;
                    conn_tkeep     = kp;
                    conn_tlast     = (b == nbeat-1);
                    forever begin
                        @(posedge clk); #1;
                        if (conn_tready[c]) break;
                    end
                end
                @(negedge clk);
                conn_tvalid = '0;
                conn_tlast  = 1'b0;
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
            sl_conn.delete();
            sl_data.delete();
        end
    endtask

    task automatic push_entry(input int d, input int c);
        begin
            @(negedge clk);
            ent_valid[d] = 1'b1;
            ent_conn[d]  = CB'(c);
            forever begin
                @(posedge clk); #1;
                if (ent_ready[d]) break;
            end
            @(negedge clk);
            ent_valid[d] = 1'b0;
        end
    endtask

    task automatic wait_done(input int d, input int n, input int limit = 400000);
        int t;
        begin
            t = 0;
            while ((n_done[d] < n) && (t < limit)) begin
                @(negedge clk);
                t = t + 1;
            end
            if (n_done[d] < n)
                err($sformatf("decoder %0d: %0d of %0d responses retired (resp_done never came)",
                              d, n_done[d], n));
        end
    endtask

    task automatic check_body(input int d);
        begin
            if (got[d].size() != exp_body[d].size()) begin
                err($sformatf("decoder %0d: %0d body bytes out, expected %0d",
                              d, got[d].size(), exp_body[d].size()));
            end else begin
                for (int i = 0; i < got[d].size(); i++) begin
                    if (got[d][i] !== exp_body[d][i]) begin
                        err($sformatf("decoder %0d: body byte %0d is %02h, expected %02h",
                                      d, i, got[d][i], exp_body[d][i]));
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

    // ---------------------------------------------------------------------------------------------
    // Cases
    // ---------------------------------------------------------------------------------------------
    int body_len = 32768;
    int hdr_len  = 630;
    int slowdiv  = 16;
    int fastdiv  = 1;
    int slowoff  = 0;
    // The floor decoder 1 must reach, as a PERCENTAGE of the rate its own sink allows (1/fastdiv).
    // run.sh sets it per case, because what it is asking differs: at fastdiv 1 the sinks ask for
    // more than one shared channel can carry and the number is a bandwidth split; at fastdiv 4 they
    // do not, and anything short of ~100% would be coupling. See the header.
    int rminp    = 80;
    real rate0, rate1, target1;

    // Mixed request shapes for `r4x`: four bodies that split at RD_MAX differently (at 16 KiB:
    // one read, one read, three reads, five reads) behind four different header lengths, so no two
    // decoders' cursors are aligned the same way.
    int mix_body [4] = '{1400, 8192, 40000, 70000};
    int mix_hdr  [4] = '{630, 217, 1024, 345};

    initial begin
        for (int c = 0; c < NCONNS; c++) src_idx[c] = 0;
        for (int d = 0; d < NRD; d++) begin
            sink_div[d]  = 1;
            sink_stop[d] = 1'b0;
            n_done[d]    = 0;
            n_last[d]    = 0;
            beats[d]     = 0;
            t_first[d]   = 0;
            t_last[d]    = 0;
        end
        if (!$value$plusargs("SCEN=%s", scen)) scen = "r1";
        void'($value$plusargs("BODY=%d", body_len));
        void'($value$plusargs("HDR=%d",  hdr_len));
        void'($value$plusargs("TOELAT=%d", toe_lat));
        void'($value$plusargs("SLOWDIV=%d", slowdiv));
        void'($value$plusargs("FASTDIV=%d", fastdiv));
        void'($value$plusargs("SLOWOFF=%d", slowoff));
        void'($value$plusargs("RMINP=%d", rminp));

        reset_seq();

        case (scen)
            // -- one connection end to end. The entry is queued BEFORE any byte has landed, which
            //    is the normal case and must simply wait.
            "r1", "rmax", "rgap": begin
                push_entry(0, 0);
                queue_response(0, 0, body_len, hdr_len);
                run_traffic();
                wait_done(0, 1);
                check_body(0);
                if (n_last[0] != 1) err($sformatf("decoder 0: %0d tlast(s), expected 1", n_last[0]));
            end

            // -- four connections over two decoders, segments interleaved. Decoder d serves conns
            //    d and d+2, in that order.
            "r4": begin
                for (int d = 0; d < NRD; d++)
                    for (int c = d; c < NCONNS; c = c + NRD) push_entry(d, c);
                for (int c = 0; c < NCONNS; c++) queue_response(c, c % NRD, body_len, hdr_len);
                interleave();
                run_traffic();
                for (int d = 0; d < NRD; d++) wait_done(d, NCONNS/NRD);
                for (int d = 0; d < NRD; d++) check_body(d);
            end

            // -- two responses in a row on one connection, with the release in between. The second
            //    must land at offset 0 of the slot again and frame from a clean cursor.
            "rtwo": begin
                push_entry(0, 0);
                queue_response(0, 0, body_len, hdr_len);
                run_traffic();
                wait_done(0, 1);
                repeat (10) @(negedge clk);
                if (landed[0] !== '0)
                    err($sformatf("landed[0]=%0d after the release, expected 0", landed[0]));
                push_entry(0, 0);
                queue_response(0, 0, body_len/2, hdr_len);
                run_traffic();
                wait_done(0, 2);
                check_body(0);
                if (n_last[0] != 2) err($sformatf("decoder 0: %0d tlast(s), expected 2", n_last[0]));
            end

            // -- FOUR READERS ON THE ONE SHARED CHANNEL, mixed request shapes, lumpy delivery.
            //    Every decoder serves its own connection, the bodies split at RD_MAX into 1, 1, 3
            //    and 5 reads behind four different header lengths, the segments are interleaved on
            //    the wire and run.sh adds DMA_RD_GAP. The check is byte exactness on all four: an
            //    in-order demux that mis-counts one beat puts one decoder's bytes in another's body
            //    and every one of them then fails.
            "r4x": begin
                for (int d = 0; d < NRD; d++) push_entry(d, d);
                for (int c = 0; c < NCONNS; c++)
                    queue_response(c, c, mix_body[c % 4], mix_hdr[c % 4]);
                interleave();
                run_traffic();
                for (int d = 0; d < NRD; d++) wait_done(d, 1);
                for (int d = 0; d < NRD; d++) begin
                    check_body(d);
                    if (n_last[d] != 1)
                        err($sformatf("decoder %0d: %0d tlast(s), expected 1", d, n_last[d]));
                end
            end

            // -- CREDIT EXHAUSTION. Decoder 0's sink is stopped dead with its reader holding two
            //    outstanding reads, so its receive fifo fills and slot_rd_share refuses it credit.
            //    Decoder 1 must then run to completion anyway: that is the whole claim -- a decoder
            //    that has stopped consuming stops ASKING, and the shared channel keeps serving
            //    everybody else instead of being held by the head of the queue. Afterwards
            //    decoder 0 is let go and must still be byte-exact, since nothing was dropped.
            "rstall": begin
                sink_stop[0] = 1'b1;
                queue_response(0, 0, body_len, hdr_len);
                queue_response(1, 1, body_len, hdr_len);
                run_traffic();
                repeat (50) @(negedge clk);
                push_entry(0, 0);
                push_entry(1, 1);
                wait_done(1, 1);
                check_body(1);
                rate1 = (t_last[1] > t_first[1])
                        ? real'(beats[1]) / real'(t_last[1] - t_first[1] + 1) : 0.0;
                $display("  decoder1 %0d beats in %0d cycles = %.4f beats/cycle (decoder 0 stopped)",
                         beats[1], t_last[1]-t_first[1]+1, rate1);
                if (!credit_seen_q[0])
                    err("decoder 0 never ran out of receive credit -- the case proves nothing");
                if (rate1 < real'(rminp) / 100.0)
                    err($sformatf("decoder 1 ran at %.4f beats/cycle with a stopped neighbour, expected >= %.2f",
                                  rate1, real'(rminp) / 100.0));
                sink_stop[0] = 1'b0;
                wait_done(0, 1);
                check_body(0);
            end

            // -- THE COUPLING EXPERIMENT. Both slots are filled first so neither decoder is waiting
            //    on the wire; then decoder 0 drains at one beat every SLOWDIV cycles while decoder 1
            //    drains at one beat every FASTDIV. Decoder 1's rate is the number this work package
            //    is for, and it is read against 1/FASTDIV -- see the header on why FASTDIV matters.
            "rslow", "rsolo": begin
                sink_div[0] = (scen == "rsolo") ? 1 : slowdiv;
                sink_div[1] = fastdiv;
                if (scen == "rsolo") slowoff = 1;
                queue_response(0, 0, body_len, hdr_len);
                queue_response(1, 1, body_len, hdr_len);
                run_traffic();
                // everything is in HBM now
                repeat (50) @(negedge clk);
                if (!slowoff) push_entry(0, 0);
                push_entry(1, 1);
                wait_done(1, 1);
                check_body(1);
                if (!slowoff) begin
                    wait_done(0, 1);
                    check_body(0);
                end
                rate0 = (t_last[0] > t_first[0])
                        ? real'(beats[0]) / real'(t_last[0] - t_first[0] + 1) : 0.0;
                rate1 = (t_last[1] > t_first[1])
                        ? real'(beats[1]) / real'(t_last[1] - t_first[1] + 1) : 0.0;
                target1 = (real'(rminp) / 100.0) / real'(fastdiv);
                $display("  decoder0 %0d beats in %0d cycles = %.4f beats/cycle (sink 1/%0d)",
                         beats[0], t_last[0]-t_first[0]+1, rate0, sink_div[0]);
                $display("  decoder1 %0d beats in %0d cycles = %.4f beats/cycle (sink 1/%0d, floor %.4f)",
                         beats[1], t_last[1]-t_first[1]+1, rate1, fastdiv, target1);
                if (rate1 < target1)
                    err($sformatf("decoder 1 ran at %.4f beats/cycle, expected >= %.4f",
                                  rate1, target1));
            end

            default: err($sformatf("unknown scenario '%s'", scen));
        endcase

        repeat (20) @(negedge clk);

        if (route_stall)      err("route_stall latched: a routed beat was refused");
        if (model_errors > 0) err($sformatf("card DMA model reported %0d error(s)", model_errors));
        for (int c = 0; c < NCONNS; c++)
            if (slot_overflow[c]) err($sformatf("slot_overflow[%0d] latched", c));
        for (int d = 0; d < NRD; d++) begin
            if (residue_err[d]) err($sformatf("decoder %0d: residue_err latched", d));
            if (sh_error[d])    err($sformatf("decoder %0d: strip_http resp_error latched", d));
        end
        // None of these can be true of a correct slot_rd_share: a beat with nothing outstanding, a
        // receive fifo that refused one (which would mean the credit is wrong), a request longer
        // than RD_MAX. They are the sticky bits that say the shared channel went wrong rather than
        // letting a mis-steered beat show up as a body byte.
        if (share_order_err) err("slot_rd_share: order_err latched (a beat arrived unowned)");
        if (share_fifo_err)  err("slot_rd_share: fifo_err latched (a receive fifo refused a beat)");
        if (share_len_err)   err("slot_rd_share: len_err latched (a read longer than RD_MAX)");

        $display("slot_reader_tb[%0s,C=%0d,D=%0d,RDMAX=%0d,SHARE=%0d]: %0s  (%0d cycles, %0d error(s))",
                 scen, NCONNS, NRD, RDMAX, SHARE, (errors == 0) ? "PASS" : "FAIL", cyc, errors);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("slot_reader_tb[%0s,C=%0d,D=%0d,RDMAX=%0d,SHARE=%0d]: FAIL  (timeout at %0t)",
                 scen, NCONNS, NRD, RDMAX, SHARE, $time);
        $finish;
    end

endmodule
