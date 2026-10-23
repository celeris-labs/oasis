#pragma once

#include "libstf/common.hpp"
#include <array>
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

// Matches hardware HttpConfig (params 0..38, START at 39, REQ_TOTAL_BYTES/REQ_CHUNK_BYTES at 40/41).
// ID string "HTT". Kept in sync with hardware/src/hdl/http_read/http_config.sv (NUM_PARAM_REGS=42,
// START_ADDR=39).
constexpr const uint64_t HTTP_READ_CONFIG_ID = 0x0000000000485454;

/// CSR revision at which the per-lane readback registers (read ids 16..20) exist, reported in
/// inflightWord[31:24] (handler_multi). It reads 0 on every bitstream built before them, and the read
/// register file answers an out-of-range address with resp_error, not with zeros -- so the host
/// refuses anything below this revision at startup (HTTPRevision::Classify) instead of reading them.
constexpr const uint8_t HTTP_CSR_REVISION_MULTI = 2;

/// Lanes the per-lane CSRs address, at a FIXED stride, whatever NUM_CONNS the bitstream was built
/// with. Lanes the bitstream does not have read 0. The stride is fixed on purpose: one that moved
/// with the lane count would silently reinterpret every field the moment a 2-lane bitstream was
/// swapped for a 4-lane one. See the read map in hardware/src/hdl/http_read/http_config.sv.
constexpr const uint8_t HTTP_LANE_SLOTS = 8;

/// CSR revision of the TOE-RING handler (handler_toe): the TOE is built with
/// TCP_STACK_RX_DDR_BYPASS_EN = 0 and keeps a 1 MiB receive ring per session in card memory itself,
/// so the host maps and offloads no card-memory buffer of its own. The REGISTER MAP IS REVISION 2's
/// -- HttpConfig's read ids end at 20 and its write map is the same -- which is why the host drives
/// it as PROTOCOL revision 2 (HTTPRevision::Classify). What differs from revision 2:
///   * ONE GET PER ARM. The handler counts GETs by arms (gets_out +1 per arm, -1 per framed
///     response); an arm announcing two GETs would be counted once and retired twice.
///   * THE GET CREDIT. ARM_READY = !stream_busy && gets_out < GET_CREDIT (LANE_POLICY[55:32]).
///   * THE WINDOW RULE. The TOE never re-opens a window that closed, so per lane the requested but
///     unread response bytes must stay <= 2^RING_LOG2 (LANE_POLICY[61:56]) - 64 KiB. The host keeps it
///     by capping every GET at toe_get_cap() -- ((2^RING_LOG2 - 64 KiB) / GET_CREDIT) - 4 KiB of body,
///     236 KiB at a 1 MiB ring and credit 4 -- and splitting every larger column chunk, whatever
///     OASIS_HTTP_CHUNK_BYTES says. toe_rx flags a lane past the budget (STALL[24], budget_err).
/// Revisions 3..5 (the HBM-slot handler, no longer built) and anything above 6 are refused
/// (HTTPReadConfig::CheckRevision) instead of guessing their register map.
constexpr const uint8_t HTTP_CSR_REVISION_TOE = 6;

/// Revision 6: what the window budget keeps free of the ring (2^RING_LOG2) per lane -- the hardware's
/// budget_err threshold is 2^RING_LOG2 minus this -- and what each GET is charged on top of its body
/// for the response header (MinIO sends ~630 bytes).
constexpr const uint64_t HTTP_TOE_RING_SLACK   = 64ULL * 1024ULL;
constexpr const uint64_t HTTP_TOE_GET_OVERHEAD = 4ULL * 1024ULL;

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

/// Pads request text to a whole 64-byte DMA beat with a header the server ignores, so the transfer
/// has no tail to round up and nothing can be left in the stream for the next batch to pick up.
void PadRequestTextToBeat(std::string &text);

/**
 * Drives the hardware HttpConfig and HTTP handler: column-chunk entries and transfer arms through the
 * CSRs, request text by host DMA (HTTPBatchSourceOperator), and every readback register decoded.
 */
class HTTPReadConfig : public libstf::Config {
  public:
    HTTPReadConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset, uint32_t num_regs);

    /// A query's worth of requests, built as text on the host. The FPGA stores nothing per request
    /// -- the text IS the request -- and its queue holds one entry per column chunk.
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
        /// One entry per GET: its length in bytes within `text`, in order, so that the requests can
        /// be told apart again. A revision-2 bitstream never needs this -- the whole text is one arm
        /// -- but a revision-6 one takes ONE ARM PER GET (the GET credit counts arms), so each
        /// request has to be armed, padded and DMA'd on its own.
        std::vector<uint32_t> request_bytes;
    };

    /// Append one column chunk's GETs to `batch`, splitting at split_bytes().
    void read_streamed(uint32_t server_ip, uint16_t server_port, const std::string &path,
                       uint64_t range_begin, uint64_t range_end, RequestBatch &batch);

    /// read_streamed()'s body, pure: append the GETs of the column chunk [range_begin, range_end]
    /// (inclusive) to `batch`, each asking for at most `split` bytes (0 = one GET), and ONE
    /// chunk_bytes entry for the whole chunk -- the hardware marks the decoder's tlast by counting
    /// those bytes down, so the chunk ends exactly once however many GETs it was split into.
    static void AppendChunkGets(const std::string &host, uint16_t server_port,
                                const std::string &path, uint64_t range_begin, uint64_t range_end,
                                uint64_t split, RequestBatch &batch);

    /// The GETs of `batch` as separate strings, in order, cut at request_bytes. Throws if the lengths
    /// do not add up to the text. Pure; exposed so the split can be checked without a board.
    static std::vector<std::string> SplitRequests(const RequestBatch &batch);

    /// Largest byte range one GET may ask for on `split_cfg` (OASIS_HTTP_CHUNK_BYTES, 0 = never split) and a
    /// per-GET hardware cap `max_get` (0 = none): the smaller of the two non-zero values. Pure.
    static uint64_t EffectiveSplit(uint64_t split_cfg, uint64_t max_get);

    /// Byte range split this bitstream needs: EffectiveSplit(OASIS_HTTP_CHUNK_BYTES, toe_get_cap()).
    uint64_t split_bytes();

    /// COLUMN CHUNKS a single batch may carry, from the hardware queue depth. Larger batches must
    /// be split: the host pushes every entry before arming, so one that does not fit cannot drain.
    /// Note this bounds chunks, not requests -- the request text is one DMA of any size.
    size_t max_batch_chunks();

    /// Which admission bit await_cfg_ready() is waiting on. Both live in the SAME nibble of read
    /// register 17 and they are not interchangeable: an ARM waits for the lane's previous request
    /// text to have gone out, an ENTRY waits for its chunk queue to have room. Waiting on the wrong
    /// one deadlocks -- the arm that would drain the queue is the beat being withheld.
    enum class LaneAdmit : uint8_t { Arm, Entry };

    /// Push the batch's chunk-length entries, then arm the transfer, ALL ON `lane`. The caller DMAs
    /// `batch.text` into that lane's request stream afterwards -- this only tells the hardware what
    /// is coming.
    ///
    /// `lane` is what the hardware routes by (req_chunk_dest, bits [35:32] of the chunk-length
    /// register); get it from lane_for_stream(). It used to be derived from the decode stream inside
    /// here while operator.cpp derived the DMA sink from the same stream a different way, so the two
    /// could disagree; and the arm carried no lane of its own at all, inheriting whatever the last
    /// entry left in the register. Both are now one explicit parameter.
    ///
    /// On a revision-6 bitstream this is legal only for a batch of ONE request: the GET credit counts
    /// arms, so every GET needs its own arm. It throws rather than corrupt; the operator drives
    /// revision 6 through push_entries() + arm_transfer() per request instead.
    void submit_batch(uint32_t server_ip, uint16_t server_port, const RequestBatch &batch,
                      uint8_t lane);

    /// The first half of submit_batch(): reserve credit for, and push, the batch's chunk-length
    /// entries on `lane`. Nothing is armed.
    void push_entries(const RequestBatch &batch, uint8_t lane);

    /// The second half: arm ONE transfer of `text_bytes` bytes of request text on `lane` (write the
    /// arm registers, wait for ARM_READY, pulse START). The caller DMAs the text afterwards.
    ///
    /// On a revision-6 bitstream ARM_READY includes the lane's GET credit, so this blocks while the
    /// lane already has GET_CREDIT GETs unfinished.
    void arm_transfer(uint32_t server_ip, uint16_t server_port, uint32_t text_bytes, uint8_t lane);

    /// Revision 6: block until the arm just written has been TAKEN, i.e. ARM_READY of `lane` has
    /// fallen. START does not back-pressure and the handler samples the LIVE registers, so writing
    /// the next beat's registers before the arm is taken would change what it arms. The arm makes the
    /// lane's request stream busy, and the caller sends that text only after this returns.
    void await_arm_taken(uint8_t lane);

    // ---- CSR revision 6 (TOE receive rings, handler_toe) ----------------------------------------

    /// True on a revision-6 bitstream (see HTTP_CSR_REVISION_TOE). Every GET then needs an arm of
    /// its own: the operator arms, pads and DMAs each GET separately.
    bool toe_ring() { return revision() == HTTP_CSR_REVISION_TOE; }

    /// Revision 6: the largest GET body that keeps a lane inside the window rule, from LANE_POLICY
    /// (GET_CREDIT, RING_LOG2). Throws if the policy word is unusable. 0 on every other revision.
    uint64_t toe_get_cap();
    /// Pure form: ((2^ring_log2 - HTTP_TOE_RING_SLACK) / get_credit) - HTTP_TOE_GET_OVERHEAD, i.e.
    /// GET_CREDIT GETs of that body plus a 4 KiB header each fill the ring up to its budget exactly.
    /// 0 when the inputs cannot describe a usable ring (credit 0, ring_log2 outside 17..30, or no
    /// room left for a body).
    static uint64_t ToeGetCap(uint8_t ring_log2, uint32_t get_credit);

    /// Pure form of await_lane_credit()'s admission rule, so it can be checked without a board: the
    /// lane owes `occ` responses and may owe at most `limit` once `needed` more are admitted.
    static bool LaneCreditOk(size_t occ, size_t needed, size_t limit);

    /// Pure form of lane_depth_limit(): `want` (OASIS_HTTP_LANE_DEPTH) clamped to [1, hw].
    /// `get_credit` (revision 6): when non-zero the depth is also clamped to it, since every column
    /// chunk is at least one GET and the hardware holds at most GET_CREDIT per lane.
    static size_t LaneDepthFor(size_t want, size_t hw, size_t get_credit = 0);

    /// Block until `lane` will accept a beat of this kind, or throw naming the lane and why it will
    /// not. See the definition for why skipping this loses whole batches without raising anything.
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
    void await_lane_credit(uint8_t lane, size_t needed);

    /// The three HTTP status digits from the last response strip_http parsed, as text ("206",
    /// "416", ...), or "unparsed". Reads CSR 12. Meaningful mainly when stall().status_bad is set.
    std::string last_http_status();

    /// One ranged GET (keep-alive) as request text.
    static std::string BuildGet(const std::string &host, uint16_t port, const std::string &path,
                                uint64_t range_begin, uint64_t range_end);

    /**
     * Read CSR 10: the request-queue occupancy (`inflightWord` in handler_multi.sv / handler_toe.sv).
     *
     * The fields fold every lane into one word (occupancy is the MAX over lanes); the per-lane
     * registers (lanes(), lane_errors()) say which lane.
     */
    struct HTTPInflight {
        uint8_t occupied      = 0; // chunk entries queued, max over lanes, saturating at 255
        uint8_t slots         = 0; // the per-lane queue depth, saturating at 255
        bool    has_pending   = false; // an announced segment is waiting to be read
        bool    peer_closed   = false; // the peer has FINed
        bool    conn_up       = false; // the persistent connection is established
        /// CSR revision, from inflightWord[31:24]. See CheckRevision().
        uint8_t revision      = 0;

        std::string describe() const;
    };
    HTTPInflight inflight();

    /// TCP sessions (lanes) the bitstream provides, cached after the first read. Every request beat
    /// names a lane and each lane's request text goes to its OWN host-recv stream.
    ///
    /// Read from hardware rather than compiled in: the CSR map and the bitstream must agree, and a
    /// host that assumes a lane count the board does not have sends text to a tied-off stream,
    /// which discards it while reporting success. See the note on req_dest in operator.cpp.
    uint8_t lane_count();

    /// The CSR revision of the programmed bitstream (inflightWord[31:24]), read once. Throws on a
    /// revision this library does not drive (CheckRevision), so callers see 2 or 6.
    uint8_t revision();
    /// Throws unless `revision` is HTTP_CSR_REVISION_MULTI or HTTP_CSR_REVISION_TOE.
    static void CheckRevision(uint8_t revision);

    /// The value written into req_chunk_dest -- bits [35:32] of the chunk-length register -- for a
    /// chunk that decodes on `stream`.
    ///
    /// TWO BITSTREAMS READ THAT FIELD DIFFERENTLY, and it is the same four bits:
    ///   - handler_multi (lane_count() > 1): it is the LANE. The lane owns a TCP session, a framer,
    ///     a chunk queue and the decoder its body bytes come out on, so the lane index IS the
    ///     decoder index. `stream % lanes`, matching what operator.cpp already does when it picks
    ///     the axis_host_recv sink for the request text -- the two MUST agree or a lane's entries
    ///     and its request text land on different lanes.
    ///   - a one-lane bitstream (lane_count() == 1): there is one connection and the field is
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
        /// [8L+7] this lane's decoupling fifo back-pressured the stack (revision 2), or refused a
        /// beat toe_rx had routed to it (revision 6).
        bool rx_fifo_stall = false;
        /// The byte exactly as read, for comparing a condition already reported against a new one.
        uint8_t raw        = 0;

        bool any() const { return raw != 0; }
        std::string describe() const;
    };

    struct HTTPLaneErrors {
        uint8_t                                       count = 0;
        std::array<HTTPLaneError, HTTP_LANE_SLOTS>    lane {};

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
        // REVISION 6 REDEFINES [55:32] and [61:56] (there is no head-of-line watchdog in
        // handler_toe). DecodePolicy() fills exactly one of the two pairs, by revision.
        uint32_t get_credit        = 0; // [55:32] on revision 6: GETs (arms) per lane unfinished
        uint8_t  ring_log2         = 0; // [61:56] on revision 6: the TOE's ring per session, log2 B

        /// Revision 6 (the raw value lives in [7:0], so this needs no other register).
        bool toe() const { return revision == HTTP_CSR_REVISION_TOE; }
        std::string describe() const;
    };
    HTTPLanePolicy policy();

    /// Chunk entries the host will let ONE LANE owe at a time: `OASIS_HTTP_LANE_DEPTH` (default 4),
    /// clamped to [1, max_batch_chunks()] (and to the GET credit on revision 6), read once and cached.
    ///
    /// This is the HOST'S pipelining cap, not a hardware limit: the lane's queue is
    /// policy().queue_depth deep. It exists because depth beyond a handful buys nothing on an
    /// HTTP/1.1 connection (see HTTP_DEFAULT_LANE_DEPTH) while costing response bytes in flight per
    /// lane.
    size_t lane_depth_limit();

    /// Pure decoders for the per-lane registers, exposed so a caller that already has the words --
    /// a pre-flight dump, a test -- can decode without a board. `count` is lane_count().
    static HTTPLanes       DecodeLanes(uint64_t occ_word, uint64_t ready_word, uint8_t count);
    static HTTPLaneErrors  DecodeLaneErrors(uint64_t err_word, uint8_t count);
    static HTTPLanePolicy  DecodePolicy(uint64_t policy_word);

    /**
     * Read CSR 11: which pipeline stage stopped making progress (`stallWord` in handler_multi.sv /
     * handler_toe.sv).
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
     *   [3]     |lane_init_err_q  -> init_error
     *   [4]     |stream_refused   -> send_error
     *   [5]     |lane_resp_err_q  -> resp_unframeable
     *   [6]     |lane_fatal_q     -> dirty_abort     (ANY fatal lane now, not only a dirty abort)
     *   [7]     |lane_status_bad_q-> status_bad
     *   [15:8]  reconn_cnt_q      -> reconnects
     *   [24]    rxd_overflow      -> notify_overflow
     *   [25]    |lane_fifo_stall  -> rx_fifo_stall
     *   [26]    |lane_timeout     -> read_timeout
     *   [27]    |rwl_starved      -> align_starved
     *   [28]    rxd_route_stall   -> route_stall
     */
    struct HTTPStall {
        bool connect_stalled = false;
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
        /// The announcement queue overflowed and segments were dropped. Sticky, and should never
        /// fire -- see NOTIFY_DEPTH in hardware/src/hdl/http_read/rx_dispatch.sv.
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
        /// REVISION 6 (handler_toe) REDEFINES [24]: toe_rx's sticky order_err | len_err | budget_err,
        /// ORed in hardware (software cannot tell the three apart). order_err: an rx_meta/data beat
        /// with no readPkg outstanding, or naming another session; len_err: a packet's tlast not on
        /// the beat its readPkg length implies; budget_err: a lane's notified-but-unread ring bytes
        /// passed 2^RING_LOG2 - 64 KiB (the window rule broken: a GET above toe_get_cap(), more than
        /// GET_CREDIT outstanding, or an origin ignoring Range). Exactly one of notify_overflow /
        /// toe_rx_err is decoded from bit 24, by the revision stall() reads it on.
        bool toe_rx_err = false;
        /// Set by stall() on a revision-6 bitstream; selects the revision-6 meaning of bits 24/28 in
        /// describe(). Not a condition.
        bool toe = false;
        /// The stallWord exactly as read, so a caller can tell a condition it has already reported
        /// from a new one. The named bools above are for reading; this is for comparing.
        uint32_t raw = 0;

        bool any() const {
            return connect_stalled || init_error || send_error
                   || resp_unframeable || dirty_abort || status_bad || notify_overflow
                   || rx_fifo_stall || read_timeout || align_starved || route_stall || toe_rx_err;
        }
        std::string describe() const;
    };
    HTTPStall stall();
    /// Pure decoder of the stallWord. `toe_ring` selects the revision-6 meaning of bit 24.
    static HTTPStall DecodeStall(uint32_t word, bool toe_ring);

    /**
     * Read CSRs 12/13: how the last HTTP response was framed (`respWord` in handler_multi.sv /
     * handler_toe.sv).
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
        /// Content-Length the server sent for the last response, latched in hardware.
        uint32_t content_length = 0;
        std::string describe() const;
    };
    HTTPResponse response();

    /**
     * Requests the host may keep in flight per stream: the queue depth the bitstream reports
     * (inflightWord[15:8]), or OASIS_HTTP_MAX_INFLIGHT if that is smaller. See
     * HTTP_DEFAULT_MAX_INFLIGHT.
     */
    uint8_t max_inflight();

    /// Every readback register this bitstream has, raw and decoded, as one multi-line string: the
    /// status/stall/response words (1..15) and the per-lane words (16..20, revision >= 2; on revision
    /// 6 with the GET credit, ring size and GET cap). Reads only; safe from any thread. This is the
    /// in-process state capture.
    std::string debug_dump();

    /// Renders the packed status word (read id 2) into per-sub-FSM fields.
    static std::string describe_status(uint32_t status);

    static constexpr uint64_t ID = HTTP_READ_CONFIG_ID;

  private:
    // Fixed by the bitstream (or the environment), so each is read once. 0 means "not read yet".
    uint8_t  revision_ {0};
    uint8_t  lane_count_ {0};
    size_t   max_batch_chunks_ {0};
    size_t   lane_depth_ {0};
    uint64_t toe_cap_ {0};
};

} // namespace oasis
