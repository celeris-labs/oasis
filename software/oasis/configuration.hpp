#pragma once

#include "libstf/common.hpp"
#include <array>
#include <atomic>
#include <coyote/cThread.hpp>
#include <cstdint>
#include <libstf/configuration.hpp>
#include <string>
#include <vector>

namespace oasis {

constexpr const uint64_t OASIS_SYSTEM_ID = 0x0A515;

/**
 * Enable/query the FPGA-side request trace: the latched CSR echo, the handler status word and the
 * request-ring occupancy.
 *
 * This used to be reachable ONLY through the OASIS_HTTP_DEBUG environment variable, while DuckDB's
 * `SET httpfpga_debug = true` lit up a completely different set of messages (the host-socket path in
 * the extension's file system). So the obvious thing to switch on produced exactly the output that
 * cannot explain an FPGA hang, and the output that can stayed dark. The extension setting now calls
 * set_http_debug(), and the environment variable still works on its own.
 */
void set_http_debug(bool enabled);
bool http_debug_enabled();

constexpr const uint64_t RDMA_READ_CONFIG_REGS = 2;
constexpr const uint64_t RDMA_READ_CONFIG_ID   = 0x2f966a70f04c0e93;

// Matches hardware HttpConfig (39 params [0..38] + START at 39). ID string "HTT".
// Kept in sync with hardware/src/hdl/http_read/http_config.sv (NUM_PARAM_REGS=39, START_ADDR=39).
// Must match HTTP_CONFIG_ADDR_SPACE in hardware/src/vfpga_top.svh. Went 32 -> 64 when the GET path
// grew from 8 to 16 CSR words (32 -> 64 characters), which pushed START from 31 to 39.
constexpr const uint64_t HTTP_READ_CONFIG_REGS = 64;
constexpr const uint64_t HTTP_READ_CONFIG_ID   = 0x0000000000485454;

/// CSR revision at which the per-lane readback registers (read ids 16..20) exist, reported in
/// inflightWord[31:24]. It reads 0 on every bitstream built before them.
///
/// THIS IS NOT A COSMETIC CHECK. The read register file answers an out-of-range address with
/// resp_error, not with zeros, so reading 16..20 on an older bitstream is a bus error rather than a
/// harmless "all fields clear". Every accessor for those registers is gated on this, and everything
/// gated falls back to the pre-lane behaviour rather than degrading.
constexpr const uint8_t HTTP_CSR_REVISION_LANES = 2;

/// Lanes the per-lane CSRs address, at a FIXED stride, whatever NUM_CONNS the bitstream was built
/// with. Lanes the bitstream does not have read 0. The stride is fixed on purpose: one that moved
/// with the lane count would silently reinterpret every field the moment a 2-lane bitstream was
/// swapped for a 4-lane one. See the read map in hardware/src/hdl/http_read/http_config.sv.
constexpr const uint8_t HTTP_LANE_SLOTS = 8;

/**
 * Configues a hardware RDMARead module to properly process the next page
 */
class RDMAReadConfig : public libstf::Config {
  public:
    RDMAReadConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset,
                   uint32_t num_regs);

    /**
     * Triggers a remote read using the RDMARead module.
     *
     * Offsets are relative to the base virtual address of the remote RDMA region. initRDMA must 
     * have exchanged queue pairs before the first enqueue_read().
     *
     * @param stream The Coyote stream on which to perform the read.
     * @param offset The offset, relative to the remote region's base vaddr, to read from.
     * @param size   The number of bytes to read.
     */
    void enqueue_read(libstf::stream_t stream, size_t offset, size_t size);

    const libstf::stream_t num_streams() const;

    static constexpr uint64_t ID = RDMA_READ_CONFIG_ID;

  private:
    libstf::stream_t num_streams_;
};

/**
 * Snapshot of the request parameters the hardware actually latched, read back from HttpConfig read
 * CSRs 3..8. The parameter write registers are write-only, so this is the only way to confirm that
 * the CSR writes landed before START sampled them.
 */
struct HTTPRequestEcho {
    uint32_t file_len        = 0;
    uint32_t file_w0         = 0; // GET path characters 0..3
    uint32_t file_w4         = 0; // GET path characters 16..19
    uint32_t file_w8         = 0; // GET path characters 32..35
    uint32_t range_begin_w0  = 0; // first four ASCII digits of the range start
    uint8_t  range_begin_len = 0;
    uint32_t range_end_w0    = 0;
    uint8_t  range_end_len   = 0;
    uint32_t server_ip       = 0;
    uint16_t server_port     = 0;

    /// One-line human-readable rendering, with the ASCII words decoded.
    std::string describe() const;
};

/**
 * Dirty bring-up of hardware HttpConfig + handler (HW TCP open).
 * Writes the full CSR map and pulses START. No body return path yet.
 */
/// Pads request text to a whole 64-byte DMA beat with a header the server ignores, so the transfer
/// has no tail to round up and nothing can be left in the stream for the next batch to pick up.
void PadRequestTextToBeat(std::string &text);

class HTTPReadConfig : public libstf::Config {
  public:
    HTTPReadConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset, uint32_t num_regs);

    /// A query's worth of requests, built as text on the host.
    ///
    /// The descriptor path writes ~40 CSRs per request and then waits for a slot in the hardware
    /// ring; measured on a scale-30 lineitem scan that ring is full for 1462 of 1465 requests, so
    /// the host is blocked for essentially the whole query. Here the FPGA stores nothing per
    /// request -- the text IS the request -- and the queue holds one bit per expected response.
    struct RequestBatch {
        /// Every GET, concatenated, in the order the responses will come back.
        std::string text;
        /// One entry per COLUMN CHUNK: its total compressed size in bytes. The hardware counts
        /// those bytes down and marks tlast on the beat that completes them, so how many ranged
        /// GETs the chunk was split into is invisible downstream.
        ///
        /// This used to be one bool per REQUEST. The flag worked but made the hardware's queue
        /// scale with request count -- thousands, once requests are pushed in bulk -- which was the
        /// last arbitrary limit in the design. A row group has a handful of chunks however finely
        /// each is split.
        std::vector<uint32_t> chunk_bytes;
    };

    /// Append one column chunk's GETs to `batch`, splitting at chunk_bytes() exactly as read() does.
    void read_streamed(uint32_t server_ip, uint16_t server_port, const std::string &path,
                       uint64_t range_begin, uint64_t range_end, RequestBatch &batch);

    /// COLUMN CHUNKS a single batch may carry, from the hardware queue depth. Larger batches must
    /// be split: the host pushes every entry before arming, so one that does not fit cannot drain.
    /// Note this bounds chunks, not requests -- the request text is one DMA of any size.
    size_t max_batch_chunks();

    /// Which admission bit await_cfg_ready() is waiting on. Both live in the SAME nibble of read
    /// register 17 and they are not interchangeable: an ARM waits for the lane's previous request
    /// text to have gone out, an ENTRY waits for its chunk queue to have room. Waiting on the wrong
    /// one deadlocks -- the arm that would drain the queue is the beat being withheld.
    enum class LaneAdmit : uint8_t { Arm, Entry };

    /// Push the batch's body_last bits, then arm the transfer, ALL ON `lane`. The caller DMAs
    /// `batch.text` into that lane's request stream afterwards -- this only tells the hardware what
    /// is coming.
    ///
    /// `lane` is what the hardware routes by (req_chunk_dest, bits [35:32] of the chunk-length
    /// register); get it from lane_for_stream(). It used to be derived from the decode stream inside
    /// here while operator.cpp derived the DMA sink from the same stream a different way, so the two
    /// could disagree; and the arm carried no lane of its own at all, inheriting whatever the last
    /// entry left in the register. Both are now one explicit parameter.
    void submit_batch(uint32_t server_ip, uint16_t server_port, const RequestBatch &batch,
                      uint8_t lane);

    /// Block until `lane` will accept a beat of this kind, or throw naming the lane and why it will
    /// not. See the definition for why skipping this loses whole batches without raising anything,
    /// and for what happens on a bitstream with no per-lane registers.
    void await_cfg_ready(const char *what, uint8_t lane, LaneAdmit admit);

    /// Block until `lane` has room for `needed` more chunk entries -- occ(lane) + needed <=
    /// lane_depth_limit(). Batches must reserve space for all of their entries up front: the arm
    /// that starts a transfer is written after the entries, so a batch that fills the queue part way
    /// through deadlocks against its own arm.
    ///
    /// A `needed` above lane_depth_limit() is not an error and not an impossible wait: the limit is
    /// the host's pipelining cap, and a batch bigger than it simply gets the lane to itself
    /// (`needed` is already bounded by max_batch_chunks(), which is the hardware's real limit).
    /// Fatal is checked first, so a dead lane fails immediately instead of never draining.
    ///
    /// On a bitstream below HTTP_CSR_REVISION_LANES there is no per-lane occupancy, and this
    /// degrades to exactly the previous behaviour: await_queue_space() against the shared queue,
    /// i.e. depth-1-per-batch semantics.
    void await_lane_credit(uint8_t lane, size_t needed,
                           const char *what = "a batch of chunk-length entries");

    /// Block until the hardware queue has room for `needed` entries, against the OR-folded
    /// occupancy in read id 10. The pre-lane path; await_lane_credit() is the per-lane one.
    void await_queue_space(size_t needed, const char *what);

    /// The three HTTP status digits from the last response strip_http parsed, as text ("206",
    /// "416", ...), or "unparsed". Reads CSR 12. Meaningful mainly when stall().status_bad is set.
    std::string last_http_status();

    /// The exact bytes http_req_builder used to assemble in hardware.
    static std::string BuildGet(const std::string &host, uint16_t port, const std::string &path,
                                uint64_t range_begin, uint64_t range_end);

    /// Fire one ranged GET. `stream` / `session_id` ignored (single HttpConfig; HW opens).
    void read(libstf::stream_t stream, uint32_t server_ip, uint16_t server_port, const std::string &path,
              uint64_t range_begin, uint64_t range_end, uint16_t session_id);

    uint8_t client_state();

    /// Read CSR 2: packed FSM status word (layout defined by `totalWord` in handler.sv).
    uint32_t debug_status();

    /**
     * Read CSR 10: the request-ring occupancy (`inflightWord` in handler.sv).
     *
     * The handler pipelines several ranged GETs over concurrent TCP sessions, so "busy" is the
     * normal state during a scan and says nothing about whether another request can be accepted.
     * This does: the ring holds `slots` descriptors and `occupied` of them are in use.
     *
     * Bitstreams older than the pipelined handler have no such register and read back zero, which
     * is reported as slots == 0. Callers must treat that as "legacy, one request at a time".
     */
    struct HTTPInflight {
        uint8_t occupied      = 0;
        uint8_t slots         = 0; // 0 => pre-pipelining bitstream
        bool    has_pending   = false; // an announced segment is waiting to be read
        bool    peer_closed   = false; // the peer has FINed
        bool    conn_up       = false; // the persistent connection is established
        /// The config port can accept another beat. MUST be polled before every START: the write
        /// register does not back-pressure, so a START landing on an unconsumed beat overwrites it
        /// and the request is lost silently.
        bool    req_ready     = false;
        /// TCP sessions this bitstream has, one per decoder lane (handler_multi). 1 on a
        /// single-session bitstream, where the field reads 0 and is normalised here -- an older
        /// bitstream has one shared connection, not zero.
        uint8_t lanes         = 1;
        /// CSR revision, from inflightWord[31:24]. 0 on every bitstream built before the per-lane
        /// registers; HTTP_CSR_REVISION_LANES or higher means read ids 16..20 exist. NOT normalised
        /// -- 0 is a real answer here and the only safe one to act on.
        uint8_t revision      = 0;

        bool multi_session() const { return lanes > 1; }
        bool legacy() const { return slots == 0; }
        uint8_t free_slots() const { return slots > occupied ? uint8_t(slots - occupied) : uint8_t(0); }
        std::string describe() const;
    };
    HTTPInflight inflight();

    /// TCP sessions the bitstream provides, cached after the first read. 1 means the single-session
    /// handler_stream; >1 means handler_multi, where every request beat must name a lane and each
    /// lane's request text goes to its OWN host-recv stream.
    ///
    /// Read from hardware rather than compiled in: the CSR map and the bitstream must agree, and a
    /// host that assumes a lane count the board does not have sends text to a tied-off stream,
    /// which discards it while reporting success. See the note on req_dest in operator.cpp.
    uint8_t lane_count();

    /// CSR revision the programmed bitstream reports (inflightWord[31:24]), cached after the first
    /// read. 0 on everything built before the per-lane registers.
    uint8_t revision();

    /// Whether read ids 16..20 may be READ AT ALL. Reading them on a bitstream below
    /// HTTP_CSR_REVISION_LANES is a resp_error, not zeros, so this gates every lane accessor.
    bool lane_csrs_available();

    /// The value written into req_chunk_dest -- bits [35:32] of the chunk-length register -- for a
    /// chunk that decodes on `stream`.
    ///
    /// TWO BITSTREAMS READ THAT FIELD DIFFERENTLY, and it is the same four bits:
    ///   - handler_multi (lane_count() > 1): it is the LANE. The lane owns a TCP session, a framer,
    ///     a chunk queue and the decoder its body bytes come out on, so the lane index IS the
    ///     decoder index. `stream % lanes`, matching what operator.cpp already does when it picks
    ///     the axis_host_recv sink for the request text -- the two MUST agree or a lane's entries
    ///     and its request text land on different lanes.
    ///   - the single-session handler (lane_count() == 1): there is one connection and the field is
    ///     purely the DECODER index, so it stays `stream & 0xF`. Folding it to 0 would send every
    ///     column's bytes to decoder 0.
    ///
    /// WP5: the modulo is a routing hazard, not a design. A chunk placed on a decode stream the
    /// bitstream has no lane for is silently rerouted to `stream % lanes` -- correct today only
    /// because the scheduler's stream count is the decoder count and the bitstream is built with one
    /// lane per decoder. Lane-aware dispatch should choose the lane and let the decode stream follow
    /// it, not the other way round.
    uint8_t lane_for_stream(libstf::stream_t stream);

    /**
     * One lane's admission window, from read ids 16 (LANE_OCC) and 17 (LANE_READY).
     *
     * Both admission bits are monotone in the host's favour: nothing but a config beat the host
     * itself writes can clear either. So a value read here is still true when the write lands, and
     * poll-then-write needs no retry and no lock -- which is why they are in one register and why
     * this struct is a snapshot rather than a handle.
     */
    struct HTTPLane {
        /// Chunk entries queued and not yet retired by a tlast, i.e. responses this lane still owes.
        /// Saturates at 255; policy().queue_depth carries the untruncated per-lane limit.
        uint8_t occ         = 0;
        bool    arm_ready   = false; // will accept an ARM beat (req_total_bytes != 0)
        bool    entry_ready = false; // will accept a chunk ENTRY beat (req_total_bytes == 0)
        bool    conn_up     = false; // holds an established TCP session
        /// Out of the game until the host reissues. CHECK THIS FIRST: arm_ready stays low forever on
        /// a lane that was armed and then went fatal, so a poll that does not look at it waits out
        /// the full timeout and then reports the wrong thing.
        bool    fatal       = false;

        bool ready_for(LaneAdmit admit) const {
            return admit == LaneAdmit::Arm ? arm_ready : entry_ready;
        }
        std::string describe() const;
    };

    /// Every lane's admission window, read in TWO CSR reads whatever the lane count. `count` is the
    /// lanes the bitstream actually has; slots beyond it read 0 and are not reported.
    struct HTTPLanes {
        uint8_t                                   count = 0;
        std::array<HTTPLane, HTTP_LANE_SLOTS>     lane {};

        /// True on a bitstream below HTTP_CSR_REVISION_LANES, where the registers were not read.
        bool empty() const { return count == 0; }
        /// Throws rather than clamping: a lane index out of range is a dispatch bug, and clamping
        /// would admit a batch against a different lane's credit.
        const HTTPLane &at(uint8_t l) const;
        std::string describe() const;
    };
    HTTPLanes lanes();

    /**
     * One lane's STICKY failure causes, from read id 19. Sticky since reset -- a reconnect does not
     * clear them, which is the point: the conditions that matter are transient in the hardware and
     * long gone by the time anyone polls.
     *
     * FATAL IS NOT HERE, it is in the admission word, and the pair is what carries the meaning:
     *   - fatal && lane_dead: rx_dispatch's head-of-line watchdog killed the lane and discarded its
     *     packets, so bytes went missing out of the MIDDLE of a response. The whole batch must be
     *     reissued; nothing about the partial data is usable.
     *   - fatal && !lane_dead: a read error that cannot be replayed, and the bits below say which.
     */
    struct HTTPLaneError {
        bool lane_dead     = false; // [8L+0] HOL-killed by rx_dispatch; bytes lost mid-response
        bool dirty         = false; // [8L+1] aborted after body bytes had reached the decoder
        bool init_err      = false; // [8L+2] a connect attempt for this lane failed
        bool resp_err      = false; // [8L+3] a response could not be framed (no Content-Length)
        bool status_bad    = false; // [8L+4] a response retired with neither 200 nor 206
        bool tx_refused    = false; // [8L+5] the TOE refused a transmit reservation (informational)
        bool read_timeout  = false; // [8L+6] the read watchdog expired -- nothing arrived at all
        bool rx_fifo_stall = false; // [8L+7] this lane's decoupling fifo back-pressured the stack
        /// The byte exactly as read, for comparing a condition already reported against a new one.
        uint8_t raw        = 0;

        bool any() const { return raw != 0; }
        std::string describe() const;
    };

    struct HTTPLaneErrors {
        uint8_t                                       count = 0;
        std::array<HTTPLaneError, HTTP_LANE_SLOTS>    lane {};

        bool empty() const { return count == 0; }
        const HTTPLaneError &at(uint8_t l) const;
        std::string describe() const;
    };
    HTTPLaneErrors lane_errors();

    /// Throw naming `lane`, what it was waiting for, and the decoded sticky causes -- including
    /// whether this was a head-of-line kill (reissue the whole batch) or an unreplayable read error.
    ///
    /// PUBLIC because the admission path is no longer the only caller. A lane can go fatal with work
    /// ALREADY on it, and those flows are never admitted again -- the scheduler routes around a fatal
    /// lane by design -- so the dispatcher needs this same diagnosis to fail the queries that are
    /// waiting on them. See Scheduler::fail_flows_on_fatal_lanes.
    ///
    /// Reads CSRs, so call it with no scheduler lock held.
    [[noreturn]] void throw_lane_fatal(uint8_t lane, const char *what);

    /**
     * Read id 20: what the bitstream was ELABORATED with, for the host to check itself against.
     *
     * Every field here is something a mismatched host gets silently wrong -- too many lanes
     * addressed, a batch larger than a lane's queue can hold, or a software watchdog shorter than
     * the hardware's, which reports a lane dead that the hardware is still waiting on. WP8's
     * pre-flight is the intended reader.
     */
    struct HTTPLanePolicy {
        uint8_t  revision          = 0; // [7:0], the same value as inflightWord[31:24]
        uint8_t  num_conns         = 0; // [15:8], UNTRUNCATED, unlike inflightWord[23:20]
        uint16_t queue_depth       = 0; // [31:16], chunk entries PER LANE, saturating at 65535
        uint32_t lane_stall_cycles = 0; // [55:32], the HOL watchdog threshold, saturating at 2^24-1
        uint8_t  lane_stall_log2   = 0; // [61:56], exact even where the field above saturates

        /// False on a bitstream below HTTP_CSR_REVISION_LANES, where the register was not read.
        bool valid() const { return revision >= HTTP_CSR_REVISION_LANES; }
        std::string describe() const;
    };
    HTTPLanePolicy policy();

    /// Chunk entries the host will let ONE LANE owe at a time: `OASIS_HTTP_LANE_DEPTH` (default 4),
    /// clamped to [1, max_batch_chunks()], read once and cached. 1 on a bitstream below
    /// HTTP_CSR_REVISION_LANES, which has no per-lane occupancy to meter against.
    ///
    /// This is the HOST'S pipelining cap, not a hardware limit: the lane's queue is
    /// policy().queue_depth deep. It exists because depth beyond a handful buys nothing on an
    /// HTTP/1.1 connection (see the measurements at HTTP_RX_WINDOW_BYTES) while costing response
    /// bytes in flight per lane.
    size_t lane_depth_limit();

    /// Pure decoders for the per-lane registers, exposed so a caller that already has the words --
    /// a pre-flight dump, a test -- can decode without a board. `count` is lane_count().
    static HTTPLanes       DecodeLanes(uint64_t occ_word, uint64_t ready_word, uint8_t count);
    static HTTPLaneErrors  DecodeLaneErrors(uint64_t err_word, uint8_t count);
    static HTTPLanePolicy  DecodePolicy(uint64_t policy_word);

    /**
     * Read CSR 11: which pipeline stage stopped making progress (`stallWord` in handler.sv).
     *
     * A full request ring says the pipeline stopped draining but not where. This says where, which
     * matters because the stages fail for very different reasons. In particular a stalled CONNECT
     * with no `init_error` is the signature of ephemeral-port reuse: the TOE's pool is
     * TCP_STACK_MAX_SESSIONS (512) ports at 32768..33279 and it releases them with no quiet time,
     * while the peer -- which closes first, because the request says `Connection: close` -- holds
     * the old 4-tuple in TIME_WAIT for 60s. On reuse the TOE presents a random ISN, Linux usually
     * refuses to recycle, and the resulting challenge ACK resets the SYN retry counter in
     * rx_engine, so the SYN is retried forever and openStatus is never emitted at all.
     *
     * WHAT DRIVES EACH BIT ON handler_multi, because the field names here predate it and several
     * now carry an OR over lanes rather than the one lane's condition they were named for (read the
     * per-lane registers -- lanes() and lane_errors() -- to find out WHICH lane):
     *
     *   [0]     conn_stall_q      -> connect_stalled
     *   [1]     tied to 0         -> send_stalled    (never set on a multi-lane bitstream)
     *   [2]     tied to 0         -> read_stalled    (never set on a multi-lane bitstream)
     *   [3]     |lane_init_err_q  -> init_error
     *   [4]     |stream_refused   -> send_error
     *   [5]     |lane_resp_err_q  -> resp_unframeable
     *   [6]     |lane_fatal_q     -> dirty_abort     (ANY fatal lane now, not only a dirty abort)
     *   [7]     |lane_status_bad_q-> status_bad
     *   [15:8]  reconn_cnt_q      -> reconnects
     *   [23:16] tied to 0         -> read_slot       (never set on a multi-lane bitstream)
     *   [24]    rxd_overflow      -> notify_overflow
     *   [25]    |lane_fifo_stall  -> rx_fifo_stall
     *   [26]    |lane_timeout     -> read_timeout
     *   [27]    |rwl_starved      -> align_starved
     *   [28]    rxd_route_stall   -> route_stall
     */
    struct HTTPStall {
        bool connect_stalled = false;
        bool send_stalled    = false;
        bool read_stalled    = false;
        bool init_error      = false;
        /// The TOE refused a send: it would not reserve room in its tx buffer for the length the
        /// handler announced. Sticky, and NOT a lost request -- the handler skips the data beats and
        /// re-sends, because nothing went out and there is nothing to unwind. Seeing this means the
        /// tx buffer is being filled faster than it drains, which only happens once requests are
        /// queued back to back; a climbing count says the request ring is deeper than the tx path
        /// can absorb.
        bool send_error      = false;
        /// A response arrived with no Content-Length, so it could not be framed. On a persistent
        /// connection that is fatal: without the length there is no way to find where the body ends
        /// and the next response begins. Covers `Transfer-Encoding: chunked` without parsing it.
        bool resp_unframeable = false;
        /// The connection died after body bytes had already reached the decoder. Replaying would
        /// duplicate them, so the handler stops instead of recovering.
        bool dirty_abort = false;
        /// A response carried a status other than 200/206 -- the "column data" is an error document.
        bool status_bad = false;
        /// Connections re-established since the bitstream was programmed. A few over a long session
        /// is the server's idle timeout doing its job; a climbing count is a problem.
        uint8_t reconnects = 0;
        uint8_t read_slot  = 0;
        /// The announcement queue overflowed and segments were dropped. Sticky, and should never
        /// fire -- see NOTIFY_DEPTH in hardware/src/hdl/http_read/tcp_session_table.sv.
        bool notify_overflow = false;
        /// The fifo that decouples the TCP stack from the HTTP parser filled up, so back-pressure
        /// reached the TOE anyway. Sticky. Not a correctness problem, but it means RX_FIFO_DEPTH in
        /// tcp_read.sv is too small for this traffic and the whole point of the decoupling -- never
        /// letting the parser stall the TOE's shared receive fifo -- has been lost. Carries no
        /// information about the size of either fifo; the TOE's is 1 << WINDOW_BITS and varies per
        /// bitstream.
        bool rx_fifo_stall = false;
        /// A read gave up waiting instead of failing outright: nothing arrived for ~2 s while a
        /// request was outstanding. Sticky. Distinguishes "the response never came" from "the server
        /// said no", which the other bits cannot -- and it is the condition that used to hang the
        /// board until it was reprogrammed.
        bool read_timeout = false;
        /// Body bytes arrived with no column-chunk length configured. Sticky. Means the host queued
        /// fewer chunk lengths than responses, so two columns merge into one decoder stream -- a
        /// silent corruption, not a failure. Any result from such a run is suspect. Driven by
        /// |rwl_starved on handler_multi.
        bool align_starved = false;
        /// rx_dispatch offered a beat to a lane that then refused it, so the lane's fifo filled
        /// despite the conn_space_ok check that exists to stop exactly that. Sticky. The shared
        /// receive path is being stalled by one lane again, which is the whole thing rx_dispatch was
        /// added to prevent -- so either the space check is wrong or that lane's fifo is undersized.
        /// It is the multi-lane sibling of rx_fifo_stall: that one says a lane's fifo back-pressured
        /// the stack, this one says the ROUTER was blocked behind it, which is what starves the
        /// other lanes.
        bool route_stall = false;
        /// The stallWord exactly as read, so a caller can tell a condition it has already reported
        /// from a new one. The named bools above are for reading; this is for comparing.
        uint32_t raw = 0;

        bool any() const {
            return connect_stalled || send_stalled || read_stalled || init_error || send_error
                   || resp_unframeable || dirty_abort || status_bad || notify_overflow
                   || rx_fifo_stall || read_timeout || align_starved || route_stall;
        }
        std::string describe() const;
    };
    HTTPStall stall();

    /**
     * Read CSRs 12/13: how the last HTTP response was framed (`respWord` in handler.sv).
     *
     * On a persistent connection the body is delimited by Content-Length rather than by the FIN, so
     * the hardware now knows the status code and whether it could frame the response at all. Before
     * this, a 404 whose XML body happened to be the right length was indistinguishable from real
     * column data.
     */
    struct HTTPResponse {
        char     status[4] = {0, 0, 0, 0}; // e.g. "206"
        bool     status_ok = false;        // 200 or 206
        bool     unframeable = false;      // no Content-Length
        bool     dirty = false;            // body bytes already emitted for the current response
        uint32_t body_remaining = 0;       // bytes of the current body still to stream
        /// Content-Length the server sent for the last response, latched in hardware. Compare
        /// against `requested`: they differ when the server answered a different question than the
        /// one asked -- a 200 instead of a 206, a range clamped at EOF, an error document. This is
        /// the check `body_remaining` cannot do, because it counts down to zero.
        uint32_t content_length = 0;
        /// Bytes the host asked for in the most recent ranged GET (host-side, not from hardware).
        /// ZERO when more than one request can be outstanding: `content_length` is latched by the
        /// hardware from whichever response is being framed, while this is simply the last range the
        /// host issued, and once those are different requests comparing them is meaningless. It
        /// would not be a harmless inaccuracy either -- pipelined GETs of a split column chunk have
        /// genuinely different lengths, so the check would fire on every healthy run and train the
        /// reader to ignore it.
        uint32_t requested = 0;

        /// False whenever `requested` is 0, which includes the pipelined case above.
        bool length_mismatch() const {
            return requested != 0 && content_length != 0 && content_length != requested;
        }
        std::string describe() const;
    };
    HTTPResponse response();

    /// Requests the hardware can hold at once (0 on a pre-pipelining bitstream). Cached after the
    /// first read; the value is fixed by the bitstream.
    uint8_t num_slots();

    /**
     * Requests the host may actually keep in flight: `min(num_slots(), the depth cap)`.
     *
     * `num_slots()` is what the bitstream advertises; this is what is safe to use, and anything
     * sizing a queue against the hardware wants this one. Overridable with `OASIS_HTTP_MAX_INFLIGHT`.
     *
     * It is safe to pipeline now only because the handler holds ONE persistent connection: the TOE
     * (`TCP_STACK_RX_DDR_BYPASS_EN=1`) has a single shared receive FIFO and hands its head to
     * whichever session asks next, so concurrent SESSIONS read each other's bytes -- but with one
     * session, arrival order and request order are the same thing. See HTTP_DEFAULT_MAX_INFLIGHT.
     */
    uint8_t max_inflight();

    /// Largest byte range the host will ask for in one GET; 0 means "never split". See
    /// HTTP_DEFAULT_CHUNK_BYTES.
    static uint64_t chunk_bytes();

    /// Read CSRs 3..8: the request parameters currently latched in hardware.
    HTTPRequestEcho request_echo();

    /// Renders a packed status word from debug_status() into per-sub-FSM fields.
    static std::string describe_status(uint32_t status);

    uint64_t read_stream_register(libstf::stream_t stream, uint32_t reg);

    static constexpr uint64_t ID = HTTP_READ_CONFIG_ID;

  private:
    /// Lanes reported by the bitstream, cached on first read. 0 means "not read yet"; lane_count()
    /// normalises a single-session bitstream's 0 to 1.
    uint8_t lane_count_cached_ {0};

    /// CSR revision, cached. -1 until the first read; the value is fixed by the bitstream.
    int revision_ {-1};

    /// lane_depth_limit(), cached. 0 means "not computed yet"; the limit itself is never 0.
    size_t lane_depth_ {0};

    /// await_cfg_ready() on a bitstream with no per-lane registers: EXACTLY the behaviour that
    /// shipped before them -- the same register, the same spin, the same timeout and the same
    /// message. A `--decoders 1` legacy bitstream must not notice that this work package happened.
    void await_cfg_ready_legacy(const char *what);

    /// Bytes asked for in the most recent ranged GET, so response() can compare what the server
    /// said against what was requested.
    std::atomic<uint32_t> last_request_bytes_ {0};

    /// The stallWord already reported on the debug path. The stall bits are sticky, so without this
    /// every remaining request in the query would reprint the same condition and bury the first.
    uint32_t stall_reported_ {0};

    /// Block until the request ring has room for one more GET, or throw naming the stalled stage.
    void await_credit();

    /// Write the CSR map for ONE ranged GET and pulse START. `body_last` is false when this GET is
    /// part of a larger column chunk and the decoder stream continues past it.
    void issue_range(uint32_t server_ip, uint16_t server_port, const std::string &path,
                     uint64_t range_begin, uint64_t range_end, bool body_last);

    /// -1 until the first inflight() read; then the bitstream's slot count.
    int num_slots_ = -1;
};

} // namespace oasis
