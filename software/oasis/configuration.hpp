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

/// CSR revision at which the bitstream is the HBM-SLOT handler (handler_slots, ADR-5): every
/// connection owns a slot in card memory, the host must hand the hardware that memory
/// (SLOT_BASE_LO/HI, write ids 42/43) before the first arm, and each connection holds ONE
/// outstanding GET at a time (read ids 21..32 exist). Reported in inflightWord[31:24] like revision 2.
///
/// Everything revision 3 needs is gated on this at RUN TIME, never at build time: the same library
/// must drive a revision-2 bitstream (build-119, build-125) exactly as it did before. Revision 3 keeps
/// read ids 16..20 in their revision-2 shape (connections 0..7), so everything gated on
/// HTTP_CSR_REVISION_LANES keeps working on it unchanged; what changes is what the host may ASK for.
constexpr const uint8_t HTTP_CSR_REVISION_SLOTS = 3;

/// CSR revision at which the slot handler takes PIPELINED GETs (2026-09-23): same register map as
/// revision 3, but ARM_READY no longer carries a depth-1 credit, several GETs may be armed on one
/// connection, and their responses land back to back in its slot. The host's rule moves from
/// "one GET per connection" to a BYTE BUDGET per connection: the responses armed since CONN_DRAINED
/// was last read set must fit in the slot (slot_budget_bytes()). CONN_DRAINED now means "slot empty
/// and nothing armed on it". Revision 3 is driven exactly as before.
constexpr const uint8_t HTTP_CSR_REVISION_PIPE = 4;

/// CSR revision at which the slot handler has MORE CONNECTIONS THAN DECODERS (stage 2, 2026-09-23).
/// The host places every GET on a connection of its choice: the ARM names it (REQ_CHUNK_BYTES
/// [44:40]) beside the decoder ([35:32]). A "lane" is then a DECODER (lane_count() = N_DECODERS, and
/// the per-lane admission/fatal bits come from DEC_STATE, read id 33), and a connection is admitted
/// for decoder d only while it is FREE (CONN_DRAINED, nothing pending) or d's TAIL (the last
/// connection d took an arm for) -- see pick_conn(). Revisions 2..4 are driven exactly as before.
constexpr const uint8_t HTTP_CSR_REVISION_CONNS = 5;

/// CSR revision of the TOE-RING handler (handler_toe, stage 1 of the TOE-buffer redesign,
/// 2026-10-11): the TOE is built with TCP_STACK_RX_DDR_BYPASS_EN = 0 and keeps a 1 MiB receive ring
/// per session in card memory itself, so there is no slot, no slot page and no card-memory buffer of
/// ours (EN_MEM = 0). The REGISTER MAP IS REVISION 2's -- HttpConfig is instantiated with its default
/// CSR_REV = 2, so read ids 21..38 are a resp_error and write ids 42/43 do not exist -- which is why
/// the host drives it as PROTOCOL revision 2 (HTTPRevision::Classify). What differs from revision 2:
///   * ONE GET PER ARM. The handler counts GETs by arms (gets_out +1 per arm, -1 per framed
///     response); an arm announcing two GETs would be counted once and retired twice.
///   * THE GET CREDIT. ARM_READY = !stream_busy && gets_out < GET_CREDIT (LANE_POLICY[55:32]).
///   * THE WINDOW RULE. The TOE never re-opens a window that closed, so per lane the requested but
///     unread response bytes must stay <= 2^RING_LOG2 (LANE_POLICY[61:56]) - 64 KiB. The host keeps it
///     by capping every GET at toe_get_cap() -- ((2^RING_LOG2 - 64 KiB) / GET_CREDIT) - 4 KiB of body,
///     236 KiB at a 1 MiB ring and credit 4 -- and splitting every larger column chunk, whatever
///     OASIS_HTTP_CHUNK_BYTES says. toe_rx flags a lane past the budget (STALL[24], budget_err).
/// Anything numerically above this is NOT treated as "at least revision 6": the host refuses a
/// revision it does not know (HTTPRevision::Classify) instead of guessing its register map.
constexpr const uint8_t HTTP_CSR_REVISION_TOE = 6;

/// Revision 6: what the window budget keeps free of the ring (2^RING_LOG2) per lane -- the hardware's
/// budget_err threshold is 2^RING_LOG2 minus this -- and what each GET is charged on top of its body
/// for the response header (MinIO sends ~630 bytes).
constexpr const uint64_t HTTP_TOE_RING_SLACK   = 64ULL * 1024ULL;
constexpr const uint64_t HTTP_TOE_GET_OVERHEAD = 4ULL * 1024ULL;

/**
 * What a raw CSR revision (inflightWord[31:24]) means to this library. Pure; HTTPReadConfig::
 * revision() returns `protocol`, so every `revision() >= HTTP_CSR_REVISION_X` gate in the code -- the
 * register map and the rules -- sees a revision-6 bitstream as the revision 2 its register map is,
 * and nothing slot-related (revisions 3..5) can run on it.
 */
struct HTTPRevision {
    uint8_t raw      = 0;     // as read from inflightWord[31:24]
    uint8_t protocol = 0;     // the register map and rules the host drives: 6 -> 2, else raw
    bool    toe_ring = false; // revision 6: handler_toe (see HTTP_CSR_REVISION_TOE)

    bool lane_csrs() const { return protocol >= HTTP_CSR_REVISION_LANES; }
    bool slot_mode() const { return protocol >= HTTP_CSR_REVISION_SLOTS; }
    bool slot_pipelined() const { return protocol >= HTTP_CSR_REVISION_PIPE; }
    bool conn_placement() const { return protocol >= HTTP_CSR_REVISION_CONNS; }

    /// Throws std::runtime_error on a revision above HTTP_CSR_REVISION_TOE: its register map is not
    /// known here, and reading or writing by a guess is how a host corrupts a bitstream's state.
    static HTTPRevision Classify(uint8_t raw);
};

/// Lane depth on a revision-4 bitstream when OASIS_HTTP_LANE_DEPTH is not set, and the most it may
/// be set to. Two already hides the per-request round trip behind the previous transfer (the
/// build-119 depth sweep: per-GET time 1020 -> 848 -> 822 us at depth 1 -> 2 -> 4).
constexpr const size_t HTTP_PIPE_DEFAULT_DEPTH = 2;
constexpr const size_t HTTP_PIPE_MAX_DEPTH     = 4;

/// What the byte budget charges per GET on top of its body: the response header (MinIO ~630 bytes)
/// plus room for a server that sends a longer one.
constexpr const uint64_t HTTP_SLOT_GET_OVERHEAD = 4ULL * 1024ULL;

/// Connections the revision-3 per-connection words address at their fixed stride (8 per 64-bit word
/// for OCC/ERR, 16 per word for READY; 4 + 2 + 4 words). Connections the bitstream lacks read 0.
constexpr const uint8_t HTTP_CONN_SLOTS = 32;

/// Header slack the host leaves in a connection's slot: one GET's BODY may be at most
/// 2^SLOT_LOG2 - this, so the response headers (~630 bytes from MinIO) always fit behind it. The
/// hardware's rule, stated in http_config.sv's SLOT_POLICY field; a response that overruns its slot
/// is dropped whole and the connection goes FATAL (CONN_ERR bit 7).
constexpr const uint64_t HTTP_SLOT_HEADER_SLACK = 64ULL * 1024ULL;

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
        /// One entry per GET: its length in bytes within `text`, in order, so that the requests can
        /// be told apart again. A revision-2 bitstream never needs this -- the whole text is one arm
        /// -- but a revision-3 one takes ONE ARM PER GET (depth 1 per connection), so each request
        /// has to be armed, padded and DMA'd on its own. Empty means "the text is one request".
        std::vector<uint32_t> request_bytes;
    };

    /// Append one column chunk's GETs to `batch`, splitting at split_bytes() -- chunk_bytes(), and on
    /// a revision-3 or revision-6 bitstream never more than max_get_bytes().
    void read_streamed(uint32_t server_ip, uint16_t server_port, const std::string &path,
                       uint64_t range_begin, uint64_t range_end, RequestBatch &batch);

    /// read_streamed()'s body, pure: append the GETs of the column chunk [range_begin, range_end]
    /// (inclusive) to `batch`, each asking for at most `split` bytes (0 = one GET), and ONE
    /// chunk_bytes entry for the whole chunk -- the hardware marks the decoder's tlast by counting
    /// those bytes down, so the chunk ends exactly once however many GETs it was split into.
    static void AppendChunkGets(const std::string &host, uint16_t server_port,
                                const std::string &path, uint64_t range_begin, uint64_t range_end,
                                uint64_t split, RequestBatch &batch);

    /// The GETs of `batch` as separate strings, in order, using request_bytes (the whole text if it
    /// is empty). Pure; exposed so the split can be checked without a board.
    static std::vector<std::string> SplitRequests(const RequestBatch &batch);

    /// Largest byte range one GET may ask for on `split_cfg` (chunk_bytes(), 0 = never split) and a
    /// per-GET hardware cap `max_get` (0 = none): the smaller of the two non-zero values. Pure.
    static uint64_t EffectiveSplit(uint64_t split_cfg, uint64_t max_get);

    /// Byte range split this bitstream needs, see EffectiveSplit(). Reads the revision once.
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

    /// Push the batch's body_last bits, then arm the transfer, ALL ON `lane`. The caller DMAs
    /// `batch.text` into that lane's request stream afterwards -- this only tells the hardware what
    /// is coming.
    ///
    /// `lane` is what the hardware routes by (req_chunk_dest, bits [35:32] of the chunk-length
    /// register); get it from lane_for_stream(). It used to be derived from the decode stream inside
    /// here while operator.cpp derived the DMA sink from the same stream a different way, so the two
    /// could disagree; and the arm carried no lane of its own at all, inheriting whatever the last
    /// entry left in the register. Both are now one explicit parameter.
    ///
    /// On a revision-3 bitstream this is legal only for a batch of ONE request: every GET needs its
    /// own arm there (see arm_transfer()), and one arm announcing several GETs would put several
    /// responses into a slot the hardware drains as one. It throws rather than corrupt; the operator
    /// drives revision 3 through push_entries() + arm_transfer() per request instead. The same holds
    /// on revision 6 (one_arm_per_get()), where the GET credit counts arms.
    void submit_batch(uint32_t server_ip, uint16_t server_port, const RequestBatch &batch,
                      uint8_t lane);

    /// The first half of submit_batch(): reserve credit for, and push, the batch's chunk-length
    /// entries on `lane`. Nothing is armed.
    void push_entries(const RequestBatch &batch, uint8_t lane);

    /// The second half: arm ONE transfer of `text_bytes` bytes of request text on `lane` (write the
    /// arm registers, wait for ARM_READY, pulse START). The caller DMAs the text afterwards.
    ///
    /// On a revision-3 bitstream ARM_READY includes the connection's DEPTH-1 CREDIT, so this blocks
    /// until the previous response on that connection has been drained out of its slot -- which is
    /// what makes one-GET-per-connection a hardware guarantee instead of a host convention.
    void arm_transfer(uint32_t server_ip, uint16_t server_port, uint32_t text_bytes, uint8_t lane);
    /// Revision 5: the same, on connection `conn` (from pick_conn()). Below revision 5 `conn` must
    /// be the lane's own connection and is not written.
    void arm_transfer(uint32_t server_ip, uint16_t server_port, uint32_t text_bytes, uint8_t lane,
                      uint8_t conn);

    /// Revision 3 only: block until the arm just written has been CONSUMED, i.e. CONN_DRAINED for
    /// the lane's connection has fallen. START does not back-pressure and the handler samples the
    /// LIVE registers, so writing the next beat's registers before the arm is consumed would change
    /// what it arms. Revisions 4 and 6: until ARM_READY has fallen (the arm made the lane's request
    /// stream busy, and the caller sends that text only after this returns). A no-op on revision 2.
    void await_arm_consumed(uint8_t lane);

    // ---- CSR revision 6 (TOE receive rings, handler_toe) ----------------------------------------

    /// True on a revision-6 bitstream (see HTTP_CSR_REVISION_TOE). revision() reports 2 there.
    bool toe_ring();
    /// The revision byte exactly as the bitstream reports it (6 on handler_toe), for messages.
    uint8_t raw_revision();
    /// True where every GET needs an arm of its own: the slot handler (revision >= 3) and the TOE-ring
    /// handler (revision 6). The operator then arms, pads and DMAs each GET separately.
    bool one_arm_per_get() { return slot_mode() || toe_ring(); }

    /// Revision 6: the largest GET body that keeps a lane inside the window rule, from LANE_POLICY
    /// (GET_CREDIT, RING_LOG2). Throws if the policy word is unusable. 0 on every other revision.
    uint64_t toe_get_cap();
    /// Pure form: ((2^ring_log2 - HTTP_TOE_RING_SLACK) / get_credit) - HTTP_TOE_GET_OVERHEAD, i.e.
    /// GET_CREDIT GETs of that body plus a 4 KiB header each fill the ring up to its budget exactly.
    /// 0 when the inputs cannot describe a usable ring (credit 0, ring_log2 outside 17..30, or no
    /// room left for a body).
    static uint64_t ToeGetCap(uint8_t ring_log2, uint32_t get_credit);

    // ---- CSR revision 3 (HBM slots) ----------------------------------------------------------

    /// True when the programmed bitstream is the slot handler (revision >= HTTP_CSR_REVISION_SLOTS).
    /// Read once and cached with revision(); nothing below revision 3 changes behaviour.
    bool slot_mode();

    /**
     * Read id 32 (SLOT_POLICY), revision 3 only: what handler_slots was elaborated with.
     */
    struct HTTPSlotPolicy {
        uint8_t  revision     = 0; // [7:0]
        uint8_t  n_conns      = 0; // [15:8]
        uint8_t  n_decoders   = 0; // [23:16]
        uint8_t  slot_log2    = 0; // [29:24], one slot is 2^this bytes
        uint8_t  rd_max_log2  = 0; // [35:30], largest single card read
        uint16_t entry_depth  = 0; // [51:36], armed GETs queued per decoder
        uint8_t  wr_fifo_log2 = 0; // [57:52], shared writer fifo, in 64-byte beats

        bool     valid() const { return revision >= HTTP_CSR_REVISION_SLOTS && slot_log2 != 0; }
        uint64_t slot_bytes() const { return valid() ? (1ULL << slot_log2) : 0; }
        /// Bytes of card memory the slot array spans: n_conns slots, back to back.
        uint64_t region_bytes() const { return slot_bytes() * n_conns; }
        /// Largest legal GET body: slot minus HTTP_SLOT_HEADER_SLACK. 0 when not valid.
        uint64_t max_get_bytes() const {
            return slot_bytes() > HTTP_SLOT_HEADER_SLACK ? slot_bytes() - HTTP_SLOT_HEADER_SLACK : 0;
        }
        std::string describe() const;
    };
    /// Cached after the first read. Empty (invalid) below revision 3 -- read id 32 is a resp_error
    /// there, so it is never read.
    HTTPSlotPolicy slot_policy();
    static HTTPSlotPolicy DecodeSlotPolicy(uint64_t word);

    /// Largest byte range one GET may ask for, from the bitstream: slot_policy().max_get_bytes() on
    /// revision 3..5, toe_get_cap() on revision 6, 0 ("no limit") on revision 2 and below.
    uint64_t max_get_bytes();

    // ---- CSR revision 4 (pipelined GETs on the slot handler) ------------------------------------

    /// True on revision >= HTTP_CSR_REVISION_PIPE: several GETs may be armed on one connection.
    bool slot_pipelined();

    /// The per-connection byte budget: slot size minus HTTP_SLOT_HEADER_SLACK. 0 below revision 4.
    uint64_t slot_budget_bytes();

    /// Revision 4: block until `body_bytes` (+ HTTP_SLOT_GET_OVERHEAD) more response bytes fit in
    /// the slot of `lane`'s connection, then charge them. The charge is cleared whenever CONN_DRAINED
    /// reads set (slot released, nothing armed), which is the only moment the host knows the slot's
    /// cursor is back at 0. A no-op below revision 4. Throws on a fatal lane or after the credit
    /// timeout. Must be called by the one thread that arms this lane, immediately before the arm.
    void reserve_slot_bytes(uint8_t lane, uint64_t body_bytes);

    /// Pure form of reserve_slot_bytes()'s admission: `used` already charged, `need` to add. A need
    /// larger than the whole budget is admitted only into an empty slot (used == 0) -- it cannot be
    /// made to fit by waiting, and max_get_bytes() already bounds a single GET below the slot size.
    static bool SlotBudgetOk(uint64_t used, uint64_t need, uint64_t budget);

    /// The body length a ranged GET asks for, from its "Range: bytes=a-b" header (b - a + 1).
    /// 0 when the text carries no parsable closed range.
    static uint64_t RequestRangeBytes(const std::string &request);

    /// Write SLOT_BASE_LO/HI (write ids 42/43): the virtual address of slot 0, as the card DMA's TLB
    /// resolves it. Throws below revision 3, where those addresses do not exist.
    void set_slot_base(uint64_t vaddr);

    /**
     * One connection's view from the revision-3 words (read ids 21..31). In stage 1 connection c is
     * decoder c, so `occ` is the chunk occupancy of decoder c (CONN_OCC is indexed by DECODER).
     */
    struct HTTPConn {
        uint8_t occ         = 0;     // CONN_OCC, chunk entries of the decoder with this index
        bool    arm_ready   = false; // CONN_READY +0, INCLUDES the depth-1 credit
        bool    entry_ready = false; // CONN_READY +1
        bool    conn_up     = false; // CONN_READY +2
        bool    fatal       = false; // CONN_READY +3
        bool    drained     = false; // CONN_DRAINED[c]: slot empty, will accept an arm
        bool    overflow    = false; // CONN_DRAINED[32+c]: sticky slot overflow (= err bit 7)
        uint8_t err_raw     = 0;     // CONN_ERR byte: bits 0..6 as LANE_ERR, bit 7 SLOT_OVERFLOW
        // Revision 5 (CONN_MAP, read ids 34..37; CONN_CAUSE, 38). Zero below it.
        uint8_t pend        = 0;     // entries armed on this connection, not yet retired (sat. 15)
        uint8_t cur_dec     = 0;     // the decoder they are queued on (its home decoder before)
        bool    is_tail     = false; // it is its decoder's tail: another arm there pipelines on it
        bool    residue     = false; // CONN_CAUSE[c]: bytes left in its slot at a release
        bool    tainter     = false; // CONN_CAUSE[32+c]: went fatal with entries pending
        std::string describe() const;
    };
    struct HTTPConns {
        uint8_t                                count = 0;
        std::array<HTTPConn, HTTP_CONN_SLOTS>  conn {};
        bool empty() const { return count == 0; }
        const HTTPConn &at(uint8_t c) const;
        std::string describe() const;
    };
    /// All eleven revision-3 readback words, decoded. Empty below revision 3. Diagnostics only --
    /// the admission paths read the one or two words they need.
    HTTPConns conns();
    static HTTPConns DecodeConns(const std::array<uint64_t, 4> &occ_words,
                                 const std::array<uint64_t, 2> &ready_words,
                                 const std::array<uint64_t, 4> &err_words, uint64_t drained_word,
                                 uint8_t count);

    /// The connection a lane's GETs travel on. Stage 1 (N_CONNS == N_DECODERS): the lane itself.
    uint8_t conn_for_lane(uint8_t lane);

    // ---- CSR revision 5 (stage 2: the host places GETs on connections) --------------------------

    /// True on revision >= HTTP_CSR_REVISION_CONNS.
    bool conn_placement();

    /// Connections this process spreads GETs over: OASIS_HTTP_CONNS clamped to [1, N_CONNS]
    /// (default all of them). The bitstream opens every connection it has either way; the unused
    /// ones simply stay idle -- so a 32-connection bitstream measures 4, 8, 16, 24 and 32 without a
    /// rebuild.
    uint8_t active_conns();

    /// GETs one connection may have armed at once when the host pipelines on it (only when no
    /// connection is free): OASIS_HTTP_CONN_DEPTH, default HTTP_PIPE_DEFAULT_DEPTH, at most
    /// HTTP_PIPE_MAX_DEPTH.
    size_t conn_depth();

    /// Revision 5: choose the connection the next GET of `lane` (a decoder) goes on, charge its
    /// `body_bytes` (+ HTTP_SLOT_GET_OVERHEAD) to that connection's slot, and return it. Blocks until
    /// one can take it; throws on a tainted decoder or after the credit timeout. Prefers a FREE
    /// connection (round robin over active_conns() -- more connections in flight is the whole point
    /// of stage 2), and otherwise pipelines on the lane's tail up to conn_depth() GETs within the
    /// slot's byte budget. Must be called by the one thread that arms, immediately before the arm.
    uint8_t pick_conn(uint8_t lane, uint64_t body_bytes);

    /// Everything pick_conn() decides on, so the rule can be checked without a board.
    struct ConnPickInputs {
        uint8_t  lane        = 0;
        uint8_t  active      = 0;       // connections to use, 0..active-1
        uint8_t  rr          = 0;       // round-robin cursor
        int      host_tail   = -1;      // the connection the host last armed on this lane
        size_t   conn_depth  = 1;
        uint64_t budget      = 0;       // slot byte budget
        uint64_t need        = 0;       // this GET's charge
        std::array<bool, HTTP_CONN_SLOTS>     drained {};
        std::array<bool, HTTP_CONN_SLOTS>     fatal {};
        std::array<uint8_t, HTTP_CONN_SLOTS>  pend {};
        std::array<uint8_t, HTTP_CONN_SLOTS>  cur_dec {};
        std::array<bool, HTTP_CONN_SLOTS>     is_tail {};
        std::array<uint64_t, HTTP_CONN_SLOTS> used {};
    };
    struct ConnPick {
        int     conn    = -1;     // -1: nothing can take it now (poll)
        bool    free    = false;  // a free connection (its byte charge restarts at 0)
        uint8_t next_rr = 0;
    };
    static ConnPick PickConn(const ConnPickInputs &in);

    /// Pure decoder of CONN_MAP (34..37) + CONN_CAUSE (38) into `conns` (revision 5).
    static void DecodeConnMap(const std::array<uint64_t, 4> &map_words, uint64_t cause_word,
                              HTTPConns &conns);

    /// Read id 31 bit `conn`: the depth-1 credit on revision 3; "slot empty and nothing armed" on
    /// revision 4 (the byte budget's reset).
    bool conn_drained(uint8_t conn);

    /// Pure form of await_lane_credit()'s admission rule, so it can be checked without a board:
    /// revision 3 additionally requires the connection's slot to be drained (`drained`); revision 4
    /// does not (its slot rule is the byte budget, taken at the arm).
    static bool LaneCreditOk(uint8_t revision, size_t occ, size_t needed, size_t limit, bool drained);

    /// Pure form of lane_depth_limit(): `want` (OASIS_HTTP_LANE_DEPTH) clamped to [1, hw]; 1 below
    /// revision 2 (no per-lane occupancy) and at revision 3 (depth 1 per connection); clamped to
    /// [1, min(hw, HTTP_PIPE_MAX_DEPTH)] at revision 4, where the caller passes
    /// HTTP_PIPE_DEFAULT_DEPTH as `want` when the variable is unset. `get_credit` (revision 6, where
    /// `revision` is the protocol revision 2): when non-zero the depth is also clamped to it, since
    /// every column chunk is at least one GET and the hardware holds at most GET_CREDIT per lane.
    static size_t LaneDepthFor(uint8_t revision, size_t want, size_t hw, size_t get_credit = 0);

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

    /// The PROTOCOL revision the host drives the programmed bitstream with, cached after the first
    /// read: inflightWord[31:24] mapped by HTTPRevision::Classify -- the raw value, except that the
    /// TOE-ring handler's 6 reads as 2 (its register map; see toe_ring() / raw_revision()). 0 on
    /// everything built before the per-lane registers. Throws on a revision this library does not know.
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
    /// Revision 5 (pure): lanes are DECODERS -- occupancy from LANE_OCC (16, per decoder) and the
    /// admission/fatal bits from DEC_STATE (33): ARM_READY +0, ENTRY_READY +1, fatal = TAINTED +2.
    /// conn_up reads true: a decoder has no session of its own.
    static HTTPLanes DecodeDecState(uint64_t occ_word, uint64_t dec_state_word, uint8_t count);

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
        /// [8L+7] on REVISION 2: this lane's decoupling fifo back-pressured the stack. Revision 3
        /// REDEFINES bit 7 (there is no per-lane fifo any more) -- see slot_overflow.
        bool rx_fifo_stall = false;
        /// [8L+7] on REVISION 3: a segment would have run past the end of this connection's slot and
        /// was dropped whole; the connection is FATAL. Exactly one of rx_fifo_stall / slot_overflow
        /// is decoded from bit 7, by the revision passed to DecodeLaneErrors().
        bool slot_overflow = false;
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
        // REVISION 6 REDEFINES [55:32] and [61:56] (there is no head-of-line watchdog in
        // handler_toe). DecodePolicy() fills exactly one of the two pairs, by revision.
        uint32_t get_credit        = 0; // [55:32] on revision 6: GETs (arms) per lane unfinished
        uint8_t  ring_log2         = 0; // [61:56] on revision 6: the TOE's ring per session, log2 B

        /// False on a bitstream below HTTP_CSR_REVISION_LANES, where the register was not read.
        bool valid() const { return revision >= HTTP_CSR_REVISION_LANES; }
        /// Revision 6 (the raw value lives in [7:0], so this needs no other register).
        bool toe() const { return revision == HTTP_CSR_REVISION_TOE; }
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
    static HTTPLaneErrors  DecodeLaneErrors(uint64_t err_word, uint8_t count,
                                            uint8_t revision = HTTP_CSR_REVISION_LANES);
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
        /// REVISION 3 ONLY (bits 29..31 were a literal 0 before it, so these decode as false on an
        /// older bitstream without any gating).
        /// [29] the slot writer throttled readPkg issue because the shared fifo was filling. NOT a
        /// failure -- it is the design working -- so it is not part of any().
        bool space_stall = false;
        /// [30] some connection's response ran past the end of its slot (dropped, connection fatal).
        bool slot_overflow = false;
        /// [31] some decoder found bytes in a slot that belong to no response it was told about:
        /// two GETs armed on one connection, or a server overrunning its Content-Length.
        bool residue_err = false;
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
            return connect_stalled || send_stalled || read_stalled || init_error || send_error
                   || resp_unframeable || dirty_abort || status_bad || notify_overflow
                   || rx_fifo_stall || read_timeout || align_starved || route_stall
                   || slot_overflow || residue_err || toe_rx_err;
        }
        std::string describe() const;
    };
    HTTPStall stall();
    /// Pure decoder of the stallWord. `toe_ring` selects the revision-6 meaning of bit 24.
    static HTTPStall DecodeStall(uint32_t word, bool toe_ring);

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

    /// Every readback register this bitstream has, raw and decoded, as one multi-line string: the
    /// status/stall/response words (1..15), the per-lane words (16..20, revision >= 2; on revision 6
    /// with the GET credit, ring size and GET cap), and the per-connection words (21..32, revision 3,
    /// never on revision 6). Reads only; safe from any thread. This is the
    /// in-process state capture -- a second process cannot attach on a revision-3 board (it would be
    /// ctid 1, and the slot descriptors carry pid 0).
    std::string debug_dump();

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

    /// CSR revision, classified and cached (raw / protocol / toe_ring). `rev_read_` false until the
    /// first read; the value is fixed by the bitstream.
    HTTPRevision rev_ {};
    bool         rev_read_ {false};
    /// The classification, read once. revision(), raw_revision() and toe_ring() are views of it.
    const HTTPRevision &rev();

    /// toe_get_cap(), cached. 0 means "not computed yet" (a usable cap is never 0).
    uint64_t toe_cap_ {0};

    /// Revision 6 half of await_arm_consumed(): block until ARM_READY of `lane` has fallen.
    void await_arm_taken_toe(uint8_t lane);

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

    /// slot_policy(), cached. `slot_policy_read_` distinguishes "not read yet" from "read, invalid".
    HTTPSlotPolicy slot_policy_ {};
    bool           slot_policy_read_ {false};

    /// Revision 4: response bytes charged against each connection's slot since CONN_DRAINED was
    /// last seen set. Touched only by the thread that arms (the dispatcher).
    std::array<uint64_t, HTTP_CONN_SLOTS> slot_used_ {};

    /// Revision 5 placement state (the arming thread only): the connection last armed per lane,
    /// the round-robin cursor, and the cached OASIS_HTTP_CONNS / OASIS_HTTP_CONN_DEPTH.
    std::array<int, HTTP_LANE_SLOTS> host_tail_ {-1, -1, -1, -1, -1, -1, -1, -1};
    uint8_t conn_rr_ {0};
    /// "; N of M connections over D decoders ..." for the revision-5 startup line.
    std::string conn_line();
    uint8_t active_conns_ {0};
    size_t  conn_depth_ {0};
};

} // namespace oasis
