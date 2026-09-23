`timescale 1ns / 1ps

import lynxTypes::*;
import libstf::*;
import parcore::*;

// =================================================================================================
// ColumnChunkDecoder: one output tlast per column chunk, at exactly num_values values, when the
// decoder's front end runs a chunk ahead of its output.
//
// WHY THIS BENCH EXISTS (build-124, 2026-09-23)
// ---------------------------------------------
// Under TPC-H sf30 the board showed decoders whose output carried every decoded byte but never
// again a tlast (so the host never got a completion interrupt for that stream), and decoders
// whose input stopped dead with their output mid-chunk. Both persisted across processes until the
// next reprogram, and only queries touching region (5-row columns: ONE output beat) did it. Two
// defects in parcore hand a chunk's value count to TypedNormalizeUntil (TNU) wrongly:
//
//   1. TNU took the count (and latched the type) when `in.valid` was high, but the chunk's first
//      beat can already sit in TNU's INPUT SKID BUFFER, taken in while the previous chunk was still
//      being counted. A one-beat chunk is then wholly inside it with `in.valid` low, and it is
//      configured only when the NEXT chunk's first beat arrives -- with whatever count is on offer
//      and with the next chunk's type (INT64 vs INT32 halves the value count per beat).
//   2. ColumnChunkDecoder's ST_IDLE accepted the next chunk's conf and did `num_values.data <= ..;
//      valid <= 1` whether or not TNU had taken the previous count, and cleared `valid` on a
//      handshake only `if (state != ST_IDLE)`: a count could be overwritten, or offered twice.
//
// Either way TNU's `remaining` no longer lands on 0 at a page's last beat. It then wraps (every
// later beat passes with no tlast -- the "no completion" wedge) or reaches 0 mid-page and waits for
// a count nobody will send (the "input stopped dead" wedge). Nothing resets it short of a
// reprogram. Fixing only (2) by gating the conf on `!num_values.valid` DEADLOCKS on (1): the
// one-beat chunk sits in the skid buffer and its count is never taken. Fixing only (1) leaves the
// overwrite. The fix (parcore, 2026-09-23) does both: TNU keys on its skid buffer's head beat
// (TypedNDataSkidBuffer, so the type travels with the beat), and the decoder takes the next conf
// only after the previous count was taken and clears `valid` on the handshake in any state.
//
// THE CASES
// ---------
// Every case feeds a sequence of PLAIN, uncompressed chunks (the thrift header, def levels and
// values are built here, byte for byte like parcore's column_chunk_decoder_test.py) back to back
// on the input and checks that the output carries exactly one tlast per chunk, after exactly that
// chunk's bytes, in order. Output back-pressure (OUTDIV) is what lets the front end run ahead.
//
//   plusargs: SCEN   0 = big, tiny, small            confs all queued up front
//                    1 = same, but each conf is written only after the previous-but-one chunk's
//                        output tlast (the host-late ordering that produces the DUPLICATE)
//                    2 = eight chunks alternating big/tiny, confs up front
//                    3 = big, ONE-beat chunk (5 x INT32, like region), small; confs up front
//                    4 = eight chunks alternating big/one-beat, confs up front
//             OUTDIV output ready one cycle in OUTDIV (1 = always ready)
//             BIG    values in a big chunk (INT64), default 256
//             BUDGET cycles to wait for the last tlast
//             NOASSERT  switch libstf's handshake assertions off inside the DUT
//
// Measured 2026-09-23 (run.sh runs the eight cases in parallel, ~7 min):
//   unfixed:            SCEN 3/4 at OUTDIV 16 stop on libstf's assertion "Signal data needs to be
//                       stable while valid && !ready" (dut.num_values); with NOASSERT SCEN 4 gives
//                       ONE of 8 tlasts and 6208 bytes out with no tlast (the no-completion wedge),
//                       SCEN 3 stops with 512 bytes out (the input-stopped wedge). SCEN 0-2 pass.
//   decoder gate only:  SCEN 3/4 at OUTDIV 16 DEADLOCK after tlast #0, 0 bytes pending.
//   TNU skid fix only:  SCEN 3 (NOASSERT) 1 of 3 tlasts, 512 bytes pending; SCEN 4 1 of 8, 6208.
//   both fixes:         all eight cases PASS.
// =================================================================================================
module decoder_numvalues_tb;

    localparam int DB = AXI_DATA_BITS / 8;   // 64

    logic clk = 1'b0, rst_n = 1'b0;
    always #2 clk = ~clk;

    ready_valid_i #(column_chunk_conf_t) conf (clk, rst_n);
    ndata_i #(data8_t, DB)               din  (clk, rst_n);
    typed_ndata_i #(DB)                  dout (clk, rst_n);
    decoder_profile_i                    prof ();

    assign prof.stop = 1'b0;

    ColumnChunkDecoder #(.DATABEAT_SIZE(DB)) dut (
        .clk(clk), .rst_n(rst_n),
        .conf(conf), .in(din), .out(dout), .profile(prof)
    );

    // ---------------------------------------------------------------------------------------------
    // Chunk construction
    // ---------------------------------------------------------------------------------------------
    typedef byte unsigned bq_t[$];

    function automatic void push_varint(ref bq_t q, input longint unsigned v);
        do begin
            byte unsigned b = v[6:0];
            v = v >> 7;
            if (v != 0) b = b | 8'h80;
            q.push_back(b);
        end while (v != 0);
    endfunction

    // A PLAIN data page of n values of the given width (4 or 8 bytes), values seed+i.
    function automatic bq_t make_plain(input int n, input int width, input int seed);
        bq_t q, payload, dl;
        // def levels: RLE run of n ones, bit width 1, behind a 4-byte little-endian length
        push_varint(dl, longint'(n) << 1);
        dl.push_back(8'h01);
        for (int k = 0; k < 4; k++) payload.push_back(8'((dl.size() >> (8*k)) & 8'hFF));
        foreach (dl[k]) payload.push_back(dl[k]);
        for (int i = 0; i < n; i++)
            for (int k = 0; k < width; k++) payload.push_back(8'(((seed + i) >> (8*k)) & 8'hFF));
        // thrift compact DataPageHeader, as _make_data_page_header(): i32 fields are zigzag varints
        q.push_back(8'h15); push_varint(q, 0);
        q.push_back(8'h15); push_varint(q, 2 * payload.size());
        q.push_back(8'h15); push_varint(q, 2 * payload.size());
        q.push_back(8'h2c);
        q.push_back(8'h15); push_varint(q, 2 * n);
        q.push_back(8'h15); push_varint(q, 0);
        q.push_back(8'h15); push_varint(q, 0);
        q.push_back(8'h15); push_varint(q, 0);
        q.push_back(8'h00);
        q.push_back(8'h00);
        foreach (payload[k]) q.push_back(payload[k]);
        return q;
    endfunction

    int scen, outdiv, big;
    int n_chunks;
    int ch_n     [16];
    int ch_width [16];
    bq_t ch_bytes[16];

    task automatic add_chunk(input int n, input int width);
        ch_n[n_chunks]     = n;
        ch_width[n_chunks] = width;
        ch_bytes[n_chunks] = make_plain(n, width, 1000 * (n_chunks + 1));
        n_chunks++;
    endtask

    // ---------------------------------------------------------------------------------------------
    // Output monitor
    // ---------------------------------------------------------------------------------------------
    int  got_bytes, got_lasts, errors;
    int  seen_last [16];
    time t_last    [16];
    int  out_ready_cnt;

    always @(negedge clk) begin
        if (rst_n && dout.valid && dout.ready) begin
            got_bytes += $countones(dout.keep);
            if (dout.last) begin
                if (got_lasts >= n_chunks) begin
                    $display("decoder_numvalues: FAIL extra tlast #%0d after %0d bytes", got_lasts, got_bytes);
                    errors++;
                end else if (got_bytes != ch_n[got_lasts] * ch_width[got_lasts]) begin
                    $display("decoder_numvalues: FAIL chunk %0d tlast after %0d bytes, expected %0d (%0d x %0d B)",
                             got_lasts, got_bytes, ch_n[got_lasts] * ch_width[got_lasts],
                             ch_n[got_lasts], ch_width[got_lasts]);
                    errors++;
                end
                $display("decoder_numvalues: t=%0t tlast #%0d", $time, got_lasts);
                if (got_lasts < 16) begin
                    seen_last[got_lasts] = 1;
                    t_last[got_lasts]    = $time;
                end
                got_lasts++;
                got_bytes = 0;
            end
        end
    end

    // output ready: one cycle in OUTDIV
    always @(posedge clk) begin
        out_ready_cnt <= (out_ready_cnt + 1) % outdiv;
        #1 dout.ready = (outdiv <= 1) ? 1'b1 : (out_ready_cnt == 0);
    end

    // ---------------------------------------------------------------------------------------------
    // Drivers
    // ---------------------------------------------------------------------------------------------
    task automatic send_conf(input int k);
        @(posedge clk); #1;
        conf.data.compression = COMPRESSION_RAW;
        conf.data.num_values  = ch_n[k];
        conf.data.typ         = (ch_width[k] == 8) ? INT64_T : INT32_T;
        conf.valid            = 1'b1;
        forever begin
            @(negedge clk);
            if (conf.ready) break;
        end
        @(posedge clk); #1;
        conf.valid = 1'b0;
    endtask

    task automatic conf_driver();
        for (int k = 0; k < n_chunks; k++) begin
            if (scen == 1 && k >= 2) begin
                // host-late: conf k only after chunk k-1's output has finished
                wait (seen_last[k-1] == 1);
                repeat (20) @(posedge clk);
            end
            send_conf(k);
        end
    endtask

    task automatic data_driver();
        for (int k = 0; k < n_chunks; k++) begin
            int nb = ch_bytes[k].size();
            for (int off = 0; off < nb; off += DB) begin
                @(posedge clk); #1;
                din.valid = 1'b1;
                din.keep  = '0;
                din.data  = '0;
                for (int j = 0; j < DB; j++) begin
                    if (off + j < nb) begin
                        din.data[j] = ch_bytes[k][off + j];
                        din.keep[j] = 1'b1;
                    end
                end
                din.last = (off + DB >= nb);
                forever begin
                    @(negedge clk);
                    if (din.ready) break;
                end
            end
        end
        @(posedge clk); #1;
        din.valid = 1'b0;
        din.last  = 1'b0;
    endtask

    initial begin
        if (!$value$plusargs("SCEN=%d", scen))     scen   = 0;
        if (!$value$plusargs("OUTDIV=%d", outdiv)) outdiv = 1;
        if (!$value$plusargs("BIG=%d", big))       big    = 256;
        // NOASSERT=1 switches off libstf's handshake assertions inside the DUT, so that an unfixed
        // decoder runs on past the protocol violation and shows what it does to the output.
        if ($test$plusargs("NOASSERT")) $assertoff(0, decoder_numvalues_tb.dut);

        n_chunks = 0; got_bytes = 0; got_lasts = 0; errors = 0; out_ready_cnt = 0;
        for (int k = 0; k < 16; k++) begin seen_last[k] = 0; t_last[k] = 0; end

        case (scen)
            2: begin
                for (int k = 0; k < 4; k++) begin
                    add_chunk(big, 8);
                    add_chunk(25, 4);
                end
            end
            3: begin
                add_chunk(big, 8);   // big INT64
                add_chunk(5, 4);     // ONE output beat, like region's 5-row INT32 columns
                add_chunk(64, 8);
            end
            4: begin
                for (int k = 0; k < 4; k++) begin
                    add_chunk(big, 8);
                    add_chunk(5, 4);
                end
            end
            default: begin
                add_chunk(big, 8);   // big INT64: its output drains slowly
                add_chunk(25, 4);    // tiny INT32, like nation's 100-byte columns
                add_chunk(64, 8);    // small INT64
            end
        endcase

        conf.valid = 1'b0; conf.data = '0;
        din.valid  = 1'b0; din.data = '0; din.keep = '0; din.last = 1'b0;
        dout.ready = 1'b1;
        repeat (20) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (20) @(posedge clk);

        fork
            conf_driver();
            data_driver();
        join_none

        begin
            longint budget;
            if (!$value$plusargs("BUDGET=%d", budget)) budget = 200_000;
            while (got_lasts < n_chunks && budget > 0) begin
                @(posedge clk);
                budget--;
            end
            repeat (2000) @(posedge clk);   // catch any extra tlast
        end

        if (got_lasts != n_chunks) begin
            $display("decoder_numvalues: FAIL %0d of %0d tlasts seen (%0d bytes pending in the open stream)",
                     got_lasts, n_chunks, got_bytes);
            errors++;
        end
        if (errors == 0)
            $display("decoder_numvalues: PASS scen=%0d outdiv=%0d big=%0d chunks=%0d", scen, outdiv, big, n_chunks);
        else
            $display("decoder_numvalues: FAIL scen=%0d outdiv=%0d big=%0d errors=%0d", scen, outdiv, big, errors);
        $finish;
    end

endmodule
