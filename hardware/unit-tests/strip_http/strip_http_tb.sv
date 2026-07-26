`timescale 1ns / 1ps

// Standalone testbench for strip_http (header strip + 64B align).
// Run: ./run.sh

import lynxTypes::*;

module strip_http_tb;

    localparam int BYTE_LANES = AXI_DATA_BITS / 8; // 64
    localparam int CLK_NS     = 10;

    logic clk;
    logic rst_n;
    logic clear;
    logic enable;

    logic                       s_axis_tvalid;
    logic [AXI_DATA_BITS-1:0]   s_axis_tdata;
    logic [BYTE_LANES-1:0]      s_axis_tkeep;
    logic                       s_axis_tlast;
    logic                       s_axis_tready;

    logic                       m_axis_tvalid;
    logic [AXI_DATA_BITS-1:0]   m_axis_tdata;
    logic [BYTE_LANES-1:0]      m_axis_tkeep;
    logic                       m_axis_tlast;
    logic                       m_axis_tready;

    logic [AXI_DATA_BITS-1:0]   out_w0, out_w1;
    logic                       out_w0_valid, out_w1_valid;
    logic                       done;
    logic [6:0]                 out_payload_idx;

    int unsigned fails;
    int unsigned passes;

    strip_http dut (
        .clk(clk),
        .rst_n(rst_n),
        .clear(clear),
        .enable(enable),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tready(s_axis_tready),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tlast(m_axis_tlast),
        .m_axis_tready(m_axis_tready),
        .out_w0(out_w0),
        .out_w1(out_w1),
        .out_w0_valid(out_w0_valid),
        .out_w1_valid(out_w1_valid),
        .done(done),
        .out_payload_idx(out_payload_idx)
    );

    initial clk = 1'b0;
    always #(CLK_NS/2) clk = ~clk;

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------
    function automatic logic [BYTE_LANES-1:0] keep_n(input int n);
        keep_n = '0;
        if (n <= 0) return keep_n;
        if (n >= BYTE_LANES) return {BYTE_LANES{1'b1}};
        keep_n = {BYTE_LANES{1'b1}} >> (BYTE_LANES - n);
    endfunction

    // Fill beat bytes [0 .. nbytes) with ascending pattern starting at base.
    // Byte 0 lives in tdata[7:0] (AXI first-byte-low).
    task automatic fill_pattern(
        output logic [AXI_DATA_BITS-1:0] data,
        output logic [BYTE_LANES-1:0]    keep,
        input  int                       nbytes,
        input  byte unsigned             base
    );
        data = '0;
        keep = keep_n(nbytes);
        for (int i = 0; i < nbytes; i++) begin
            data[i*8 +: 8] = base + i[7:0];
        end
    endtask

    // Place \r\n\r\n at byte index `pos` (0 = LSB / first AXI byte).
    task automatic poke_crlf(
        inout logic [AXI_DATA_BITS-1:0] data,
        input  int                      pos
    );
        data[pos*8 +: 8]       = 8'h0D;
        data[(pos+1)*8 +: 8]   = 8'h0A;
        data[(pos+2)*8 +: 8]   = 8'h0D;
        data[(pos+3)*8 +: 8]   = 8'h0A;
    endtask

    task automatic reset_dut();
        clear          = 1'b1;
        enable         = 1'b0;
        s_axis_tvalid  = 1'b0;
        s_axis_tdata   = '0;
        s_axis_tkeep   = '0;
        s_axis_tlast   = 1'b0;
        m_axis_tready  = 1'b1;
        @(posedge clk);
        clear  = 1'b0;
        enable = 1'b1;
        @(posedge clk);
    endtask

    // Drive one input beat; wait for ready.
    task automatic drive_beat(
        input logic [AXI_DATA_BITS-1:0] data,
        input logic [BYTE_LANES-1:0]    keep,
        input logic                     last
    );
        s_axis_tdata  = data;
        s_axis_tkeep  = keep;
        s_axis_tlast  = last;
        s_axis_tvalid = 1'b1;
        do @(posedge clk); while (!(s_axis_tvalid && s_axis_tready));
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
    endtask

    // Collect body beats until done (or timeout).
    task automatic collect_body(
        output logic [AXI_DATA_BITS-1:0] out_data[$],
        output logic [BYTE_LANES-1:0]    out_keep[$],
        input  int                       timeout_cycles = 200
    );
        int cycles;
        out_data.delete();
        out_keep.delete();
        cycles = 0;
        while (!done && cycles < timeout_cycles) begin
            @(posedge clk);
            cycles++;
            if (m_axis_tvalid && m_axis_tready) begin
                out_data.push_back(m_axis_tdata);
                out_keep.push_back(m_axis_tkeep);
                // Every beat must be bottom-justified (keep = N ones from lane 0),
                // otherwise the DataNormalizer downstream would scramble it. This is
                // the check the flatten-based byte comparison cannot catch.
                if (m_axis_tkeep !== keep_n(count_keep(m_axis_tkeep))) begin
                    $error("[justify] non-bottom-justified keep=0x%016h", m_axis_tkeep);
                    fails++;
                end
                if (m_axis_tlast) begin
                    // wait one more for done flop
                end
            end
        end
        // Allow done to register after last accept
        for (int i = 0; i < 3 && !done; i++) @(posedge clk);
    endtask

    function automatic int count_keep(input logic [BYTE_LANES-1:0] k);
        count_keep = 0;
        for (int i = 0; i < BYTE_LANES; i++) if (k[i]) count_keep++;
    endfunction

    // Flatten collected AXIS beats into a byte queue (first-byte-low).
    function automatic void flatten(
        input  logic [AXI_DATA_BITS-1:0] data[$],
        input  logic [BYTE_LANES-1:0]    keep[$],
        output byte unsigned             bytes[$]
    );
        bytes.delete();
        for (int b = 0; b < data.size(); b++) begin
            for (int i = 0; i < BYTE_LANES; i++) begin
                if (keep[b][i]) bytes.push_back(data[b][i*8 +: 8]);
            end
        end
    endfunction

    task automatic expect_bytes(
        input string         name,
        input byte unsigned  got[$],
        input byte unsigned  exp[$]
    );
        if (got.size() != exp.size()) begin
            $error("[%s] length got=%0d exp=%0d", name, got.size(), exp.size());
            fails++;
            return;
        end
        for (int i = 0; i < exp.size(); i++) begin
            if (got[i] !== exp[i]) begin
                $error("[%s] byte[%0d] got=0x%02x exp=0x%02x", name, i, got[i], exp[i]);
                fails++;
                return;
            end
        end
        $display("[PASS] %s (%0d bytes)", name, exp.size());
        passes++;
    endtask

    // \r is not a standard SystemVerilog string escape, so CRLF is pushed as
    // explicit bytes rather than relying on "\r\n" in a literal.
    task automatic push_str(ref byte unsigned out[$], input string s);
        for (int i = 0; i < s.len(); i++) begin
            out.push_back(byte'(s[i]));
        end
    endtask

    task automatic push_crlf(ref byte unsigned out[$]);
        out.push_back(8'h0D);
        out.push_back(8'h0A);
    endtask

    // Append a full HTTP response (header with Content-Length + body) to `out`.
    task automatic make_response(
        ref   byte unsigned out[$],
        input int           body_len,
        input byte unsigned base
    );
        push_str(out, "HTTP/1.1 200 OK");
        push_crlf(out);
        push_str(out, "Content-Type: application/octet-stream");
        push_crlf(out);
        push_str(out, $sformatf("Content-Length: %0d", body_len));
        push_crlf(out);
        push_crlf(out);
        for (int i = 0; i < body_len; i++) begin
            out.push_back(base + i[7:0]);
        end
    endtask

    // Drive a byte stream chopped into 64B beats; tlast only on the final beat
    // when `set_last` is high (otherwise the connection stays open).
    task automatic drive_stream(input byte unsigned bytes[$], input logic set_last);
        int pos, n;
        logic [AXI_DATA_BITS-1:0] beat;
        pos = 0;
        while (pos < bytes.size()) begin
            n = bytes.size() - pos;
            if (n > BYTE_LANES) n = BYTE_LANES;
            beat = '0;
            for (int i = 0; i < n; i++) begin
                beat[i*8 +: 8] = bytes[pos + i];
            end
            drive_beat(beat, keep_n(n), set_last && ((pos + n) >= bytes.size()));
            pos += n;
        end
    endtask

    // Collect output beats until `n_resp` tlast-delimited responses have been seen.
    task automatic collect_responses(
        input  int                       n_resp,
        output logic [AXI_DATA_BITS-1:0] out_data[$],
        output logic [BYTE_LANES-1:0]    out_keep[$],
        output int                       resp_lens[$],
        input  int                       timeout_cycles = 4000
    );
        int cycles, seen, cur;
        out_data.delete();
        out_keep.delete();
        resp_lens.delete();
        cycles = 0;
        seen   = 0;
        cur    = 0;
        while (seen < n_resp && cycles < timeout_cycles) begin
            @(posedge clk);
            cycles++;
            if (m_axis_tvalid && m_axis_tready) begin
                out_data.push_back(m_axis_tdata);
                out_keep.push_back(m_axis_tkeep);
                cur += count_keep(m_axis_tkeep);
                if (m_axis_tlast) begin
                    resp_lens.push_back(cur);
                    cur = 0;
                    seen++;
                end
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Cases
    // ------------------------------------------------------------------

    // Case 1: header + body in same beat, CRLF mid-beat, tlast.
    // Header pad then \r\n\r\n at byte 10 → payload starts at byte 14.
    task automatic case_same_beat_flush();
        logic [AXI_DATA_BITS-1:0] beat, out_d[$];
        logic [BYTE_LANES-1:0]    out_k[$];
        byte unsigned got[$], exp[$];
        int pay_start;

        $display("--- case_same_beat_flush ---");
        reset_dut();
        beat = '0;
        for (int i = 0; i < 14; i++) beat[i*8 +: 8] = 8'h41; // 'A' header junk
        poke_crlf(beat, 10);
        // payload bytes 14..29 = 16 bytes of 0x10..
        for (int i = 0; i < 16; i++) beat[(14+i)*8 +: 8] = 8'h10 + i[7:0];
        // strip_http presents the first beat combinationally, so collect concurrently.
        fork
            drive_beat(beat, keep_n(30), 1'b1);
            collect_body(out_d, out_k);
        join
        flatten(out_d, out_k, got);
        for (int i = 0; i < 16; i++) exp.push_back(8'h10 + i[7:0]);
        expect_bytes("same_beat_flush", got, exp);
        if (out_payload_idx != 7'd14) begin
            $error("[same_beat_flush] offset got=%0d exp=14", out_payload_idx);
            fails++;
        end
    endtask

    // Case 2: \r\n\r\n on last 4 bytes of beat → offset=64, body on next beat.
    task automatic case_crlf_at_end_body_next();
        logic [AXI_DATA_BITS-1:0] b0, b1, out_d[$];
        logic [BYTE_LANES-1:0]    out_k[$], k_unused;
        byte unsigned got[$], exp[$];

        $display("--- case_crlf_at_end_body_next ---");
        reset_dut();
        fill_pattern(b0, k_unused, 64, 8'hA0);
        // overwrite last 4 bytes with CRLF (bytes 60..63)
        poke_crlf(b0, 60);

        fork
            begin
                drive_beat(b0, {BYTE_LANES{1'b1}}, 1'b0);
                fill_pattern(b1, k_unused, 64, 8'h01);
                drive_beat(b1, {BYTE_LANES{1'b1}}, 1'b1);
            end
            begin
                collect_body(out_d, out_k);
            end
        join

        flatten(out_d, out_k, got);
        for (int i = 0; i < 64; i++) exp.push_back(8'h01 + i[7:0]);
        expect_bytes("crlf_at_end_body_next", got, exp);
        if (out_payload_idx != 7'd64) begin
            $error("[crlf_at_end] offset got=%0d exp=64", out_payload_idx);
            fails++;
        end
    endtask

    // Case 3: CRLF spans beats via prev_tail (last 2 of beat0 + first 2 of beat1).
    task automatic case_crlf_spans_beats();
        logic [AXI_DATA_BITS-1:0] b0, b1, out_d[$];
        logic [BYTE_LANES-1:0]    out_k[$], k_unused;
        byte unsigned got[$], exp[$];

        $display("--- case_crlf_spans_beats ---");
        reset_dut();
        fill_pattern(b0, k_unused, 64, 8'hB0);
        // last two bytes of beat0 = \r\n  (bytes 62,63)
        b0[62*8 +: 8] = 8'h0D;
        b0[63*8 +: 8] = 8'h0A;
        // first two of beat1 = \r\n, then payload from byte 2
        fill_pattern(b1, k_unused, 64, 8'h20);
        b1[0*8 +: 8] = 8'h0D;
        b1[1*8 +: 8] = 8'h0A;
        // payload bytes 2..63 already from fill starting 0x20 — rewrite payload as 0x30+
        for (int i = 2; i < 64; i++) b1[i*8 +: 8] = 8'h30 + (i-2);
        // strip_http presents beats combinationally, so collect concurrently.
        fork
            begin
                drive_beat(b0, {BYTE_LANES{1'b1}}, 1'b0);
                drive_beat(b1, {BYTE_LANES{1'b1}}, 1'b1);
            end
            collect_body(out_d, out_k);
        join
        flatten(out_d, out_k, got);
        // payload = bytes 2..63 of b1 = 62 bytes
        for (int i = 0; i < 62; i++) exp.push_back(8'h30 + i[7:0]);
        expect_bytes("crlf_spans_beats", got, exp);
    endtask

    // Case 4: multi-beat body with mid-beat align + partial last keep.
    task automatic case_multibeat_partial_last();
        logic [AXI_DATA_BITS-1:0] b0, b1, b2, out_d[$];
        logic [BYTE_LANES-1:0]    k2, out_k[$], k_unused;
        byte unsigned got[$], exp[$];
        int pay0;

        $display("--- case_multibeat_partial_last ---");
        reset_dut();
        // CRLF at byte 8 → payload starts at 12 in first beat
        b0 = '0;
        for (int i = 0; i < 12; i++) b0[i*8 +: 8] = 8'h48;
        poke_crlf(b0, 8);
        for (int i = 12; i < 64; i++) b0[i*8 +: 8] = 8'h40 + (i-12);

        fork
            begin
                drive_beat(b0, {BYTE_LANES{1'b1}}, 1'b0);
                fill_pattern(b1, k_unused, 64, 8'h80);
                drive_beat(b1, {BYTE_LANES{1'b1}}, 1'b0);
                fill_pattern(b2, k2, 20, 8'hC0);
                drive_beat(b2, k2, 1'b1);
            end
            begin
                collect_body(out_d, out_k);
            end
        join

        flatten(out_d, out_k, got);

        // Expected: 52 bytes from b0[12..63], 64 from b1, 20 from b2
        for (int i = 0; i < 52; i++) exp.push_back(8'h40 + i[7:0]);
        for (int i = 0; i < 64; i++) exp.push_back(8'h80 + i[7:0]);
        for (int i = 0; i < 20; i++) exp.push_back(8'hC0 + i[7:0]);
        expect_bytes("multibeat_partial_last", got, exp);
    endtask

    // Case 5: backpressure — hold m_axis_tready low for a few cycles mid-stream.
    task automatic case_backpressure();
        logic [AXI_DATA_BITS-1:0] b0, b1, out_d[$];
        logic [BYTE_LANES-1:0]    out_k[$], k_unused;
        byte unsigned got[$], exp[$];
        int stall;

        $display("--- case_backpressure ---");
        reset_dut();
        b0 = '0;
        poke_crlf(b0, 0); // payload from byte 4
        for (int i = 4; i < 64; i++) b0[i*8 +: 8] = 8'h50 + (i-4);

        // Drive and collect concurrently (combinational first-beat output).
        fork
            begin
                drive_beat(b0, {BYTE_LANES{1'b1}}, 1'b0);
                fill_pattern(b1, k_unused, 64, 8'h90);
                // insert stalls while driving second beat / body out
                m_axis_tready = 1'b0;
                repeat (5) @(posedge clk);
                m_axis_tready = 1'b1;
                drive_beat(b1, {BYTE_LANES{1'b1}}, 1'b1);
            end
            begin
                collect_body(out_d, out_k, 400);
            end
        join

        flatten(out_d, out_k, got);
        for (int i = 0; i < 60; i++) exp.push_back(8'h50 + i[7:0]);
        for (int i = 0; i < 64; i++) exp.push_back(8'h90 + i[7:0]);
        expect_bytes("backpressure", got, exp);
    endtask

    // Case 6: header-only last beat (CRLF at end), empty body → flush empty / done.
    task automatic case_header_only_tlast();
        logic [AXI_DATA_BITS-1:0] b0, out_d[$];
        logic [BYTE_LANES-1:0]    out_k[$], k_unused;

        $display("--- case_header_only_tlast ---");
        reset_dut();
        fill_pattern(b0, k_unused, 64, 8'h11);
        poke_crlf(b0, 60);
        drive_beat(b0, {BYTE_LANES{1'b1}}, 1'b1);
        collect_body(out_d, out_k);

        // Expect either no beats or one empty-keep last beat; must reach done.
        if (!done) begin
            $error("[header_only_tlast] did not reach done");
            fails++;
        end else if (out_d.size() == 0) begin
            $display("[PASS] header_only_tlast (no body beats)");
            passes++;
        end else if (out_d.size() == 1 && count_keep(out_k[0]) == 0) begin
            $display("[PASS] header_only_tlast (empty flush beat)");
            passes++;
        end else begin
            $error("[header_only_tlast] unexpected %0d beats, keep0=%0d",
                   out_d.size(), count_keep(out_k[0]));
            fails++;
        end
    endtask

    initial begin
        fails  = 0;
        passes = 0;
        rst_n  = 1'b0;
        clear  = 1'b1;
        enable = 1'b0;
        s_axis_tvalid = 1'b0;
        m_axis_tready = 1'b1;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        case_same_beat_flush();
        case_crlf_at_end_body_next();
        case_crlf_spans_beats();
        case_multibeat_partial_last();
        case_backpressure();
        case_header_only_tlast();

        $display("========================================");
        $display("strip_http_tb: %0d passed, %0d failed", passes, fails);
        $display("========================================");
        if (fails != 0) $fatal(1, "test failed");
        $finish;
    end

    // Safety timeout
    initial begin
        #200_000;
        $fatal(1, "timeout");
    end

endmodule
