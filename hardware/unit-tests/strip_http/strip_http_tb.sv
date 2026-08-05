`timescale 1ns / 1ps

// Standalone testbench for strip_http -- the HTTP/1.1 response framer.
// Run: ./run.sh
//
// The DUT no longer ends a body on the TCP tlast; it parses Content-Length and counts the body down.
// That is what makes one persistent connection possible, so the cases below are built around the
// situations a persistent connection creates and the old FIN-delimited design never saw:
//
//   * two responses back to back in ONE byte stream, with the boundary deliberately landing in the
//     middle of a 64-byte beat -- the case that would have run body k into header k+1;
//   * a header block split across beats at every awkward place (inside the name, inside the value,
//     between CR and LF);
//   * body_last=0, i.e. one decoder stream assembled from several ranged GETs, which must produce
//     exactly ONE tlast at the very end and none in between;
//   * a header block with no Content-Length at all, which must latch resp_error rather than guess.
//
// Bytes are compared end to end, and every emitted beat is checked to be bottom-justified: the
// downstream DataNormalizer places bytes from $countones(tkeep), so a beat whose valid bytes do not
// start at lane 0 is silently scrambled rather than rejected.

import lynxTypes::*;

module strip_http_tb;

    localparam int BYTE_LANES = AXI_DATA_BITS / 8; // 64
    localparam int CLK_NS     = 10;

    logic clk;
    logic rst_n;
    logic clear;
    logic enable;
    logic body_last;
    logic resp_ack;

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
    logic                       resp_done, resp_dirty, resp_error;
    logic [23:0]                status_ascii;
    logic                       status_ok;
    logic [31:0]                body_remaining;
    logic [6:0]                 out_payload_idx;

    int unsigned fails;
    int unsigned passes;

    strip_http dut (
        .clk(clk),
        .rst_n(rst_n),
        .clear(clear),
        .enable(enable),
        .body_last(body_last),
        .resp_ack(resp_ack),
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
        .resp_done(resp_done),
        .resp_dirty(resp_dirty),
        .resp_error(resp_error),
        .status_ascii(status_ascii),
        .status_ok(status_ok),
        .body_remaining(body_remaining),
        .out_payload_idx(out_payload_idx)
    );

    initial clk = 1'b0;
    always #(CLK_NS/2) clk = ~clk;

    // ------------------------------------------------------------------
    // Output collector: every accepted beat, plus a bottom-justification check.
    // ------------------------------------------------------------------
    byte unsigned got_bytes[$];
    int           tlast_at[$];   // byte counts at which a tlast was seen

    function automatic int count_keep(input logic [BYTE_LANES-1:0] k);
        count_keep = 0;
        for (int i = 0; i < BYTE_LANES; i++) if (k[i]) count_keep++;
    endfunction

    function automatic logic [BYTE_LANES-1:0] keep_n(input int n);
        keep_n = '0;
        if (n <= 0) return keep_n;
        if (n >= BYTE_LANES) return {BYTE_LANES{1'b1}};
        keep_n = {BYTE_LANES{1'b1}} >> (BYTE_LANES - n);
    endfunction

    // Sampled at the NEGEDGE. Reading a handshake just after a posedge gives the values the edge
    // produced, not the ones it consumed; mid-cycle they are settled and are exactly what the next
    // posedge will transfer.
    always @(negedge clk) begin
        if (rst_n && m_axis_tvalid && m_axis_tready) begin
            if (m_axis_tkeep !== keep_n(count_keep(m_axis_tkeep))) begin
                $error("[justify] non-bottom-justified keep=0x%016h", m_axis_tkeep);
                fails++;
            end
            for (int i = 0; i < BYTE_LANES; i++) begin
                if (m_axis_tkeep[i]) got_bytes.push_back(m_axis_tdata[i*8 +: 8]);
            end
            if (m_axis_tlast) tlast_at.push_back(got_bytes.size());
        end
    end

    // ------------------------------------------------------------------
    // Stimulus helpers
    // ------------------------------------------------------------------
    task automatic reset_dut();
        clear         = 1'b1;
        enable        = 1'b1;
        body_last     = 1'b1;
        resp_ack      = 1'b0;
        s_axis_tvalid = 1'b0;
        s_axis_tdata  = '0;
        s_axis_tkeep  = '0;
        s_axis_tlast  = 1'b0;
        m_axis_tready = 1'b1;
        got_bytes.delete();
        tlast_at.delete();
        @(posedge clk);
        @(posedge clk);
        #1;
        clear = 1'b0;
        @(posedge clk);
        #1;
    endtask

    // \r is not a standard SystemVerilog string escape, so CRLF goes in as explicit bytes.
    task automatic push_str(ref byte unsigned out[$], input string s);
        for (int i = 0; i < s.len(); i++) out.push_back(byte'(s[i]));
    endtask

    task automatic push_crlf(ref byte unsigned out[$]);
        out.push_back(8'h0D);
        out.push_back(8'h0A);
    endtask

    // A realistic MinIO-shaped 206 response. `cl_name` lets a case exercise the case-insensitive
    // match, and `omit_cl` the unframeable path.
    task automatic make_response(
        ref   byte unsigned out[$],
        input int           body_len,
        input byte unsigned base,
        input string        status   = "206 Partial Content",
        input string        cl_name  = "Content-Length",
        input bit           omit_cl  = 1'b0
    );
        push_str(out, "HTTP/1.1 ");
        push_str(out, status);
        push_crlf(out);
        push_str(out, "Accept-Ranges: bytes");
        push_crlf(out);
        push_str(out, "Content-Type: application/octet-stream");
        push_crlf(out);
        if (!omit_cl) begin
            push_str(out, cl_name);
            push_str(out, ": ");
            push_str(out, $sformatf("%0d", body_len));
            push_crlf(out);
        end
        push_str(out, "Server: MinIO");
        push_crlf(out);
        push_crlf(out);
        for (int i = 0; i < body_len; i++) out.push_back(base + i[7:0]);
    endtask

    // Drive a byte stream chopped into beats of at most `beat_max` bytes. tlast is never asserted:
    // on a persistent connection there is no FIN, and the DUT must not need one.
    task automatic drive_stream(input byte unsigned bytes[$], input int beat_max = BYTE_LANES);
        int pos, n;
        logic [AXI_DATA_BITS-1:0] beat;
        pos = 0;
        while (pos < bytes.size()) begin
            n = bytes.size() - pos;
            if (n > beat_max) n = beat_max;
            beat = '0;
            for (int i = 0; i < n; i++) beat[i*8 +: 8] = bytes[pos + i];
            s_axis_tdata  = beat;
            s_axis_tkeep  = keep_n(n);
            s_axis_tlast  = 1'b0;
            s_axis_tvalid = 1'b1;
            // Wait mid-cycle until the DUT will accept at the coming posedge, then let that posedge
            // happen. Polling tready straight after a posedge instead reads the value the edge just
            // produced, which made the driver advance on transfers that had not happened and
            // silently shifted every later beat boundary.
            @(negedge clk);
            while (!s_axis_tready) @(negedge clk);
            @(posedge clk);
            // Hold the beat a moment past the edge. Changing a driven signal in the same delta as
            // the posedge is a race the DUT can lose either way -- here it lost it consistently,
            // sampling the NEXT beat and dropping the status line of every response.
            #1;
            pos += n;
        end
        s_axis_tvalid = 1'b0;
    endtask

    // Retire `n_resp` responses. `lasts[i]` is the body_last presented while response i streams.
    // body_last for response i+1 is armed in the same cycle as the ack for response i, which the DUT
    // guarantees is early enough: it holds at the LF closing the next header block until acked.
    task automatic serve(input int n_resp, ref bit lasts[$]);
        int guard;
        for (int i = 0; i < n_resp; i++) begin
            guard = 0;
            while (!resp_done && !resp_error && guard < 20000) begin
                @(negedge clk);
                guard++;
            end
            if (resp_error) return;
            if (!resp_done) begin
                $error("[serve] response %0d never completed", i);
                fails++;
                return;
            end
            body_last = (i + 1 < n_resp) ? lasts[i+1] : 1'b1;
            resp_ack  = 1'b1;
            @(posedge clk);
            #1;
            resp_ack = 1'b0;
        end
    endtask

    task automatic expect_bytes(input string name, input byte unsigned exp[$]);
        if (got_bytes.size() != exp.size()) begin
            $error("[%s] length got=%0d exp=%0d", name, got_bytes.size(), exp.size());
            fails++;
            return;
        end
        for (int i = 0; i < exp.size(); i++) begin
            if (got_bytes[i] !== exp[i]) begin
                $error("[%s] byte[%0d] got=0x%02x exp=0x%02x", name, i, got_bytes[i], exp[i]);
                fails++;
                return;
            end
        end
        $display("[PASS] %s (%0d bytes)", name, exp.size());
        passes++;
    endtask

    task automatic expect_int(input string name, input int got, input int exp);
        if (got !== exp) begin
            $error("[%s] got=%0d exp=%0d", name, got, exp);
            fails++;
        end else begin
            $display("[PASS] %s = %0d", name, exp);
            passes++;
        end
    endtask

    // ------------------------------------------------------------------
    // Cases
    // ------------------------------------------------------------------

    // One response. The body length is chosen so it neither starts nor ends on a beat boundary.
    task automatic case_single_response();
        byte unsigned stream[$], exp[$];
        bit lasts[$];

        $display("--- case_single_response ---");
        reset_dut();
        make_response(stream, 150, 8'h10);
        for (int i = 0; i < 150; i++) exp.push_back(8'h10 + i[7:0]);
        lasts = '{1'b1};

        fork
            drive_stream(stream);
            serve(1, lasts);
        join

        expect_bytes("single_response", exp);
        expect_int("single_response tlast count", tlast_at.size(), 1);
        if (tlast_at.size() == 1) expect_int("single_response tlast position", tlast_at[0], 150);
        if (status_ascii !== "206" || !status_ok) begin
            $error("[single_response] status got='%s' ok=%0b", string'(status_ascii), status_ok);
            fails++;
        end
    endtask

    // THE case keep-alive exists for: two responses in one continuous stream, no FIN anywhere, and
    // the boundary between body 0 and the status line of response 1 deliberately inside a beat.
    task automatic case_two_responses();
        byte unsigned stream[$], exp[$];
        bit lasts[$];

        $display("--- case_two_responses ---");
        reset_dut();
        // 100 and 77 are both non-multiples of 64, so response 1's header starts mid-beat and its
        // body starts at a different phase again.
        make_response(stream, 100, 8'h20);
        make_response(stream, 77,  8'h70);
        for (int i = 0; i < 100; i++) exp.push_back(8'h20 + i[7:0]);
        for (int i = 0; i < 77;  i++) exp.push_back(8'h70 + i[7:0]);
        lasts = '{1'b1, 1'b1};

        fork
            drive_stream(stream);
            serve(2, lasts);
        join

        expect_bytes("two_responses", exp);
        expect_int("two_responses tlast count", tlast_at.size(), 2);
        if (tlast_at.size() == 2) begin
            expect_int("two_responses tlast 0", tlast_at[0], 100);
            expect_int("two_responses tlast 1", tlast_at[1], 177);
        end
    endtask

    // One decoder stream assembled from three ranged GETs: exactly one tlast, at the very end.
    // This is what the host does when it splits a column chunk to bound the bytes in flight.
    task automatic case_split_chunk_single_tlast();
        byte unsigned stream[$], exp[$];
        bit lasts[$];

        $display("--- case_split_chunk_single_tlast ---");
        reset_dut();
        make_response(stream, 200, 8'h01);
        make_response(stream, 200, 8'h41);
        make_response(stream, 90,  8'h81);
        for (int i = 0; i < 200; i++) exp.push_back(8'h01 + i[7:0]);
        for (int i = 0; i < 200; i++) exp.push_back(8'h41 + i[7:0]);
        for (int i = 0; i < 90;  i++) exp.push_back(8'h81 + i[7:0]);
        lasts = '{1'b0, 1'b0, 1'b1};
        body_last = lasts[0];

        fork
            drive_stream(stream);
            serve(3, lasts);
        join

        expect_bytes("split_chunk", exp);
        expect_int("split_chunk tlast count", tlast_at.size(), 1);
        if (tlast_at.size() == 1) expect_int("split_chunk tlast position", tlast_at[0], 490);
    endtask

    // Beats of 1..7 bytes chop the header block at every alignment, including between the CR and
    // the LF of the blank line -- the byte pair the whole frame decision hangs on.
    task automatic case_ragged_beats();
        byte unsigned stream[$], exp[$];
        bit lasts[$];

        $display("--- case_ragged_beats ---");
        reset_dut();
        make_response(stream, 130, 8'hA0);
        make_response(stream, 33,  8'hE0);
        for (int i = 0; i < 130; i++) exp.push_back(8'hA0 + i[7:0]);
        for (int i = 0; i < 33;  i++) exp.push_back(8'hE0 + i[7:0]);
        lasts = '{1'b1, 1'b1};

        fork
            drive_stream(stream, 7);
            serve(2, lasts);
        join

        expect_bytes("ragged_beats", exp);
        expect_int("ragged_beats tlast count", tlast_at.size(), 2);
    endtask

    // Downstream back-pressure across a response boundary. drain_wait_q must keep the framer off the
    // next body until the previous one has actually left the skid.
    task automatic case_backpressure();
        byte unsigned stream[$], exp[$];
        bit lasts[$];

        $display("--- case_backpressure ---");
        reset_dut();
        make_response(stream, 300, 8'h05);
        make_response(stream, 64,  8'h55);
        for (int i = 0; i < 300; i++) exp.push_back(8'h05 + i[7:0]);
        for (int i = 0; i < 64;  i++) exp.push_back(8'h55 + i[7:0]);
        lasts = '{1'b1, 1'b1};

        fork
            begin
                fork
                    drive_stream(stream);
                    serve(2, lasts);
                join
            end
            // Stutter tready for as long as the run lasts; killed by the disable below. Every
            // change lands #1 past the edge for the same reason drive_stream holds its beat.
            forever begin
                m_axis_tready = 1'b0;
                repeat (3) @(posedge clk);
                #1;
                m_axis_tready = 1'b1;
                @(posedge clk);
                #1;
            end
        join_any
        disable fork;
        m_axis_tready = 1'b1;
        @(posedge clk);

        expect_bytes("backpressure", exp);
        expect_int("backpressure tlast count", tlast_at.size(), 2);
    endtask

    // Content-Length: 0 completes with no body beat at all, and must not swallow the response after
    // it. A ranged GET can legitimately answer 0 bytes (an empty column chunk).
    task automatic case_zero_length();
        byte unsigned stream[$], exp[$];
        bit lasts[$];

        $display("--- case_zero_length ---");
        reset_dut();
        make_response(stream, 0,  8'h00);
        make_response(stream, 48, 8'h60);
        for (int i = 0; i < 48; i++) exp.push_back(8'h60 + i[7:0]);
        lasts = '{1'b1, 1'b1};

        fork
            drive_stream(stream);
            serve(2, lasts);
        join

        expect_bytes("zero_length", exp);
        expect_int("zero_length tlast count", tlast_at.size(), 1);
    endtask

    // Header names are case-insensitive per RFC 9110; a server that sends "content-length" must not
    // silently become an unframeable response.
    task automatic case_lowercase_header();
        byte unsigned stream[$], exp[$];
        bit lasts[$];

        $display("--- case_lowercase_header ---");
        reset_dut();
        make_response(stream, 96, 8'h30, "206 Partial Content", "content-length");
        for (int i = 0; i < 96; i++) exp.push_back(8'h30 + i[7:0]);
        lasts = '{1'b1};

        fork
            drive_stream(stream);
            serve(1, lasts);
        join

        expect_bytes("lowercase_header", exp);
        if (resp_error) begin
            $error("[lowercase_header] resp_error set");
            fails++;
        end
    endtask

    // No Content-Length: unframeable. This is the Transfer-Encoding: chunked guard, expressed as the
    // more general condition. It must latch resp_error and emit nothing, not guess a length.
    task automatic case_no_content_length();
        byte unsigned stream[$];
        int guard;

        $display("--- case_no_content_length ---");
        reset_dut();
        make_response(stream, 64, 8'hF0, "200 OK", "Content-Length", 1'b1);

        fork
            drive_stream(stream);
            begin
                guard = 0;
                while (!resp_error && guard < 5000) begin
                    @(posedge clk);
                    guard++;
                end
            end
        join_any
        disable fork;

        if (!resp_error) begin
            $error("[no_content_length] resp_error not set");
            fails++;
        end else if (got_bytes.size() != 0) begin
            $error("[no_content_length] emitted %0d bytes", got_bytes.size());
            fails++;
        end else begin
            $display("[PASS] no_content_length (resp_error, no bytes emitted)");
            passes++;
        end
    endtask

    // A 404 still has a Content-Length and still frames, so the framer keeps working -- but the host
    // has to be able to tell that the "column data" it just received is an XML error document.
    task automatic case_bad_status();
        byte unsigned stream[$];
        bit lasts[$];

        $display("--- case_bad_status ---");
        reset_dut();
        make_response(stream, 40, 8'h00, "404 Not Found");
        lasts = '{1'b1};

        fork
            drive_stream(stream);
            serve(1, lasts);
        join

        if (status_ascii !== "404") begin
            $error("[bad_status] status got='%s'", string'(status_ascii));
            fails++;
        end else if (status_ok) begin
            $error("[bad_status] status_ok set for a 404");
            fails++;
        end else begin
            $display("[PASS] bad_status (404 captured, status_ok low)");
            passes++;
        end
    endtask

    // resp_dirty is what tells the handler whether a dead connection can be replayed. It must be
    // low while only headers have been consumed and high once body bytes are downstream.
    task automatic case_dirty_flag();
        byte unsigned stream[$];
        bit lasts[$];
        int guard;

        $display("--- case_dirty_flag ---");
        reset_dut();
        make_response(stream, 256, 8'h11);

        if (resp_dirty) begin
            $error("[dirty_flag] set before any data");
            fails++;
        end

        fork
            drive_stream(stream);
            begin
                guard = 0;
                while (got_bytes.size() == 0 && guard < 5000) begin
                    @(posedge clk);
                    guard++;
                end
                if (!resp_dirty) begin
                    $error("[dirty_flag] not set after body bytes were emitted");
                    fails++;
                end else begin
                    $display("[PASS] dirty_flag");
                    passes++;
                end
            end
        join

        lasts = '{1'b1};
        serve(1, lasts);
        // The ack retires the response and clears dirty for the next one.
        @(posedge clk);
        if (resp_dirty) begin
            $error("[dirty_flag] still set after resp_ack");
            fails++;
        end
    endtask

    initial begin
        fails  = 0;
        passes = 0;
        rst_n  = 1'b0;
        clear  = 1'b1;
        enable = 1'b1;
        body_last     = 1'b1;
        resp_ack      = 1'b0;
        s_axis_tvalid = 1'b0;
        m_axis_tready = 1'b1;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        case_single_response();
        case_two_responses();
        case_split_chunk_single_tlast();
        case_ragged_beats();
        case_backpressure();
        case_zero_length();
        case_lowercase_header();
        case_no_content_length();
        case_bad_status();
        case_dirty_flag();

        $display("========================================");
        $display("strip_http_tb: %0d passed, %0d failed", passes, fails);
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
