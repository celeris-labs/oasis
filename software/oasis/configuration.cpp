#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <iomanip>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include <libstf/logging.hpp>
#include <libstf/profiling.hpp>
#include <oasis/configuration.hpp>

using libstf::Profiler;

namespace oasis {

namespace {
std::atomic<bool> g_http_debug {false};
} // namespace

void set_http_debug(bool enabled) { g_http_debug.store(enabled, std::memory_order_relaxed); }

bool http_debug_enabled() {
    if (g_http_debug.load(std::memory_order_relaxed)) {
        return true;
    }
    const char *dbg = std::getenv("OASIS_HTTP_DEBUG");
    return dbg != nullptr && dbg[0] == '1';
}

constexpr const uint32_t RDMA_READ_VADDR_ADDR = 0;
constexpr const uint32_t RDMA_READ_SIZE_ADDR  = 1;

RDMAReadConfig::RDMAReadConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset,
                               uint32_t num_regs)
    : Config(cthread, addr_offset, num_regs), num_streams_(read_register(1).value()) {}

const std::string rdma_read_prefix = "oasis::RDMAReadConfig::";

void RDMAReadConfig::enqueue_read(libstf::stream_t stream, size_t offset, size_t size) {
    Profiler::open_regions({rdma_read_prefix + "enqueue_read"});
    auto base_vaddr = reinterpret_cast<uintptr_t>(cthread->getQpair()->remote.vaddr);
    auto reg_offset = stream * RDMA_READ_CONFIG_REGS;
    write_register(libstf::ConfigRegister(reg_offset + RDMA_READ_VADDR_ADDR, base_vaddr + offset));
    write_register(libstf::ConfigRegister(reg_offset + RDMA_READ_SIZE_ADDR, size));
    Profiler::close_regions({rdma_read_prefix + "enqueue_read"});
}

const libstf::stream_t RDMAReadConfig::num_streams() const { return num_streams_; }

namespace {

// HttpConfig write map (hardware/src/hdl/http_read/http_config.sv). Write ids 2..38 are the old
// per-request descriptor fields: a non-zero REQ_TOTAL_BYTES selects the streamed request path, which
// ignores them, so the host never writes them.
constexpr const uint32_t HTTP_SERVER_IP       = 0;
constexpr const uint32_t HTTP_SERVER_PORT     = 1;
constexpr const uint32_t HTTP_START           = 39;
// 40, above START. See the map comment in http_config.sv for why it is above rather than below:
// 0..38 was full, and moving START would shift every parameter after it.
constexpr const uint32_t HTTP_REQ_TOTAL_BYTES = 40;
// Bytes in one decoder stream, i.e. a column chunk. Queued ahead of the data; the hardware counts
// them down and marks tlast. One per CHUNK, not per request.
constexpr const uint32_t HTTP_REQ_CHUNK_BYTES = 41;

// Read-side CSRs (see hardware/src/hdl/http_read/http_config.sv). Ids 1 and 3..9 (client state and
// the echo of the descriptor fields) are only printed raw, by debug_dump().
constexpr const uint32_t HTTP_TOTAL_WORD       = 2;
constexpr const uint32_t HTTP_INFLIGHT         = 10;
constexpr const uint32_t HTTP_STALL            = 11;
constexpr const uint32_t HTTP_RESP             = 12;
constexpr const uint32_t HTTP_BODY_REMAINING   = 13;
constexpr const uint32_t HTTP_CONTENT_LENGTH   = 14;
// The true response-queue depth. inflightWord's slot/occupancy fields are byte-wide and saturate at
// 255; this is how a host learns it may push thousands.
constexpr const uint32_t HTTP_QUEUE_DEPTH      = 15;

// PER-LANE READBACK -- CSR REVISION 2 AND UP. Read ids 16..20, all 64 bits, at a fixed stride of 8
// lanes whatever NUM_CONNS is. The read register file answers an out-of-range address with
// resp_error, NOT with zeros, which is why a bitstream below HTTP_CSR_REVISION_MULTI is refused at
// startup. Field tables live in hardware/src/hdl/http_read/http_config.sv.
constexpr const uint32_t HTTP_LANE_OCC         = 16; // byte per lane at [8L+7:8L], saturating at 255
constexpr const uint32_t HTTP_LANE_READY       = 17; // nibble per lane: arm/entry/conn_up/fatal
constexpr const uint32_t HTTP_LANE_STATE       = 18; // tcp_read nibble low, http_req_stream high
constexpr const uint32_t HTTP_LANE_ERR         = 19; // sticky byte per lane at [8L+7:8L]
constexpr const uint32_t HTTP_LANE_POLICY      = 20; // revision / NUM_CONNS / depths, at elaboration

// Bit positions inside a lane's nibble in HTTP_LANE_READY, at 4L.
constexpr const unsigned HTTP_LANE_ARM_READY   = 0;
constexpr const unsigned HTTP_LANE_ENTRY_READY = 1;
constexpr const unsigned HTTP_LANE_CONN_UP     = 2;
constexpr const unsigned HTTP_LANE_FATAL       = 3;

// How long to wait for a request slot before giving up. Reaching this means the pipeline stopped
// draining -- a response that never arrived, or a connection that never opened -- so it is a
// diagnosis, not a tuning knob. Generous enough that a slow object server never trips it.
constexpr const auto HTTP_CREDIT_TIMEOUT = std::chrono::seconds(30);

// -------------------------------------------------------------------------------------------------
// How many requests may be outstanding, and how big each one is.
//
// WHAT BOUNDS THE BYTES IN FLIGHT: TCP DOES.
// The stack is built with TCP_STACK_RX_DDR_BYPASS_EN=1, so the whole thing has ONE receive buffer --
// `rx_buffer_fifo` in tcp_stack.sv -- and since coyote f248089d/b21b4ec6 that fifo is sized to
// exactly 1 << WINDOW_BITS, today 16384 x 64 B = 1 MiB. The advertised window is computed in
// rx_sar_table as (appd - recvd) - 1, i.e. the buffer minus what the application has been told about
// but not yet read, and `appd` advances only when tcp_read issues a readPkg. With exactly one
// session the logical per-session buffer IS that physical fifo, so the number on the wire is the
// truth: if the reader falls behind, the window shrinks and the sender stops. Nothing here has to
// arrange that.
//
// IT WAS NOT ALWAYS TRUE, WHICH IS WHY THIS COMMENT IS LONG.
// Up to build-94 the fifo was 1024 beats (64 KB) while the same arithmetic advertised up to 256 KB.
// The stack invited four times what it could hold, rx_engine dropped the overflow once free space
// fell below 375 beats, and with out-of-order buffering disabled every drop cost a go-back-N -- the
// duplicate-ACK storms, seconds apart, with a query stalled behind them. The only lever the host had
// was to refuse to ASK for more than the buffer could hold, so HTTP_DEFAULT_MAX_INFLIGHT *
// HTTP_DEFAULT_CHUNK_BYTES was capped under ~41.5 KB. That is where the 4 x 8 KiB default came from.
//
// Two things then removed the need for it, in order. b238c4e put a fifo between the TOE and the HTTP
// parser, which showed the backlog had been the parser holding TREADY low through a header walk
// rather than the network outrunning the decoder -- the decoder drains at ~16 GB/s and was never the
// slow party. Then the rx fifo was sized to the window, which made the advertised number honest. The
// bytes-in-flight cap in HttpMaxInflight was removed after that; see the comment there for what
// still needs watching (a window that reaches zero is expensive to reopen).
//
// So the chunk size is no longer sized against a drop threshold. It is sized against latency: a GET
// costs the object store roughly the same time whatever its size, so bigger chunks amortise it. What
// reports trouble if any of this regresses is rx_fifo_stall -- the drain stopping is the failure
// mode now, not the arithmetic.
//
// WHY PIPELINING IS SAFE AGAIN
// Depth > 1 used to wedge the receive path, and the reason was never the depth: it was concurrent
// SESSIONS. Under RX_DDR_BYPASS `rx_app_stream_if()` answers a readPkg by echoing back the session
// ID the app asked for plus a bare 1-bit token, and `rxAppMemDataRead()` (toe.cpp) consumes that
// token by popping one packet from the HEAD of the shared FIFO without ever looking at the session.
// The real contract is "readPkg must be issued in the global ARRIVAL order across all sessions",
// which a handler draining slots in REQUEST order cannot honour with several connections open.
//
// Each lane now holds ONE persistent connection, and on one session arrival order and request order
// are the same thing, so HTTP/1.1 pipelining over it is legal. Across lanes rx_dispatch issues
// readPkg in arrival order (revision 2), and on revision 6 the TOE keeps a receive ring per session.
//
// 0 MEANS "WHATEVER THE BITSTREAM ADVERTISES". It was 4 to match NUM_SLOTS in vfpga_top.svh, which
// made the two numbers a pair that had to be kept in step by hand -- and silently capped a deeper
// ring back to 4 if only the hardware moved. The handler reports its own ring size in the INFLIGHT
// register; that is the authority. OASIS_HTTP_MAX_INFLIGHT still overrides, which is how to walk the
// depth back without a rebuild if a run misbehaves.
constexpr const uint8_t  HTTP_DEFAULT_MAX_INFLIGHT = 0;

// Largest byte range asked for in one GET. 0 disables splitting entirely: ONE GET PER COLUMN CHUNK,
// which is the default.
//
// WHY THE SPLIT IS OFF
// A GET costs the object store roughly a fixed amount whatever its size, and HTTP/1.1 serialises
// that cost -- ADR-3 measured per-GET time falling only 1020 -> 848 -> 822 us across pipeline depth
// 1 -> 2 -> 4, because MinIO answers request 1 fully before it reads request 2. Splitting a 2 MB
// column chunk into eleven 192 KiB GETs therefore pays that fixed cost eleven times to move the same
// bytes. The split never bought throughput; it bought a bound on response size, and that bound is no
// longer needed (below). Fewer, larger requests is the whole optimisation.
//
// THE BOUND IT USED TO PROVIDE IS GONE
// The 8 KiB original existed to keep `depth x chunk` under the ~41.5 KB threshold at which rx_engine
// began dropping, back when the stack advertised 256 KB against a 64 KB fifo. Two changes retired
// it, in order: b238c4e put a fifo between the TOE and the HTTP parser (the backlog was the parser
// holding TREADY low through a header walk, not the network outrunning the decoder, which drains at
// ~16 GB/s); then the window and the fifo were made equal. Verified in the submodule, not from
// memory:
//
//   WINDOW_SCALE_BITS = 4  ->  WINDOW_BITS = 20  ->  BUFFER_SIZE = 1 MiB
//                                          parcore/libstf/coyote/hw/services/network/hls/toe/
//                                          toe_config.hpp.in:36
//   rx_buffer_fifo    = axis_data_fifo_512_d16384 = 16384 x 64 B = 1 MiB
//   axis_max_data_count = 16'd16384 at both sites  tcp_stack.sv:544, :671, :681
//
// So the stack advertises exactly what it can hold, and a response larger than the window is
// ordinary TCP flow control rather than an overrun: the window closes as the decoder falls behind
// and reopens as it drains.
//
// AN EARLIER VERSION OF THIS COMMENT SAID "DELIBERATELY NOT 262144", on the grounds that 2^18 was
// BUFFER_SIZE and every sweep that hung had hung at or above it. That was true of WINDOW_SCALE_BITS
// = 2 and is not true of the hardware built since; the boundary it named moved to 1 MiB. It is kept
// here because the observation behind it -- sweeps hang AT the window, not at some fraction of it --
// is the thing to re-test if this default misbehaves.
//
// WHAT TO WATCH, AND HOW TO BACK OUT
// rx_fifo_stall (stallWord bit 25) is the failure mode now: it means the drain stopped, so
// back-pressure reached the TOE. Read it with the reconnect count next to it -- a climbing reconnect
// count is the peer giving up, a stall bit alone is local. Neither is a correctness problem by
// itself; both mean this number is implicated. There is also a Coyote-side hazard that big responses
// make more likely: rx_engine accepts a segment only with >375 beats (24000 B) free while
// rx_sar_table advertises (appd - recvd) - 1 and knows nothing about that floor, so an advertised
// window landing in 1..24000 deadlocks rather than back-pressures. The clamp for it shipped in
// build-105 and lives in the parcore submodule, which means it does NOT survive a
// `git submodule update` -- check that before blaming this constant.
//
// OASIS_HTTP_CHUNK_BYTES=<bytes> restores splitting at any size without a rebuild. 196608 (192 KiB)
// was the previous default and is the known-good fallback; scripts/sweep.sh walks the range.
constexpr const uint64_t HTTP_DEFAULT_CHUNK_BYTES = 0;

// Chunk entries ONE LANE may owe at a time. Read once from OASIS_HTTP_LANE_DEPTH; the caller clamps
// it to [1, max_batch_chunks()].
//
// WHY 4, AND WHY A CAP AT ALL. Each lane is one HTTP/1.1 keep-alive connection, and pipelining on
// one of those is strictly ordered: MinIO answers request 1 fully before it starts request 2, so the
// measured per-GET time falls only 1020 -> 848 -> 822 us across depth 1 -> 2 -> 4 and flattens after.
// What depth costs is bytes the server may have in flight for that lane, against a receive fifo the
// lanes share. So a handful is all there is to win, and 4 is where the curve stops moving.
//
// It is per LANE, which is the whole point of the multi-lane design: N lanes at depth 4 is N x 4
// requests outstanding, and those DO overlap, because they are separate connections.
constexpr const uint64_t HTTP_DEFAULT_LANE_DEPTH = 4;

// Environment variable `name` as a positive integer, or `fallback` when it is unset, empty, zero
// or negative.
uint64_t EnvOr(const char *name, uint64_t fallback) {
    const char     *env   = std::getenv(name);
    const long long value = (env == nullptr) ? 0 : std::atoll(env);
    return value <= 0 ? fallback : static_cast<uint64_t>(value);
}

// OASIS_HTTP_CHUNK_BYTES, read once: it is consulted for every column chunk.
uint64_t ConfiguredChunkBytes() {
    static const uint64_t configured = EnvOr("OASIS_HTTP_CHUNK_BYTES", HTTP_DEFAULT_CHUNK_BYTES);
    return configured;
}

// The two FSM states read id 18 exports for one lane, decoded. The transmit side is named because a
// lane parked in IDLE with a transfer still armed is exactly the shape of a wedged transmit path,
// and nothing else exports it.
std::string DescribeLaneState(uint64_t state_word, uint8_t lane) {
    static const char *tx_states[] = {"IDLE", "SEND_META", "WAIT_STAT", "SEND_DATA", "DRAIN"};
    const auto rd = static_cast<unsigned>((state_word >> (4 * lane)) & 0xFu);
    const auto tx = static_cast<unsigned>((state_word >> (32 + 4 * lane)) & 0xFu);
    std::ostringstream oss;
    oss << "read_state=" << rd << " tx_state=" << (tx < 5 ? tx_states[tx] : "?") << "(" << tx << ")";
    return oss.str();
}

std::string IpToAscii(uint32_t ip_be) {
    return std::to_string((ip_be >> 24) & 0xff) + "." + std::to_string((ip_be >> 16) & 0xff) + "." +
           std::to_string((ip_be >> 8) & 0xff) + "." + std::to_string(ip_be & 0xff);
}

} // namespace

HTTPReadConfig::HTTPReadConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset,
                                 uint32_t num_regs)
    : Config(cthread, addr_offset, num_regs) {}

// -------------------------------------------------------------------------------------------------
// Streamed requests: build every GET of a column chunk as TEXT and hand the lot over at once. The
// FPGA stores nothing per request: the text is the request, and the queue holds one entry per
// column chunk.
// -------------------------------------------------------------------------------------------------
// Requests one batch may carry. The queue holds one entry per expected response and the host pushes
// every entry BEFORE arming the transfer, so a batch larger than the queue can never drain.
size_t HTTPReadConfig::max_batch_chunks() {
    // The dedicated register, not inflightWord[15:8], which saturates at 255.
    if (max_batch_chunks_ == 0) {
        max_batch_chunks_ = static_cast<uint32_t>(read_register(HTTP_QUEUE_DEPTH).value());
        if (max_batch_chunks_ == 0) {
            throw std::runtime_error("FPGA HTTP handler reports a chunk queue depth of 0 (read id 15)");
        }
    }
    return max_batch_chunks_;
}

std::string HTTPReadConfig::BuildGet(const std::string &host, uint16_t port, const std::string &path,
                                     uint64_t range_begin, uint64_t range_end) {
    std::ostringstream oss;
    oss << "GET " << path << " HTTP/1.1\r\n"
        << "Host: " << host << ":" << port << "\r\n"
        << "Range: bytes=" << range_begin << "-" << range_end << "\r\n"
        << "Connection: keep-alive\r\n\r\n";
    return oss.str();
}

void HTTPReadConfig::read_streamed(uint32_t server_ip, uint16_t server_port,
                                   const std::string &path, uint64_t range_begin,
                                   uint64_t range_end, RequestBatch &batch) {
    // chunk_bytes(), capped on a revision-6 bitstream at toe_get_cap() (236 KiB at a 1 MiB ring and
    // GET credit 4). There the split is the WINDOW RULE: GET_CREDIT capped responses plus their
    // headers are exactly what a lane's TOE ring may hold unread, and a bigger GET could close the
    // window for good. Even with OASIS_HTTP_CHUNK_BYTES unset (0, "never split"), split_bytes() is the
    // cap, and a column chunk larger than it is split exactly like an OASIS_HTTP_CHUNK_BYTES split --
    // one entry, several GETs.
    AppendChunkGets(IpToAscii(server_ip), server_port, path, range_begin, range_end, split_bytes(),
                    batch);
}

void HTTPReadConfig::AppendChunkGets(const std::string &host, uint16_t server_port,
                                     const std::string &path, uint64_t range_begin,
                                     uint64_t range_end, uint64_t split, RequestBatch &batch) {
    if (range_end < range_begin) {
        throw std::runtime_error("HTTP column chunk with an empty range [" +
                                 std::to_string(range_begin) + "," + std::to_string(range_end) +
                                 "] in '" + path + "'");
    }
    const uint64_t total = range_end - range_begin + 1;
    if (total > UINT32_MAX) {
        // The chunk-length entry is 32 bits in hardware (REQ_CHUNK_BYTES[31:0]); truncating it would
        // end the decoder's stream in the wrong place.
        throw std::runtime_error("HTTP column chunk of " + std::to_string(total) +
                                 " bytes does not fit the 32-bit chunk-length entry");
    }

    // Same split as read(): only the LAST GET of the chunk ends the decoder stream, because the
    // DataNormalizer resets its running byte offset on tlast and an extra one mid-chunk would
    // desynchronise every column after it.
    // ONE entry for the whole chunk, whatever it splits into. The hardware marks the stream end by
    // counting these bytes, so the split is invisible to it.
    batch.chunk_bytes.push_back(static_cast<uint32_t>(total));

    // Every GET's length is recorded so the revision-6 path can arm them one at a time. Written so
    // that a range ending at the top of the 64-bit space cannot wrap the cursor.
    for (uint64_t begin = range_begin;; ) {
        const uint64_t end = (split == 0 || range_end - begin < split) ? range_end : begin + split - 1;
        const auto     get = BuildGet(host, server_port, path, begin, end);
        batch.text += get;
        batch.request_bytes.push_back(static_cast<uint32_t>(get.size()));
        if (end == range_end) {
            break;
        }
        begin = end + 1;
    }
}

std::vector<std::string> HTTPReadConfig::SplitRequests(const RequestBatch &batch) {
    size_t total = 0;
    for (const uint32_t n : batch.request_bytes) {
        total += n;
    }
    if (total != batch.text.size()) {
        throw std::runtime_error("HTTP request batch: request lengths add up to " +
                                 std::to_string(total) + " bytes but the text is " +
                                 std::to_string(batch.text.size()));
    }
    std::vector<std::string> out;
    size_t off = 0;
    for (const uint32_t n : batch.request_bytes) {
        out.push_back(batch.text.substr(off, n));
        off += n;
    }
    return out;
}

uint64_t HTTPReadConfig::EffectiveSplit(uint64_t split_cfg, uint64_t max_get) {
    if (max_get == 0) {
        return split_cfg;
    }
    if (split_cfg == 0) {
        return max_get;
    }
    return std::min(split_cfg, max_get);
}

uint64_t HTTPReadConfig::split_bytes() {
    return EffectiveSplit(ConfiguredChunkBytes(), toe_get_cap());
}

// Pad the batch's request text to a whole 64-byte beat, using a header the server ignores.
//
// Coyote's DMA moves whole beats, so a 2069-byte batch is transferred as 2112. The hardware
// discards the 43-byte tail (ST_DRAIN), but on a bitstream without that fix the tail stays at the
// head of the stream and becomes the NEXT batch's opening bytes -- the server then sees a request
// line prefixed with junk and answers 400. That is what makes build-101 unable to run any query
// touching more than one row group.
//
// Making the text itself a whole number of beats removes the tail entirely, so there is nothing to
// discard or to leak, on any bitstream. Unknown headers are ignored by definition, and MinIO was
// checked: padded requests of 128, 129, 165 and 328 bytes all answer 206.
//
// This is not a substitute for ST_DRAIN -- a short DMA or a resized buffer would reintroduce a tail
// and only the hardware can be sure of consuming it. It is the cheaper half of the same guarantee,
// and it is what lets a bitstream without the drain work at all.
void PadRequestTextToBeat(std::string &text) {
    constexpr size_t BEAT = 64;
    const size_t     rem  = text.size() % BEAT;
    if (rem == 0 || text.size() < 4) {
        return;
    }
    size_t needed = BEAT - rem;
    // "X-Pad: " + value + CRLF is 9 bytes of overhead, so anything under that has to round up to
    // the next beat rather than squeeze in.
    while (needed < 9) {
        needed += BEAT;
    }
    // Insert before the blank line that terminates the LAST request, so it stays a valid header.
    const size_t tail = text.rfind("\r\n\r\n");
    if (tail == std::string::npos) {
        return;
    }
    text.insert(tail + 2, "X-Pad: " + std::string(needed - 9, 'a') + "\r\n");
}

// Wait until the hardware can accept another config beat.
//
// THIS IS NOT OPTIONAL, and leaving it out is what made every multi-batch query fail.
// ConfigWriteReadyRegister does not back-pressure: a START written while the previous beat is still
// unconsumed OVERWRITES it, and that beat disappears with no error raised anywhere.
//
// The cost was invisible in the obvious places and glaring on the wire. An arm dropped this way
// means a whole batch's request text is never transmitted: a scale-30 supplier scan submitted three
// batches, sent two, and MinIO saw 46 requests where 69 were meant -- the missing batch's bytes
// simply absent from the byte stream. The query then waited forever for column bytes nobody had
// asked for.
//
// THE ORDER OF THE WRITES AROUND THIS CALL IS PART OF THE PROTOCOL.
//
// req_ready is combinational on the LIVE req_total_bytes register, because that field is what tells
// the hardware whether the pending beat is a chunk-length entry (zero) or a transfer arm (non-zero)
// -- and the two have different admission rules: an entry needs queue room, an arm needs the
// previous transfer to have finished sending. So the caller must write every parameter INCLUDING
// req_total_bytes, then poll, then pulse START. Polling first asks whether the PREVIOUS beat would
// be accepted, which is a different question and frequently the opposite answer: an arm polled
// while the registers still held an entry sees the entry's condition, passes, and is then refused
// and overwritten. That produced exactly the failures this check was added to prevent -- hangs when
// an arm was lost, and wrong ANSWERS when a chunk-length entry was, because a missing length merges
// two columns into one decoder stream and every value after the seam is shifted.
//
// An arm waits on the previous transfer draining, so this can legitimately block for as long as a
// batch takes to send. The timeout is the same 30 s used for the request ring: reaching it means
// the pipeline stopped, which is a diagnosis rather than a tuning knob.
//
// ONE register read per poll (id 17), because both admission bits and the fatal flag live in the
// same nibble -- see the atomicity note in handler_multi.sv.
//
// WHY THE FATAL CHECK COMES FIRST, and not after the ready test.
// ARM_READY is !stream_busy for the lane. A lane that was armed and then went fatal never finishes
// sending, so stream_busy stays high and ARM_READY stays LOW FOREVER. Polling it without looking at
// FATAL is therefore not "wait a bit longer", it is a guaranteed 30 s wait ending in a timeout
// message that describes a stalled pipeline rather than the dead lane that is actually the problem.
// The batch has to be reissued either way; the only question is whether the host finds that out now
// or in half a minute.
//
// The OR-folded req_ready bit (inflightWord[19]) answers about "the lane last addressed", which is
// only the right question when the beat about to be written names that same lane; the lane's own
// nibble always is.
void HTTPReadConfig::await_cfg_ready(const char *what, uint8_t lane, LaneAdmit admit) {
    const auto deadline = std::chrono::steady_clock::now() + HTTP_CREDIT_TIMEOUT;
    while (true) {
        const auto l = DecodeLanes(0, read_register(HTTP_LANE_READY).value(), lane_count()).at(lane);
        if (l.fatal) {
            throw_lane_fatal(lane, what);
        }
        if (l.ready_for(admit)) {
            return;
        }
        if (std::chrono::steady_clock::now() > deadline) {
            const auto state_word = read_register(HTTP_LANE_STATE).value();
            // The poll above reads the admission word only -- occupancy is a second register and
            // this path is the one place it is worth the read, because "refused an entry" and
            // "refused an entry with 64 responses outstanding" are different diagnoses.
            std::ostringstream msg;
            msg << "FPGA HTTP lane " << unsigned(lane) << " has refused a " << what << " for "
                << std::chrono::duration_cast<std::chrono::seconds>(HTTP_CREDIT_TIMEOUT).count()
                << "s [" << lanes().at(lane).describe() << "; "
                << DescribeLaneState(state_word, lane) << "; "
                << lane_errors().describe() << "; " << stall().describe()
                << "]. That lane has stopped draining.";
            throw std::runtime_error(msg.str());
        }
        std::this_thread::sleep_for(std::chrono::microseconds(20));
    }
}

// A fatal lane, explained rather than merely reported.
//
// The distinction the caller needs is not in the fatal bit, it is in LANE_ERR bit 0: the hardware
// tears a fatal lane's session down, which clears rx_dispatch's own dead flag, so without the sticky
// copy a head-of-line kill and an unreplayable read failure look identical from here -- and they ask
// for opposite things. A HOL kill dropped bytes out of the MIDDLE of a response that other lanes
// were being starved behind, and the batch is simply gone; a read error means this lane's request
// cannot be replayed by the hardware, and the host holds the only copy of the text.
void HTTPReadConfig::throw_lane_fatal(uint8_t lane, const char *what) {
    const auto errs       = lane_errors();
    const auto state_word = read_register(HTTP_LANE_STATE).value();
    const auto e          = errs.at(lane);

    std::ostringstream msg;
    msg << "FPGA HTTP lane " << unsigned(lane) << " is fatal while waiting for " << what << ": ";
    if (e.lane_dead) {
        msg << "the head-of-line watchdog in rx_dispatch declared it dead and discarded its packets, "
               "so bytes were lost out of the MIDDLE of a response. Nothing that arrived on this "
               "lane is usable -- the whole batch must be reissued. A lane is killed only after it "
               "has held the shared receive path for LANE_STALL_CYCLES (policy()), which means it "
               "stopped consuming: look at the decoder behind it, not at the network";
    } else {
        msg << "a read failed in a way the hardware cannot replay. Streamed request text is consumed "
               "as it is sent, so only the host still has it; the lane stays down until the host "
               "restarts it";
    }
    msg << " [" << e.describe() << "; " << DescribeLaneState(state_word, lane) << "; "
        << stall().describe() << "]";
    throw std::runtime_error(msg.str());
}

// Per-lane admission: wait until this lane can owe `needed` more responses.
//
// The shared queue in inflightWord cannot answer this once there are several lanes: its occupancy is
// the MAX over lanes, so a busy neighbour would block a batch for an idle lane, and a lane that has
// stopped draining would be invisible behind one that has not.
//
// `needed` above the limit is not made into an impossible wait. The limit is a HOST pipelining cap,
// while the hardware's real bound is the lane's queue (policy().queue_depth, and max_batch_chunks()
// is what submit_batch checks against); a batch larger than the cap is legal and simply gets the
// lane to itself.
void HTTPReadConfig::await_lane_credit(uint8_t lane, size_t needed) {
    const char *what = "a batch of chunk-length entries";
    if (needed == 0) {
        return;
    }

    const size_t limit    = std::max<size_t>(lane_depth_limit(), needed);
    const auto   deadline = std::chrono::steady_clock::now() + HTTP_CREDIT_TIMEOUT;
    while (true) {
        const auto l = lanes().at(lane);
        // Before the arithmetic: a dead lane never retires anything, so its occupancy never falls
        // and waiting on it is waiting forever.
        if (l.fatal) {
            throw_lane_fatal(lane, what);
        }
        if (LaneCreditOk(l.occ, needed, limit)) {
            return;
        }
        if (std::chrono::steady_clock::now() > deadline) {
            std::ostringstream msg;
            msg << "FPGA HTTP lane " << unsigned(lane) << " never freed room for " << needed
                << " more chunk entries (limit " << limit << ") for " << what << " within "
                << std::chrono::duration_cast<std::chrono::seconds>(HTTP_CREDIT_TIMEOUT).count()
                << "s [" << l.describe() << "; " << lane_errors().describe() << "; "
                << stall().describe() << "]. That lane has stopped draining.";
            throw std::runtime_error(msg.str());
        }
        std::this_thread::sleep_for(std::chrono::microseconds(20));
    }
}

// The three status digits strip_http captured, as text. CSR 12 (respWord) carries them as ASCII
// in bits [23:0]; the handler only kept a bad/good bit, so a failure said "not 200/206" without
// ever naming the code -- and 416 (range past EOF), 400 (malformed request) and 503 (server out of
// resources) each mean something completely different about who is at fault.
std::string HTTPReadConfig::last_http_status() {
    const uint32_t w = static_cast<uint32_t>(read_register(HTTP_RESP).value());
    const char d[3] = {static_cast<char>((w >> 16) & 0xFF), static_cast<char>((w >> 8) & 0xFF),
                       static_cast<char>(w & 0xFF)};
    for (const char c : d) {
        if (c < '0' || c > '9') {
            return "unparsed";
        }
    }
    return std::string(d, 3);
}

void HTTPReadConfig::submit_batch(uint32_t server_ip, uint16_t server_port,
                                  const RequestBatch &batch, uint8_t lane) {
    if (batch.chunk_bytes.empty()) {
        return;
    }
    // Revision 6 refuses for its own reason: the GET credit counts ARMS (+1 per arm, -1 per framed
    // response), so one arm announcing two GETs is charged once and retired twice -- the credit then
    // admits more responses than the TOE ring may hold unread, and the window rule is gone.
    if (toe_ring() && batch.request_bytes.size() > 1) {
        std::ostringstream msg;
        msg << "HTTP batch of " << batch.request_bytes.size() << " GETs cannot be submitted as one "
            << "arm on a CSR revision-6 (TOE receive ring) bitstream: the GET credit counts one GET "
            << "per arm, so every GET needs its own arm. Use push_entries() + arm_transfer() per "
            << "request (HTTPBatchSourceOperator does).";
        throw std::runtime_error(msg.str());
    }
    push_entries(batch, lane);
    arm_transfer(server_ip, server_port, static_cast<uint32_t>(batch.text.size()), lane);

    if (http_debug_enabled()) {
        // Print the handler's state with EVERY batch, not just the sizes.
        //
        // The state registers cannot be read while a query is stuck: that query holds vfid 0, so a
        // second process cannot attach, and a process blocked in the driver often cannot be killed
        // to release it. scripts/util/http_state.sh therefore returns nothing in exactly the case
        // it exists for. Printing here means the LAST line before a hang carries the state going
        // into the batch that hung, which is the reading that was otherwise unobtainable.
        const auto f = inflight();
        const auto st = stall();
        std::fprintf(stderr,
                     "[oasis-http] batch: lane %u, %zu column chunks, %zu bytes of request text | "
                     "%s | %s\n",
                     unsigned(lane), batch.chunk_bytes.size(), batch.text.size(),
                     f.describe().c_str(), st.any() ? st.describe().c_str() : "no stalls");
        std::fprintf(stderr, "[oasis-http]   %s\n", lanes().describe().c_str());
        // Name the status the moment it goes bad. It is a live register, so it must be read while
        // the failure is on the board -- by the time the run ends it may have been overwritten.
        if (st.status_bad) {
            std::fprintf(stderr, "[oasis-http]   HTTP status from the server: %s\n",
                         last_http_status().c_str());
        }
    }
}

void HTTPReadConfig::push_entries(const RequestBatch &batch, uint8_t lane) {
    if (batch.chunk_bytes.empty()) {
        return;
    }
    // The caller must have split to the queue depth already -- see max_batch_chunks(). Pushing more
    // entries than the queue holds deadlocks rather than back-pressuring: the host blocks on
    // req_ready waiting for the queue to drain, and it cannot drain because the arm that starts the
    // transfer comes AFTER the entries.
    if (batch.chunk_bytes.size() > max_batch_chunks()) {
        std::ostringstream msg;
        msg << "HTTP batch of " << batch.chunk_bytes.size() << " column chunks exceeds the hardware "
            << "queue (" << max_batch_chunks() << "); it must be split, or the entries deadlock "
            << "against the arm";
        throw std::runtime_error(msg.str());
    }
    // Reserve room for the whole batch BEFORE pushing any of it. Without this the loop below can
    // fill the queue mid-batch and hang with the arm never issued: the remaining entries wait for
    // space, space is freed only by responses, and responses need the arm.
    await_lane_credit(lane, batch.chunk_bytes.size());

    // The lane, on EVERY beat of this batch. handler_multi takes cfg_lane from req_chunk_dest --
    // bits [35:32] of the chunk-length register -- for entries AND for the arm, so it is not
    // per-chunk metadata, it is the address the beat is delivered to.
    const uint64_t lane_field = static_cast<uint64_t>(lane & 0xF) << 32;

    // 1. One queue entry per expected response, carrying only its body_last bit. req_total_bytes
    //    stays 0 on these beats, which is what tells the hardware they are entries and not an arm.
    for (const uint32_t bytes : batch.chunk_bytes) {
        // PARAMETERS FIRST, THEN POLL, THEN TRIGGER. req_ready is combinational on the LIVE value
        // of req_total_bytes, so polling before writing it asks whether the PREVIOUS beat would be
        // accepted. See await_cfg_ready.
        // The lane rides in bits [35:32] of the 64-bit chunk-length register. It MUST be the lane
        // whose decoder the chunk's configuration was enqueued on, or the bytes reach a decoder
        // expecting a different column. There is no register-map change here on purpose: moving
        // anything in that map shifts every later parameter silently.
        write_register(
            libstf::ConfigRegister(HTTP_REQ_CHUNK_BYTES, static_cast<uint64_t>(bytes) | lane_field));
        write_register(libstf::ConfigRegister(HTTP_REQ_TOTAL_BYTES, 0u));
        await_cfg_ready("chunk-length entry", lane, LaneAdmit::Entry);
        write_register(libstf::ConfigRegister(HTTP_START, 1));
    }
}

void HTTPReadConfig::arm_transfer(uint32_t server_ip, uint16_t server_port, uint32_t text_bytes,
                                  uint8_t lane) {
    const uint64_t lane_field = static_cast<uint64_t>(lane & 0xF) << 32;

    // 2. The arm: server address plus the byte count, which is what opens the connection.
    //    The length announced here is the PADDED one -- see PadRequestTextToBeat.
    write_register(libstf::ConfigRegister(HTTP_SERVER_IP, server_ip));
    write_register(libstf::ConfigRegister(HTTP_SERVER_PORT, server_port));
    // THE ARM NAMES ITS OWN LANE. This write is not new to the protocol -- the register and the
    // field are the ones the entries above use -- but until now the arm did not perform it, so it
    // was routed by whatever the LAST ENTRY happened to leave behind. That is correct only while
    // every batch pushes at least one entry immediately before its arm and both belong to the same
    // lane: it is ambient state standing in for an address. A batch whose entries were admitted on
    // one lane and whose arm followed another lane's beat would open the wrong connection and send
    // this lane's request text down it.
    //
    // The low 32 bits are the chunk length, which an arm beat does not use: handler_multi pushes the
    // chunk queue only when req_total_bytes == 0, and this beat is about to set it non-zero.
    write_register(libstf::ConfigRegister(HTTP_REQ_CHUNK_BYTES, lane_field));
    write_register(
        libstf::ConfigRegister(HTTP_REQ_TOTAL_BYTES, static_cast<uint64_t>(text_bytes)));
    // Only now does req_ready describe an ARM. Before this write it still described whatever the
    // last beat was, and an arm polled against an entry's condition gets written into a refusal.
    // On a revision-6 bitstream the same bit also carries the lane's GET credit, so this is where a
    // lane's (GET_CREDIT+1)-th GET waits for its oldest response to be framed.
    await_cfg_ready("transfer arm", lane, LaneAdmit::Arm);
    write_register(libstf::ConfigRegister(HTTP_START, 1));
}

// Revision 6: wait until the arm just written has been TAKEN, i.e. ARM_READY for the lane has fallen.
//
// ConfigWriteReadyRegister does not back-pressure and HttpConfig hands the handler the LIVE register
// values, not a snapshot taken at the START write. So until the handler has consumed this arm, the
// next register write -- the next GET's arm, or the next flow's chunk entry -- rewrites what this arm
// means. await_cfg_ready() cannot see that: it polled ARM_READY BEFORE the START.
//
// ARM_READY falling is the proof: it is !stream_busy && gets_out < GET_CREDIT, it was polled HIGH
// before the START, and taking the arm makes the lane's request stream busy until its text has been
// sent -- text this thread sends only after this returns. So the fall cannot be missed between polls
// (gets_out reaching the credit is equally proof). Nothing but a release lowers gets_out, and a
// release does not clear stream_busy. Two reads per poll (16, 17).
void HTTPReadConfig::await_arm_taken(uint8_t lane) {
    const auto start = std::chrono::steady_clock::now();
    while (true) {
        const auto l = lanes().at(lane);
        if (!l.arm_ready) {
            return;
        }
        if (l.fatal) {
            throw_lane_fatal(lane, "its arm to be taken");
        }
        if (std::chrono::steady_clock::now() - start > HTTP_CREDIT_TIMEOUT) {
            std::ostringstream msg;
            msg << "FPGA HTTP lane " << unsigned(lane) << " (CSR revision 6): an arm was written but "
                << "ARM_READY never fell, i.e. the handler did not take it [" << lanes().describe()
                << "; " << lane_errors().describe() << "; " << stall().describe() << "]";
            throw std::runtime_error(msg.str());
        }
        std::this_thread::sleep_for(std::chrono::microseconds(2));
    }
}

// Mirrors the totalWord layout in hardware/src/hdl/http_read/handler_multi.sv (and handler_toe.sv).
// The 4-bit client_state CSR multiplexes several sub-FSMs onto one value (2, 6, 9 and 10 each alias
// two states), so only this packed word can say which stage is actually stuck.
std::string HTTPReadConfig::describe_status(uint32_t status) {
    static const char *handler_states[] = {"IDLE", "CONNECT", "SEND", "READ", "RECONNECT"};
    const auto top = status & 0xFu;

    std::ostringstream oss;
    oss << "handler=" << (top < 5 ? handler_states[top] : "?") << "(" << top << ")"
        << " init=" << ((status >> 4) & 0xFu) << " send=" << ((status >> 8) & 0xFu)
        << " read=" << ((status >> 12) & 0xFu) << " | done i/s/r=" << ((status >> 16) & 1u) << "/"
        << ((status >> 18) & 1u) << "/" << ((status >> 20) & 1u)
        << " err i/s/r=" << ((status >> 17) & 1u) << "/" << ((status >> 19) & 1u) << "/"
        << ((status >> 21) & 1u) << " busy=" << ((status >> 22) & 1u)
        << " sid=" << ((status >> 24) & 0xFFu);
    return oss.str();
}

HTTPReadConfig::HTTPInflight HTTPReadConfig::inflight() {
    const auto word = static_cast<uint32_t>(read_register(HTTP_INFLIGHT).value());
    HTTPInflight f {};
    f.occupied    = static_cast<uint8_t>(word & 0xFFu);
    f.slots       = static_cast<uint8_t>((word >> 8) & 0xFFu);
    f.has_pending = (word & (1u << 16)) != 0;
    f.peer_closed = (word & (1u << 17)) != 0;
    f.conn_up     = (word & (1u << 18)) != 0;
    // [31:24] is the CSR revision, and it is the ENTIRE compatibility scheme between this library
    // and a programmed bitstream. It is deliberately NOT normalised: 0 means "the per-lane registers
    // are not there and reading them is a bus error", which is a fact to act on rather than a
    // missing value to paper over.
    f.revision    = static_cast<uint8_t>((word >> 24) & 0xFFu);
    return f;
}

uint8_t HTTPReadConfig::lane_count() {
    // LANE_POLICY carries NUM_CONNS untruncated (inflightWord[23:20] is four bits). The per-lane
    // registers reach HTTP_LANE_SLOTS lanes, so a bitstream with more cannot be metered.
    if (lane_count_ == 0) {
        const auto conns = policy().num_conns;
        if (conns == 0 || conns > HTTP_LANE_SLOTS) {
            throw std::runtime_error("FPGA HTTP handler reports " + std::to_string(conns) +
                                     " lanes (LANE_POLICY); this library drives 1 to " +
                                     std::to_string(HTTP_LANE_SLOTS));
        }
        lane_count_ = conns;
    }
    return lane_count_;
}

void HTTPReadConfig::CheckRevision(uint8_t revision) {
    if (revision == HTTP_CSR_REVISION_MULTI || revision == HTTP_CSR_REVISION_TOE) {
        return;
    }
    std::ostringstream msg;
    msg << "FPGA HTTP handler reports CSR revision " << unsigned(revision) << " (inflightWord[31:24]); "
        << "this liboasis drives revisions 2 (handler_multi) and 6 (handler_toe). Program a matching "
           "bitstream, or install the host library built for this one.";
    throw std::runtime_error(msg.str());
}

uint8_t HTTPReadConfig::revision() {
    // Read once, and before anything touches read ids 16..20: below revision 2 those reads are a
    // resp_error rather than a zero.
    if (revision_ == 0) {
        const uint8_t raw = inflight().revision;
        CheckRevision(raw);
        revision_ = raw;
    }
    return revision_;
}

uint8_t HTTPReadConfig::lane_for_stream(libstf::stream_t stream) {
    const uint8_t lanes = lane_count();
    // See the header: on handler_multi this field is the LANE (which owns the decoder too), on the
    // single-session handler it is the DECODER index and folding it to 0 would send every column's
    // bytes to decoder 0.
    return (lanes > 1) ? static_cast<uint8_t>(static_cast<uint32_t>(stream) % lanes)
                       : static_cast<uint8_t>(static_cast<uint32_t>(stream) & 0xFu);
}

HTTPReadConfig::HTTPLanes HTTPReadConfig::DecodeLanes(uint64_t occ_word, uint64_t ready_word,
                                                     uint8_t count) {
    HTTPLanes l {};
    l.count = (count > HTTP_LANE_SLOTS) ? HTTP_LANE_SLOTS : count;
    for (uint8_t i = 0; i < l.count; i++) {
        const auto nib   = static_cast<unsigned>((ready_word >> (4u * i)) & 0xFu);
        l.lane[i].occ    = static_cast<uint8_t>((occ_word >> (8u * i)) & 0xFFu);
        l.lane[i].arm_ready   = (nib & (1u << HTTP_LANE_ARM_READY)) != 0;
        l.lane[i].entry_ready = (nib & (1u << HTTP_LANE_ENTRY_READY)) != 0;
        l.lane[i].conn_up     = (nib & (1u << HTTP_LANE_CONN_UP)) != 0;
        l.lane[i].fatal       = (nib & (1u << HTTP_LANE_FATAL)) != 0;
    }
    return l;
}

HTTPReadConfig::HTTPLaneErrors HTTPReadConfig::DecodeLaneErrors(uint64_t err_word, uint8_t count) {
    HTTPLaneErrors e {};
    e.count = (count > HTTP_LANE_SLOTS) ? HTTP_LANE_SLOTS : count;
    for (uint8_t i = 0; i < e.count; i++) {
        const auto byte  = static_cast<uint8_t>((err_word >> (8u * i)) & 0xFFu);
        e.lane[i].raw           = byte;
        e.lane[i].lane_dead     = (byte & (1u << 0)) != 0;
        e.lane[i].dirty         = (byte & (1u << 1)) != 0;
        e.lane[i].init_err      = (byte & (1u << 2)) != 0;
        e.lane[i].resp_err      = (byte & (1u << 3)) != 0;
        e.lane[i].status_bad    = (byte & (1u << 4)) != 0;
        e.lane[i].tx_refused    = (byte & (1u << 5)) != 0;
        e.lane[i].read_timeout  = (byte & (1u << 6)) != 0;
        e.lane[i].rx_fifo_stall = (byte & (1u << 7)) != 0;
    }
    return e;
}

HTTPReadConfig::HTTPLanePolicy HTTPReadConfig::DecodePolicy(uint64_t policy_word) {
    HTTPLanePolicy p {};
    p.revision          = static_cast<uint8_t>(policy_word & 0xFFu);
    p.num_conns         = static_cast<uint8_t>((policy_word >> 8) & 0xFFu);
    p.queue_depth       = static_cast<uint16_t>((policy_word >> 16) & 0xFFFFu);
    if (p.revision == HTTP_CSR_REVISION_TOE) {
        // handler_toe: {2'd0, 6'(RING_LOG2), 24'(GET_CREDIT), QDEPTH, NUM_CONNS, 8'd6}. There is no
        // head-of-line watchdog to report, so the stall fields stay 0 rather than misreport.
        p.get_credit = static_cast<uint32_t>((policy_word >> 32) & 0xFFFFFFu);
        p.ring_log2  = static_cast<uint8_t>((policy_word >> 56) & 0x3Fu);
        return p;
    }
    p.lane_stall_cycles = static_cast<uint32_t>((policy_word >> 32) & 0xFFFFFFu);
    p.lane_stall_log2   = static_cast<uint8_t>((policy_word >> 56) & 0x3Fu);
    return p;
}

HTTPReadConfig::HTTPLanes HTTPReadConfig::lanes() {
    // TWO reads, and the admission bits come out of ONE of them on purpose -- both are monotone in
    // the host's favour, so a nibble read here is still true when the write it admits lands.
    const auto occ   = read_register(HTTP_LANE_OCC).value();
    const auto ready = read_register(HTTP_LANE_READY).value();
    return DecodeLanes(occ, ready, lane_count());
}

HTTPReadConfig::HTTPLaneErrors HTTPReadConfig::lane_errors() {
    return DecodeLaneErrors(read_register(HTTP_LANE_ERR).value(), lane_count());
}

HTTPReadConfig::HTTPLanePolicy HTTPReadConfig::policy() {
    return DecodePolicy(read_register(HTTP_LANE_POLICY).value());
}

size_t HTTPReadConfig::lane_depth_limit() {
    if (lane_depth_ != 0) {
        return lane_depth_;
    }
    const size_t hw      = max_batch_chunks();
    const bool   env_set = std::getenv("OASIS_HTTP_LANE_DEPTH") != nullptr &&
                           *std::getenv("OASIS_HTTP_LANE_DEPTH") != '\0';
    const size_t want    = static_cast<size_t>(EnvOr("OASIS_HTTP_LANE_DEPTH", HTTP_DEFAULT_LANE_DEPTH));
    // Revision 6: never more chunks queued per lane than the hardware holds GETs (every chunk is at
    // least one GET). Chunks split into several GETs can still exceed the credit; their later arms
    // then wait for earlier responses (emit_one_get_per_arm in operator.cpp).
    const size_t credit  = toe_ring() ? static_cast<size_t>(policy().get_credit) : 0;
    if (toe_ring() && credit == 0) {
        throw std::runtime_error("FPGA reports CSR revision 6 (TOE receive ring) but LANE_POLICY "
                                 "carries GET_CREDIT 0 [" + policy().describe() + "]");
    }
    lane_depth_          = LaneDepthFor(want, hw, credit);
    if (toe_ring()) {
        char line[320];
        std::snprintf(line, sizeof(line),
                      "HTTPReadConfig: CSR revision 6 (TOE receive rings, revision-2 register map): "
                      "%u lane(s), lane depth %zu%s, one GET per arm, GET credit %zu per lane, "
                      "GETs capped at %llu B (split %llu B)",
                      unsigned(lane_count()), lane_depth_,
                      env_set ? " (OASIS_HTTP_LANE_DEPTH)" : " (default)", credit,
                      static_cast<unsigned long long>(toe_get_cap()),
                      static_cast<unsigned long long>(split_bytes()));
        std::fprintf(stderr, "[oasis-http] %s\n", line);
        libstf::log(libstf::LogLevel::INFO, "%s", line);
        if (want > lane_depth_ && env_set) {
            libstf::log(libstf::LogLevel::WARNING,
                        "HTTPReadConfig: OASIS_HTTP_LANE_DEPTH=%zu clamped to %zu on a CSR revision-6 "
                        "bitstream (GET credit %zu, queue %zu)", want, lane_depth_, credit, hw);
        }
    }
    return lane_depth_;
}

size_t HTTPReadConfig::LaneDepthFor(size_t want, size_t hw, size_t get_credit) {
    if (get_credit != 0) {
        // Revision 6 (the GET credit). Every column chunk is at least one GET, and the
        // hardware holds at most GET_CREDIT unfinished GETs per lane, so a deeper host queue would only
        // admit flows whose first arm then waits on the dispatcher thread.
        hw = std::min(hw, get_credit);
    }
    return std::max<size_t>(1, std::min(want, hw));
}

bool HTTPReadConfig::LaneCreditOk(size_t occ, size_t needed, size_t limit) {
    return occ + needed <= limit;
}


// ---- CSR revision 6 -------------------------------------------------------------------------------

uint64_t HTTPReadConfig::ToeGetCap(uint8_t ring_log2, uint32_t get_credit) {
    // 17: a ring of 128 KiB is the smallest that leaves anything after the 64 KiB slack and one 4 KiB
    // header; 30: 1 GiB, far past any TOE (WINDOW_BITS is 20). Outside that the word is garbage.
    if (get_credit == 0 || ring_log2 < 17 || ring_log2 > 30) {
        return 0;
    }
    const uint64_t budget  = (1ULL << ring_log2) - HTTP_TOE_RING_SLACK;
    const uint64_t per_get = budget / get_credit;
    return per_get > HTTP_TOE_GET_OVERHEAD ? per_get - HTTP_TOE_GET_OVERHEAD : 0;
}

uint64_t HTTPReadConfig::toe_get_cap() {
    if (!toe_ring()) {
        return 0;
    }
    if (toe_cap_ == 0) {
        const auto p   = policy();
        const auto cap = p.toe() ? ToeGetCap(p.ring_log2, p.get_credit) : 0;
        if (cap == 0) {
            // A GET size guessed here could close a lane's TOE window for good (the TOE never sends
            // a window update on reads), so refuse outright.
            throw std::runtime_error("FPGA reports CSR revision 6 (TOE receive ring) but its "
                                     "LANE_POLICY word gives no usable GET cap [" + p.describe() + "]");
        }
        toe_cap_ = cap;
    }
    return toe_cap_;
}

const HTTPReadConfig::HTTPLane &HTTPReadConfig::HTTPLanes::at(uint8_t l) const {
    if (l >= count) {
        std::ostringstream msg;
        msg << "HTTP lane " << unsigned(l) << " does not exist: this bitstream has "
            << unsigned(count) << " lane(s)";
        throw std::out_of_range(msg.str());
    }
    return lane[l];
}

const HTTPReadConfig::HTTPLaneError &HTTPReadConfig::HTTPLaneErrors::at(uint8_t l) const {
    if (l >= count) {
        std::ostringstream msg;
        msg << "HTTP lane " << unsigned(l) << " does not exist: this bitstream has "
            << unsigned(count) << " lane(s)";
        throw std::out_of_range(msg.str());
    }
    return lane[l];
}

std::string HTTPReadConfig::HTTPLane::describe() const {
    std::ostringstream oss;
    oss << "occ=" << unsigned(occ) << (conn_up ? " conn=up" : " conn=down")
        << (arm_ready ? " arm" : "") << (entry_ready ? " entry" : "") << (fatal ? " FATAL" : "");
    return oss.str();
}

std::string HTTPReadConfig::HTTPLanes::describe() const {
    std::ostringstream oss;
    oss << "lanes=" << unsigned(count);
    for (uint8_t i = 0; i < count; i++) {
        oss << " [" << unsigned(i) << ": " << lane[i].describe() << "]";
    }
    return oss.str();
}

std::string HTTPReadConfig::HTTPLaneError::describe() const {
    if (!any()) {
        return "no sticky errors";
    }
    std::ostringstream oss;
    oss << "errors:";
    if (lane_dead)     oss << " lane_dead";
    if (dirty)         oss << " dirty";
    if (init_err)      oss << " init_err";
    if (resp_err)      oss << " resp_err";
    if (status_bad)    oss << " status_bad";
    if (tx_refused)    oss << " tx_refused";
    if (read_timeout)  oss << " read_timeout";
    if (rx_fifo_stall) oss << " rx_fifo_stall";
    return oss.str();
}

std::string HTTPReadConfig::HTTPLaneErrors::describe() const {
    std::ostringstream oss;
    oss << "lane errors:";
    bool any_set = false;
    for (uint8_t i = 0; i < count; i++) {
        if (lane[i].any()) {
            any_set = true;
            oss << " [" << unsigned(i) << ": " << lane[i].describe() << "]";
        }
    }
    if (!any_set) {
        oss << " none";
    }
    return oss.str();
}

std::string HTTPReadConfig::HTTPLanePolicy::describe() const {
    std::ostringstream oss;
    if (toe()) {
        oss << "policy: rev=" << unsigned(revision) << " (TOE receive rings) lanes="
            << unsigned(num_conns) << " queue_depth=" << unsigned(queue_depth)
            << " get_credit=" << get_credit << " ring=2^" << unsigned(ring_log2)
            << " B -> GET cap " << ToeGetCap(ring_log2, get_credit) << " B";
        return oss.str();
    }
    oss << "policy: rev=" << unsigned(revision) << " lanes=" << unsigned(num_conns)
        << " queue_depth=" << unsigned(queue_depth) << " lane_stall_cycles=" << lane_stall_cycles
        << " (2^" << unsigned(lane_stall_log2) << ")";
    return oss.str();
}

std::string HTTPReadConfig::HTTPInflight::describe() const {
    std::ostringstream oss;
    oss << "inflight=" << static_cast<unsigned>(occupied) << "/" << static_cast<unsigned>(slots)
        << " conn=" << (conn_up ? "up" : "down") << (has_pending ? " pending" : "")
        << (peer_closed ? " peer-closed" : "") << " rev=" << static_cast<unsigned>(revision);
    return oss.str();
}

HTTPReadConfig::HTTPStall HTTPReadConfig::stall() {
    return DecodeStall(static_cast<uint32_t>(read_register(HTTP_STALL).value()), toe_ring());
}

HTTPReadConfig::HTTPStall HTTPReadConfig::DecodeStall(uint32_t word, bool toe_ring) {
    HTTPStall s {};
    s.raw              = word;
    s.connect_stalled  = (word & (1u << 0)) != 0;
    s.init_error       = (word & (1u << 3)) != 0;
    s.send_error       = (word & (1u << 4)) != 0;
    s.resp_unframeable = (word & (1u << 5)) != 0;
    s.dirty_abort      = (word & (1u << 6)) != 0;
    s.status_bad       = (word & (1u << 7)) != 0;
    s.reconnects       = static_cast<uint8_t>((word >> 8) & 0xFFu);
    // Bit 24: the announcement queue's overflow on revision 2; toe_rx's ORed contract errors
    // (order_err | len_err | budget_err) on revision 6. Exactly one of the two is decoded.
    s.toe              = toe_ring;
    s.notify_overflow  = !toe_ring && (word & (1u << 24)) != 0;
    s.toe_rx_err       = toe_ring && (word & (1u << 24)) != 0;
    s.rx_fifo_stall    = (word & (1u << 25)) != 0;
    s.read_timeout     = (word & (1u << 26)) != 0;
    s.align_starved    = (word & (1u << 27)) != 0;
    s.route_stall      = (word & (1u << 28)) != 0;
    return s;
}

std::string HTTPReadConfig::HTTPStall::describe() const {
    std::ostringstream oss;
    if (!any()) {
        oss << "no stage stall reported";
        if (reconnects) oss << " (" << static_cast<unsigned>(reconnects) << " reconnect(s))";
        return oss.str();
    }
    oss << "stalled:";
    if (connect_stalled)  oss << " CONNECT";
    if (init_error)       oss << " init_error";
    if (send_error)       oss << " send_error";
    if (resp_unframeable) oss << " unframeable_response";
    if (dirty_abort)      oss << " dirty_abort";
    if (status_bad)       oss << " bad_http_status";
    if (notify_overflow)  oss << " notify_overflow";
    if (toe_rx_err)       oss << " toe_rx_err(order|len|budget)";
    if (rx_fifo_stall)    oss << " rx_fifo_stall";
    if (read_timeout)     oss << " read_timeout";
    if (align_starved)    oss << " align_starved";
    if (route_stall)      oss << " route_stall";
    if (reconnects)       oss << " reconnects=" << static_cast<unsigned>(reconnects);

    // One explanation per line. These are sticky bits and several latch together over a long query,
    // so run as prose they produce a paragraph in which every sentence contradicts the next -- a
    // connect-stall essay attached to a run whose connection is up, wrapped around the one line that
    // actually mattered. Newline-separated, the reader can see which conditions are present at all.
    if (read_timeout) {
        oss << "\n    read_timeout: a read waited ~2 s with nothing arriving and gave up. The most "
               "likely cause is a reconnect: the announcement the reader was waiting on belonged to "
               "the session that just closed, so it could never arrive. Before the watchdog existed "
               "this hung until the host's credit timeout and left the handler out of ST_IDLE, which "
               "only reprogramming clears. Now it aborts and the handler replays the request.";
    }
    if (send_error) {
        oss << "\n    send_error: the TOE refused to reserve tx buffer room for a request. Sticky, "
               "and NOT a lost request -- the handler skips the data beats and re-sends, because "
               "nothing went out. It means requests are being queued faster than the tx path drains "
               "them, which only becomes possible once they are issued back to back. If this is set "
               "and throughput is fine, ignore it; if it is set and the run is slow, the request "
               "ring is deeper than the tx path can absorb.";
    }
    if (align_starved) {
        oss << "\n    align_starved: body bytes arrived with no column-chunk length configured, so "
               "the hardware could not tell where one decoder stream ends. The host queued fewer "
               "chunk lengths than the responses it asked for. Two columns would be concatenated "
               "into one stream, which corrupts silently rather than failing -- treat any result "
               "from this run as suspect.";
    }
    if (rx_fifo_stall && toe) {
        oss << "\n    rx_fifo_stall (revision 6): a lane's decoupling fifo REFUSED a beat it was "
               "offered (axis_fifo overflow_stall, sticky). A slow decoder is not the cause: then "
               "toe_rx simply stops asking for that lane's bytes, which leaves them in its own TOE "
               "ring and raises nothing. A refusal means toe_rx's exact reservation was wrong -- the "
               "lane-level twin of route_stall; LANE_ERR bit 7 names the lane.";
    }
    if (rx_fifo_stall && !toe) {
        oss << "\n    rx_fifo_stall: the fifo between the TCP stack and the HTTP parser filled, so "
               "the parser back-pressured the TOE after all. Results stay correct -- the TOE's "
               "receive fifo is overrun and recovered by retransmission -- but the decoupling is "
               "defeated and throughput suffers. This says the PARSER is not draining fast enough; "
               "it says nothing about how big either fifo is, and no register reports that. The "
               "TOE's is 1 << WINDOW_BITS, which differs per bitstream (256 KiB up to build-96, "
               "1 MiB from build-97) -- read it off the wire instead, as the window the FPGA "
               "advertises in its ACKs. Either lower OASIS_HTTP_CHUNK_BYTES or raise RX_FIFO_DEPTH "
               "in hardware/src/hdl/http_read/tcp_read.sv (needs a resynthesis).";
    }
    if (route_stall && toe) {
        oss << "\n    route_stall (revision 6): toe_rx routed a beat to a lane that refused it. toe_rx "
               "asks for a lane's bytes only after that lane's fifo has promised room for all of them "
               "(exact reservation), so this says the reservation arithmetic is wrong -- a hardware "
               "bug, not a traffic condition.";
    }
    if (route_stall && !toe) {
        oss << "\n    route_stall: rx_dispatch offered a beat to a lane that then refused it, so "
               "that lane's fifo had filled despite the conn_space_ok check whose entire job is to "
               "stop exactly that. The shared receive path is being held by one lane again, which is "
               "what the dispatcher exists to prevent -- so the other lanes are starving behind it. "
               "Either the space check is wrong or that lane's RX_FIFO_DEPTH is too small for its "
               "traffic. lane_errors() says which lane: it is the one with rx_fifo_stall set.";
    }

    if (resp_unframeable) {
        oss << "\n    unframeable: a response arrived with no Content-Length, so the hardware could not tell where "
               "its body ends and the next response begins, and stopped rather than guessing. On a "
               "ranged GET of a static object that should be impossible -- check whether the server "
               "answered with Transfer-Encoding: chunked, or whether the reply was an error page";
    }
    if (dirty_abort) {
        oss << ". The connection died with work outstanding and the hardware could not recover it. "
               "Either body bytes had already reached the decoder -- those cannot be unsent, so "
               "replaying would duplicate them in a column -- or a column chunk was still owed "
               "bytes, and the requests that would have supplied them were STREAMED, so the "
               "hardware has no copy to re-send. Reconnecting in that state answers nothing and "
               "used to spin, opening and closing a connection per attempt until the TOE's 512 "
               "ephemeral ports ran out; it now stops here instead. The host still holds the "
               "request text, so a retry has to come from there. Reprogram to clear";
    }
    if (status_bad) {
        oss << ". The server answered something other than 200/206, so whatever reached the decoder "
               "is an error document, not column data. The three digits are in CSR 12 bits [23:0] "
               "as ASCII -- HTTPReadConfig::last_http_status() decodes them. 416 means a range past "
               "end of file (a metadata/offset bug on our side), 400 a malformed request (request "
               "text corruption), 5xx the server itself";
    }
    if (toe_rx_err) {
        oss << "\n    toe_rx_err (revision 6, STALL[24], sticky): toe_rx saw one of three conditions "
               "the readback ORs together -- order_err (rx data or metadata with no readPkg "
               "outstanding, or naming another session: the TOE broke its contract), len_err (a "
               "packet's tlast not on the beat its readPkg length implies), or budget_err (a lane's "
               "notified-but-unread ring bytes passed 2^RING_LOG2 - 64 KiB: the window rule was "
               "broken -- a GET above the cap, more than GET_CREDIT outstanding, or an origin that "
               "ignored Range and sent more than was asked). A budget_err lane's TOE window may close "
               "for good. Only the RTL or an ILA tells the three apart.";
    }
    if (notify_overflow) {
        oss << ". The announcement queue overflowed, so segments the TOE announced were dropped and "
               "that response is permanently short. This should be unreachable (NOTIFY_DEPTH in "
               "rx_dispatch.sv vs the shared rx fifo); if it fires, the reader is not draining";
    }

    // The one failure mode worth naming outright, because nothing else in the system points at it.
    if (connect_stalled && !init_error) {
        oss << "\n    connect_stalled: openStatus never arrived at all: "
               "most likely the TOE reused an ephemeral port (it has 512, at 32768..33279, released "
               "with no quiet time) while the server still held that 4-tuple in TIME_WAIT, and is "
               "now retrying the SYN forever. Connections are cumulative since the bitstream was "
               "programmed, not per process. Keep-alive is what makes this rare -- a whole query now "
               "costs one connection -- so a high reconnect count next to this is the thing to chase";
    }
    return oss.str();
}

HTTPReadConfig::HTTPResponse HTTPReadConfig::response() {
    const auto word = static_cast<uint32_t>(read_register(HTTP_RESP).value());
    HTTPResponse r {};
    for (int i = 0; i < 3; i++) {
        const auto c = static_cast<char>((word >> (8 * (2 - i))) & 0xFFu);
        r.status[i]  = (c >= 0x20 && c < 0x7F) ? c : '?';
    }
    r.status_ok      = (word & (1u << 24)) != 0;
    r.unframeable    = (word & (1u << 25)) != 0;
    r.dirty          = (word & (1u << 26)) != 0;
    r.body_remaining = static_cast<uint32_t>(read_register(HTTP_BODY_REMAINING).value());
    r.content_length = static_cast<uint32_t>(read_register(HTTP_CONTENT_LENGTH).value());
    return r;
}

std::string HTTPReadConfig::HTTPResponse::describe() const {
    std::ostringstream oss;
    oss << "last response: status=" << std::string(status, 3) << (status_ok ? " (ok)" : " (NOT ok)")
        << " Content-Length=" << content_length << " body_remaining=" << body_remaining;
    if (unframeable) oss << " UNFRAMEABLE(no Content-Length)";
    if (dirty)       oss << " partially-delivered";
    return oss.str();
}

uint8_t HTTPReadConfig::max_inflight() {
    // 0 and anything at or above the queue depth mean the whole queue.
    const uint8_t  slots      = inflight().slots;
    const uint64_t configured = EnvOr("OASIS_HTTP_MAX_INFLIGHT", HTTP_DEFAULT_MAX_INFLIGHT);
    return (configured == 0 || configured >= slots) ? slots : static_cast<uint8_t>(configured);
}

std::string HTTPReadConfig::debug_dump() {
    std::ostringstream o;
    const auto hex = [](uint64_t v) {
        std::ostringstream h;
        h << "0x" << std::hex << std::setw(16) << std::setfill('0') << v;
        return h.str();
    };
    const int last = int(HTTP_LANE_POLICY);
    o << "HTTP CSR dump (revision " << unsigned(revision())
      << (toe_ring() ? ", TOE receive rings, revision-2 register map" : "") << ", read ids 0.."
      << last << "):\n";
    std::vector<uint64_t> w(static_cast<size_t>(last) + 1, 0);
    for (int i = 0; i <= last; i++) {
        w[i] = read_register(static_cast<uint32_t>(i)).value();
        o << "  [" << std::setw(2) << i << "] " << hex(w[i]) << "\n";
    }
    o << "  status(2):   " << describe_status(static_cast<uint32_t>(w[HTTP_TOTAL_WORD])) << "\n";
    o << "  inflight:    " << inflight().describe() << "\n";
    o << "  stall:       " << stall().describe() << "\n";
    o << "  response:    " << response().describe() << " (decoder 0's framer)\n";
    const uint8_t n = lane_count();
    o << "  " << DecodeLanes(w[HTTP_LANE_OCC], w[HTTP_LANE_READY], n).describe() << "\n";
    o << "  " << DecodeLaneErrors(w[HTTP_LANE_ERR], n).describe() << "\n";
    for (uint8_t l = 0; l < n; l++) {
        o << "  lane " << unsigned(l) << " state: " << DescribeLaneState(w[HTTP_LANE_STATE], l) << "\n";
    }
    o << "  " << DecodePolicy(w[HTTP_LANE_POLICY]).describe() << "\n";
    if (toe_ring()) {
        // Revision 6 only: what the revision-2 words mean on handler_toe. No register above 20 is
        // read -- they do not exist on this bitstream.
        const auto f = static_cast<uint32_t>(w[HTTP_INFLIGHT]);
        const auto p = DecodePolicy(w[HTTP_LANE_POLICY]);
        o << "  revision 6: INFLIGHT[16] some lane has notified bytes not yet asked for = "
          << ((f >> 16) & 1u) << ", INFLIGHT[17] some lane's FIN has settled = " << ((f >> 17) & 1u)
          << "; ARM_READY includes the GET credit (" << p.get_credit << " per lane); GET cap "
          << ToeGetCap(p.ring_log2, p.get_credit) << " B; STALL[24] = toe_rx order|len|budget error = "
          << ((static_cast<uint32_t>(w[HTTP_STALL]) >> 24) & 1u) << "; LANE_ERR bit 0 unused (no "
          << "dead lanes), bit 7 = the lane's fifo refused a routed beat\n";
        o << "  host: lane depth " << lane_depth_ << " (0 = not computed yet), split "
          << (toe_cap_ != 0 ? EffectiveSplit(ConfiguredChunkBytes(), toe_cap_) : 0) << " B\n";
    }
    return o.str();
}

} // namespace oasis
