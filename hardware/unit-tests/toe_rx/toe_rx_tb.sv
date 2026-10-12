`timescale 1ns / 1ps
// =================================================================================================
// toe_rx_tb -- unit bench for toe_rx (the receive side for the TOE with per-session rings).
//
// The world around toe_rx, modelled from the contract only:
//   * TOE: notifications (one per cycle at most, never held off -- TREADY must be 1), readPkg
//     (random TREADY), and per readPkg in issue order, after a random latency, one rx_meta and one
//     data packet of exactly len bytes (ceil(len/64) beats, keep low-aligned, tlast on the last).
//     Byte k of session s is a function of (s, k), so every routed byte is checked.
//     OVER-READ (a readPkg asking for more than was notified for that session) = FAIL; so is a
//     zero length, and more than one readPkg for a session after its release (only the one
//     already in the issue register may still go out).
//   * Lanes: a model of tcp_read RSV_EXACT -- level, reservation, registered free = D-4-level-rsv
//     -- and a consumer popping with a per-lane probability. A routed beat arriving at a level of
//     D-4 or more is a refusal = FAIL (the reservation is wrong).
//   * Bindings and lane_up driven by the scenarios.
// Every routed beat is checked against the expected (lane, session, offset, keep, last) record,
// in order. Per lane, readPkgs outstanding (TB view) must stay <= RD_OUT.
//
// Scenarios (run in sequence, each from reset): fair, slow, small, outlim, stale, bindcyc,
// err_meta, err_short, err_stray, budget.   ./run.sh [scenario]
// =================================================================================================
import lynxTypes::*;

module toe_rx_tb;
    localparam int N         = 4;
    localparam int RD_MAX    = 16384;
    localparam int RD_OUT    = 4;
    localparam int FREE_BITS = 12;
    localparam int RING_LOG2 = 20;
    localparam int BPB       = AXI_DATA_BITS / 8;
    localparam int CB        = $clog2(N);

    logic clk = 1'b0, rst_n = 1'b0;
    always #2ns clk = ~clk;
    int cyc = 0;
    always @(posedge clk) cyc++;

    // ---------------------------------------------------------------------------------------------
    // DUT
    // ---------------------------------------------------------------------------------------------
    logic                       n_tvalid, n_tready;
    logic [TCP_NOTIFY_BITS-1:0] n_tdata;
    logic                       bind_en, release_en;
    logic [CB-1:0]              bind_conn, release_conn;
    logic [15:0]                bind_sid;
    logic [N-1:0]               lane_up;
    logic [FREE_BITS-1:0]       lane_free [N];
    logic                       rp_tvalid, rp_tready;
    logic [31:0]                rp_tdata;
    logic                       rm_tvalid, rm_tready;
    logic [15:0]                rm_tdata;
    logic                       rd_tvalid, rd_tready, rd_tlast;
    logic [AXI_DATA_BITS-1:0]   rd_tdata;
    logic [BPB-1:0]             rd_tkeep;
    logic [N-1:0]               pkg_issued;
    logic [FREE_BITS-1:0]       pkg_beats;
    logic [N-1:0]               c_tvalid, c_tready;
    logic [AXI_DATA_BITS-1:0]   c_tdata;
    logic [BPB-1:0]             c_tkeep;
    logic                       c_tlast;
    logic [N-1:0]               l_closed, l_unread, l_busy;
    logic                       order_err, len_err, budget_err, route_stall;

    toe_rx #(.NUM_CONNS(N), .RD_MAX(RD_MAX), .RD_OUT(RD_OUT), .FREE_BITS(FREE_BITS),
             .RING_LOG2(RING_LOG2)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_notifications_TVALID(n_tvalid), .s_axis_notifications_TREADY(n_tready),
        .s_axis_notifications_TDATA (n_tdata),
        .bind_en(bind_en), .bind_conn(bind_conn), .bind_sid(bind_sid),
        .release_en(release_en), .release_conn(release_conn),
        .lane_up(lane_up), .lane_free(lane_free),
        .m_axis_read_package_TVALID(rp_tvalid), .m_axis_read_package_TREADY(rp_tready),
        .m_axis_read_package_TDATA (rp_tdata),
        .s_axis_rx_metadata_TVALID(rm_tvalid), .s_axis_rx_metadata_TREADY(rm_tready),
        .s_axis_rx_metadata_TDATA (rm_tdata),
        .s_axis_rx_data_TVALID(rd_tvalid), .s_axis_rx_data_TREADY(rd_tready),
        .s_axis_rx_data_TDATA (rd_tdata),  .s_axis_rx_data_TKEEP (rd_tkeep),
        .s_axis_rx_data_TLAST (rd_tlast),
        .lane_pkg_issued(pkg_issued), .lane_pkg_beats(pkg_beats),
        .conn_tvalid(c_tvalid), .conn_tready(c_tready),
        .conn_tdata (c_tdata),  .conn_tkeep (c_tkeep), .conn_tlast(c_tlast),
        .lane_closed(l_closed), .lane_unread(l_unread), .lane_rd_busy(l_busy),
        .order_err(order_err), .len_err(len_err), .budget_err(budget_err),
        .route_stall(route_stall), .dbg_oq_occ()
    );

    // ---------------------------------------------------------------------------------------------
    // Bookkeeping
    // ---------------------------------------------------------------------------------------------
    int  n_err = 0;
    function automatic void err(string s);
        n_err++;
        if (n_err <= 20) $display("  [cyc=%0d] *** ERROR: %s", cyc, s);
    endfunction

    function automatic byte unsigned sbyte(int sid, longint k);
        return byte'((sid * 31 + k * 7 + k / 251) & 8'hFF);
    endfunction

    longint notified [int];     // bytes notified per session (at the notification handshake)
    longint requested[int];     // bytes asked for per session
    int     lane_of  [int];     // session -> lane it was last bound to
    bit     is_bound [int];
    int     after_rel[int];     // readPkgs for a session since its release
    int     sid_of_lane [N];
    int     tb_out [N];         // readPkgs outstanding per lane, TB view
    int     tb_out_max [N];
    int     rp_per_lane [N];
    int     beats_routed [N];
    int     pulse_q [N][$];     // reservation pulses not yet matched to a readPkg

    // knobs
    int D = 2048;               // lane fifo depth (model)
    int rdlat_min = 20, rdlat_max = 200;
    int rp_pct = 100;           // readPkg TREADY probability
    int gap_pct = 0;            // probability of a bubble between data beats
    int cons_pct [N];
    bit corrupt_meta = 0, short_pkt = 0, stray_beat = 0;

    // ---------------------------------------------------------------------------------------------
    // Notification driver
    // ---------------------------------------------------------------------------------------------
    class Note; int sid; int len; bit closed; endclass
    Note nq[$];

    function automatic logic [TCP_NOTIFY_BITS-1:0] pack_notif(int sid, int len, bit closed);
        logic [TCP_NOTIFY_BITS-1:0] w;
        w = '0; w[15:0] = 16'(sid); w[31:16] = 16'(len); w[63:32] = 32'h0A000001;
        w[79:64] = 16'd80; w[80] = closed;
        return w;
    endfunction

    task automatic notify(int sid, int len, bit closed = 0);
        Note x; x = new(); x.sid = sid; x.len = len; x.closed = closed; nq.push_back(x);
    endtask

    bit manual = 0;   // a scenario drives the notification port itself (exact cycle alignment)
    always @(posedge clk) begin
        if (!rst_n) begin
            n_tvalid <= 1'b0;
        end else if (!manual) begin
            if (n_tvalid) begin
                if (!n_tready) err("notification TREADY low");
                else begin
                    Note x; x = nq.pop_front();
                    if (!notified.exists(x.sid)) notified[x.sid] = 0;
                    notified[x.sid] += x.len;
                end
            end
            // the one presented stays at the front until its handshake (popped above)
            if (nq.size() > 0) begin
                Note y; y = nq[0];
                n_tdata  <= pack_notif(y.sid, y.len, y.closed);
                n_tvalid <= 1'b1;
            end else n_tvalid <= 1'b0;
        end
    end

    // ---------------------------------------------------------------------------------------------
    // TOE readPkg side
    // ---------------------------------------------------------------------------------------------
    class Rp; int sid; int len; int lane; longint off; int due; endclass
    Rp meta_q[$], data_q[$];

    always @(posedge clk) begin
        if (!rst_n) rp_tready <= 1'b0;
        else        rp_tready <= ($urandom_range(0, 99) < rp_pct);
    end

    int last_pulse [N];
    always @(posedge clk) if (rst_n) begin
        // reservation pulses first (a pulse may coincide with its readPkg's handshake). A lane is
        // blocked for 3 cycles after its grant, so its pulses are at least 4 cycles apart.
        for (int L = 0; L < N; L++) if (pkg_issued[L]) begin
            pulse_q[L].push_back(int'(pkg_beats));
            if (cyc - last_pulse[L] < 4) err($sformatf("lane %0d granted again %0d cycles after its last grant", L, cyc - last_pulse[L]));
            last_pulse[L] = cyc;
        end
        if (rp_tvalid && rp_tready) begin
            Rp r; int sid, len, L;
            sid = int'(rp_tdata[15:0]); len = int'(rp_tdata[31:16]);
            if (len == 0) err($sformatf("readPkg of length 0 for sid %0d", sid));
            if (!notified.exists(sid)) notified[sid] = 0;
            if (!requested.exists(sid)) requested[sid] = 0;
            if (requested[sid] + len > notified[sid])
                err($sformatf("OVER-READ: readPkg(sid=%0d, len=%0d) with %0d notified, %0d already requested",
                              sid, len, notified[sid], requested[sid]));
            if (!lane_of.exists(sid)) begin
                err($sformatf("readPkg for sid %0d, never bound", sid));
                L = 0;
            end else L = lane_of[sid];
            if (!is_bound[sid]) begin
                after_rel[sid]++;
                if (after_rel[sid] > 1)
                    err($sformatf("readPkg #%0d for sid %0d after its release", after_rel[sid], sid));
            end
            if (pulse_q[L].size() == 0) err($sformatf("readPkg for lane %0d without a reservation pulse", L));
            else begin
                int b; b = pulse_q[L].pop_front();
                if (b != (len + BPB - 1) / BPB)
                    err($sformatf("lane %0d reserved %0d beats for a %0d-byte readPkg", L, b, len));
            end
            r = new(); r.sid = sid; r.len = len; r.lane = L; r.off = requested[sid];
            r.due = cyc + $urandom_range(rdlat_min, rdlat_max);
            requested[sid] += len;
            meta_q.push_back(r); data_q.push_back(r);
            tb_out[L]++; rp_per_lane[L]++;
            if (tb_out[L] > tb_out_max[L]) tb_out_max[L] = tb_out[L];
            if (tb_out[L] > RD_OUT) err($sformatf("lane %0d has %0d readPkgs outstanding (RD_OUT %0d)", L, tb_out[L], RD_OUT));
        end
    end

    // meta: in order, at the readPkg's due time (before its data)
    initial begin : meta_srv
        rm_tvalid = 1'b0; rm_tdata = '0;
        forever begin
            @(posedge clk);
            if (rst_n && meta_q.size() > 0 && cyc >= meta_q[0].due - 2) begin
                Rp r; r = meta_q.pop_front();
                rm_tdata  <= 16'(corrupt_meta ? r.sid ^ 16'h0100 : r.sid);
                corrupt_meta = 0;
                rm_tvalid <= 1'b1;
                @(posedge clk);
                if (!rm_tready) err("rx_meta TREADY low");
                rm_tvalid <= 1'b0;
            end
        end
    end

    // expected beats at the lane outputs, in order
    class Eb; int lane; int sid; longint off; int nb; bit last; endclass
    Eb exp_q[$];
    bit data_busy = 0;   // the data server is inside a packet (it may be in a bubble)

    initial begin : data_srv
        rd_tvalid = 1'b0; rd_tlast = 1'b0; rd_tdata = '0; rd_tkeep = '0;
        forever begin
            @(posedge clk);
            if (rst_n && stray_beat) begin
                stray_beat = 0;
                rd_tdata <= '0; rd_tkeep <= '1; rd_tlast <= 1'b1; rd_tvalid <= 1'b1;
                @(posedge clk);
                rd_tvalid <= 1'b0; rd_tlast <= 1'b0;
            end else if (rst_n && data_q.size() > 0 && cyc >= data_q[0].due) begin
                Rp r; int nbeats;
                r = data_q.pop_front();
                nbeats = (r.len + BPB - 1) / BPB;
                if (short_pkt && nbeats > 1) begin short_pkt = 0; nbeats = nbeats - 1; end
                data_busy = 1;
                for (int i = 0; i < nbeats && rst_n; i++) begin
                    automatic int nb = ((r.len - i*BPB) > BPB) ? BPB : (r.len - i*BPB);
                    automatic logic [AXI_DATA_BITS-1:0] d = '0;
                    automatic logic [BPB-1:0] k = '0;
                    Eb e;
                    for (int b = 0; b < nb; b++) begin
                        d[b*8 +: 8] = sbyte(r.sid, r.off + i*BPB + b);
                        k[b] = 1'b1;
                    end
                    while ($urandom_range(0, 99) < gap_pct) begin
                        rd_tvalid <= 1'b0; @(posedge clk);
                    end
                    rd_tdata <= d; rd_tkeep <= k; rd_tlast <= (i == nbeats - 1); rd_tvalid <= 1'b1;
                    e = new(); e.lane = r.lane; e.sid = r.sid; e.off = r.off + i*BPB; e.nb = nb;
                    e.last = (i == nbeats - 1); exp_q.push_back(e);
                    @(posedge clk);
                    if (!rd_tready) err("rx_data TREADY low");
                end
                rd_tvalid <= 1'b0; rd_tlast <= 1'b0;
                data_busy = 0;
            end
        end
    end

    // ---------------------------------------------------------------------------------------------
    // Lanes: tcp_read RSV_EXACT model + consumer + the routed-beat checker
    // ---------------------------------------------------------------------------------------------
    int lv [N], rsv [N];
    bit check_data = 1;

    always @(posedge clk) begin
        for (int L = 0; L < N; L++) begin
            if (!rst_n) begin
                lv[L] = 0; rsv[L] = 0; lane_free[L] <= '0;
            end else begin
                int f;
                // tcp_read's timing: free_q is registered from level_q/rsv_q, which take this
                // cycle's pulse and beat only at this edge -- so the pulse shows in free two
                // edges after it was presented, as in the RTL.
                f = D - 4 - lv[L] - rsv[L];
                lane_free[L] <= (f < 0) ? '0 : FREE_BITS'(f);
                if (pkg_issued[L]) rsv[L] += int'(pkg_beats);
                if (c_tvalid[L]) begin
                    Eb e;
                    if (lv[L] >= D - 4) err($sformatf("lane %0d fifo REFUSES a routed beat (level %0d, depth %0d)", L, lv[L], D));
                    lv[L]++; rsv[L]--;
                    if (rsv[L] < 0) err($sformatf("lane %0d: a beat arrived beyond its reservation", L));
                    beats_routed[L]++;
                    if (exp_q.size() == 0) err($sformatf("lane %0d got a beat nobody sent", L));
                    else begin
                        e = exp_q.pop_front();
                        if (check_data) begin
                            if (e.lane != L) err($sformatf("beat of sid %0d (lane %0d) routed to lane %0d", e.sid, e.lane, L));
                            if (c_tlast != e.last) err($sformatf("lane %0d: tlast %0b, expected %0b", L, c_tlast, e.last));
                            if ($countones(c_tkeep) != e.nb) err($sformatf("lane %0d: keep %0d bytes, expected %0d", L, $countones(c_tkeep), e.nb));
                            for (int b = 0; b < e.nb; b++)
                                if (c_tdata[b*8 +: 8] !== sbyte(e.sid, e.off + b)) begin
                                    err($sformatf("lane %0d sid %0d byte %0d wrong", L, e.sid, e.off + b));
                                    break;
                                end
                        end
                        if (e.last) tb_out[e.lane]--;
                    end
                end
                if (lv[L] > 0 && $urandom_range(0, 99) < cons_pct[L]) lv[L]--;
            end
        end
    end
    assign c_tready = '1;

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------
    task automatic reset_all();
        rst_n = 1'b0;
        bind_en = 0; release_en = 0; bind_conn = '0; release_conn = '0; bind_sid = '0;
        lane_up = '0;
        repeat (4) @(posedge clk);   // the servers drop what they were doing while reset is low
        nq.delete(); meta_q.delete(); data_q.delete(); exp_q.delete();
        notified.delete(); requested.delete(); lane_of.delete(); is_bound.delete(); after_rel.delete();
        for (int L = 0; L < N; L++) begin
            tb_out[L] = 0; tb_out_max[L] = 0; rp_per_lane[L] = 0; beats_routed[L] = 0;
            pulse_q[L].delete(); cons_pct[L] = 100; sid_of_lane[L] = -1; last_pulse[L] = -100;
        end
        D = 2048; rdlat_min = 20; rdlat_max = 200; rp_pct = 100; gap_pct = 0;
        corrupt_meta = 0; short_pkt = 0; stray_beat = 0; check_data = 1;
        n_err = 0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);
    endtask

    task automatic do_bind(int L, int sid);
        @(posedge clk);
        bind_en <= 1'b1; bind_conn <= CB'(L); bind_sid <= 16'(sid);
        @(posedge clk);
        bind_en <= 1'b0;
        lane_of[sid] = L; is_bound[sid] = 1; after_rel[sid] = 0; sid_of_lane[L] = sid;
    endtask

    task automatic do_release(int L);
        @(posedge clk);
        release_en <= 1'b1; release_conn <= CB'(L);
        @(posedge clk);
        release_en <= 1'b0;
        if (sid_of_lane[L] >= 0) is_bound[sid_of_lane[L]] = 0;
    endtask

    // keep `ahead` bytes notified beyond what was requested, for each listed lane, until `until`
    task automatic feeder(int L, longint ahead, int segmax, int t_end);
        while (cyc < t_end) begin
            int sid; sid = sid_of_lane[L];
            @(posedge clk);
            if (sid >= 0 && nq.size() < 8) begin
                longint have; have = (notified.exists(sid) ? notified[sid] : 0) - (requested.exists(sid) ? requested[sid] : 0);
                foreach (nq[i]) if (nq[i].sid == sid) have += nq[i].len;
                if (have < ahead) notify(sid, $urandom_range(1, segmax));
            end
        end
    endtask

    task automatic wait_quiet(int bound, output bit ok);
        int t0; t0 = cyc; ok = 0;
        while ((cyc - t0) < bound) begin
            bit q; q = (nq.size() == 0) && (meta_q.size() == 0) && (data_q.size() == 0) && (exp_q.size() == 0) && !rd_tvalid && !data_busy;
            foreach (notified[s]) if (is_bound.exists(s) && is_bound[s] && lane_up[lane_of[s]] && requested.exists(s) == 0 && notified[s] != 0) q = 0;
            foreach (notified[s]) if (is_bound.exists(s) && is_bound[s] && lane_up[lane_of[s]] && requested.exists(s) && requested[s] != notified[s]) q = 0;
            if (q) begin ok = 1; return; end
            @(posedge clk);
        end
    endtask

    string scen, only;
    int fails = 0, cases = 0;

    task automatic verdict(string name, string extra, bit fail_cond);
        cases++;
        if (fail_cond || n_err != 0) begin
            fails++;
            $display("FAIL  toe_rx  %-10s %s (errors=%0d)", name, extra, n_err);
        end else
            $display("PASS  toe_rx  %-10s %s", name, extra);
    endtask

    // ---------------------------------------------------------------------------------------------
    // Scenarios
    // ---------------------------------------------------------------------------------------------
    task automatic run_scen(string s);
        bit ok;
        int t0, tot, minrp;
        reset_all();
        case (s)
        // all lanes busy: byte exact, round robin shares the readPkgs, line rate kept
        "fair": begin
            for (int L = 0; L < N; L++) do_bind(L, 100 + L);
            lane_up = '1;
            t0 = cyc;
            fork
                feeder(0, 200000, 9000, t0 + 40000); feeder(1, 200000, 9000, t0 + 40000);
                feeder(2, 200000, 9000, t0 + 40000); feeder(3, 200000, 9000, t0 + 40000);
            join
            wait_quiet(20000, ok);
            tot = 0; minrp = 1 << 30;
            for (int L = 0; L < N; L++) begin tot += beats_routed[L]; if (rp_per_lane[L] < minrp) minrp = rp_per_lane[L]; end
            verdict(s, $sformatf("readPkgs/lane %0d %0d %0d %0d, %0.2f beats/cycle, max outstanding %0d",
                                 rp_per_lane[0], rp_per_lane[1], rp_per_lane[2], rp_per_lane[3],
                                 real'(tot) / real'(cyc - t0), tb_out_max[0]),
                    !ok || order_err || len_err || budget_err || route_stall ||
                    (minrp * N * 10 < (rp_per_lane[0]+rp_per_lane[1]+rp_per_lane[2]+rp_per_lane[3]) * 8) ||
                    (real'(tot) / real'(cyc - t0)) < 0.8);
        end
        // lane 0's consumer stops for good: its fifo is promised to the last beat and never
        // refuses, the others keep their rate; then lane 0 resumes and everything drains
        "slow": begin
            int b1 [N];
            D = 600;
            for (int L = 0; L < N; L++) do_bind(L, 100 + L);
            lane_up = '1;
            cons_pct[0] = 0;
            t0 = cyc;
            fork
                feeder(0, 100000, 4096, t0 + 30000); feeder(1, 100000, 4096, t0 + 30000);
                feeder(2, 100000, 4096, t0 + 30000); feeder(3, 100000, 4096, t0 + 30000);
            join
            for (int L = 0; L < N; L++) b1[L] = beats_routed[L];
            $display("  [cyc=%0d] lane 0 stopped: level %0d + reserved %0d of %0d (free %0d); lanes 1..3 got %0d %0d %0d beats",
                     cyc, lv[0], rsv[0], D - 4, lane_free[0], beats_routed[1], beats_routed[2], beats_routed[3]);
            ok = (lv[0] + rsv[0] <= D - 4) && (lv[0] >= D - 4 - 256);
            b1[0] = lv[0] + rsv[0];
            cons_pct[0] = 100;
            begin bit ok2; wait_quiet(60000, ok2); ok = ok && ok2; end
            verdict(s, $sformatf("lane0 held at %0d/%0d beats; others %0.2f beats/cycle each",
                                 b1[0], D - 4, real'(b1[1]) / 30000.0),
                    !ok || order_err || len_err || route_stall || (real'(b1[1]) / 30000.0) < 0.25);
        end
        // tiny notifications, random consumers, readPkg TREADY and data bubbles
        "small": begin
            D = 300; rp_pct = 60; gap_pct = 20; rdlat_min = 2; rdlat_max = 60;
            for (int L = 0; L < N; L++) begin do_bind(L, 200 + 3*L); cons_pct[L] = 20 + 25*L; end
            lane_up = '1;
            t0 = cyc;
            fork
                feeder(0, 3000, 200, t0 + 30000); feeder(1, 3000, 200, t0 + 30000);
                feeder(2, 3000, 64, t0 + 30000);  feeder(3, 3000, 1, t0 + 30000);
            join
            wait_quiet(40000, ok);
            verdict(s, $sformatf("readPkgs/lane %0d %0d %0d %0d", rp_per_lane[0], rp_per_lane[1],
                                 rp_per_lane[2], rp_per_lane[3]),
                    !ok || order_err || len_err || budget_err || route_stall);
        end
        // one lane alone, tiny fifo, its consumer stopped, a 64-byte notification every cycle and
        // an immediate TOE: grants come as fast as the block allows while the promise approaches
        // the limit, and none may over-promise (a block one cycle too short does: the grant then
        // sees a free count that does not include the previous readPkg yet). It stops short of
        // the last beat by design: a lane waits until its fifo has room for min(unread, RD_MAX).
        "solo": begin
            // Twelve rounds over fifo depths 40..73, each from reset: notifications of 1..160
            // bytes every cycle for 50 cycles (at most 2 x the fifo's limit in total, so the rest
            // still fits one readPkg once the consumer resumes), the TOE answering at once.
            int errs, worst;
            errs = 0; worst = 0; ok = 1;
            for (int it = 0; it < 12; it++) begin
                if (it > 0) reset_all();
                D = 40 + 3*it; rdlat_min = 1; rdlat_max = 1;
                do_bind(0, 100);
                lane_up = 4'b0001;
                cons_pct[0] = 0;
                for (int i = 0; i < 50; i++) begin
                    @(posedge clk);
                    notify(100, $urandom_range(1, 160));
                end
                repeat (300) @(posedge clk);
                if (lv[0] + rsv[0] > D - 4) ok = 0;
                if (lv[0] + rsv[0] > worst - (D - 4) + (D - 4)) worst = lv[0] + rsv[0] - (D - 4);
                cons_pct[0] = 100;
                begin bit ok2; wait_quiet(20000, ok2); ok = ok && ok2; end
                if (order_err || len_err || route_stall) ok = 0;
                errs += n_err;
            end
            n_err = errs;
            minrp = rp_per_lane[0];
            verdict(s, $sformatf("12 rounds, D 40..73, promise never past the limit (last round %0d readPkgs)", minrp), !ok);
        end
        // a long TOE latency: RD_OUT readPkgs per lane in flight, never more
        "outlim": begin
            rdlat_min = 1500; rdlat_max = 2000;
            for (int L = 0; L < N; L++) do_bind(L, 100 + L);
            lane_up = '1;
            t0 = cyc;
            fork
                feeder(0, 300000, 9000, t0 + 20000); feeder(1, 300000, 9000, t0 + 20000);
            join
            wait_quiet(40000, ok);
            verdict(s, $sformatf("max outstanding lane0 %0d lane1 %0d (RD_OUT %0d)", tb_out_max[0], tb_out_max[1], RD_OUT),
                    !ok || tb_out_max[0] != RD_OUT || tb_out_max[1] != RD_OUT || order_err || len_err);
        end
        // stale notifications for a session released in the cycle they are consumed (or the one
        // before) are dropped; a readPkg in flight at the release completes and is routed; the
        // lane rebinds to the SAME sid and reads exactly what is notified after that
        "stale": begin
            int u_after;
            for (int L = 0; L < N; L++) do_bind(L, 100 + L);
            lane_up = 4'b1101;                       // lane 1 is not read (as if its decoder were slow)
            notify(101, 3000); notify(101, 3000);
            repeat (10) @(posedge clk);
            // A notification at the port in cycle t is consumed at t+1. Two back to back: the
            // first is consumed IN the release cycle, the second in the cycle after it.
            manual = 1;
            @(posedge clk);
            n_tdata <= pack_notif(101, 777, 0); n_tvalid <= 1'b1;
            @(posedge clk);
            n_tdata <= pack_notif(101, 888, 0);
            release_en <= 1'b1; release_conn <= CB'(1);
            @(posedge clk);
            n_tvalid <= 1'b0;
            release_en <= 1'b0; is_bound[101] = 0;
            notified[101] += 777 + 888;
            @(posedge clk);
            manual = 0;
            @(posedge clk);
            u_after = l_unread[1];
            if (u_after) err("lane 1 still has unread bytes after its release");
            // and one arriving after the release is not counted either
            notify(101, 500);
            repeat (20) @(posedge clk);
            if (l_unread[1]) err("a notification for a released session was counted");
            // rebind lane 1 to the same session id: a fresh count
            notified[101] = 0; requested[101] = 0;
            do_bind(1, 101);
            lane_up = '1;
            notify(101, 5000);
            wait_quiet(20000, ok);
            verdict(s, $sformatf("rebound sid 101 read %0d of 5000", requested[101]),
                    !ok || requested[101] != 5000 || order_err || len_err);
        end
        // a notification consumed in the very cycle its session is bound is counted
        "bindcyc": begin
            do_bind(0, 100);
            lane_up = '1;
            manual = 1;
            @(posedge clk);
            n_tdata <= pack_notif(300, 1234, 0);     // at the port now, consumed next cycle
            n_tvalid <= 1'b1;
            @(posedge clk);
            n_tvalid <= 1'b0;
            bind_en <= 1'b1; bind_conn <= CB'(2); bind_sid <= 16'd300;
            notified[300] = 1234;
            @(posedge clk);
            bind_en <= 1'b0; lane_of[300] = 2; is_bound[300] = 1; sid_of_lane[2] = 300; after_rel[300] = 0;
            manual = 0;
            wait_quiet(20000, ok);
            verdict(s, $sformatf("read %0d of 1234", requested.exists(300) ? requested[300] : 0),
                    !ok || !requested.exists(300) || requested[300] != 1234 || order_err || len_err);
        end
        "err_meta": begin
            for (int L = 0; L < N; L++) do_bind(L, 100 + L);
            lane_up = '1;
            notify(100, 3000); notify(102, 3000);
            repeat (5) @(posedge clk);
            corrupt_meta = 1;
            notify(101, 3000);
            wait_quiet(20000, ok);
            verdict(s, $sformatf("order_err=%0b len_err=%0b", order_err, len_err), !order_err || len_err);
        end
        "err_short": begin
            for (int L = 0; L < N; L++) do_bind(L, 100 + L);
            lane_up = '1;
            short_pkt = 1; check_data = 0;
            notify(100, 3000);
            repeat (2000) @(posedge clk);
            n_err = 0;   // the model's own per-beat checks see the broken packet; the verdict is the flag
            verdict(s, $sformatf("len_err=%0b", len_err), !len_err);
        end
        "err_stray": begin
            for (int L = 0; L < N; L++) do_bind(L, 100 + L);
            lane_up = '1;
            check_data = 0;
            stray_beat = 1;
            repeat (100) @(posedge clk);
            n_err = 0;
            verdict(s, $sformatf("order_err=%0b", order_err), !order_err);
        end
        // budget: exactly 1 MiB - 64 KiB unread is legal, one byte more sets budget_err
        "budget": begin
            longint lim; bit e1;
            lim = (longint'(1) << RING_LOG2) - 65536;
            do_bind(0, 100);
            lane_up = '0;                            // nothing is read
            for (longint s = 0; s < lim; s += 65535) notify(100, int'((lim - s > 65535) ? 65535 : lim - s));
            repeat (60) @(posedge clk);
            e1 = budget_err;
            notify(100, 1);
            repeat (10) @(posedge clk);
            verdict(s, $sformatf("at the limit %0b, one byte over %0b", e1, budget_err), e1 || !budget_err);
        end
        default: begin $display("unknown scenario %s", s); fails++; end
        endcase
    endtask

    initial begin
        string list[$];
        list = '{"fair", "slow", "solo", "small", "outlim", "stale", "bindcyc", "err_meta", "err_short", "err_stray", "budget"};
        if ($value$plusargs("SCEN=%s", only)) list = '{only};
        foreach (list[i]) run_scen(list[i]);
        $display("toe_rx: %0d failed of %0d", fails, cases);
        $finish;
    end

    initial begin
        #200ms;
        $display("toe_rx: WATCHDOG");
        $finish;
    end
endmodule
