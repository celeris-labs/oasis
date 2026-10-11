`timescale 1ns / 1ps

// =================================================================================================
// tcp_mem_mux_tb -- Coyote's tcp_mem_mux (hardware/patches/0008) against a model of both sides:
//
//   TOE side, per channel (0 = tx ring, 1 = rx ring): a read requester + read data / read status
//   consumers, and a write requester (command and data) + write status consumer. The write side
//   issues commands the way the TOE does (rxEngMemWrite, tasi_pkg_pusher): command first, data
//   after it; for a ring-end split the second command must be accepted BEFORE the first part's
//   last beat can go (worst case of the HLS iteration that writes both).
//
//   Shell side: one in-order datamover (one read engine, one write engine, like
//   axi_datamover_mem_unaligned): random command acceptance, random latency, data gaps, status
//   in command order; write data is accepted only while a write command is pending (no
//   store-and-forward in the datamover, so a granted command whose data is missing stalls every
//   later write -- which is what the mux must avoid for rx).
//
// CHECKS (all continuous; any one fails the case):
//   * per channel, commands reach the datamover in issue order, with the address the TOE gave plus
//     bit 29 for rx and the same btt;
//   * read data: every packet reaches the channel that issued it, in order, with the right bytes
//     (the datamover returns pat(bit29, addr + i)), packed keep and tlast exactly at ceil(btt/64);
//   * read / write status: in order, to the right channel (the status byte is a hash of the
//     command, which the mux never interprets);
//   * write data: every packet lands under its own command (bytes = pat(channel, addr + i) with the
//     channel taken from bit 29, so a misplaced or interleaved write cannot match), exact length;
//   * liveness: progress watchdog; scenario-specific bounds on rx latency while tx misbehaves.
//
// +SCEN=<name> (xsim -sv_seed <n> picks the random stream). Prints one verdict line:
//   tcp_mem_mux_tb '<scen>': PASS|FAIL ...
// =================================================================================================
module tcp_mem_mux_tb #(
    parameter int TXW_DEPTH  = 1024,
    parameter int N_RD       = 32,
    parameter int N_WR       = 32,
    parameter int CMDQ_DEPTH = 16
);
    localparam int DB = 512;
    localparam int KB = DB/8;
    localparam int CB = 96;
    localparam int SB = 8;
    localparam int TX = 0;
    localparam int RX = 1;

    // ---------------------------------------------------------------------------------------------
    // DUT
    // ---------------------------------------------------------------------------------------------
    logic aclk = 1'b0, aresetn = 1'b0;
    always #2 aclk = ~aclk;

    logic [1:0] s_rd_cmd_valid = '0, s_rd_cmd_ready;  logic [1:0][CB-1:0] s_rd_cmd_data = '0;
    logic [1:0] s_wr_cmd_valid = '0, s_wr_cmd_ready;  logic [1:0][CB-1:0] s_wr_cmd_data = '0;
    logic [1:0] m_rd_sts_valid, m_rd_sts_ready = '0;  logic [1:0][SB-1:0] m_rd_sts_data;
    logic [1:0] m_wr_sts_valid, m_wr_sts_ready = '0;  logic [1:0][SB-1:0] m_wr_sts_data;
    logic [1:0] m_rd_tvalid, m_rd_tready = '0;
    logic [DB-1:0] m_rd_tdata; logic [KB-1:0] m_rd_tkeep; logic m_rd_tlast;
    logic [1:0] s_wr_tvalid = '0, s_wr_tready;
    logic [1:0][DB-1:0] s_wr_tdata = '0; logic [1:0][KB-1:0] s_wr_tkeep = '0; logic [1:0] s_wr_tlast = '0;

    logic m_rd_cmd_valid, m_rd_cmd_ready = 1'b0; logic [CB-1:0] m_rd_cmd_data;
    logic m_wr_cmd_valid, m_wr_cmd_ready = 1'b0; logic [CB-1:0] m_wr_cmd_data;
    logic s_rd_sts_valid = 1'b0, s_rd_sts_ready;  logic [SB-1:0] s_rd_sts_data = '0;
    logic s_wr_sts_valid = 1'b0, s_wr_sts_ready;  logic [SB-1:0] s_wr_sts_data = '0;
    logic s_rd_tvalid = 1'b0, s_rd_tready;
    logic [DB-1:0] s_rd_tdata = '0; logic [KB-1:0] s_rd_tkeep = '0; logic s_rd_tlast = 1'b0;
    logic m_wr_tvalid, m_wr_tready = 1'b0;
    logic [DB-1:0] m_wr_tdata; logic [KB-1:0] m_wr_tkeep; logic m_wr_tlast;

    tcp_mem_mux #(
        .TXW_DEPTH(TXW_DEPTH), .N_RD(N_RD), .N_WR(N_WR), .CMDQ_DEPTH(CMDQ_DEPTH)
    ) dut (.*);

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------
    longint unsigned cyc = 0;
    always @(posedge aclk) cyc <= cyc + 1;

    int errors = 0;
    int progress = 0;            // bumped by every completion on the TOE side
    string scen;

    function automatic logic [CB-1:0] mk_cmd(longint unsigned addr, int btt);
        logic [CB-1:0] c;
        c = '0;
        c[31:0]   = addr[31:0];
        c[64+:23] = btt[22:0];
        return c;
    endfunction

    // payload byte at address a (bit 29 already stripped) written / returned for channel ch
    function automatic logic [7:0] pat(int ch, longint unsigned a);
        logic [63:0] x;
        x = (a + 64'h1234) * 64'h9E3779B97F4A7C15 + (ch ? 64'hC2B2AE3D27D4EB4F : 64'h0);
        return x[63:56] ^ x[31:24];
    endfunction

    // status byte the datamover model returns for a command (address as emitted, incl. bit 29)
    function automatic logic [7:0] sts_hash(longint unsigned addr, int btt);
        logic [63:0] x;
        x = (addr ^ (64'(btt) << 31)) * 64'hFF51AFD7ED558CCD;
        return x[63:56] ^ x[23:16];
    endfunction

    function automatic logic [KB-1:0] keep_of(int nbytes);  // 1..64
        logic [KB-1:0] k;
        k = '0;
        for (int i = 0; i < KB; i++) if (i < nbytes) k[i] = 1'b1;
        return k;
    endfunction

    function automatic bit chance(int pct);
        return ($urandom_range(0, 99) < pct);
    endfunction

    task automatic fail(string msg);
        errors++;
        if (errors <= 20) $display("[%0t] ERROR: %s", $time, msg);
    endtask

    typedef struct {
        longint unsigned addr;   // TOE address (bit 29 = 0)
        int              btt;
        bit              split_next;   // next command must be accepted before this one's last beat
        longint unsigned t_iss;  // cycle the TOE side's command was accepted
    } cmd_t;

    function automatic longint unsigned emitted(int ch, longint unsigned a);
        return ch ? (a | 64'h2000_0000) : a;
    endfunction

    // ---------------------------------------------------------------------------------------------
    // Scenario knobs
    // ---------------------------------------------------------------------------------------------
    int n_rd[2], n_wr[2];
    int rd_max[2], wr_max[2], big_pct[2];
    int split_pct[2];
    int free_order[2];                 // write data may run ahead of / behind commands freely
    int free_gap[2];                   // max idle cycles before a packet in free order
    int cmd_gap[2];                    // max idle cycles between TOE-side commands
    int wbeat_gap_pct[2], wbeat_gap_max[2];
    int wstall_pct[2], wstall_len[2];  // long mid-packet stall of the write data
    int rdy_rd[2], rdy_rsts[2], rdy_wsts[2];   // percent ready on the TOE side
    int dm_rcmd_rdy, dm_wcmd_rdy, dm_wdat_rdy, dm_rgap_pct;
    int dm_rlat_min, dm_rlat_max, dm_wlat_min, dm_wlat_max;
    longint unsigned wsts_stall_from[2], wsts_stall_to[2];
    longint unsigned rd_stall_from[2], rd_stall_to[2];
    int max_rx_wlat;                   // bound on rx write latency (cmd accepted -> status), 0 = none
    int min_rx_w_in_stall;             // rx write statuses required while tx is stalled, 0 = none
    int min_rate_pct;                  // write and read data beats per cycle (x100) required, 0 = none
    longint unsigned watchdog;

    initial begin
        if (!$value$plusargs("SCEN=%s", scen)) scen = "basic";
        for (int c = 0; c < 2; c++) begin
            n_rd[c] = 400; n_wr[c] = 400;
            rd_max[c] = 4096; wr_max[c] = 4096; big_pct[c] = 5;
            split_pct[c] = 10; free_order[c] = 0; free_gap[c] = 50; cmd_gap[c] = 20;
            wbeat_gap_pct[c] = 10; wbeat_gap_max[c] = 4;
            wstall_pct[c] = 0; wstall_len[c] = 0;
            rdy_rd[c] = 80; rdy_rsts[c] = 80; rdy_wsts[c] = 80;
            wsts_stall_from[c] = 0; wsts_stall_to[c] = 0;
            rd_stall_from[c] = 0; rd_stall_to[c] = 0;
        end
        rd_max[RX] = 65535; big_pct[RX] = 10;       // readPkg: up to 64 KiB
        wr_max[TX] = 65535; big_pct[TX] = 3;        // tx_app write: up to 64 KiB
        dm_rcmd_rdy = 70; dm_wcmd_rdy = 70; dm_wdat_rdy = 80; dm_rgap_pct = 10;
        dm_rlat_min = 20; dm_rlat_max = 200; dm_wlat_min = 10; dm_wlat_max = 300;
        max_rx_wlat = 0; min_rx_w_in_stall = 0; min_rate_pct = 0;
        watchdog = 200000;

        case (scen)
            "basic": ;
            "bp": begin   // heavy backpressure / gaps everywhere
                for (int c = 0; c < 2; c++) begin
                    rdy_rd[c] = 25; rdy_rsts[c] = 30; rdy_wsts[c] = 30;
                    wbeat_gap_pct[c] = 40; wbeat_gap_max[c] = 10; cmd_gap[c] = 5;
                end
                dm_rcmd_rdy = 20; dm_wcmd_rdy = 20; dm_wdat_rdy = 25; dm_rgap_pct = 50;
                dm_rlat_max = 600; dm_wlat_max = 800;
            end
            "burst": begin  // no gaps, everything ready: full-rate back-to-back
                for (int c = 0; c < 2; c++) begin
                    rdy_rd[c] = 100; rdy_rsts[c] = 100; rdy_wsts[c] = 100;
                    wbeat_gap_pct[c] = 0; cmd_gap[c] = 0;
                end
                dm_rcmd_rdy = 100; dm_wcmd_rdy = 100; dm_wdat_rdy = 100; dm_rgap_pct = 0;
                dm_rlat_min = 5; dm_rlat_max = 30; dm_wlat_min = 5; dm_wlat_max = 30;
            end
            "rate": begin   // saturated: no gaps anywhere, data ahead of commands -> 1 beat/cycle each way
                for (int c = 0; c < 2; c++) begin
                    rdy_rd[c] = 100; rdy_rsts[c] = 100; rdy_wsts[c] = 100;
                    wbeat_gap_pct[c] = 0; cmd_gap[c] = 0; free_order[c] = 1; free_gap[c] = 0;
                    split_pct[c] = 0; n_rd[c] = 300; n_wr[c] = 300;
                end
                big_pct[TX] = 0; wr_max[TX] = 4096;   // keep the tx store-and-forward out of the way
                dm_rcmd_rdy = 100; dm_wcmd_rdy = 100; dm_wdat_rdy = 100; dm_rgap_pct = 0;
                dm_rlat_min = 5; dm_rlat_max = 30; dm_wlat_min = 5; dm_wlat_max = 30;
                min_rate_pct = 95;
            end
            "free": begin   // write data independent of command timing (data before command too)
                free_order[TX] = 1; free_order[RX] = 1; split_pct[TX] = 0; split_pct[RX] = 0;
            end
            "max": begin    // maximum tx writes (1024 beats, unaligned, ring-end splits), 64 KiB reads
                n_rd[TX] = 100; n_wr[TX] = 60; n_rd[RX] = 150; n_wr[RX] = 600;
                big_pct[TX] = 70; split_pct[TX] = 30; big_pct[RX] = 50;
                wbeat_gap_pct[TX] = 30; wbeat_gap_max[TX] = 3;
            end
            "tx_slow": begin  // tx write data trickles and stalls mid-packet; rx must not notice
                n_wr[TX] = 12; n_rd[TX] = 50; n_wr[RX] = 3000; n_rd[RX] = 200;
                big_pct[TX] = 50; split_pct[TX] = 30;
                wbeat_gap_pct[TX] = 50; wbeat_gap_max[TX] = 40;
                wstall_pct[TX] = 60; wstall_len[TX] = 20000;
                cmd_gap[RX] = 30;
                max_rx_wlat = 4000; min_rx_w_in_stall = 200;
                watchdog = 400000;
            end
            "wsts_stall": begin  // tx stops reading its write statuses for 60k cycles
                n_wr[TX] = 300; n_wr[RX] = 2000; n_rd[TX] = 100; n_rd[RX] = 200;
                big_pct[TX] = 0; wr_max[TX] = 512; cmd_gap[TX] = 5;
                wsts_stall_from[TX] = 2000; wsts_stall_to[TX] = 62000;
                // >= 100: the def config completes ~1000 rx writes in the window, the small one
                // (N_WR 1: one write in flight per channel) ~300, the no-credit mutant ~0
                max_rx_wlat = 4000; min_rx_w_in_stall = 100;
                watchdog = 400000;
            end
            "rd_hol": begin  // tx stops reading its read data for 20k cycles (documented coupling)
                n_rd[TX] = 300; n_rd[RX] = 300; n_wr[TX] = 50; n_wr[RX] = 300;
                rd_max[TX] = 4096; cmd_gap[TX] = 2;
                rd_stall_from[TX] = 3000; rd_stall_to[TX] = 23000;
            end
            "addr29": begin  // negative: an incoming address with bit 29 set must trip the assertion
                for (int c = 0; c < 2; c++) begin n_rd[c] = 0; n_wr[c] = 0; end
            end
            default: begin
                $display("tcp_mem_mux_tb '%s': FAIL unknown scenario", scen);
                $finish;
            end
        endcase
    end

    // ---------------------------------------------------------------------------------------------
    // Bookkeeping queues
    // ---------------------------------------------------------------------------------------------
    cmd_t iss_rd[2][$];     // TOE side read commands, for the datamover's order check
    cmd_t exp_rdd[2][$];    // ... for the read data checker
    cmd_t exp_rds[2][$];    // ... for the read status checker
    cmd_t iss_wr[2][$];     // TOE side write commands, for the datamover's order check
    cmd_t exp_wrs[2][$];    // ... for the write status checker
    cmd_t plan_wr[2][$];    // write plan (commands and data are driven from it)

    int done_rdd[2] = '{0, 0}, done_rds[2] = '{0, 0}, done_wrs[2] = '{0, 0};
    int wc_acc[2] = '{0, 0};          // write commands accepted
    int wd_done[2] = '{0, 0};         // write packets fully accepted
    int wd_at_last[2] = '{-1, -1};    // data waiting at packet i's last beat for command i+1
    bit tx_wstalling = 0;             // tx write data in a long mid-packet stall
    int rx_w_in_stall = 0, rx_wlat_max = 0, rx_rbeats_in_tx_rstall = 0;
    longint unsigned tx_rstall_len = 0;

    function automatic cmd_t new_cmd(int ch, int maxlen, int bigpct);
        cmd_t x;
        longint unsigned sid, off;
        int len;
        sid = $urandom_range(0, 511);
        if (chance(bigpct)) len = $urandom_range(maxlen > 8192 ? maxlen - 4096 : 1, maxlen);
        else                len = $urandom_range(1, maxlen < 4096 ? maxlen : 4096);
        off = $urandom_range(0, (1 << 20) - 1);
        if (off + len > (1 << 20)) off = (1 << 20) - len;   // the TOE splits at the ring end
        x.addr = (sid << 20) | off;
        x.btt = len;
        x.split_next = 0;
        x.t_iss = 0;
        return x;
    endfunction

    // Write plan: optionally a ring-end split pair (part 1 to the ring end, part 2 at offset 0).
    task automatic make_plan(int c);
        int i;
        i = 0;
        while (i < n_wr[c]) begin
            cmd_t a, b;
            // a tx write is at most TXW_DEPTH beats (the TOE: <= 1024, see tcp_mem_mux.sv)
            a = new_cmd(c, (c == TX && wr_max[c] > TXW_DEPTH*KB) ? TXW_DEPTH*KB : wr_max[c],
                        big_pct[c]);
            if (i + 1 < n_wr[c] && chance(split_pct[c]) && a.btt > 1) begin
                int l1;
                l1 = $urandom_range(1, a.btt - 1);
                b = a;
                a.addr = (a.addr & ~64'hFFFFF) | ((1 << 20) - l1);
                b.addr = (b.addr & ~64'hFFFFF);
                b.btt  = a.btt - l1;
                a.btt  = l1;
                a.split_next = 1;
                plan_wr[c].push_back(a);
                plan_wr[c].push_back(b);
                i += 2;
            end else begin
                plan_wr[c].push_back(a);
                i += 1;
            end
        end
    endtask

    // ---------------------------------------------------------------------------------------------
    // TOE side: read requester
    // ---------------------------------------------------------------------------------------------
    task automatic rd_gen(int c);
        for (int i = 0; i < n_rd[c]; i++) begin
            cmd_t x;
            repeat ($urandom_range(0, cmd_gap[c])) @(posedge aclk);
            x = new_cmd(c, rd_max[c], big_pct[c]);
            s_rd_cmd_data[c]  <= mk_cmd(x.addr, x.btt);
            s_rd_cmd_valid[c] <= 1'b1;
            do @(posedge aclk); while (!s_rd_cmd_ready[c]);
            x.t_iss = cyc;
            iss_rd[c].push_back(x); exp_rdd[c].push_back(x); exp_rds[c].push_back(x);
            s_rd_cmd_valid[c] <= 1'b0;
        end
    endtask

    // read data consumer + checker
    task automatic rd_sink(int c);
        int off;
        off = 0;
        forever begin
            @(posedge aclk);
            if (m_rd_tvalid[c] && m_rd_tready[c]) begin
                if (exp_rdd[c].size() == 0) begin
                    fail($sformatf("ch%0d read data with no read outstanding", c));
                end else begin
                    cmd_t x;
                    int rem, nb;
                    bit lastb;
                    x = exp_rdd[c][0];
                    rem = x.btt - off;
                    nb = (rem > KB) ? KB : rem;
                    lastb = (rem <= KB);
                    if (m_rd_tkeep !== keep_of(nb))
                        fail($sformatf("ch%0d read keep %h, expected %0d bytes (btt %0d off %0d)", c, m_rd_tkeep, nb, x.btt, off));
                    if (m_rd_tlast !== lastb)
                        fail($sformatf("ch%0d read tlast %0b at off %0d of btt %0d", c, m_rd_tlast, off, x.btt));
                    for (int i = 0; i < nb; i++)
                        if (m_rd_tdata[8*i +: 8] !== pat(c, x.addr + off + i)) begin
                            fail($sformatf("ch%0d read byte %0d of 0x%0h: %h, expected %h (misrouted?)",
                                           c, off + i, x.addr, m_rd_tdata[8*i +: 8], pat(c, x.addr + off + i)));
                            break;
                        end
                    if (lastb || m_rd_tlast) begin
                        void'(exp_rdd[c].pop_front());
                        off = 0;
                        done_rdd[c]++; progress++;
                    end else begin
                        off += KB;
                    end
                end
                if (c == RX && tx_rstall_len != 0 && cyc >= rd_stall_from[TX] && cyc < rd_stall_to[TX])
                    rx_rbeats_in_tx_rstall++;
            end
            if (rd_stall_to[c] != 0 && cyc >= rd_stall_from[c] && cyc < rd_stall_to[c])
                m_rd_tready[c] <= 1'b0;
            else
                m_rd_tready[c] <= chance(rdy_rd[c]);
        end
    endtask

    task automatic rds_sink(int c);
        forever begin
            @(posedge aclk);
            if (m_rd_sts_valid[c] && m_rd_sts_ready[c]) begin
                if (exp_rds[c].size() == 0) fail($sformatf("ch%0d read status with no read outstanding", c));
                else begin
                    cmd_t x;
                    x = exp_rds[c].pop_front();
                    if (m_rd_sts_data[c] !== sts_hash(emitted(c, x.addr), x.btt))
                        fail($sformatf("ch%0d read status %h, expected %h (order/route)", c, m_rd_sts_data[c],
                                       sts_hash(emitted(c, x.addr), x.btt)));
                    done_rds[c]++; progress++;
                end
            end
            m_rd_sts_ready[c] <= chance(rdy_rsts[c]);
        end
    endtask

    // ---------------------------------------------------------------------------------------------
    // TOE side: write requester (command process + data process) and status consumer
    // ---------------------------------------------------------------------------------------------
    task automatic wr_cmd_gen(int c);
        for (int i = 0; i < plan_wr[c].size(); i++) begin
            cmd_t x;
            if (!free_order[c]) begin
                // TOE order: command i after packet i-1 is complete, or -- ring-end split -- while
                // packet i-1 waits at its last beat for this command.
                while (!(i == 0 || wd_done[c] >= i || (plan_wr[c][i-1].split_next && wd_at_last[c] == i-1)))
                    @(posedge aclk);
            end
            repeat ($urandom_range(0, cmd_gap[c])) @(posedge aclk);
            x = plan_wr[c][i];
            s_wr_cmd_data[c]  <= mk_cmd(x.addr, x.btt);
            s_wr_cmd_valid[c] <= 1'b1;
            do @(posedge aclk); while (!s_wr_cmd_ready[c]);
            x.t_iss = cyc;
            iss_wr[c].push_back(x); exp_wrs[c].push_back(x);
            wc_acc[c] = i + 1;
            s_wr_cmd_valid[c] <= 1'b0;
        end
    endtask

    task automatic wr_dat_gen(int c);
        for (int i = 0; i < plan_wr[c].size(); i++) begin
            cmd_t x;
            int nbeats, stall_at;
            x = plan_wr[c][i];
            nbeats = (x.btt + KB - 1) / KB;
            if (!free_order[c]) while (wc_acc[c] < i + 1) @(posedge aclk);
            else repeat ($urandom_range(0, free_gap[c])) @(posedge aclk);
            stall_at = (wstall_len[c] != 0 && chance(wstall_pct[c])) ? $urandom_range(0, nbeats - 1) : -1;
            for (int b = 0; b < nbeats; b++) begin
                int nb;
                logic [DB-1:0] d;
                if (b == nbeats - 1 && x.split_next && !free_order[c]) begin
                    wd_at_last[c] = i;
                    while (wc_acc[c] < i + 2) @(posedge aclk);
                end
                if (b == stall_at) begin
                    if (c == TX) tx_wstalling = 1;
                    repeat (wstall_len[c]) @(posedge aclk);
                    if (c == TX) tx_wstalling = 0;
                end
                if (chance(wbeat_gap_pct[c])) repeat ($urandom_range(1, wbeat_gap_max[c])) @(posedge aclk);
                nb = (x.btt - b*KB > KB) ? KB : x.btt - b*KB;
                d = '0;
                for (int k = 0; k < nb; k++) d[8*k +: 8] = pat(c, x.addr + b*KB + k);
                s_wr_tdata[c]  <= d;
                s_wr_tkeep[c]  <= keep_of(nb);
                s_wr_tlast[c]  <= (b == nbeats - 1);
                s_wr_tvalid[c] <= 1'b1;
                do @(posedge aclk); while (!s_wr_tready[c]);
                s_wr_tvalid[c] <= 1'b0;
            end
            wd_done[c] = i + 1;
        end
    endtask

    task automatic wrs_sink(int c);
        forever begin
            @(posedge aclk);
            if (m_wr_sts_valid[c] && m_wr_sts_ready[c]) begin
                if (exp_wrs[c].size() == 0) fail($sformatf("ch%0d write status with no write outstanding", c));
                else begin
                    cmd_t x;
                    x = exp_wrs[c].pop_front();
                    if (m_wr_sts_data[c] !== sts_hash(emitted(c, x.addr), x.btt))
                        fail($sformatf("ch%0d write status %h, expected %h (order/route)", c, m_wr_sts_data[c],
                                       sts_hash(emitted(c, x.addr), x.btt)));
                    if (c == RX) begin
                        if (int'(cyc - x.t_iss) > rx_wlat_max) rx_wlat_max = int'(cyc - x.t_iss);
                        if (tx_wstalling || (wsts_stall_to[TX] != 0 && cyc >= wsts_stall_from[TX] && cyc < wsts_stall_to[TX]))
                            rx_w_in_stall++;
                    end
                    done_wrs[c]++; progress++;
                end
            end
            if (wsts_stall_to[c] != 0 && cyc >= wsts_stall_from[c] && cyc < wsts_stall_to[c])
                m_wr_sts_ready[c] <= 1'b0;
            else
                m_wr_sts_ready[c] <= chance(rdy_wsts[c]);
        end
    endtask

    // ---------------------------------------------------------------------------------------------
    // Shell side: in-order datamover model
    // ---------------------------------------------------------------------------------------------
    typedef struct {
        longint unsigned addr;   // as emitted by the mux (bit 29 = channel)
        int              btt;
        longint unsigned t;      // earliest cycle for data (reads) / status
    } dm_t;
    dm_t dm_rq[$], dm_rsq[$], dm_wq[$], dm_wsq[$];

    // command acceptance + per-channel order check
    always @(posedge aclk) begin
        if (aresetn) begin
            if (m_rd_cmd_valid && m_rd_cmd_ready) begin
                dm_t d;
                int ch;
                d.addr = m_rd_cmd_data[31:0];
                d.btt  = m_rd_cmd_data[64+:23];
                d.t    = cyc + $urandom_range(dm_rlat_min, dm_rlat_max);
                ch = d.addr[29];
                if (m_rd_cmd_data[63:32] !== '0 || m_rd_cmd_data[95:87] !== '0)
                    fail($sformatf("read command reserved bits set: %h", m_rd_cmd_data));
                if (iss_rd[ch].size() == 0) fail($sformatf("datamover: read 0x%0h for ch%0d which issued none", d.addr, ch));
                else begin
                    cmd_t x;
                    x = iss_rd[ch].pop_front();
                    if (d.addr !== emitted(ch, x.addr) || d.btt != x.btt)
                        fail($sformatf("datamover: ch%0d read 0x%0h/%0d, expected 0x%0h/%0d", ch, d.addr, d.btt,
                                       emitted(ch, x.addr), x.btt));
                end
                dm_rq.push_back(d);
            end
            if (m_wr_cmd_valid && m_wr_cmd_ready) begin
                dm_t d;
                int ch;
                d.addr = m_wr_cmd_data[31:0];
                d.btt  = m_wr_cmd_data[64+:23];
                d.t    = 0;
                ch = d.addr[29];
                if (m_wr_cmd_data[63:32] !== '0 || m_wr_cmd_data[95:87] !== '0)
                    fail($sformatf("write command reserved bits set: %h", m_wr_cmd_data));
                if (iss_wr[ch].size() == 0) fail($sformatf("datamover: write 0x%0h for ch%0d which issued none", d.addr, ch));
                else begin
                    cmd_t x;
                    x = iss_wr[ch].pop_front();
                    if (d.addr !== emitted(ch, x.addr) || d.btt != x.btt)
                        fail($sformatf("datamover: ch%0d write 0x%0h/%0d, expected 0x%0h/%0d", ch, d.addr, d.btt,
                                       emitted(ch, x.addr), x.btt));
                end
                dm_wq.push_back(d);
            end
        end
        m_rd_cmd_ready <= chance(dm_rcmd_rdy);
        m_wr_cmd_ready <= chance(dm_wcmd_rdy);
    end

    // shell-side data rate: beats per cycle between the first and the last beat
    longint unsigned wr_beats = 0, wr_t0 = 0, wr_t1 = 0, rd_beats = 0, rd_t0 = 0, rd_t1 = 0;
    always @(posedge aclk) begin
        if (m_wr_tvalid && m_wr_tready) begin
            if (wr_beats == 0) wr_t0 = cyc;
            wr_beats++; wr_t1 = cyc;
        end
        if (s_rd_tvalid && s_rd_tready) begin
            if (rd_beats == 0) rd_t0 = cyc;
            rd_beats++; rd_t1 = cyc;
        end
    end

    // read engine: data packets in command order, then status
    initial begin
        int off;
        longint unsigned last_st;
        off = 0; last_st = 0;
        forever begin
            @(posedge aclk);
            if (s_rd_tvalid && s_rd_tready) begin
                dm_t d;
                d = dm_rq[0];
                if (d.btt - off <= KB) begin
                    dm_t s;
                    void'(dm_rq.pop_front());
                    s = d;
                    s.t = cyc + $urandom_range(0, 50);
                    if (s.t < last_st) s.t = last_st;
                    last_st = s.t;
                    dm_rsq.push_back(s);
                    off = 0;
                end else off += KB;
            end
            if ((!s_rd_tvalid || s_rd_tready)) begin
                // present the next beat (or idle)
                if (dm_rq.size() != 0 && cyc >= dm_rq[0].t && !chance(dm_rgap_pct)) begin
                    dm_t d;
                    int rem, nb, ch;
                    logic [DB-1:0] w;
                    d = dm_rq[0];
                    ch = d.addr[29];
                    rem = d.btt - off;
                    nb = (rem > KB) ? KB : rem;
                    w = '0;
                    for (int k = 0; k < nb; k++) w[8*k +: 8] = pat(ch, (d.addr & ~64'h2000_0000) + off + k);
                    s_rd_tdata  <= w;
                    s_rd_tkeep  <= keep_of(nb);
                    s_rd_tlast  <= (rem <= KB);
                    s_rd_tvalid <= 1'b1;
                end else begin
                    s_rd_tvalid <= 1'b0;
                end
            end
        end
    end

    // read status
    initial begin
        forever begin
            @(posedge aclk);
            if (s_rd_sts_valid && s_rd_sts_ready) void'(dm_rsq.pop_front());
            if (dm_rsq.size() != 0 && cyc >= dm_rsq[0].t) begin
                s_rd_sts_valid <= 1'b1;
                s_rd_sts_data  <= sts_hash(dm_rsq[0].addr, dm_rsq[0].btt);
            end else s_rd_sts_valid <= 1'b0;
        end
    end

    // write engine: data accepted only for a pending command, checked, then status in order
    initial begin
        int off;
        longint unsigned last_st;
        off = 0; last_st = 0;
        forever begin
            @(posedge aclk);
            if (m_wr_tvalid && m_wr_tready) begin
                if (dm_wq.size() == 0) fail("datamover: write data with no write command (model bug)");
                else begin
                    dm_t d;
                    int rem, nb, ch;
                    bit lastb;
                    d = dm_wq[0];
                    ch = d.addr[29];
                    rem = d.btt - off;
                    nb = (rem > KB) ? KB : rem;
                    lastb = (rem <= KB);
                    if (m_wr_tkeep !== keep_of(nb))
                        fail($sformatf("datamover: write keep %h at off %0d of 0x%0h/%0d", m_wr_tkeep, off, d.addr, d.btt));
                    if (m_wr_tlast !== lastb)
                        fail($sformatf("datamover: write tlast %0b at off %0d of 0x%0h/%0d (interleaved or wrong length)",
                                       m_wr_tlast, off, d.addr, d.btt));
                    for (int k = 0; k < nb; k++)
                        if (m_wr_tdata[8*k +: 8] !== pat(ch, (d.addr & ~64'h2000_0000) + off + k)) begin
                            fail($sformatf("datamover: write byte %0d of 0x%0h: %h, expected %h (wrong data under this command)",
                                           off + k, d.addr, m_wr_tdata[8*k +: 8], pat(ch, (d.addr & ~64'h2000_0000) + off + k)));
                            break;
                        end
                    if (lastb || m_wr_tlast) begin
                        dm_t s;
                        void'(dm_wq.pop_front());
                        s = d;
                        s.t = cyc + $urandom_range(dm_wlat_min, dm_wlat_max);
                        if (s.t < last_st) s.t = last_st;
                        last_st = s.t;
                        dm_wsq.push_back(s);
                        off = 0;
                    end else off += KB;
                end
            end
            m_wr_tready <= (dm_wq.size() != 0) && chance(dm_wdat_rdy);
        end
    end

    // write status
    initial begin
        forever begin
            @(posedge aclk);
            if (s_wr_sts_valid && s_wr_sts_ready) void'(dm_wsq.pop_front());
            if (dm_wsq.size() != 0 && cyc >= dm_wsq[0].t) begin
                s_wr_sts_valid <= 1'b1;
                s_wr_sts_data  <= sts_hash(dm_wsq[0].addr, dm_wsq[0].btt);
            end else s_wr_sts_valid <= 1'b0;
        end
    end

    // ---------------------------------------------------------------------------------------------
    // Main
    // ---------------------------------------------------------------------------------------------
    function automatic bit all_done();
        for (int c = 0; c < 2; c++)
            if (done_rdd[c] < n_rd[c] || done_rds[c] < n_rd[c] || done_wrs[c] < plan_wr[c].size()) return 0;
        return 1;
    endfunction

    initial begin
        int last_prog;
        longint unsigned last_t;
        string why;
        #1;
        for (int c = 0; c < 2; c++) make_plan(c);
        tx_rstall_len = rd_stall_to[TX] - rd_stall_from[TX];
        repeat (10) @(posedge aclk);
        aresetn <= 1'b1;
        repeat (5) @(posedge aclk);

        if (scen == "addr29") begin
            s_rd_cmd_data[RX]  <= mk_cmd(64'h2010_0040, 64);   // bit 29 set on input
            s_rd_cmd_valid[RX] <= 1'b1;
            do @(posedge aclk); while (!s_rd_cmd_ready[RX]);
            s_rd_cmd_valid[RX] <= 1'b0;
            repeat (100) @(posedge aclk);
            $display("tcp_mem_mux_tb 'addr29': DONE (the verdict is the assertion message above)");
            $finish;
        end

        fork
            rd_gen(TX); rd_gen(RX);
            rd_sink(TX); rd_sink(RX);
            rds_sink(TX); rds_sink(RX);
            wr_cmd_gen(TX); wr_cmd_gen(RX);
            wr_dat_gen(TX); wr_dat_gen(RX);
            wrs_sink(TX); wrs_sink(RX);
        join_none

        last_prog = 0; last_t = cyc;
        while (!all_done()) begin
            @(posedge aclk);
            if (progress != last_prog) begin last_prog = progress; last_t = cyc; end
            else if (cyc - last_t > watchdog) begin
                fail($sformatf("no progress for %0d cycles (deadlock): rd data %0d/%0d,%0d/%0d  rd sts %0d,%0d  wr sts %0d/%0d,%0d/%0d",
                               watchdog, done_rdd[TX], n_rd[TX], done_rdd[RX], n_rd[RX], done_rds[TX], done_rds[RX],
                               done_wrs[TX], plan_wr[TX].size(), done_wrs[RX], plan_wr[RX].size()));
                break;
            end
        end
        repeat (200) @(posedge aclk);

        // nothing may be left anywhere
        for (int c = 0; c < 2; c++)
            if (exp_rdd[c].size() || exp_rds[c].size() || exp_wrs[c].size() || iss_rd[c].size() || iss_wr[c].size())
                fail($sformatf("ch%0d leftovers: rdd %0d rds %0d wrs %0d iss_rd %0d iss_wr %0d", c, exp_rdd[c].size(),
                               exp_rds[c].size(), exp_wrs[c].size(), iss_rd[c].size(), iss_wr[c].size()));
        if (dm_rq.size() || dm_rsq.size() || dm_wq.size() || dm_wsq.size())
            fail("datamover model leftovers");

        why = "";
        if (max_rx_wlat != 0 && rx_wlat_max > max_rx_wlat) begin
            fail($sformatf("rx write latency %0d cycles > bound %0d (rx coupled to tx)", rx_wlat_max, max_rx_wlat));
        end
        if (min_rx_w_in_stall != 0 && rx_w_in_stall < min_rx_w_in_stall) begin
            fail($sformatf("only %0d rx writes completed while tx was stalled (need %0d)", rx_w_in_stall, min_rx_w_in_stall));
        end

        begin
            int wr_rate, rd_rate;
            wr_rate = (wr_t1 > wr_t0) ? int'(100 * wr_beats / (wr_t1 - wr_t0 + 1)) : 0;
            rd_rate = (rd_t1 > rd_t0) ? int'(100 * rd_beats / (rd_t1 - rd_t0 + 1)) : 0;
            if (min_rate_pct != 0 && (wr_rate < min_rate_pct || rd_rate < min_rate_pct))
                fail($sformatf("data rate write %0d%% / read %0d%% of one beat per cycle, need %0d%%", wr_rate, rd_rate, min_rate_pct));
            $display("  stats: cycles %0d | reads tx %0d rx %0d | writes tx %0d rx %0d | rx write latency max %0d | rx writes during tx stall %0d | rx read beats during tx read stall %0d | beats/cycle wr %0d%% rd %0d%%",
                     cyc, done_rdd[TX], done_rdd[RX], done_wrs[TX], done_wrs[RX], rx_wlat_max, rx_w_in_stall,
                     rx_rbeats_in_tx_rstall, wr_rate, rd_rate);
        end
        if (errors == 0) begin
            if (scen == "rd_hol")
                $display("tcp_mem_mux_tb '%s': PASS (read HOL as documented: %0d rx read beats delivered during the %0d-cycle tx read stall)",
                         scen, rx_rbeats_in_tx_rstall, tx_rstall_len);
            else
                $display("tcp_mem_mux_tb '%s': PASS", scen);
        end else
            $display("tcp_mem_mux_tb '%s': FAIL (%0d errors)", scen, errors);
        $finish;
    end

endmodule
