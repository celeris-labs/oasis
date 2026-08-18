#pragma once

#include "libstf/common.hpp"
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

    /// Push the batch's body_last bits, then arm the transfer. The caller DMAs `batch.text` into
    /// the request stream afterwards -- this only tells the hardware what is coming.
    void submit_batch(uint32_t server_ip, uint16_t server_port, const RequestBatch &batch);

    /// Block until the config port can take another beat. See the definition for why skipping this
    /// loses whole batches without raising anything.
    void await_cfg_ready(const char *what);

    /// Block until the hardware queue has room for `needed` entries. Batches must reserve space for
    /// all of their entries up front: the arm that starts a transfer is written after the entries,
    /// so a batch that fills the queue part way through deadlocks against its own arm.
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

        bool legacy() const { return slots == 0; }
        uint8_t free_slots() const { return slots > occupied ? uint8_t(slots - occupied) : uint8_t(0); }
        std::string describe() const;
    };
    HTTPInflight inflight();

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
        /// silent corruption, not a failure. Any result from such a run is suspect.
        bool align_starved = false;
        /// The stallWord exactly as read, so a caller can tell a condition it has already reported
        /// from a new one. The named bools above are for reading; this is for comparing.
        uint32_t raw = 0;

        bool any() const {
            return connect_stalled || send_stalled || read_stalled || init_error || send_error
                   || resp_unframeable || dirty_abort || status_bad || notify_overflow
                   || rx_fifo_stall || read_timeout || align_starved;
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
