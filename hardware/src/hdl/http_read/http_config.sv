`timescale 1ns / 1ps

import lynxTypes::*;
import libstf::*;
import http_types::*;

`include "libstf_macros.svh"
`include "config_macros.svh"

// =================================================================================================
// HttpConfig
//
// A libstf-style sub-configuration that:
//   * Latches all HTTP client parameters via per-field ConfigWriteRegister
//     blocks (addresses 0..(N_PARAM-1)).
//   * Exposes the latest snapshot of those fields on a packed http_config_t
//     bus, ready to be sampled when the START write arrives.
//   * Emits one ready/valid beat carrying the entire http_config_t struct
//     when the host writes the START register (ConfigWriteReadyRegister).
//   * Exposes a read register file so the host can poll status and identify
//     the config (HTTP_CONFIG_ID).
//
// Register map (write side, addressed within this config's AXI-Lite space). The design uses
// SERVER_IP, SERVER_PORT, START, REQ_TOTAL_BYTES and REQ_CHUNK_BYTES; the host builds the request
// text itself. 2..38 are reserved: they are latched and echoed (read registers 3..9), and no
// handler reads them.
//   0  SERVER_IP        ([31:0])     -- TCP connect target, BE in low bytes
//   1  SERVER_PORT      ([31:0])     -- TCP port (uses [15:0])
//   2..38               reserved     -- PORT_HEX, IP_HEX_LEN, IP_HEX_W0..3, FILE_LEN, FILE_W0..15,
//                                       REQ_FLAGS, PKG_WORD_COUNT, USER_FREQUENCY, TIME_IN_SECONDS,
//                                       RANGE_BEGIN_LEN, RANGE_BEGIN_W0..3, RANGE_END_LEN,
//                                       RANGE_END_W0..3 (the ConfigWriteRegister list below)
//   39 START            (ConfigWriteReadyRegister)  -- value ignored, write triggers
//   41 REQ_CHUNK_BYTES  ([31:0] bytes, [35:32] lane) -- bytes in ONE decoder stream (a column
//                                       chunk) and the lane it is for. Queued ahead of the data;
//                                       axis_rewrite_last counts them down and marks tlast. One per
//                                       COLUMN CHUNK, not per request.
//   40 REQ_TOTAL_BYTES  ([31:0])     -- 0: the START beat is a chunk-length ENTRY for the lane in
//                                       REQ_CHUNK_BYTES[35:32]. Non-zero: the beat ARMS that lane,
//                                       and this many bytes of request text follow on its host
//                                       stream. Write it BEFORE START, which snapshots the
//                                       live cfg.
//
// With START at 39 and parameters up to 41 the map has 42 registers, so HTTP_CONFIG_ADDR_SPACE in
// vfpga_top.svh is 64. software/oasis/configuration.cpp mirrors these addresses.
//
// Register map (read side); INFLIGHT[31:24] carries its CSR revision, 2. Bits not listed read 0.
//   0  HTTP_CONFIG_ID   "HTT"
//   1  CLIENT_STATE     ([3:0])      -- lane 0's tcp_read state (also STATUS[11:8])
//   2  STATUS           ([31:0])     -- the handler's totalWord: [7:4] tcp_init state, [11:8] lane
//                                       0's tcp_read state, [18] every lane connected, [20] some
//                                       lane fatal, [21] some TX reservation refused, [22] busy,
//                                       [23] as STALL[24]
//   3  ECHO_FILE_LEN    ([31:0])     -- 3..7 and 9 echo reserved write registers, so they read
//   4  ECHO_FILE_W0     ([31:0])        0; 8 echoes the server
//   5  ECHO_FILE_W4     ([31:0])
//   6  ECHO_RANGE_BEGIN ([39:32] len, [31:0] first 4 ASCII digits)
//   7  ECHO_RANGE_END   ([39:32] len, [31:0] first 4 ASCII digits)
//   8  ECHO_SERVER      ([47:32] port, [31:0] ip)
//   9  ECHO_FILE_W8     ([31:0])
//   10 INFLIGHT         ([7:0] the most chunk entries any lane has queued, saturating,
//                        [15:8] QUEUE_DEPTH, saturating,
//                        [16] some lane has an announcement queued in rx_dispatch,
//                        [17] some lane's peer FINed,
//                        [18] every lane connected, [19] req_ready for the lane the beat names,
//                        [23:20] lane count, [31:24] CSR revision) -- the handler's inflightWord
//   11 STALL            (sticky, OR over the lanes: [0] an open was not answered within the connect
//                        watchdog, [3] an open was refused, [4] a TX reservation was refused,
//                        [5] a response could not be framed (no Content-Length), [6] some lane is
//                        fatal, [7] a status read as neither 200 nor 206, [15:8] reconnects,
//                        saturating,
//                        [24] rx_dispatch dropped an announcement (never: the interface is held
//                             instead),
//                        [25] a lane's decoupling fifo refused a routed beat, which is lost,
//                        [26] a read watchdog expired, [27] body bytes arrived with no chunk length
//                        queued, [28] the dispatcher routed a beat its lane refused, which is lost)
//   12 RESP             ([23:0] lane 0's status digits ASCII, [24] every lane's status is 200/206,
//                        [25] some lane's response could not be framed, [26] some lane is aborting
//                        with body bytes of the response already emitted)
//   13 BODY_REMAINING   ([31:0]) -- lane 0: bytes of the current body still to stream; a read that
//                        is stuck with this non-zero is waiting on the network, not on the decoder
//   14 CONTENT_LENGTH   ([31:0]) -- lane 0: the Content-Length the server sent for the last
//                        response, LATCHED. The host knows what it asked for; this is what arrived.
//                        The two differing is the difference between a slow network and a server
//                        answering a different question (a 200 instead of a 206, a range clamped at
//                        EOF, an error document). BODY_REMAINING alone cannot say this -- it counts
//                        down to zero and is meaningless once the response is over.
//   15 QUEUE_DEPTH      ([31:0]) -- chunk entries per lane, untruncated (INFLIGHT[15:8] saturates)
//
// The host reads INFLIGHT[31:24] first and refuses any revision but 2. The read register file
// answers an address above 20 with resp_error, not with a plausible zero.
//
// Registers 16..20 are indexed by LANE at a fixed stride of 8 lanes, whatever NUM_CONNS the
// bitstream was built with. Lanes that do not exist read 0; INFLIGHT[23:20] says how many are real.
// Widths are 64 bits (AXIL_DATA_BITS).
//
//   16 LANE_OCC        -- chunk entries QUEUED AND NOT YET RETIRED, one byte per lane, saturating
//                         at 255. Lane L at [8L+7:8L]. Retired means a tlast completed the chunk's
//                         byte count, so this is "responses this lane still owes", which is what
//                         the host's credit is against. QUEUE_DEPTH (15) is the untruncated limit.
//   17 LANE_READY      -- the ADMISSION WINDOW, one nibble per lane at [4L+3:4L]:
//                           [4L+0] ARM_READY   the lane will accept an ARM beat (req_total_bytes
//                                              != 0) -- its previous request text has gone out
//                           [4L+1] ENTRY_READY the lane will accept a chunk ENTRY beat
//                                              (req_total_bytes == 0) -- its queue has room
//                           [4L+2] CONN_UP     the lane holds an established TCP session
//                           [4L+3] FATAL       the lane is out of the game until the host reissues
//                         BOTH admission bits are in ONE register on purpose. They are monotone in
//                         the host's favour -- only a config beat the host itself writes can clear
//                         either -- so a value read here is still true when the write lands, and
//                         poll-then-write needs no retry and no lock. Note ARM_READY stays 0 on a
//                         fatal lane that was armed and never sent: check FATAL first, or wait
//                         forever.
//   18 LANE_STATE      -- FSM states, one nibble per lane:
//                           [4L+3:4L]      tcp_read state_debug (the receive/framing lane)
//                           [32+4L+3:32+4L] http_req_stream state_debug (that lane's transmit side:
//                                          0 IDLE, 1 SEND_META, 2 WAIT_STAT, 3 SEND_DATA, 4 DRAIN)
//   19 LANE_ERR        -- STICKY causes, one byte per lane at [8L+7:8L]. Sticky since reset; a
//                         reconnect does not clear them, which is the point -- the conditions that
//                         matter are transient at the hardware and long gone by the time anyone
//                         polls:
//                           [8L+0] LANE_DEAD      rx_dispatch's head-of-line watchdog
//                                                 declared this lane dead and started discarding
//                                                 its packets. THE ONE THAT CANNOT BE INFERRED:
//                                                 the handler tears the session down in response,
//                                                 which clears rx_dispatch's own dead bit, so
//                                                 without this a HOL kill and an unreplayable read
//                                                 failure look identical. Bytes were dropped out
//                                                 of the MIDDLE of a response -- the whole batch
//                                                 must be reissued.
//                           [8L+1] DIRTY          the read aborted after body bytes had already
//                                                 reached the decoder, so a replay would duplicate
//                           [8L+2] INIT_ERR       an open for this lane was refused; with FATAL it
//                                                 was the open of a reconnect
//                           [8L+3] RESP_ERR       a response could not be framed (no
//                                                 Content-Length)
//                           [8L+4] STATUS_BAD     a response retired with a status read as neither
//                                                 200 nor 206
//                           [8L+5] TX_REFUSED     the TOE refused at least one transmit reservation
//                                                 (informational; it is re-announced)
//                           [8L+6] READ_TIMEOUT   the read watchdog expired -- nothing arrived, as
//                                                 opposed to the server saying no
//                           [8L+7] RX_FIFO_STALL  this lane's decoupling fifo refused a beat routed
//                                                 to it, and the beat was lost: the stream is
//                                                 corrupt. Should never fire; see the reservation
//                                                 in tcp_read.sv
//                         FATAL lives in 17, not here. Fatal AND lane_dead is a HOL kill;
//                         fatal and not lane_dead is a read that could not be replayed or a refused
//                         reconnect, and the other bits say which.
//   20 LANE_POLICY     -- fixed at elaboration, for the host to sanity-check itself against:
//                           [7:0]   CSR revision (same value as INFLIGHT[31:24])
//                           [15:8]  NUM_CONNS
//                           [31:16] QUEUE_DEPTH, chunk entries PER LANE, saturating at 65535
//                           [55:32] LANE_STALL_CYCLES, the HOL watchdog threshold in cycles,
//                                   saturating at 2^24-1 -- a software watchdog shorter than it
//                                   declares a lane dead that the hardware is still waiting on
//                           [61:56] log2 of it, exact even where the 24-bit field saturates
//                           [63:62] zero
//
// The admission bits are not optional bookkeeping. ConfigWriteReadyRegister does NOT back-pressure:
// a START write that lands while the previous one is still unconsumed overwrites it, and the
// earlier beat is lost without a trace. So the host polls LANE_READY for the lane a beat names
// before it writes START, and LANE_OCC against QUEUE_DEPTH is its chunk credit.
//
// =================================================================================================
module HttpConfig #(
    parameter integer NUM_PARAM_REGS = 42,
    parameter integer START_ADDR     = 39
) (
    input  logic clk,
    input  logic rst_n,

    write_config_i.s write_config,
    read_config_i.s  read_config,

    // Live snapshot of the latched configuration. The handler can read these
    // directly; they are stable across runs as long as the host does not
    // overwrite the corresponding write registers.
    output http_config_t cfg,

    // Trigger: fires for one beat (until consumer raises ready) when the
    // host writes to the START register. data carries the cfg snapshot at
    // that moment.
    ready_valid_i.m  start_cfg,

    // Status read back to the host
    input  logic [3:0]  client_state,
    input  logic [31:0] total_word,
    input  logic [31:0] inflight_word,
    input  logic [31:0] queue_depth_word,
    input  logic [31:0] stall_word,
    input  logic [31:0] resp_word,
    input  logic [31:0] content_length_word,
    input  logic [31:0] body_remaining_word,

    // Per-lane readback, read registers 16..20. See the read map above for the field tables.
    input  logic [63:0] lane_occ_word,
    input  logic [63:0] lane_ready_word,
    input  logic [63:0] lane_state_word,
    input  logic [63:0] lane_err_word,
    input  logic [63:0] lane_policy_word
);

`RESET_RESYNC

localparam logic [AXIL_DATA_BITS - 1:0] HTTP_CONFIG_ID = 64'h0000_0000_0048_5454; // "HTT"

// The map below is hardcoded in the ConfigWriteRegister instantiations, so these parameters cannot
// move it -- they only place START and size the address space. Parameters occupy 0..38, 40 and 41,
// and START sits at 39, between them. The checks below hold that START aliases no parameter (a
// START on a parameter register would fire the request on a write to that parameter) and that the
// address space covers the highest parameter.
localparam int LAST_PARAM_ADDR   = 38;   // highest contiguous parameter, below START
localparam int STREAM_PARAM_ADDR = 41;   // req_total_bytes at 40, req_chunk_bytes at 41
`ASSERT_ELAB(START_ADDR > LAST_PARAM_ADDR)
`ASSERT_ELAB(START_ADDR < STREAM_PARAM_ADDR)
`ASSERT_ELAB(NUM_PARAM_REGS > STREAM_PARAM_ADDR)

// -------------------------------------------------------------------------------------------------
// Per-field write registers. Each ConfigWriteRegister latches the AXI-Lite
// data into its output on a write to its assigned address.
// -------------------------------------------------------------------------------------------------
data64_t reg_server_ip;
data64_t reg_server_port;
data64_t reg_port_hex;
data64_t reg_ip_hex_len;
data64_t reg_ip_hex_w0;
data64_t reg_ip_hex_w1;
data64_t reg_ip_hex_w2;
data64_t reg_ip_hex_w3;
data64_t reg_file_len;
data64_t reg_file_w0;
data64_t reg_file_w1;
data64_t reg_file_w2;
data64_t reg_file_w3;
data64_t reg_file_w4;
data64_t reg_file_w5;
data64_t reg_file_w6;
data64_t reg_file_w7;
data64_t reg_file_w8;
data64_t reg_file_w9;
data64_t reg_file_w10;
data64_t reg_file_w11;
data64_t reg_file_w12;
data64_t reg_file_w13;
data64_t reg_file_w14;
data64_t reg_file_w15;
data64_t reg_req_flags;
data64_t reg_pkg_word_count;
data64_t reg_user_frequency;
data64_t reg_time_in_seconds;
data64_t reg_range_begin_len;
data64_t reg_range_begin_w0;
data64_t reg_range_begin_w1;
data64_t reg_range_begin_w2;
data64_t reg_range_begin_w3;
data64_t reg_range_end_len;
data64_t reg_req_total_bytes;
data64_t reg_req_chunk_bytes;
data64_t reg_range_end_w0;
data64_t reg_range_end_w1;
data64_t reg_range_end_w2;
data64_t reg_range_end_w3;

ConfigWriteRegister #(0,  data64_t) inst_reg_server_ip        (clk, write_config, reg_server_ip);
ConfigWriteRegister #(1,  data64_t) inst_reg_server_port      (clk, write_config, reg_server_port);
ConfigWriteRegister #(2,  data64_t) inst_reg_port_hex         (clk, write_config, reg_port_hex);
ConfigWriteRegister #(3,  data64_t) inst_reg_ip_hex_len       (clk, write_config, reg_ip_hex_len);
ConfigWriteRegister #(4,  data64_t) inst_reg_ip_hex_w0        (clk, write_config, reg_ip_hex_w0);
ConfigWriteRegister #(5,  data64_t) inst_reg_ip_hex_w1        (clk, write_config, reg_ip_hex_w1);
ConfigWriteRegister #(6,  data64_t) inst_reg_ip_hex_w2        (clk, write_config, reg_ip_hex_w2);
ConfigWriteRegister #(7,  data64_t) inst_reg_ip_hex_w3        (clk, write_config, reg_ip_hex_w3);
ConfigWriteRegister #(8,  data64_t) inst_reg_file_len         (clk, write_config, reg_file_len);
ConfigWriteRegister #(9,  data64_t) inst_reg_file_w0          (clk, write_config, reg_file_w0);
ConfigWriteRegister #(10, data64_t) inst_reg_file_w1          (clk, write_config, reg_file_w1);
ConfigWriteRegister #(11, data64_t) inst_reg_file_w2          (clk, write_config, reg_file_w2);
ConfigWriteRegister #(12, data64_t) inst_reg_file_w3          (clk, write_config, reg_file_w3);
ConfigWriteRegister #(13, data64_t) inst_reg_file_w4          (clk, write_config, reg_file_w4);
ConfigWriteRegister #(14, data64_t) inst_reg_file_w5          (clk, write_config, reg_file_w5);
ConfigWriteRegister #(15, data64_t) inst_reg_file_w6          (clk, write_config, reg_file_w6);
ConfigWriteRegister #(16, data64_t) inst_reg_file_w7          (clk, write_config, reg_file_w7);
ConfigWriteRegister #(17, data64_t) inst_reg_file_w8          (clk, write_config, reg_file_w8);
ConfigWriteRegister #(18, data64_t) inst_reg_file_w9          (clk, write_config, reg_file_w9);
ConfigWriteRegister #(19, data64_t) inst_reg_file_w10         (clk, write_config, reg_file_w10);
ConfigWriteRegister #(20, data64_t) inst_reg_file_w11         (clk, write_config, reg_file_w11);
ConfigWriteRegister #(21, data64_t) inst_reg_file_w12         (clk, write_config, reg_file_w12);
ConfigWriteRegister #(22, data64_t) inst_reg_file_w13         (clk, write_config, reg_file_w13);
ConfigWriteRegister #(23, data64_t) inst_reg_file_w14         (clk, write_config, reg_file_w14);
ConfigWriteRegister #(24, data64_t) inst_reg_file_w15         (clk, write_config, reg_file_w15);
ConfigWriteRegister #(25, data64_t) inst_reg_req_flags        (clk, write_config, reg_req_flags);
ConfigWriteRegister #(26, data64_t) inst_reg_pkg_word_count   (clk, write_config, reg_pkg_word_count);
ConfigWriteRegister #(27, data64_t) inst_reg_user_frequency   (clk, write_config, reg_user_frequency);
ConfigWriteRegister #(28, data64_t) inst_reg_time_in_seconds  (clk, write_config, reg_time_in_seconds);
// 40, above the START trigger at 39. Writing a parameter above the trigger is safe because the
// trigger reads the LIVE cfg: the host writes 40, then 39, and the snapshot includes it.
ConfigWriteRegister #(40, data64_t) inst_reg_req_total_bytes (clk, write_config, reg_req_total_bytes);
ConfigWriteRegister #(41, data64_t) inst_reg_req_chunk_bytes (clk, write_config, reg_req_chunk_bytes);
ConfigWriteRegister #(29, data64_t) inst_reg_range_begin_len    (clk, write_config, reg_range_begin_len);
ConfigWriteRegister #(30, data64_t) inst_reg_range_begin_w0     (clk, write_config, reg_range_begin_w0);
ConfigWriteRegister #(31, data64_t) inst_reg_range_begin_w1     (clk, write_config, reg_range_begin_w1);
ConfigWriteRegister #(32, data64_t) inst_reg_range_begin_w2     (clk, write_config, reg_range_begin_w2);
ConfigWriteRegister #(33, data64_t) inst_reg_range_begin_w3     (clk, write_config, reg_range_begin_w3);
ConfigWriteRegister #(34, data64_t) inst_reg_range_end_len      (clk, write_config, reg_range_end_len);
ConfigWriteRegister #(35, data64_t) inst_reg_range_end_w0       (clk, write_config, reg_range_end_w0);
ConfigWriteRegister #(36, data64_t) inst_reg_range_end_w1       (clk, write_config, reg_range_end_w1);
ConfigWriteRegister #(37, data64_t) inst_reg_range_end_w2       (clk, write_config, reg_range_end_w2);
ConfigWriteRegister #(38, data64_t) inst_reg_range_end_w3       (clk, write_config, reg_range_end_w3);

// -------------------------------------------------------------------------------------------------
// Live snapshot bus. The handler samples whichever fields it needs from `cfg`.
// -------------------------------------------------------------------------------------------------
always_comb begin
    cfg.server_ip       = reg_server_ip      [31:0];
    cfg.server_port     = reg_server_port    [31:0];
    cfg.port_hex        = reg_port_hex       [31:0];
    cfg.ip_hex_len      = reg_ip_hex_len     [7:0];
    cfg.ip_hex_w0       = reg_ip_hex_w0      [31:0];
    cfg.ip_hex_w1       = reg_ip_hex_w1      [31:0];
    cfg.ip_hex_w2       = reg_ip_hex_w2      [31:0];
    cfg.ip_hex_w3       = reg_ip_hex_w3      [31:0];
    cfg.file_len        = reg_file_len       [31:0];
    cfg.file_w0         = reg_file_w0        [31:0];
    cfg.file_w1         = reg_file_w1        [31:0];
    cfg.file_w2         = reg_file_w2        [31:0];
    cfg.file_w3         = reg_file_w3        [31:0];
    cfg.file_w4         = reg_file_w4        [31:0];
    cfg.file_w5         = reg_file_w5        [31:0];
    cfg.file_w6         = reg_file_w6        [31:0];
    cfg.file_w7         = reg_file_w7        [31:0];
    cfg.file_w8         = reg_file_w8        [31:0];
    cfg.file_w9         = reg_file_w9        [31:0];
    cfg.file_w10        = reg_file_w10       [31:0];
    cfg.file_w11        = reg_file_w11       [31:0];
    cfg.file_w12        = reg_file_w12       [31:0];
    cfg.file_w13        = reg_file_w13       [31:0];
    cfg.file_w14        = reg_file_w14       [31:0];
    cfg.file_w15        = reg_file_w15       [31:0];
    cfg.req_flags       = reg_req_flags      [15:0];
    cfg.pkg_word_count  = reg_pkg_word_count [31:0];
    cfg.user_frequency  = reg_user_frequency [31:0];
    cfg.time_in_seconds = reg_time_in_seconds[31:0];
    cfg.req_total_bytes = reg_req_total_bytes[31:0];
    cfg.req_chunk_bytes = reg_req_chunk_bytes[31:0];
    cfg.req_chunk_dest  = reg_req_chunk_bytes[35:32];
    cfg.range_begin_len = reg_range_begin_len[7:0];
    cfg.range_begin_w0  = reg_range_begin_w0 [31:0];
    cfg.range_begin_w1  = reg_range_begin_w1 [31:0];
    cfg.range_begin_w2  = reg_range_begin_w2 [31:0];
    cfg.range_begin_w3  = reg_range_begin_w3 [31:0];
    cfg.range_end_len   = reg_range_end_len  [7:0];
    cfg.range_end_w0    = reg_range_end_w0   [31:0];
    cfg.range_end_w1    = reg_range_end_w1   [31:0];
    cfg.range_end_w2    = reg_range_end_w2   [31:0];
    cfg.range_end_w3    = reg_range_end_w3   [31:0];
end

// -------------------------------------------------------------------------------------------------
// Start trigger. The host writes any value to START_ADDR and we emit one
// beat carrying the current cfg snapshot. ConfigWriteReadyRegister gives us
// a registered valid/data pair which we just rewire to carry the struct.
// -------------------------------------------------------------------------------------------------
ready_valid_i #(data64_t) start_raw();

ConfigWriteReadyRegister #(START_ADDR, data64_t) inst_start_trigger (
    .clk         (clk),
    .rst_n       (reset_synced),
    .write_config(write_config),
    .data        (start_raw)
);

assign start_cfg.data  = cfg;
assign start_cfg.valid = start_raw.valid;
assign start_raw.ready = start_cfg.ready;

// -------------------------------------------------------------------------------------------------
// Read register file: host can poll status here.
//
// Registers 3..9 echo latched write parameters: the write registers are write-only, and an echo is
// the only way to see what a register holds. The host does not write the reserved 2..38, so these
// read 0; 8 echoes the server it does write.
// -------------------------------------------------------------------------------------------------
// 21 (0..20). The read register file answers anything above NUM_READ_REGS-1 with resp_error, which
// is the whole compatibility scheme -- a host that reads a register this bitstream does not have
// gets an error, not a plausible zero.
localparam int NUM_READ_REGS = 21;

logic [AXIL_DATA_BITS - 1:0] read_registers[NUM_READ_REGS];

assign read_registers[0] = HTTP_CONFIG_ID;
assign read_registers[1] = {60'b0, client_state};
assign read_registers[2] = {32'b0, total_word};
assign read_registers[3] = {32'b0, cfg.file_len};
assign read_registers[4] = {32'b0, cfg.file_w0};
assign read_registers[5] = {32'b0, cfg.file_w4};
assign read_registers[6] = {24'b0, cfg.range_begin_len, cfg.range_begin_w0};
assign read_registers[7] = {24'b0, cfg.range_end_len,   cfg.range_end_w0};
assign read_registers[8] = {16'b0, cfg.server_port[15:0], cfg.server_ip};
// Path chars 32..35.
assign read_registers[9] = {32'b0, cfg.file_w8};
// Lane occupancy, the lane count and the CSR revision. See the map above.
assign read_registers[10] = {32'b0, inflight_word};
// Sticky stall and error causes, OR-folded over the lanes. See the handler.
assign read_registers[11] = {32'b0, stall_word};
// HTTP response framing. On a persistent connection the body is delimited by Content-Length rather
// than by the FIN, so "the response was a 404 whose XML body happened to parse as column data" and
// "the response could not be framed at all" are distinguishable from the host. See strip_http.sv.
assign read_registers[12] = {32'b0, resp_word};
assign read_registers[13] = {32'b0, body_remaining_word};
assign read_registers[14] = {32'b0, content_length_word};
// Chunk entries per lane, untruncated: INFLIGHT's occupancy and depth bytes saturate at 255.
assign read_registers[15] = {32'b0, queue_depth_word};

// -------------------------------------------------------------------------------------------------
// Per-lane visibility.
//
// Everything from 10 to 15 folds N lanes into one 32-bit window with OR: the host learns that
// SOMETHING failed, not which lane to reissue. These five are indexed by lane at a fixed stride.
//
// They sit above 15 and nothing at 0..15 depends on them. Extend the map, never edit it: a
// bitstream and a library that disagree about the map fail silently in both directions. The
// revision byte in INFLIGHT names this map, and the host checks it first.
// -------------------------------------------------------------------------------------------------
assign read_registers[16] = lane_occ_word;
assign read_registers[17] = lane_ready_word;
assign read_registers[18] = lane_state_word;
assign read_registers[19] = lane_err_word;
assign read_registers[20] = lane_policy_word;

// The read side shares HTTP_CONFIG_ADDR_SPACE (vfpga_top.svh) with the write side, which is sized
// for the parameters and START; the read map must not be the larger of the two.
`ASSERT_ELAB(NUM_READ_REGS <= NUM_PARAM_REGS + 1)
// Registers 16..20 are 64 bits wide.
`ASSERT_ELAB(AXIL_DATA_BITS >= 64)

// -------------------------------------------------------------------------------------------------
// The read register file, IN TWO REGISTERED STAGES.
//
// libstf's ConfigReadRegisterFile compares the address against every register on the read
// handshake and OR-muxes the 64-bit words straight into resp_data, in one cycle. Both ends of that
// cone are far away: the address is libstf's inst_config.read_addr (a subtract in the read
// splitter, fanning out into every register file of the design), and the words are combinational
// status from all over the handler and the decoder lanes, across SLR boundaries. It fails timing.
//
// Here, with the same protocol towards the splitter (read_ready only while idle, resp_valid held
// until resp_ready):
//   * every word is registered each cycle (read_words_q), so the mux reads flops of this module;
//   * the handshake cycle h only registers the address decode (rd_match_q);
//   * cycle h+1 muxes rd_match_q over read_words_q -- which hold the words of cycle h -- into
//     resp_data/resp_error and raises resp_valid.
// So a read returns exactly what ConfigReadRegisterFile would (the words and the decode of the
// handshake cycle), one cycle later. The splitter waits for resp_valid however long it takes
// (it matches responses to reads through its own fifo), so the extra cycle is legal on the AXI-Lite
// side too: rvalid simply comes a cycle later.
// -------------------------------------------------------------------------------------------------
logic [AXIL_DATA_BITS - 1:0] read_words_q[NUM_READ_REGS];

always_ff @(posedge clk) begin
    for (int i = 0; i < NUM_READ_REGS; i++) read_words_q[i] <= read_registers[i];
end

typedef enum logic [1:0] {RD_WAIT, RD_SELECT, RD_RESPOND} rd_state_t;
rd_state_t                   rd_state_q;
logic [NUM_READ_REGS - 1:0]  rd_match_q;
logic [AXIL_DATA_BITS - 1:0] rd_data_w;

assign read_config.read_ready = (rd_state_q == RD_WAIT);

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        rd_state_q             <= RD_WAIT;
        read_config.resp_valid <= 1'b0;
    end else begin
        case (rd_state_q)
            RD_WAIT: begin
                if (read_config.read_valid) rd_state_q <= RD_SELECT;
            end
            RD_SELECT: begin
                read_config.resp_valid <= 1'b1;
                rd_state_q             <= RD_RESPOND;
            end
            default: begin // RD_RESPOND
                if (read_config.resp_ready) begin
                    read_config.resp_valid <= 1'b0;
                    rd_state_q             <= RD_WAIT;
                end
            end
        endcase
    end
end

// Decode and response data carry no reset: they are only ever read under their state.
always_ff @(posedge clk) begin
    if ((rd_state_q == RD_WAIT) && read_config.read_valid) begin
        for (int i = 0; i < NUM_READ_REGS; i++) rd_match_q[i] <= (read_config.read_addr == i);
    end
    if (rd_state_q == RD_SELECT) begin
        read_config.resp_data  <= rd_data_w;
        read_config.resp_error <= !(|rd_match_q);
    end
end

always_comb begin
    rd_data_w = '0;
    for (int i = 0; i < NUM_READ_REGS; i++) rd_data_w |= rd_match_q[i] ? read_words_q[i] : '0;
end

endmodule
