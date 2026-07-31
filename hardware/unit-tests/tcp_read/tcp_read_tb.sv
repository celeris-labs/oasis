`timescale 1ns / 1ps

// Standalone testbench for tcp_read (+ strip_http).
//
// Models the TOE application interface: for each TCP segment the TOE emits a notification
// (session, length), the DUT issues a readPkg for that length, the TOE returns one rx-metadata
// beat and then the segment bytes as bottom-justified rx-data beats ending in tlast. When the
// server closes, the TOE emits a notification with length=0, closed=1.
//
// The DUT must reassemble the whole HTTP response across all those segments, strip the header
// once, and present the body as ONE stream with a single tlast. We check the body bytes at
// strip_http's output are byte-exact and that exactly one tlast is produced.
//
// Run: ./run.sh

import lynxTypes::*;

module tcp_read_tb;

    localparam int BYTE_LANES = AXI_DATA_BITS / 8; // 64
    localparam int CLK_NS     = 10;
    localparam logic [15:0] SESSION = 16'h0042;

    logic clk;
    logic rst_n;
    logic start;

    // notifications (TB -> DUT)
    logic                        s_axis_notifications_TVALID;
    logic                        s_axis_notifications_TREADY;
    logic [TCP_NOTIFY_BITS-1:0]  s_axis_notifications_TDATA;
    // readPkg (DUT -> TB)
    logic                          m_axis_read_package_TVALID;
    logic                          m_axis_read_package_TREADY;
    logic [TCP_RD_PKG_REQ_BITS-1:0] m_axis_read_package_TDATA;
    // rx metadata (TB -> DUT)
    logic                        s_axis_rx_metadata_TVALID;
    logic                        s_axis_rx_metadata_TREADY;
    logic [TCP_RX_META_BITS-1:0] s_axis_rx_metadata_TDATA;
    // rx data (TB -> DUT)
    logic                        s_axis_rx_data_TVALID;
    logic                        s_axis_rx_data_TREADY;
    logic [AXI_DATA_BITS-1:0]    s_axis_rx_data_TDATA;
    logic [BYTE_LANES-1:0]       s_axis_rx_data_TKEEP;
    logic                        s_axis_rx_data_TLAST;
    // body (DUT -> TB)
    logic                        m_axis_body_tvalid;
    logic                        m_axis_body_tready;
    logic [AXI_DATA_BITS-1:0]    m_axis_body_tdata;
    logic [BYTE_LANES-1:0]       m_axis_body_tkeep;
    logic                        m_axis_body_tlast;

    logic                        done;
    logic                        error;
    logic [3:0]                  debug_rx_write_ptr;
    logic [AXI_DATA_BITS-1:0]    debug_rx_buffer_w0, debug_rx_buffer_w1;
    logic [3:0]                  state_debug;

    int unsigned fails;
    int unsigned passes;

    // Module-level output collection (written by consumer, read after join).
    logic [AXI_DATA_BITS-1:0] col_data[$];
    logic [BYTE_LANES-1:0]    col_keep[$];
    int                       col_nlast;
    bit                       bp_enable;       // consumer drops tready periodically
    bit                       combined_close;  // last data notification carries closed=1

    tcp_read dut (
        .clk(clk), .rst_n(rst_n), .start(start), .session_id(SESSION),
        .s_axis_notifications_TVALID(s_axis_notifications_TVALID),
        .s_axis_notifications_TREADY(s_axis_notifications_TREADY),
        .s_axis_notifications_TDATA(s_axis_notifications_TDATA),
        .m_axis_read_package_TVALID(m_axis_read_package_TVALID),
        .m_axis_read_package_TREADY(m_axis_read_package_TREADY),
        .m_axis_read_package_TDATA(m_axis_read_package_TDATA),
        .s_axis_rx_metadata_TVALID(s_axis_rx_metadata_TVALID),
        .s_axis_rx_metadata_TREADY(s_axis_rx_metadata_TREADY),
        .s_axis_rx_metadata_TDATA(s_axis_rx_metadata_TDATA),
        .s_axis_rx_data_TVALID(s_axis_rx_data_TVALID),
        .s_axis_rx_data_TREADY(s_axis_rx_data_TREADY),
        .s_axis_rx_data_TDATA(s_axis_rx_data_TDATA),
        .s_axis_rx_data_TKEEP(s_axis_rx_data_TKEEP),
        .s_axis_rx_data_TLAST(s_axis_rx_data_TLAST),
        .m_axis_body_tvalid(m_axis_body_tvalid),
        .m_axis_body_tready(m_axis_body_tready),
        .m_axis_body_tdata(m_axis_body_tdata),
        .m_axis_body_tkeep(m_axis_body_tkeep),
        .m_axis_body_tlast(m_axis_body_tlast),
        .done(done), .error(error),
        .debug_rx_write_ptr(debug_rx_write_ptr),
        .debug_rx_buffer_w0(debug_rx_buffer_w0),
        .debug_rx_buffer_w1(debug_rx_buffer_w1),
        .state_debug(state_debug)
    );

    initial clk = 1'b0;
    always #(CLK_NS/2) clk = ~clk;

    // ------------------------------------------------------------------ helpers
    function automatic logic [BYTE_LANES-1:0] keep_n(input int n);
        keep_n = '0;
        if (n <= 0) return keep_n;
        if (n >= BYTE_LANES) return {BYTE_LANES{1'b1}};
        keep_n = {BYTE_LANES{1'b1}} >> (BYTE_LANES - n);
    endfunction

    function automatic int count_keep(input logic [BYTE_LANES-1:0] k);
        count_keep = 0;
        for (int i = 0; i < BYTE_LANES; i++) if (k[i]) count_keep++;
    endfunction

    function automatic logic [TCP_NOTIFY_BITS-1:0] make_notif(
        input logic [15:0] sid, input logic [15:0] len, input logic closed);
        make_notif = '0;
        make_notif[TCP_SESSION_BITS-1:0]                       = sid;   // [15:0]
        make_notif[TCP_LEN_BITS+TCP_SESSION_BITS-1:TCP_SESSION_BITS] = len; // [31:16]
        make_notif[TCP_SESSION_BITS+TCP_LEN_BITS+32+16]        = closed; // bit 80
    endfunction

    // Probe internal handshakes to localize any beat drop: in_fire = rx->hold (concatenator input),
    // out_fire = hold->strip_http (concatenator output). If in==out but body is short, strip_http
    // (skid) drops; if in>out, the concatenator drops.
    int cnt_in_fire, cnt_out_fire, cnt_fsm2skid, cnt_skidout;
    always @(posedge clk) if (rst_n) begin
        if (dut.in_fire)  cnt_in_fire  <= cnt_in_fire  + 1;
        if (dut.out_fire) cnt_out_fire <= cnt_out_fire + 1;
        // strip_http internal: FSM presents to skid, and skid emits downstream
        if (dut.inst_strip_http.fsm_tvalid   && dut.inst_strip_http.fsm_tready)   cnt_fsm2skid <= cnt_fsm2skid + 1;
        if (dut.inst_strip_http.m_axis_tvalid && dut.inst_strip_http.m_axis_tready) cnt_skidout  <= cnt_skidout  + 1;
    end

    function automatic void flatten(
        input  logic [AXI_DATA_BITS-1:0] data[$],
        input  logic [BYTE_LANES-1:0]    keep[$],
        output byte unsigned             bytes[$]);
        bytes.delete();
        for (int b = 0; b < data.size(); b++)
            for (int i = 0; i < BYTE_LANES; i++)
                if (keep[b][i]) bytes.push_back(data[b][i*8 +: 8]);
    endfunction

    task automatic push_str(ref byte unsigned out[$], input string s);
        for (int i = 0; i < s.len(); i++) out.push_back(byte'(s[i]));
    endtask
    task automatic push_crlf(ref byte unsigned out[$]);
        out.push_back(8'h0D); out.push_back(8'h0A);
    endtask

    // Build a full 206 response into `resp` and the expected body into `body`.
    task automatic build_response(ref byte unsigned resp[$], ref byte unsigned body[$],
                                  input int body_len, input byte unsigned base);
        resp.delete(); body.delete();
        push_str(resp, "HTTP/1.1 206 Partial Content"); push_crlf(resp);
        push_str(resp, "Content-Range: bytes 0-199/100000"); push_crlf(resp);
        push_str(resp, $sformatf("Content-Length: %0d", body_len)); push_crlf(resp);
        push_crlf(resp);
        for (int i = 0; i < body_len; i++) begin
            resp.push_back(base + i[7:0]);
            body.push_back(base + i[7:0]);
        end
    endtask

    // Real MinIO 206 header -- the EXACT tpch-30 failing response. Its length is 668 bytes, so
    // 668 mod 64 = 28: the body starts at lane 28 and strip_http must emit a 36-byte first body
    // beat. The synthetic ~88B build_response header never produces this alignment (it lands on
    // lane 22-26 = 38-42 byte first beats). The hardware cmp localized the inserted byte to output
    // offset 37 -- exactly the 36-byte-first-beat merge seam -- so this is the alignment to test.
    task automatic build_response_minio(ref byte unsigned resp[$], ref byte unsigned body[$],
                                        input int body_len, input byte unsigned base);
        resp.delete(); body.delete();
        push_str(resp, "HTTP/1.1 206 Partial Content"); push_crlf(resp);
        push_str(resp, "Accept-Ranges: bytes"); push_crlf(resp);
        push_str(resp, "Content-Length: 262144"); push_crlf(resp);
        push_str(resp, "Content-Range: bytes 190925654-191187797/191187798"); push_crlf(resp);
        push_str(resp, "Content-Type: application/octet-stream"); push_crlf(resp);
        push_str(resp, "ETag: \"492506d8e3a80381773389855aca92f4-3\""); push_crlf(resp);
        push_str(resp, "Last-Modified: Wed, 25 Mar 2026 10:41:34 GMT"); push_crlf(resp);
        push_str(resp, "Server: MinIO"); push_crlf(resp);
        push_str(resp, "Strict-Transport-Security: max-age=31536000; includeSubDomains"); push_crlf(resp);
        push_str(resp, "Vary: Origin"); push_crlf(resp);
        push_str(resp, "Vary: Accept-Encoding"); push_crlf(resp);
        push_str(resp, "X-Amz-Id-2: dd9025bab4ad464b049177c95eb6ebf374d3b3fd1af9251148b658df7ac2e3e8"); push_crlf(resp);
        push_str(resp, "X-Amz-Request-Id: 18C7100D915407B4"); push_crlf(resp);
        push_str(resp, "X-Content-Type-Options: nosniff"); push_crlf(resp);
        push_str(resp, "X-Ratelimit-Limit: 13103"); push_crlf(resp);
        push_str(resp, "X-Ratelimit-Remaining: 13103"); push_crlf(resp);
        push_str(resp, "X-Xss-Protection: 1; mode=block"); push_crlf(resp);
        push_str(resp, "Date: Thu, 30 Jul 2026 12:10:27 GMT"); push_crlf(resp);
        push_str(resp, "Connection: close"); push_crlf(resp);
        push_crlf(resp);
        $display("[minio] header len = %0d bytes, body starts at lane %0d (first beat %0d bytes)",
                 resp.size(), resp.size() % 64, 64 - (resp.size() % 64));
        for (int i = 0; i < body_len; i++) begin
            resp.push_back(base + i[7:0]);
            body.push_back(base + i[7:0]);
        end
    endtask

    // Build a response whose header is EXACTLY hdr_len bytes (padded via one X-Pad line), so the
    // body starts at lane (hdr_len % 64) and strip_http emits a (64 - hdr_len%64)-byte first beat.
    // Sweeping hdr_len over [64,127] exercises every possible first-beat size 1..64.
    task automatic build_response_len(ref byte unsigned resp[$], ref byte unsigned body[$],
                                      input int body_len, input byte unsigned base, input int hdr_len);
        int k;
        resp.delete(); body.delete();
        push_str(resp, "HTTP/1.1 206 Partial Content"); push_crlf(resp); // 30 bytes
        push_str(resp, "X-Pad: ");                                       // 7 bytes
        k = hdr_len - 41;                                                // 30 + 7 + k + 2(pad crlf) + 2(blank) = 41+k
        if (k < 0) k = 0;
        for (int i = 0; i < k; i++) resp.push_back(8'h61);               // 'a' filler
        push_crlf(resp);
        push_crlf(resp);                                                 // end of header
        for (int i = 0; i < body_len; i++) begin
            resp.push_back(base + i[7:0]);
            body.push_back(base + i[7:0]);
        end
    endtask

    task automatic expect_bytes(input string name, input byte unsigned got[$], input byte unsigned exp[$]);
        int first_mismatch, nmin;
        first_mismatch = -1;
        nmin = (got.size() < exp.size()) ? got.size() : exp.size();
        for (int i = 0; i < nmin; i++)
            if (got[i] !== exp[i]) begin first_mismatch = i; break; end
        if (got.size() != exp.size() || first_mismatch != -1) begin
            $error("[%s] length got=%0d exp=%0d, first byte mismatch at %0d",
                   name, got.size(), exp.size(), first_mismatch);
            if (first_mismatch >= 0) begin
                int lo; lo = (first_mismatch > 4) ? first_mismatch - 4 : 0;
                for (int i = lo; i < lo + 16 && i < nmin; i++)
                    $display("    [%0d] got=%02x exp=%02x %s",
                             i, got[i], exp[i], (got[i] !== exp[i]) ? "<--" : "");
            end
            fails++; return;
        end
        $display("[PASS] %s (%0d bytes)", name, exp.size());
        passes++;
    endtask

    // ------------------------------------------------------------------ TOE drivers
    task automatic drive_notif(input logic [15:0] len, input logic closed);
        s_axis_notifications_TVALID = 1'b1;
        s_axis_notifications_TDATA  = make_notif(SESSION, len, closed);
        do @(posedge clk); while (!(s_axis_notifications_TVALID && s_axis_notifications_TREADY));
        s_axis_notifications_TVALID = 1'b0;
    endtask

    task automatic check_readpkg(input int explen);
        // readPkg TREADY is held high, so the cycle TVALID=1 is the fire.
        do @(posedge clk); while (!m_axis_read_package_TVALID);
        if (m_axis_read_package_TDATA[TCP_LEN_BITS+TCP_SESSION_BITS-1:TCP_SESSION_BITS] !== explen[15:0]) begin
            $error("[readpkg] len got=%0d exp=%0d",
                   m_axis_read_package_TDATA[TCP_LEN_BITS+TCP_SESSION_BITS-1:TCP_SESSION_BITS], explen);
            fails++;
        end
        if (m_axis_read_package_TDATA[TCP_SESSION_BITS-1:0] !== SESSION) begin
            $error("[readpkg] session got=0x%04x exp=0x%04x",
                   m_axis_read_package_TDATA[TCP_SESSION_BITS-1:0], SESSION);
            fails++;
        end
    endtask

    task automatic drive_metadata();
        s_axis_rx_metadata_TVALID = 1'b1;
        s_axis_rx_metadata_TDATA  = 16'hABCD;
        do @(posedge clk); while (!(s_axis_rx_metadata_TVALID && s_axis_rx_metadata_TREADY));
        s_axis_rx_metadata_TVALID = 1'b0;
    endtask

    task automatic drive_rx_beat(input logic [AXI_DATA_BITS-1:0] data,
                                 input logic [BYTE_LANES-1:0] keep, input logic last);
        s_axis_rx_data_TDATA  = data;
        s_axis_rx_data_TKEEP  = keep;
        s_axis_rx_data_TLAST  = last;
        s_axis_rx_data_TVALID = 1'b1;
        do @(posedge clk); while (!(s_axis_rx_data_TVALID && s_axis_rx_data_TREADY));
        s_axis_rx_data_TVALID = 1'b0;
        s_axis_rx_data_TLAST  = 1'b0;
    endtask

    // Drive a segment's bytes as bottom-justified 64B beats, tlast on the last beat.
    task automatic drive_segment(input byte unsigned bytes[$]);
        int pos, n;
        logic [AXI_DATA_BITS-1:0] beat;
        pos = 0;
        while (pos < bytes.size()) begin
            n = bytes.size() - pos;
            if (n > BYTE_LANES) n = BYTE_LANES;
            beat = '0;
            for (int i = 0; i < n; i++) beat[i*8 +: 8] = bytes[pos + i];
            drive_rx_beat(beat, keep_n(n), (pos + n) >= bytes.size());
            pos += n;
        end
    endtask

    // Input side: notification + readPkg + metadata + data per segment, then FIN.
    // When combined_close is set, the last data notification carries closed=1 and there is no
    // separate zero-length FIN (exercises the pending_close path).
    task automatic producer(input byte unsigned resp[$], input int seg_lens[$]);
        int off;
        logic last_seg;
        byte unsigned seg[$];
        off = 0;
        for (int s = 0; s < seg_lens.size(); s++) begin
            last_seg = (s == seg_lens.size() - 1);
            seg.delete();
            for (int i = 0; i < seg_lens[s]; i++) seg.push_back(resp[off + i]);
            off += seg_lens[s];
            drive_notif(seg_lens[s][15:0], combined_close && last_seg);
            check_readpkg(seg_lens[s]);
            drive_metadata();
            drive_segment(seg);
        end
        if (!combined_close) drive_notif(16'd0, 1'b1); // separate FIN
    endtask

    // Output side: collect body beats until done. Exactly one clock edge and one sample per
    // iteration; tready is changed cleanly between edges. With bp_enable we stall 2 of every 4
    // cycles, which fills strip_http's 2-slot skid and back-pressures the whole chain.
    task automatic consumer();
        int idle;
        col_data.delete(); col_keep.delete(); col_nlast = 0;
        m_axis_body_tready = 1'b1;
        idle = 0;
        forever begin
            @(posedge clk);
            if (m_axis_body_tvalid && m_axis_body_tready) begin
                col_data.push_back(m_axis_body_tdata);
                col_keep.push_back(m_axis_body_tkeep);
                if (m_axis_body_tkeep !== keep_n(count_keep(m_axis_body_tkeep))) begin
                    $error("[justify] non-bottom-justified keep=0x%016h", m_axis_body_tkeep);
                    fails++;
                end
                if (m_axis_body_tlast) col_nlast++;
            end
            // Stop a couple cycles after done so any final beat is captured with tready high.
            if (done) begin
                m_axis_body_tready <= 1'b1;
                repeat (3) begin
                    @(posedge clk);
                    if (m_axis_body_tvalid && m_axis_body_tready) begin
                        col_data.push_back(m_axis_body_tdata);
                        col_keep.push_back(m_axis_body_tkeep);
                        if (m_axis_body_tlast) col_nlast++;
                    end
                end
                break;
            end
            idle++;
            if (idle > 200000) break;
            // tready for the next edge: stall 2 of every 4 cycles. NON-BLOCKING so tready is stable
            // at every posedge -- a blocking write here races the DUT (and monitor) sampling tready
            // at the same edge, and drops beats in the *testbench*, not the DUT.
            m_axis_body_tready <= !(bp_enable && ((idle % 4 == 0) || (idle % 4 == 1)));
        end
    endtask

    task automatic run_request(input string name, input byte unsigned resp[$],
                               input byte unsigned exp_body[$], input int seg_lens[$]);
        byte unsigned got[$];
        cnt_in_fire = 0; cnt_out_fire = 0; cnt_fsm2skid = 0; cnt_skidout = 0;
        start = 1'b1;
        fork
            producer(resp, seg_lens);
            consumer();
        join
        start = 1'b0;
        repeat (5) @(posedge clk); // let FSM return to IDLE
        flatten(col_data, col_keep, got);
        $display("    [probe] rx->hold in_fire=%0d, hold->strip out_fire=%0d | strip: fsm->skid=%0d, skid->out=%0d, collected=%0d",
                 cnt_in_fire, cnt_out_fire, cnt_fsm2skid, cnt_skidout, col_data.size());
        expect_bytes(name, got, exp_body);
        if (col_nlast != 1) begin
            $error("[%s] tlast count got=%0d exp=1", name, col_nlast);
            fails++;
        end
    endtask

    // ------------------------------------------------------------------ cases
    task automatic case_single_segment();
        byte unsigned resp[$], body[$];
        int segs[$];
        build_response(resp, body, 120, 8'h00);
        segs = { resp.size() };               // whole response in one segment
        $display("--- case_single_segment (%0d bytes, 1 segment) ---", resp.size());
        run_request("single_segment", resp, body, segs);
    endtask

    task automatic case_multiseg();
        byte unsigned resp[$], body[$];
        int segs[$], total;
        build_response(resp, body, 200, 8'h00);
        total = resp.size();
        // Non-64-aligned segments so partial beats appear at readPkg boundaries (in the body,
        // after the header). Header (~86B) stays inside segment 0's first full beats.
        segs = { 130, 77, total - 130 - 77 };
        $display("--- case_multiseg (%0d bytes, segs 130/77/%0d) ---", total, total - 207);
        run_request("multiseg", resp, body, segs);
    endtask

    task automatic case_many_small_segments();
        byte unsigned resp[$], body[$];
        int segs[$], total, off;
        build_response(resp, body, 300, 8'h20);
        total = resp.size();
        // Many tiny segments (13 bytes each) — stresses the header spanning the first few
        // full-beat boundaries is NOT hit (header in seg0..). Actually forces header across
        // several small segments; strip_http uses prev_tail across full beats only, so keep
        // the first segment >= header. Use one header-sized segment then 13B chunks.
        segs.delete();
        segs.push_back(96);            // whole header (~86B) + a little body, full-beat aligned region
        off = 96;
        while (off < total) begin
            if (total - off >= 13) segs.push_back(13);
            else segs.push_back(total - off);
            off += segs[segs.size()-1];
        end
        $display("--- case_many_small_segments (%0d bytes, %0d segments) ---", total, segs.size());
        run_request("many_small_segments", resp, body, segs);
    endtask

    task automatic case_combined_close();
        byte unsigned resp[$], body[$];
        int segs[$], total;
        build_response(resp, body, 180, 8'h40);
        total = resp.size();
        segs = { 140, total - 140 };
        combined_close = 1'b1;
        $display("--- case_combined_close (%0d bytes, close on last data notif) ---", total);
        run_request("combined_close", resp, body, segs);
        combined_close = 1'b0;
    endtask

    task automatic case_backpressure();
        byte unsigned resp[$], body[$];
        int segs[$], total;
        build_response(resp, body, 250, 8'h10);
        total = resp.size();
        segs = { 120, 90, total - 210 };
        bp_enable = 1'b1;
        $display("--- case_backpressure (%0d bytes, downstream tready toggling) ---", total);
        run_request("backpressure", resp, body, segs);
        bp_enable = 1'b0;
    endtask

    task automatic case_sequential();
        byte unsigned r1[$], b1[$], r2[$], b2[$];
        int s1[$], s2[$], t2;
        build_response(r1, b1, 64, 8'h00);
        s1 = { 100, r1.size() - 100 };
        $display("--- case_sequential #1 ---");
        run_request("sequential_1", r1, b1, s1);
        build_response(r2, b2, 150, 8'h80);
        t2 = r2.size();
        s2 = { 111, 64, t2 - 175 };
        $display("--- case_sequential #2 ---");
        run_request("sequential_2", r2, b2, s2);
    endtask

    // Chop a `total`-byte response into `seg_len`-byte TCP segments (last is the remainder).
    function automatic void mss_segments(input int total, input int seg_len, output int segs[$]);
        int off;
        segs.delete();
        off = 0;
        while (off < total) begin
            if (total - off >= seg_len) segs.push_back(seg_len);
            else                        segs.push_back(total - off);
            off += segs[segs.size()-1];
        end
    endfunction

    // Large transfer at a realistic MSS: this is the case the ~300B cases above never reach and
    // the size at which the hardware loses 1-22 bytes. Header lives inside segment 0; strip_http
    // strips it once and the body must come out byte-exact across dozens of segment seams.
    task automatic case_large_mss(input string name, input int body_len, input byte unsigned base,
                                  input int seg_len, input bit bp);
        byte unsigned resp[$], body[$];
        int segs[$];
        build_response(resp, body, body_len, base);
        mss_segments(resp.size(), seg_len, segs);
        bp_enable = bp;
        $display("--- %s (body %0d, resp %0d, %0d segs of %0d, bp=%0d) ---",
                 name, body_len, resp.size(), segs.size(), seg_len, bp);
        run_request(name, resp, body, segs);
        bp_enable = 1'b0;
    endtask

    // Real-MinIO-header cases: body-start lane 28 / 36-byte first beat, the exact tpch-30 alignment.
    task automatic case_minio_single();
        byte unsigned resp[$], body[$];
        int segs[$];
        build_response_minio(resp, body, 800, 8'h00);
        segs = { resp.size() };               // whole response in one segment
        $display("--- case_minio_single (resp %0d, body 800, 1 segment) ---", resp.size());
        run_request("minio_single", resp, body, segs);
    endtask

    task automatic case_minio_mss();
        byte unsigned resp[$], body[$];
        int segs[$];
        build_response_minio(resp, body, 4096, 8'h60);
        mss_segments(resp.size(), 1460, segs); // header (668) spans ~11 beats inside segment 0
        $display("--- case_minio_mss (resp %0d, %0d segs of 1460) ---", resp.size(), segs.size());
        run_request("minio_mss", resp, body, segs);
    endtask

    task automatic case_minio_bp();
        byte unsigned resp[$], body[$];
        int segs[$];
        build_response_minio(resp, body, 2048, 8'h90);
        mss_segments(resp.size(), 512, segs);
        bp_enable = 1'b1;
        $display("--- case_minio_bp (resp %0d, %0d segs of 512, backpressure) ---", resp.size(), segs.size());
        run_request("minio_bp", resp, body, segs);
        bp_enable = 1'b0;
    endtask

    // ------------------------------------------------------------------ main
    initial begin
        fails  = 0; passes = 0;
        rst_n  = 1'b0; start = 1'b0;
        bp_enable = 1'b0; combined_close = 1'b0;
        s_axis_notifications_TVALID = 1'b0;
        s_axis_rx_metadata_TVALID   = 1'b0;
        s_axis_rx_data_TVALID       = 1'b0;
        m_axis_read_package_TREADY  = 1'b1; // always accept readPkg
        m_axis_body_tready          = 1'b1;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        case_single_segment();
        case_multiseg();
        case_many_small_segments();
        case_combined_close();
        case_backpressure();
        case_sequential();

        // Large, realistic-MSS transfers (the ~300B cases above never reach this scale).
        case_large_mss("large_1460",     65536, 8'h00, 1460, 1'b0);
        case_large_mss("large_1460_bp",  65536, 8'h55, 1460, 1'b1);
        case_large_mss("large_8960",     65536, 8'hAA, 8960, 1'b0);
        case_large_mss("large_1461_odd", 40000, 8'h11, 1461, 1'b1);
        case_large_mss("large_536",      49152, 8'h33,  536, 1'b0);

        // Isolation: 64-ALIGNED segments (512 = 8 full beats) => every segment ends on a FULL beat
        // with tlast. Normal ~88B header (lane 24), so this removes the minio alignment variable.
        case_large_mss("aligned_512_nobp", 4096, 8'h00,  512, 1'b0); // control: no backpressure
        case_large_mss("aligned_512_bp",   4096, 8'h00,  512, 1'b1); // suspect: full-beat tlast + bp
        case_large_mss("aligned_1024_bp",  8192, 8'h22, 1024, 1'b1); // 64-aligned, larger
        case_large_mss("unaligned_500_bp", 4096, 8'h44,  500, 1'b1); // 500%64!=0 -> partial tail + bp

        // Exact tpch-30 alignment: real 668B MinIO header => body-start lane 28, 36B first beat.
        case_minio_single();
        case_minio_mss();
        case_minio_bp();

        $display("========================================");
        $display("tcp_read_tb: %0d passed, %0d failed", passes, fails);
        $display("========================================");
        if (fails != 0) $fatal(1, "test failed");
        $finish;
    end

    // Safety timeout
    initial begin
        #2_000_000;
        $fatal(1, "timeout");
    end

endmodule
