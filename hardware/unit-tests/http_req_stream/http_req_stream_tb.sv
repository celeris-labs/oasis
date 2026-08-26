`timescale 1ns / 1ps

import lynxTypes::*;

// =================================================================================================
// Testbench for http_req_stream: host request bytes -> TCP transmit.
//
// The module replaces the per-request descriptor ring, so the properties that matter are the ones
// the ring used to guarantee structurally and now have to be checked:
//
//   1. EVERY byte the host hands over reaches the wire, exactly once, in order. The ring could not
//      corrupt request text because it rebuilt it from latched fields; a byte stream can, by
//      dropping or duplicating a beat, and the result would be a malformed GET that MinIO answers
//      with a 400 whose body then flows into a column.
//   2. The announced tx_meta length matches the bytes actually pushed for that chunk. If they
//      disagree the TOE's idea of the stream and ours diverge permanently.
//   3. A REFUSED reservation pushes NOTHING and is retried with the same bytes. This is the case
//      that cannot be recovered from after the fact, because an AXI-Stream cannot be rewound.
//   4. Back-pressure on either side is survivable: the host stream stalling mid-chunk, and the TOE
//      stalling tx_data.
//
// The transfer is deliberately not a multiple of the 64-byte beat, so the final beat of the final
// chunk exercises the partial-keep path.
// =================================================================================================
module http_req_stream_tb;

    localparam int LANES       = AXI_DATA_BITS / 8;
    localparam int CHUNK_BYTES = 4096;
    // 9000 bytes = two full chunks plus 808 -- so three chunks, the last partial, and the last beat
    // of it carrying 40 of 64 lanes.
    localparam int TOTAL_BYTES = 9000;
    // What the DMA actually moves: whole 64-byte beats, so 9000 arrives as 9024. The 24 bytes past
    // the announced length must NOT reach the wire and must NOT be left in the stream, where they
    // would prefix the next transfer's first request line. That is a real observed failure -- an
    // intermittent 400 Bad Request on an otherwise healthy connection.
    localparam int DMA_BYTES = ((TOTAL_BYTES + LANES - 1) / LANES) * LANES;
    localparam int REFUSE_ON   = 2;   // refuse the 2nd reservation

    logic clk = 0, rst_n = 0;
    always #2 clk = ~clk;

    logic        conn_up = 0;
    logic [31:0] req_total_bytes = 0;
    logic        req_start = 0;

    logic                       rq_valid = 0, rq_ready;
    logic [AXI_DATA_BITS-1:0]   rq_data  = '0;
    logic [LANES-1:0]           rq_keep  = '0;
    logic                       rq_last  = 0;

    logic                        txm_valid, txm_ready = 1;
    logic [TCP_TX_META_BITS-1:0] txm_data;
    logic                        txd_valid, txd_ready = 1;
    logic [AXI_DATA_BITS-1:0]    txd_data;
    logic [LANES-1:0]            txd_keep;
    logic                        txd_last;
    logic                        txs_valid = 0, txs_ready;
    logic [TCP_TX_STAT_BITS-1:0] txs_data  = '0;

    logic        busy, refused_sticky;
    logic [29:0] tx_space;
    logic [3:0]  state_debug;

    http_req_stream #(.CHUNK_BYTES(CHUNK_BYTES)) dut (
        .clk(clk), .rst_n(rst_n),
        .conn_up(conn_up), .session_id(16'h00A5),
        .req_total_bytes(req_total_bytes), .req_start(req_start),
        .s_axis_req_TVALID(rq_valid), .s_axis_req_TREADY(rq_ready),
        .s_axis_req_TDATA(rq_data), .s_axis_req_TKEEP(rq_keep), .s_axis_req_TLAST(rq_last),
        .m_axis_tx_meta_TVALID(txm_valid), .m_axis_tx_meta_TREADY(txm_ready),
        .m_axis_tx_meta_TDATA(txm_data),
        .m_axis_tx_data_TVALID(txd_valid), .m_axis_tx_data_TREADY(txd_ready),
        .m_axis_tx_data_TDATA(txd_data), .m_axis_tx_data_TKEEP(txd_keep),
        .m_axis_tx_data_TLAST(txd_last),
        .s_axis_tx_status_TVALID(txs_valid), .s_axis_tx_status_TREADY(txs_ready),
        .s_axis_tx_status_TDATA(txs_data),
        .bus_req(), .bus_grant(1'b1),
        .busy(busy), .refused_sticky(refused_sticky), .tx_space(tx_space),
        .state_debug(state_debug)
    );

    // Reference bytes, and what actually reached the wire.
    byte src [TOTAL_BYTES];
    byte got [$];
    int  errors = 0;
    int  metas_seen = 0, refusals = 0, beats_after_refusal = 0;
    int  announced [$];      // tx_meta lengths, in order
    int  chunk_bytes_seen = 0;
    bit  expect_no_data = 0;

    // -- host: drive the request bytes, with occasional stalls -------------------------------------
    initial begin
        int off;
        @(posedge rst_n);
        off = 0;
        while (off < DMA_BYTES) begin
            automatic int n = (DMA_BYTES - off >= LANES) ? LANES : (DMA_BYTES - off);
            rq_data = '0; rq_keep = '0;
            for (int l = 0; l < n; l++) begin
                // Past TOTAL_BYTES this is padding -- deliberately non-zero and distinctive, so if
                // any of it reaches the wire the byte comparison names it rather than passing on a
                // lucky zero.
                rq_data[l*8 +: 8] = (off + l < TOTAL_BYTES) ? src[off + l] : 8'hEE;
                rq_keep[l]        = 1'b1;
            end
            rq_last  = (off + n >= DMA_BYTES);
            rq_valid = 1'b1;
            @(posedge clk);
            while (!rq_ready) @(posedge clk);
            off += n;
            // Stall the host stream now and then: the DMA is not obliged to keep up.
            if ((off % 1024) == 0) begin
                rq_valid = 1'b0;
                repeat (7) @(posedge clk);
            end
        end
        rq_valid = 1'b0;
    end

    // -- TOE: answer tx_meta, refusing once --------------------------------------------------------
    initial begin
        @(posedge rst_n);
        forever begin
            automatic int len;
            @(posedge clk);
            if (txm_valid && txm_ready) begin
                len = int'(txm_data[31:16]);
                announced.push_back(len);
                metas_seen++;
                repeat (2) @(posedge clk);
                if (metas_seen == REFUSE_ON) begin
                    txs_data  <= {2'd1, 30'd0, 16'(len), 16'h00A5};   // error != 0
                    refusals++;
                    expect_no_data <= 1'b1;
                end else begin
                    txs_data  <= {2'd0, 30'd65536, 16'(len), 16'h00A5};
                    expect_no_data <= 1'b0;
                    chunk_bytes_seen = 0;
                end
                txs_valid <= 1'b1;
                @(posedge clk);
                while (!txs_ready) @(posedge clk);
                txs_valid <= 1'b0;
            end
        end
    end

    // -- TOE: consume tx_data, with back-pressure --------------------------------------------------
    initial begin
        @(posedge rst_n);
        forever begin
            @(posedge clk);
            if (txd_valid && txd_ready) begin
                if (expect_no_data) begin
                    beats_after_refusal++;
                    $error("tx data beat after a REFUSED reservation at %0t", $time);
                end
                for (int l = 0; l < LANES; l++) begin
                    if (txd_keep[l]) got.push_back(byte'(txd_data[l*8 +: 8]));
                end
                chunk_bytes_seen += $countones(txd_keep);
                if (txd_last) begin
                    // The chunk just closed must match what was announced for it.
                    automatic int want = (announced.size() > 0) ? announced[announced.size()-1] : -1;
                    if (chunk_bytes_seen != want) begin
                        $error("chunk pushed %0d bytes but tx_meta announced %0d",
                               chunk_bytes_seen, want);
                        errors++;
                    end
                    chunk_bytes_seen = 0;
                end
            end
        end
    end

    // Back-pressure the transmit side in bursts.
    initial begin
        @(posedge rst_n);
        forever begin
            repeat (23) @(posedge clk);
            txd_ready = 1'b0;
            repeat (5)  @(posedge clk);
            txd_ready = 1'b1;
        end
    end

    // -- sequence ----------------------------------------------------------------------------------
    initial begin
        for (int i = 0; i < TOTAL_BYTES; i++) src[i] = byte'((i * 7 + 13) & 8'hFF);

        repeat (10) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // Arm BEFORE the connection is up: nothing may go out until it is.
        req_total_bytes = TOTAL_BYTES;
        req_start = 1'b1; @(posedge clk); req_start = 1'b0;
        repeat (20) @(posedge clk);
        if (metas_seen != 0) begin
            $error("a reservation was announced while the connection was down");
            errors++;
        end
        conn_up = 1'b1;

        fork begin
            // Poll rather than `wait`: the expression involves a queue's size(), and changes to a
            // queue do not re-trigger a wait's sensitivity, so it would block forever.
            while (busy || got.size() != TOTAL_BYTES) @(posedge clk);
        end
        begin
            repeat (200000) @(posedge clk);
            $error("timed out: %0d of %0d bytes reached the wire", got.size(), TOTAL_BYTES);
            errors++;
        end
        join_any
        disable fork;
        repeat (20) @(posedge clk);

        // 1. every byte, exactly once, in order
        if (got.size() != TOTAL_BYTES) begin
            $error("wire carried %0d bytes, host handed over %0d", got.size(), TOTAL_BYTES);
            errors++;
        end else begin
            for (int i = 0; i < TOTAL_BYTES; i++) begin
                if (got[i] !== src[i]) begin
                    $error("byte %0d differs: wire 0x%02x, host 0x%02x", i, got[i], src[i]);
                    errors++;
                    if (errors > 5) break;
                end
            end
        end

        // 2. the announcements add up to the transfer, and none exceeded the chunk size
        begin
            automatic int sum = 0;
            automatic int refused_len = (announced.size() >= REFUSE_ON) ? announced[REFUSE_ON-1] : 0;
            for (int i = 0; i < announced.size(); i++) begin
                sum += announced[i];
                if (announced[i] > CHUNK_BYTES) begin
                    $error("announced %0d bytes, above CHUNK_BYTES=%0d", announced[i], CHUNK_BYTES);
                    errors++;
                end
            end
            // The refused chunk is announced twice, so the sum overshoots by exactly that chunk.
            if (sum != TOTAL_BYTES + refused_len) begin
                $error("announced %0d bytes total, expected %0d (transfer + one re-announced chunk)",
                       sum, TOTAL_BYTES + refused_len);
                errors++;
            end
        end

        // 3. the refusal pushed nothing and was retried
        if (refusals != 1)            begin $error("expected 1 refusal, saw %0d", refusals); errors++; end
        if (beats_after_refusal != 0) begin $error("%0d beats followed a refusal", beats_after_refusal); errors++; end
        if (!refused_sticky)          begin $error("refused_sticky did not latch"); errors++; end
        if (metas_seen != announced.size()) begin $error("meta bookkeeping mismatch"); errors++; end

        $display("--------------------------------------------------------------");
        $display("bytes on the wire   : %0d / %0d", got.size(), TOTAL_BYTES);
        $display("tx_meta reservations: %0d (%0d refused and retried)", metas_seen, refusals);
        $display("beats after refusal : %0d (must be 0)", beats_after_refusal);
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d error(s))", errors);
        $display("--------------------------------------------------------------");
        $finish;
    end

endmodule
