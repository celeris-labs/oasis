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

// Turns the per-batch FPGA request trace on stderr on or off (lane windows, stall word, decoder
// counters). OASIS_HTTP_DEBUG=1 and SET httpfpga_debug = true turn it on too.
void set_http_debug(bool enabled);
bool http_debug_enabled();

constexpr const uint64_t RDMA_READ_CONFIG_REGS = 2;
constexpr const uint64_t RDMA_READ_CONFIG_ID   = 0x2f966a70f04c0e93;

// HttpConfig in hardware/src/hdl/http_read/http_config.sv ("HTT"). The host writes ids 0, 1 and
// 39 to 41 and reads ids 0 to 20.
constexpr const uint64_t HTTP_READ_CONFIG_ID = 0x0000000000485454;

// The CSR revisions this library drives, from inflightWord[31:24]. Both have the same register map.
// Revision 2 is handler_multi: the lanes share the TOE's receive fifo. Revision 6 is handler_toe: the
// TOE keeps a receive ring per session (2^RING_LOG2 bytes) and three rules change:
//   * One GET per arm. The handler counts GETs by arms (+1 per arm, -1 per framed response).
//   * The GET credit. ARM_READY also needs fewer than GET_CREDIT unfinished GETs on the lane.
//   * The window budget. The TOE never reopens a window that closed, so a lane's requested but
//     unread bytes must stay below 2^RING_LOG2 - HTTP_TOE_RING_SLACK. The host keeps it by capping
//     every GET at toe_get_cap() (236 KiB at a 1 MiB ring and credit 4).
// Every other revision is refused at startup (HTTPReadConfig::CheckRevision).
constexpr const uint8_t HTTP_CSR_REVISION_MULTI = 2;
constexpr const uint8_t HTTP_CSR_REVISION_TOE   = 6;

// Lanes the per-lane CSRs (read ids 16 to 20) address, at a fixed stride whatever the bitstream's lane
// count. Lanes the bitstream does not have read 0.
constexpr const uint8_t HTTP_LANE_SLOTS = 8;

// Revision 6: the part of each ring the window budget keeps free (toe_rx's budget_err fires above
// 2^RING_LOG2 minus this), and what each GET is charged for its response header on top of its body.
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

// Pads request text to a whole 64-byte DMA beat with a header the server ignores (X-Pad).
void PadRequestTextToBeat(std::string &text);

/**
 * Drives HttpConfig and the HTTP handler behind it (handler_multi or handler_toe). Lane L owns a TCP
 * session, a chunk queue and decoder L. The host builds the GETs as text and DMAs them into the
 * lane's request stream; through the CSRs it pushes one chunk-length entry per column chunk (the
 * hardware marks the decoder's tlast by counting those bytes) and arms each transfer.
 */
class HTTPReadConfig : public libstf::Config {
  public:
    HTTPReadConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset, uint32_t num_regs);

    static constexpr uint64_t ID = HTTP_READ_CONFIG_ID;

    // The GETs of one or more column chunks.
    struct RequestBatch {
        std::string           text;          // every GET, in the order the responses come back
        std::vector<uint32_t> chunk_bytes;   // per column chunk: its size in bytes
        std::vector<uint32_t> request_bytes; // per GET: its length within `text`
    };

    // ---- Request text ---------------------------------------------------------------------------

    // Appends the GETs of the column chunk [offset, offset + size) to `batch`, split at
    // split_bytes(). Throws on an empty chunk.
    void append_chunk(uint32_t server_ip, uint16_t server_port, const std::string &path,
                      uint64_t offset, uint64_t size, RequestBatch &batch);
    // append_chunk() for the inclusive range [range_begin, range_end]: GETs of at most `split` bytes
    // each (0 = one GET) and one chunk_bytes entry for the whole chunk.
    static void AppendChunkGets(const std::string &host, uint16_t server_port,
                                const std::string &path, uint64_t range_begin, uint64_t range_end,
                                uint64_t split, RequestBatch &batch);
    // One ranged GET (keep-alive) as request text.
    static std::string BuildGet(const std::string &host, uint16_t port, const std::string &path,
                                uint64_t range_begin, uint64_t range_end);
    // The GETs of `batch` as separate strings, cut at request_bytes. Throws if the lengths do not add
    // up to the text.
    static std::vector<std::string> SplitRequests(const RequestBatch &batch);

    // Largest byte range of one GET: OASIS_HTTP_CHUNK_BYTES (0, the default, is one GET per column
    // chunk) capped at toe_get_cap() on revision 6.
    uint64_t split_bytes();
    // The smaller of the two limits, where 0 is no limit.
    static uint64_t EffectiveSplit(uint64_t split_cfg, uint64_t max_get);

    // ---- Writing beats --------------------------------------------------------------------------

    // The admission bit of a lane's LANE_READY nibble a beat waits for: an arm waits for the lane's
    // previous request text to have gone out, an entry for room in its chunk queue.
    enum class LaneAdmit : uint8_t { Arm, Entry };

    // Reserves room for, then pushes, the batch's chunk-length entries on `lane`.
    void push_entries(const RequestBatch &batch, uint8_t lane);
    // Arms one transfer of `text_bytes` bytes of request text on `lane`: writes the arm registers,
    // waits for ARM_READY and pulses START. The caller DMAs the text afterwards. On revision 6 this
    // waits while the lane has GET_CREDIT GETs unfinished.
    void arm_transfer(uint32_t server_ip, uint16_t server_port, uint32_t text_bytes, uint8_t lane);
    // Revision 6: waits until the arm just written was taken (ARM_READY fell). The handler samples
    // the live registers, so the next beat may only be written after that.
    void await_arm_taken(uint8_t lane);
    // Waits until `lane` accepts a beat of kind `admit`, or throws naming the lane and the reason.
    void await_cfg_ready(const char *what, uint8_t lane, LaneAdmit admit);
    // Waits until `lane` has room for `needed` more chunk entries, or throws. A batch reserves room for
    // all of its entries first: the arm comes after them, so a batch that filled the queue part way
    // would wait on itself. A `needed` above lane_depth_limit() gets the lane to itself.
    void await_lane_credit(uint8_t lane, size_t needed);
    // Throws naming `lane`, what it waited for and its sticky causes. Reads CSRs, so call it with no
    // scheduler lock held.
    [[noreturn]] void throw_lane_fatal(uint8_t lane, const char *what);

    // ---- What the bitstream reports, read once --------------------------------------------------

    // The CSR revision, 2 or 6. Throws on any other.
    uint8_t revision();
    bool    toe_ring() { return revision() == HTTP_CSR_REVISION_TOE; }
    // Throws unless the library drives `revision`.
    static void CheckRevision(uint8_t revision);

    // Lanes (TCP sessions) of the bitstream, one per decoder.
    uint8_t lane_count();
    // The lane a column chunk decoding on `stream` is fetched on: the stream itself. Throws for a
    // stream without a lane.
    uint8_t lane_for_stream(libstf::stream_t stream);
    // Column chunks one batch may carry: the per-lane queue depth (read id 15).
    size_t max_batch_chunks();
    // Chunk entries one lane may owe: OASIS_HTTP_LANE_DEPTH (default 4) clamped by LaneDepthFor().
    // This is the host's pipelining cap; the hardware queue is deeper.
    size_t lane_depth_limit();
    // Revision 6: the largest GET body that keeps a lane inside the window budget, from LANE_POLICY.
    // Throws if the policy gives none. 0 on revision 2.
    uint64_t toe_get_cap();
    // Requests one stream may keep in flight: the queue depth the bitstream reports
    // (inflightWord[15:8]), or OASIS_HTTP_MAX_INFLIGHT if that is smaller.
    uint8_t max_inflight();

    // Pure forms of the rules above, for the board-free checks.
    // Whether a lane that owes `occ` entries may take `needed` more under `limit`.
    static bool LaneCreditOk(size_t occ, size_t needed, size_t limit);
    // `want` clamped to [1, hw], and to `get_credit` when that is non-zero (revision 6: every column
    // chunk is at least one GET).
    static size_t LaneDepthFor(size_t want, size_t hw, size_t get_credit = 0);
    // ((2^ring_log2 - HTTP_TOE_RING_SLACK) / get_credit) - HTTP_TOE_GET_OVERHEAD, or 0 when that
    // describes no usable ring.
    static uint64_t ToeGetCap(uint8_t ring_log2, uint32_t get_credit);

    // ---- Readback -------------------------------------------------------------------------------

    // Read id 10 (inflightWord). Occupancy is the maximum over lanes.
    struct HTTPInflight {
        uint8_t occupied    = 0;     // chunk entries queued, saturating at 255
        uint8_t slots       = 0;     // the per-lane queue depth, saturating at 255
        bool    has_pending = false; // [16] rev 2: a segment waits to be read; rev 6: notified bytes
        bool    peer_closed = false; // [17] rev 2: the peer sent FIN; rev 6: a FIN has settled
        bool    conn_up     = false; // [18] every lane is connected
        uint8_t revision    = 0;     // [31:24]

        std::string describe() const;
    };
    HTTPInflight inflight();

    // One lane's admission window, from read ids 16 (LANE_OCC) and 17 (LANE_READY). Only a beat the
    // host writes clears an admission bit, so a sample stays valid until the host acts on it.
    struct HTTPLane {
        uint8_t occ         = 0;     // chunk entries not yet retired, saturating at 255
        bool    arm_ready   = false; // accepts an arm
        bool    entry_ready = false; // accepts a chunk entry
        bool    conn_up     = false; // holds an established TCP session
        bool    fatal       = false; // out of service until reprogrammed; arm_ready then stays low

        bool ready_for(LaneAdmit admit) const {
            return admit == LaneAdmit::Arm ? arm_ready : entry_ready;
        }
        std::string describe() const;
    };
    struct HTTPLanes {
        uint8_t                               count = 0; // the bitstream's lanes
        std::array<HTTPLane, HTTP_LANE_SLOTS> lane {};

        // Throws std::out_of_range for a lane the bitstream does not have.
        const HTTPLane &at(uint8_t l) const;
        std::string describe() const;
    };
    HTTPLanes lanes();

    // One lane's sticky failure causes, from read id 19 (a byte per lane). On a fatal lane lane_dead
    // means rx_dispatch's head-of-line watchdog killed it, losing bytes mid-response; otherwise the
    // other bits say which read error the hardware could not replay.
    struct HTTPLaneError {
        bool    lane_dead     = false; // [0] killed by the head-of-line watchdog (revision 2)
        bool    dirty         = false; // [1] aborted after body bytes reached the decoder
        bool    init_err      = false; // [2] a connect attempt failed
        bool    resp_err      = false; // [3] a response had no Content-Length
        bool    status_bad    = false; // [4] a response was neither 200 nor 206
        bool    tx_refused    = false; // [5] the TOE refused a transmit reservation
        bool    read_timeout  = false; // [6] the read watchdog expired
        bool    rx_fifo_stall = false; // [7] the lane fifo back-pressured the TOE (rev 2) or refused a
                                       //     routed beat (rev 6)
        uint8_t raw           = 0;

        bool any() const { return raw != 0; }
        std::string describe() const;
    };
    struct HTTPLaneErrors {
        uint8_t                                    count = 0;
        std::array<HTTPLaneError, HTTP_LANE_SLOTS> lane {};

        const HTTPLaneError &at(uint8_t l) const;
        std::string describe() const;
    };
    HTTPLaneErrors lane_errors();

    // Read id 20: what the bitstream was built with.
    struct HTTPLanePolicy {
        uint8_t  revision          = 0; // [7:0]
        uint8_t  num_conns         = 0; // [15:8], the lane count
        uint16_t queue_depth       = 0; // [31:16], chunk entries per lane
        uint32_t lane_stall_cycles = 0; // [55:32], revision 2: the head-of-line watchdog threshold
        uint8_t  lane_stall_log2   = 0; // [61:56], revision 2: the same as a power of two
        uint32_t get_credit        = 0; // [55:32], revision 6: unfinished GETs per lane
        uint8_t  ring_log2         = 0; // [61:56], revision 6: the TOE's ring per session, log2 bytes

        bool toe() const { return revision == HTTP_CSR_REVISION_TOE; }
        std::string describe() const;
    };
    HTTPLanePolicy policy();

    static HTTPLanes      DecodeLanes(uint64_t occ_word, uint64_t ready_word, uint8_t count);
    static HTTPLaneErrors DecodeLaneErrors(uint64_t err_word, uint8_t count);
    static HTTPLanePolicy DecodePolicy(uint64_t policy_word);

    // Read id 11 (stallWord): sticky conditions, most of them ORed over the lanes (lanes() and
    // lane_errors() name the lane). Bit 24 differs by revision.
    struct HTTPStall {
        bool     connect_stalled  = false; // [0] an open waited past the stall threshold
        bool     init_error       = false; // [3] a connect attempt failed
        bool     send_error       = false; // [4] the TOE refused a transmit reservation
        bool     resp_unframeable = false; // [5] a response had no Content-Length
        bool     dirty_abort      = false; // [6] a lane is fatal
        bool     status_bad       = false; // [7] a response was neither 200 nor 206
        uint8_t  reconnects       = 0;     // [15:8] sessions reopened since programming
        bool     notify_overflow  = false; // [24] revision 2: rx_dispatch dropped an announcement
        bool     toe_rx_err       = false; // [24] revision 6: toe_rx order, length or budget error
        bool     rx_fifo_stall    = false; // [25] a lane fifo back-pressured or refused a beat
        bool     read_timeout     = false; // [26] a read waited with nothing arriving
        bool     align_starved    = false; // [27] body bytes arrived with no chunk length queued
        bool     route_stall      = false; // [28] the receive router was refused by a lane
        bool     toe              = false; // decoded as revision 6
        uint32_t raw              = 0;

        bool any() const {
            return connect_stalled || init_error || send_error || resp_unframeable || dirty_abort ||
                   status_bad || notify_overflow || rx_fifo_stall || read_timeout || align_starved ||
                   route_stall || toe_rx_err;
        }
        std::string describe() const;
    };
    HTTPStall stall();
    static HTTPStall DecodeStall(uint32_t word, bool toe_ring);

    // Read ids 12 to 14 (respWord, body remaining, Content-Length). The status digits and lengths are
    // lane 0's; the ok, unframeable and dirty flags are folded over all lanes.
    struct HTTPResponse {
        char     status[4]      = {0, 0, 0, 0}; // e.g. "206"
        bool     status_ok      = false;        // 200 or 206
        bool     unframeable    = false;        // no Content-Length
        bool     dirty          = false;        // body bytes already emitted for the response
        uint32_t body_remaining = 0;
        uint32_t content_length = 0;
        std::string describe() const;
    };
    HTTPResponse response();

    // Every readback register, raw and decoded, as one multi-line string. Reads only.
    std::string debug_dump();
    // Decodes read id 2 (totalWord).
    static std::string describe_status(uint32_t status);

  private:
    // Fixed by the bitstream (or the environment), so each is read once. 0 means not read yet.
    uint8_t  revision_ {0};
    uint8_t  lane_count_ {0};
    size_t   max_batch_chunks_ {0};
    size_t   lane_depth_ {0};
    uint64_t toe_cap_ {0};
};

} // namespace oasis
