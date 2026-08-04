`timescale 1ns / 1ps

// Regression test for the "one run behind" request-builder bug.
//
// http_req_builder used to hold `req_ready` high in IDLE after finishing a build. Its consumer
// (tcp_send_http) raises `start` and samples `req_ready` in the SAME cycle, so from the second
// request onwards it latched the PREVIOUS build's header_data/header_len and sent the previous
// request's GET -- the file path and Range were always one run behind. Only the first request after
// reset was correct, because req_ready resets to 0.
//
// This bench drives two different requests back to back using exactly that handshake and checks
// that each capture matches the config that was live when it was issued.
module http_req_builder_tb;

    logic          clk = 1'b0;
    logic          rst_n = 1'b0;
    logic          start = 1'b0;

    logic [7:0]    ipHexLen;
    logic [127:0]  ipHex;
    logic [31:0]   portHex;
    logic [6:0]    fileLen;
    logic [31:0]   fileWord0, fileWord1, fileWord2, fileWord3;
    logic [31:0]   fileWord4, fileWord5, fileWord6, fileWord7;
    logic [31:0]   fileWord8, fileWord9, fileWord10, fileWord11;
    logic [31:0]   fileWord12, fileWord13, fileWord14, fileWord15;
    logic [7:0]    rangeBeginLen;
    logic [31:0]   rangeBeginW0, rangeBeginW1, rangeBeginW2, rangeBeginW3;
    logic [7:0]    rangeEndLen;
    logic [31:0]   rangeEndW0, rangeEndW1, rangeEndW2, rangeEndW3;

    logic [2047:0] header_data;
    logic [15:0]   header_len;
    logic          req_ready;

    // Captured by the emulated consumer
    logic [2047:0] cap_data;
    logic [15:0]   cap_len;

    int            errors = 0;

    http_req_builder dut (
        .ap_clk        (clk),
        .ap_rst_n      (rst_n),
        .start         (start),
        .partial_en    (1'b1),
        .ipHexLen      (ipHexLen),
        .ipHex         (ipHex),
        .portHex       (portHex),
        .fileLen       (fileLen),
        .fileWord0     (fileWord0),
        .fileWord1     (fileWord1),
        .fileWord2     (fileWord2),
        .fileWord3     (fileWord3),
        .fileWord4     (fileWord4),
        .fileWord5     (fileWord5),
        .fileWord6     (fileWord6),
        .fileWord7     (fileWord7),
        .fileWord8     (fileWord8),
        .fileWord9     (fileWord9),
        .fileWord10    (fileWord10),
        .fileWord11    (fileWord11),
        .fileWord12    (fileWord12),
        .fileWord13    (fileWord13),
        .fileWord14    (fileWord14),
        .fileWord15    (fileWord15),
        .rangeBeginLen (rangeBeginLen),
        .rangeBeginW0  (rangeBeginW0),
        .rangeBeginW1  (rangeBeginW1),
        .rangeBeginW2  (rangeBeginW2),
        .rangeBeginW3  (rangeBeginW3),
        .rangeEndLen   (rangeEndLen),
        .rangeEndW0    (rangeEndW0),
        .rangeEndW1    (rangeEndW1),
        .rangeEndW2    (rangeEndW2),
        .rangeEndW3    (rangeEndW3),
        .header_data   (header_data),
        .header_len    (header_len),
        .req_ready     (req_ready)
    );

    always #5 clk = ~clk;

    // -- config drivers (little-endian byte packing, matching PackAsciiWords in software) ----------
    task automatic set_path(input string s);
        logic [31:0] w [16];
        for (int i = 0; i < 16; i++) w[i] = '0;
        for (int i = 0; i < s.len(); i++) w[i / 4][(i % 4) * 8 +: 8] = s[i];
        fileLen   = s.len();
        fileWord0 = w[0]; fileWord1 = w[1]; fileWord2 = w[2]; fileWord3 = w[3];
        fileWord4 = w[4]; fileWord5 = w[5]; fileWord6 = w[6]; fileWord7 = w[7];
        fileWord8 = w[8]; fileWord9 = w[9]; fileWord10 = w[10]; fileWord11 = w[11];
        fileWord12 = w[12]; fileWord13 = w[13]; fileWord14 = w[14]; fileWord15 = w[15];
    endtask

    task automatic set_ip(input string s);
        logic [127:0] v = '0;
        for (int i = 0; i < s.len(); i++) v[i * 8 +: 8] = s[i];
        ipHex    = v;
        ipHexLen = s.len();
    endtask

    task automatic set_port(input string s); // exactly 4 ASCII chars
        logic [31:0] v = '0;
        for (int i = 0; i < s.len(); i++) v[i * 8 +: 8] = s[i];
        portHex = v;
    endtask

    task automatic set_range_begin(input string s);
        logic [31:0] w [4];
        for (int i = 0; i < 4; i++) w[i] = '0;
        for (int i = 0; i < s.len(); i++) w[i / 4][(i % 4) * 8 +: 8] = s[i];
        rangeBeginLen = s.len();
        rangeBeginW0 = w[0]; rangeBeginW1 = w[1]; rangeBeginW2 = w[2]; rangeBeginW3 = w[3];
    endtask

    task automatic set_range_end(input string s);
        logic [31:0] w [4];
        for (int i = 0; i < 4; i++) w[i] = '0;
        for (int i = 0; i < s.len(); i++) w[i / 4][(i % 4) * 8 +: 8] = s[i];
        rangeEndLen = s.len();
        rangeEndW0 = w[0]; rangeEndW1 = w[1]; rangeEndW2 = w[2]; rangeEndW3 = w[3];
    endtask

    // `\r` is not a standard SystemVerilog string escape (xsim drops the backslash), so CRLF is
    // built from bytes.
    function automatic string crlf();
        return string'({8'h0D, 8'h0A});
    endfunction

    function automatic string expected(input string path, input string ip, input string port4,
                                       input string rb, input string re);
        return {"GET ", path, " HTTP/1.1", crlf(), "Host: ", ip, ":", port4, crlf(),
                "Range: bytes=", rb, "-", re, crlf(), "Connection: close", crlf(), crlf()};
    endfunction

    // -- emulate tcp_send_http's ST_BUILD_HDR exactly ---------------------------------------------
    // `start` is a level (state_q == ST_BUILD_HDR) and req_ready / header_* are sampled
    // combinationally in the same cycle. The negedge sample models that same-cycle visibility.
    task automatic issue_request(input string tag, input bit expect_ready_low_at_start);
        int guard;
        @(posedge clk);
        start = 1'b1;
        #1;
        if (expect_ready_low_at_start && req_ready !== 1'b0) begin
            $display("FAIL [%s]: req_ready already high in the cycle start is raised -- stale level from the previous build (the one-run-behind bug)", tag);
            errors++;
        end

        guard = 0;
        forever begin
            @(negedge clk);
            if (req_ready === 1'b1) begin
                cap_len  = header_len;
                cap_data = header_data;
                break;
            end
            guard++;
            if (guard > 1000) begin
                $display("FAIL [%s]: timed out waiting for req_ready", tag);
                errors++;
                break;
            end
        end

        @(posedge clk);
        start = 1'b0;

        // Idle gap. Dropping `start` one cycle after the capture (as tcp_send_http does, since
        // start == (state_q == ST_BUILD_HDR)) kicks off one more build. In hardware a whole TCP
        // transaction elapses before the next request, so that build has long finished and its
        // req_ready is settled by then. Without this gap the next request would arrive while the
        // builder is still mid-build, which hides the stale-level bug entirely.
        repeat (300) @(posedge clk);
    endtask

    task automatic check(input string tag, input string exp);
        if (cap_len !== exp.len()) begin
            $display("FAIL [%s]: header_len = %0d, expected %0d", tag, cap_len, exp.len());
            errors++;
            return;
        end
        for (int i = 0; i < exp.len(); i++) begin
            if (cap_data[i * 8 +: 8] !== exp[i]) begin
                $display("FAIL [%s]: byte %0d = 0x%02x ('%c'), expected 0x%02x ('%c')", tag, i,
                         cap_data[i * 8 +: 8], cap_data[i * 8 +: 8], exp[i], exp[i]);
                errors++;
                return;
            end
        end
        $display("PASS [%s]: %0d bytes match", tag, cap_len);
    endtask

    string exp1, exp2, exp3, exp4, exp5;
    string path33, path64;

    initial begin
        set_path("/a/1.parquet");
        set_ip("10.0.0.1");
        set_port("9000");
        set_range_begin("100");
        set_range_end("199");

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // Request 1 -- worked even with the bug (req_ready resets to 0).
        exp1 = expected("/a/1.parquet", "10.0.0.1", "9000", "100", "199");
        issue_request("req1", 1'b1);
        check("req1", exp1);

        // Request 2 with a completely different config. With the bug this captured req1's header.
        set_path("/bb/22.parquet");
        set_ip("10.0.0.2");
        set_port("9001");
        set_range_begin("4242");
        set_range_end("5353");
        exp2 = expected("/bb/22.parquet", "10.0.0.2", "9001", "4242", "5353");
        issue_request("req2", 1'b1);
        check("req2", exp2);
        if (cap_len === exp1.len()) begin
            $display("FAIL [req2]: captured req1's length -- still one run behind");
            errors++;
        end

        // Request 3: same length as req2 but different bytes. This is the case that produced no
        // host-side error at all (stale size == requested size) and silently returned wrong data.
        set_path("/cc/33.parquet");
        set_range_begin("7777");
        set_range_end("8888");
        exp3 = expected("/cc/33.parquet", "10.0.0.2", "9001", "7777", "8888");
        issue_request("req3", 1'b1);
        check("req3", exp3);

        // Request 4: 33 characters -- one past the old 8-word / 32-character budget. Before the
        // widening this could not be expressed at all; the software guard threw instead.
        path33 = "/throughput/tpch-1/nation.parquet";
        if (path33.len() != 33) begin
            $display("FAIL [req4]: test path is %0d chars, expected 33", path33.len());
            errors++;
        end
        set_path(path33);
        set_range_begin("4");
        set_range_end("60");
        exp4 = expected(path33, "10.0.0.2", "9001", "4", "60");
        issue_request("req4", 1'b1);
        check("req4", exp4);

        // Request 5: exactly 64 characters, the new maximum. Exercises the top word (fileWord15)
        // and the [5:2] word select that replaced [4:2].
        path64 = "/throughput/tpch-30/verylongprefix/lineitem_column_chunk.parquet";
        if (path64.len() != 64) begin
            $display("FAIL [req5]: test path is %0d chars, expected 64", path64.len());
            errors++;
        end
        set_path(path64);
        set_range_begin("1048576");
        set_range_end("2097151");
        exp5 = expected(path64, "10.0.0.2", "9001", "1048576", "2097151");
        issue_request("req5", 1'b1);
        check("req5", exp5);

        // The whole point of widening the buffer: this header no longer fits in two 64-byte beats,
        // so tcp_send_http's send FSM has to emit a third. Guard against a future change that
        // silently shrinks the header back under 128 and stops covering the multi-beat path.
        if (cap_len <= 16'd128) begin
            $display("FAIL [req5]: header is %0d bytes, expected >128 to exercise the 3rd send beat",
                     cap_len);
            errors++;
        end else begin
            $display("PASS [req5]: %0d bytes spans %0d send beats", cap_len, (cap_len + 63) / 64);
        end

        if (errors == 0) $display("http_req_builder_tb: ALL TESTS PASSED");
        else             $display("http_req_builder_tb: %0d FAILURE(S)", errors);
        $finish;
    end

endmodule
