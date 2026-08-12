#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>

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

// HttpConfig write map (hardware/src/hdl/http_read/http_config.sv)
constexpr const uint32_t HTTP_SERVER_IP       = 0;
constexpr const uint32_t HTTP_SERVER_PORT     = 1;
constexpr const uint32_t HTTP_PORT_HEX        = 2;
constexpr const uint32_t HTTP_IP_HEX_LEN      = 3;
constexpr const uint32_t HTTP_IP_HEX_W0       = 4;
constexpr const uint32_t HTTP_FILE_LEN        = 8;
constexpr const uint32_t HTTP_FILE_W0         = 9;  // 9..24 (16 words, 64 path characters)
// Register 25 was a dead `num_sessions` field; it now carries per-request flags (bit 0 = this
// response ends the decoder stream). Reusing it keeps the address map byte-for-byte identical --
// shifting any register lands every later parameter in the wrong place, silently.
constexpr const uint32_t HTTP_REQ_FLAGS       = 25;
constexpr const uint32_t HTTP_PKG_WORD_COUNT  = 26;
constexpr const uint32_t HTTP_USER_FREQUENCY  = 27;
constexpr const uint32_t HTTP_TIME_IN_SECONDS = 28;
constexpr const uint32_t HTTP_RANGE_BEGIN_LEN = 29;
constexpr const uint32_t HTTP_RANGE_BEGIN_W0  = 30; // 30..33
constexpr const uint32_t HTTP_RANGE_END_LEN   = 34;
constexpr const uint32_t HTTP_RANGE_END_W0    = 35; // 35..38
constexpr const uint32_t HTTP_START           = 39;

// Bitstreams up to and including build-88 instantiate HttpConfig with START_ADDR=31: the override in
// vfpga_top.svh was not moved when the GET path widened from 8 to 16 words. On those, a write to 31
// -- RANGE_BEGIN_W1 in the map above -- ALSO fires the start trigger, snapshotting the config while
// registers 32..38 (the rest of the Range begin, all of the Range end) still hold their previous
// values. The FPGA then sends "Range: bytes=<truncated begin>-" with no end and the server answers
// 400. Writing this register last, immediately before START, is correct on both: on a fixed bitstream
// it is an ordinary parameter and START at 39 still comes after it, and on a legacy one the trigger
// fires only once everything else has landed. ConfigWriteReadyRegister registers its valid, so the
// snapshot taken on that write includes the register 31 write itself.
constexpr const uint32_t HTTP_LEGACY_START = 31;

// totalWord bit 22: the handler is outside ST_IDLE. See describe_status() for the full layout.
constexpr const uint32_t HTTP_STATUS_BUSY_BIT = 22;

// ASCII words transferred per Range endpoint. Range values are absolute file
// offsets, so they scale with file size, not with read size: 2 words (8 digits)
// caps out at ~95 MiB, which any real Parquet file blows past immediately. 4
// words = 16 digits ~ 8.9 PiB.
constexpr const uint32_t HTTP_RANGE_WORDS = 4;
constexpr const uint32_t HTTP_RANGE_MAX_DIGITS = HTTP_RANGE_WORDS * 4;

// ASCII words transferred for the GET path (64 chars) and the Host: IP (16 chars).
constexpr const uint32_t HTTP_FILE_WORDS = 16;
constexpr const uint32_t HTTP_IP_WORDS   = 4;

// http_req_builder assembles the request into a fixed 256-byte buffer (buffer_q[255:0]) with no
// overflow detection -- writes past the end alias instead of failing, so this check is the only
// thing standing between a long path and a silently corrupted request. The fixed parts are
// "GET " (4) + " HTTP/1.1\r\nHost: " (17) + ":" (1) + port (4) + CRLF (2) +
// "Range: bytes=" (13) + "-" (1) + CRLF (2) + "Connection: keep-alive\r\n\r\n" (26) = 70 bytes.
constexpr const uint32_t HTTP_HEADER_BUFFER_BYTES = 256;
constexpr const uint32_t HTTP_HEADER_FIXED_BYTES  = 70;

// Read-side CSRs (see hardware/src/hdl/http_read/http_config.sv).
constexpr const uint32_t HTTP_CLIENT_STATE     = 1;
constexpr const uint32_t HTTP_TOTAL_WORD       = 2;
constexpr const uint32_t HTTP_ECHO_FILE_LEN    = 3;
constexpr const uint32_t HTTP_ECHO_FILE_W0     = 4;
constexpr const uint32_t HTTP_ECHO_FILE_W4     = 5;
constexpr const uint32_t HTTP_ECHO_RANGE_BEGIN = 6;
constexpr const uint32_t HTTP_ECHO_RANGE_END   = 7;
constexpr const uint32_t HTTP_ECHO_SERVER      = 8;
constexpr const uint32_t HTTP_ECHO_FILE_W8     = 9;
constexpr const uint32_t HTTP_INFLIGHT         = 10;
constexpr const uint32_t HTTP_STALL            = 11;
constexpr const uint32_t HTTP_RESP             = 12;
constexpr const uint32_t HTTP_BODY_REMAINING   = 13;
constexpr const uint32_t HTTP_CONTENT_LENGTH   = 14;

// How long to wait for a request slot before giving up. Reaching this means the pipeline stopped
// draining -- a response that never arrived, or a connection that never opened -- so it is a
// diagnosis, not a tuning knob. Generous enough that a slow object server never trips it.
constexpr const auto HTTP_CREDIT_TIMEOUT = std::chrono::seconds(30);

// -------------------------------------------------------------------------------------------------
// The two knobs that together bound how many bytes the server can have in flight to the FPGA.
//
// WHY THAT BOUND MATTERS
// The Coyote TOE is built with TCP_STACK_RX_DDR_BYPASS_EN=1
// (parcore/libstf/coyote/hw/services/network/hls/toe/CMakeLists.txt). On that path the entire stack
// has ONE receive buffer -- `axis_data_fifo_512_d1024 rx_buffer_fifo` in tcp_stack.sv, 1024 x 64 B
// = 64 KB -- and `rx_sar_table.cpp:71` computes the advertised window from the application read
// pointer alone, with no knowledge of that buffer: WINDOW_BITS is 18, so it can advertise up to
// 256 KB. Grep rx_sar_table for `data_count` and you get nothing. Meanwhile `rx_engine.cpp` DROPS a
// segment and answers ACK_NODELAY -- a duplicate ACK -- once free space falls below 375 beats, i.e.
// once occupancy passes ~41.5 KB. Out-of-order buffering is disabled on this path, so one drop
// forces go-back-N. The stack therefore invites the server to send four to six times what it can
// hold, discards the overflow and re-requests it, and that is what the duplicate-ACK storms are.
//
// The proper fix is in the TOE (plumb rxbuffer_data_count into rx_sar_table and clamp the window to
// real free space) or, cheaply, a bigger FIFO. Neither is done here. Instead the HOST refuses to
// ask for more than the buffer can hold: a ranged GET's response is bounded by the range, so
//
//     bytes the server may have in flight  <=  HTTP_DEFAULT_MAX_INFLIGHT * HTTP_DEFAULT_CHUNK_BYTES
//
// and keeping that product safely under 41.5 KB means the FIFO cannot overflow no matter how fast
// the sender is or how slowly the decoder drains. 4 x 8 KiB = 32 KiB leaves ~9 KB of headroom for
// the response headers and in-flight ACK slack.
//
// SUPERSEDED ON build-94 -- read this before trusting the paragraph above. The reasoning is sound
// but the premise is not: the FIFO backed up because the HTTP PARSER was holding TREADY low for the
// duration of a header walk, not because the network outran the decoder. The decoder drains at
// 16 GB/s at 0.25% duty; it was never the slow party. Once b238c4e decoupled the two, responses
// eight times larger than the whole threshold ran with no penalty at all (the sweep table under
// HTTP_DEFAULT_CHUNK_BYTES). The bytes-in-flight bound is therefore NOT the invariant that keeps
// this correct, and sizing a chunk against 41.5 KB now only costs requests. What does keep it
// correct is that the drain never stops -- which rx_fifo_stall reports on, and which is the bit to
// read if any of this starts misbehaving.
//
// WHY PIPELINING IS SAFE AGAIN
// Depth > 1 used to wedge the receive path, and the reason was never the depth: it was concurrent
// SESSIONS. Under RX_DDR_BYPASS `rx_app_stream_if()` answers a readPkg by echoing back the session
// ID the app asked for plus a bare 1-bit token, and `rxAppMemDataRead()` (toe.cpp) consumes that
// token by popping one packet from the HEAD of the shared FIFO without ever looking at the session.
// The real contract is "readPkg must be issued in the global ARRIVAL order across all sessions",
// which a handler draining slots in REQUEST order cannot honour with several connections open.
//
// The handler now holds ONE persistent connection for every request (see handler.sv). With a single
// session, arrival order and request order are the same thing, so the contract holds by
// construction and HTTP/1.1 pipelining over that connection is both legal and safe.
constexpr const uint8_t  HTTP_DEFAULT_MAX_INFLIGHT = 4;

// Largest byte range asked for in one GET. 0 disables splitting entirely (one GET per column chunk).
//
// RAISED 8192 -> 131072 ON build-94. The 8 KiB default existed to keep `depth x chunk` under the
// ~41.5 KB drop threshold described above. That bound was real, but it was a symptom: the parser
// held s_axis_rx_data_TREADY low for the ~550 cycles of a header walk, so the shared FIFO backed up
// behind it and small requests were the only way to stay under the edge. b238c4e put a FIFO between
// the TOE and the parser, and the edge went with it.
//
// Measured on build-94, scripts/sweep.sh, lineitem sf1, per-GET marginal cost in microseconds:
//
//            4K->8K   8K->16K  16K->32K  32K->64K  64K->128K
//   depth 1    1019       988      1116       936        720
//   depth 2     927       705       786       508        801
//   depth 4     888       779       719       764        600
//
// Flat, at every depth. On build-93 the same sweep showed +10.4 ms/GET at 32K->64K -- a response
// that no longer fit alongside the parser's backlog. That cliff is gone, so the cost of a GET is now
// latency and nothing else, and the only thing that matters is issuing fewer of them.
//
// 131072 is the largest size actually measured, not a limit. Bigger is very likely still better;
// sweep further before raising it again, because past here nothing has been observed. Note the
// bytes-in-flight product is now 4 x 128 KiB = 512 KiB, eight times what the old rule permitted --
// that is deliberate and is what the sweep above tested, but it means rx_fifo_stall (stallWord bit
// 25) is the thing to watch: if it ever sets, back-pressure has reached the TOE again and this
// number is why.
//
// Splitting is nearly free only because the connection is persistent: the extra requests cost a
// ~150-byte GET and a ~200-byte response header each, pipelined, with no handshake and no teardown.
// 196608 = 192 KiB. Raised from 131072 on build-95, where the rx fifo went 64 KiB -> 256 KiB on both
// sides (ours and the TOE's). rx_fifo_stall no longer sets at any size up to here, which it did at
// 131072 on build-94 -- so the decoupling now actually holds at the size we ask for.
//
// Deliberately NOT 262144. That is 2^18 = BUFFER_SIZE = 1 << WINDOW_BITS, exactly the window the TOE
// advertises, and every sweep that has hung has hung at or above it. The buffer got bigger in
// build-95 but WINDOW_BITS did not, so that boundary is untouched and is not worth walking into for
// a few percent.
constexpr const uint64_t HTTP_DEFAULT_CHUNK_BYTES = 196608;

// Effective request-ring depth: min(bitstream slots, HTTP_DEFAULT_MAX_INFLIGHT or the override).
// OASIS_HTTP_MAX_INFLIGHT=0 means "whatever the bitstream advertises". Raising this without also
// lowering OASIS_HTTP_CHUNK_BYTES raises the bytes-in-flight bound above -- read the block above
// before doing that.
// The TCP window the stack advertises: 1 << WINDOW_BITS with WINDOW_BITS = 16 + WINDOW_SCALE_BITS
// and WINDOW_SCALE_BITS = 2 (toe_config.hpp.in). Since build-95 the receive fifo is the same size,
// so this one number is both what the peer is invited to send and what can actually be held.
//
// MEASURED, against MinIO on 10.253.74.74, one keep-alive connection, 48 MB per point. The budget
// is chunk x depth and every row inside it spends the same 256 KiB:
//
//     chunk  depth  in-flight    MB/s
//      192K      1       192K   148.2   <- the default
//      256K      1       256K   179.3   best that fits today
//      128K      2       256K   137.3
//       64K      4       256K    68.1
//       32K      8       256K    42.9
//      512K      1       512K   293.6   needs a bigger window
//     1024K      1      1024K   423.1   needs a bigger window
//      512K      2      1024K   384.1
//
// Two things follow, and the second one is the surprise. First, throughput is very nearly LINEAR in
// chunk size, because a request costs ~1.4 ms of MinIO time-to-first-byte whatever its size, so
// doubling the chunk halves how often that is paid. Second, DEPTH IS ACTIVELY HARMFUL under a fixed
// budget: 64K x 4 is 2.2x SLOWER than 192K x 1 for exactly the same bytes in flight. HTTP/1.1
// pipelining is strictly ordered and MinIO overlaps only ~1.5x of the queued work, which never pays
// for the 4x smaller requests it was bought with. One big request beats several small ones at every
// budget tested -- 512K x 1 > 256K x 2, 1024K x 1 > 512K x 2.
//
// So the ONE thing that raises single-connection throughput is a bigger window, and the only reason
// the chunk is not already larger is that this number caps it.
constexpr const uint64_t HTTP_RX_WINDOW_BYTES = 262144;

// Overridable because the window is a property of the BITSTREAM, not of this build: a bitstream with
// WINDOW_SCALE_BITS raised can hold more, and there is no CSR that reports it. Setting this HIGHER
// than the running bitstream's real window re-creates the failure d0224ee fixed -- the peer is
// invited to send more than the fifo holds, the overflow is dropped, and the wire fills with genuine
// retransmissions and duplicate ACKs seconds apart. Raise it only together with the bitstream.
uint64_t HttpRxWindowBytes() {
    static const uint64_t configured = [] {
        const char *env = std::getenv("OASIS_HTTP_RX_WINDOW_BYTES");
        if (env == nullptr || *env == '\0') {
            return HTTP_RX_WINDOW_BYTES;
        }
        const long long parsed = std::atoll(env);
        if (parsed <= 0) {
            return HTTP_RX_WINDOW_BYTES;
        }
        std::fprintf(stderr,
                     "oasis: OASIS_HTTP_RX_WINDOW_BYTES=%lld overrides the built-in %llu. This must "
                     "not exceed 1 << WINDOW_BITS of the PROGRAMMED bitstream.\n",
                     parsed, static_cast<unsigned long long>(HTTP_RX_WINDOW_BYTES));
        return static_cast<uint64_t>(parsed);
    }();
    return configured;
}

uint8_t HttpMaxInflight(uint8_t slots) {
    static const int configured = [] {
        const char *env = std::getenv("OASIS_HTTP_MAX_INFLIGHT");
        if (env == nullptr) {
            return static_cast<int>(HTTP_DEFAULT_MAX_INFLIGHT);
        }
        const int parsed = std::atoi(env);
        return parsed < 0 ? static_cast<int>(HTTP_DEFAULT_MAX_INFLIGHT) : parsed;
    }();

    int depth = (configured == 0 || configured >= static_cast<int>(slots))
                    ? static_cast<int>(slots)
                    : configured;

    // Bound in-flight BYTES, not in-flight REQUESTS. This used to be a bare count, which was safe
    // only because the chunk size happened to be small: at 4 x 8 KiB the product was 32 KiB. Raising
    // the chunk to 192 KiB silently made it 768 KiB -- three times the window and three times the
    // fifo -- and the result was real retransmissions on the wire (server resending the same segment
    // while the FPGA dup-ACKed it, seconds apart, with the whole query stalled behind it).
    //
    // A count cannot express the constraint that matters. The peer may not be invited to send more
    // than can be held, so the product is what has to be capped, and the chunk size is the term that
    // moves. Always at least 1: a single response larger than the window is a separate problem and
    // is handled by keeping HTTP_DEFAULT_CHUNK_BYTES below it.
    const uint64_t chunk = HTTPReadConfig::chunk_bytes();
    if (chunk > 0) {
        const int by_bytes = static_cast<int>(HttpRxWindowBytes() / chunk);
        depth = std::max(1, std::min(depth, by_bytes));
    }
    return static_cast<uint8_t>(depth);
}

// Packs `s` little-endian into `words`. Throws rather than truncating: a silently shortened path
// makes the FPGA request a different (usually nonexistent) file, and the 404 body then flows through
// the datapath as if it were real data.
void PackAsciiWords(const std::string &s, uint32_t &len, uint32_t *words, size_t n_words,
                    const char *what) {
    if (s.size() > n_words * 4) {
        std::ostringstream msg;
        msg << "HTTP " << what << " is " << s.size() << " characters, but only " << (n_words * 4)
            << " are transferred to the FPGA: '" << s << "'";
        throw std::runtime_error(msg.str());
    }
    len = static_cast<uint32_t>(s.size());
    std::memset(words, 0, n_words * sizeof(uint32_t));
    for (size_t i = 0; i < s.size(); i++) {
        words[i / 4] |= static_cast<uint32_t>(static_cast<uint8_t>(s[i])) << (8 * (i % 4));
    }
}

std::string IpToAscii(uint32_t ip_be) {
    return std::to_string((ip_be >> 24) & 0xff) + "." + std::to_string((ip_be >> 16) & 0xff) + "." +
           std::to_string((ip_be >> 8) & 0xff) + "." + std::to_string(ip_be & 0xff);
}

uint32_t PackPortHex(uint16_t port) {
    std::ostringstream oss;
    oss.width(4);
    oss.fill('0');
    oss << port;
    const auto s = oss.str();
    uint32_t word = 0;
    for (uint32_t i = 0; i < 4; i++) {
        word |= static_cast<uint32_t>(static_cast<uint8_t>(s[i])) << (8 * i);
    }
    return word;
}

} // namespace

HTTPReadConfig::HTTPReadConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset,
                                 uint32_t num_regs)
    : Config(cthread, addr_offset, num_regs) {}

// Splits [range_begin, range_end] into GETs of at most chunk_bytes() and fires them in order. Only
// the last one is marked body_last, so the whole column chunk still arrives as ONE decoder stream
// with exactly one tlast -- the DataNormalizer resets its running byte offset on tlast, so an extra
// one mid-chunk would desynchronise everything after it.
void HTTPReadConfig::read(libstf::stream_t /*stream*/, uint32_t server_ip, uint16_t server_port,
                          const std::string &path, uint64_t range_begin, uint64_t range_end,
                          uint16_t /*session_id*/) {
    const uint64_t chunk = chunk_bytes();
    if (chunk == 0 || (range_end - range_begin + 1) <= chunk) {
        issue_range(server_ip, server_port, path, range_begin, range_end, /*body_last*/ true);
        return;
    }

    for (uint64_t begin = range_begin; begin <= range_end; begin += chunk) {
        const uint64_t end  = std::min(begin + chunk - 1, range_end);
        const bool     last = (end == range_end);
        issue_range(server_ip, server_port, path, begin, end, last);
    }
}

uint64_t HTTPReadConfig::chunk_bytes() {
    static const uint64_t configured = [] {
        const char *env = std::getenv("OASIS_HTTP_CHUNK_BYTES");
        if (env == nullptr) {
            return HTTP_DEFAULT_CHUNK_BYTES;
        }
        const long long parsed = std::atoll(env);
        return parsed < 0 ? HTTP_DEFAULT_CHUNK_BYTES : static_cast<uint64_t>(parsed);
    }();
    return configured;
}

void HTTPReadConfig::await_credit() {
    // Make sure the hardware can actually take this request before writing any of it.
    //
    // ConfigWriteReadyRegister does not back-pressure: a START write that lands while the previous
    // one is still unconsumed OVERWRITES it, and that request disappears without a trace. So the
    // host has to police the depth itself.
    //
    // On a pipelined bitstream the ring reports its occupancy and we wait for a free slot. On a
    // pre-pipelining one there is no such register (it reads back zero), and the only signal
    // available is the busy bit -- there, a request arriving mid-transfer really is dropped for
    // good, because the old handler sampled runTx as a one-cycle pulse in ST_IDLE only. That is the
    // wedge that outlives the process and makes every later run fail; with no reset CSR, the only
    // way out is reprogramming.
    if (num_slots() == 0) {
        if (const uint32_t status = debug_status(); (status & (1u << HTTP_STATUS_BUSY_BIT)) != 0) {
            std::ostringstream msg;
            msg << "FPGA HTTP handler is still busy from an earlier request ["
                << describe_status(status)
                << "]; this bitstream predates the pipelined handler and only accepts a new request "
                   "from its IDLE state, so this one would be silently dropped and then hang. There "
                   "is no reset register -- reprogram the bitstream to clear it.";
            throw std::runtime_error(msg.str());
        }
    } else {
        // Cap the depth at HttpMaxInflight() rather than at the ring size: depth x chunk size is
        // what bounds the bytes the server may have in flight. See HTTP_DEFAULT_MAX_INFLIGHT.
        const uint8_t depth    = max_inflight();
        const auto    deadline = std::chrono::steady_clock::now() + HTTP_CREDIT_TIMEOUT;
        HTTPInflight  flight   = inflight();
        while (flight.occupied >= depth) {
            if (std::chrono::steady_clock::now() > deadline) {
                std::ostringstream msg;
                msg << "FPGA HTTP request ring has been at its depth limit (" << unsigned(depth)
                    << " of " << unsigned(flight.slots) << " slots) for "
                    << std::chrono::duration_cast<std::chrono::seconds>(HTTP_CREDIT_TIMEOUT).count()
                    << "s [" << flight.describe() << "; " << describe_status(debug_status())
                    << "]. The pipeline has stopped draining -- " << stall().describe()
                    << ". There is no reset register -- reprogram the bitstream to clear it.";
                msg << " " << response().describe() << ".";
                throw std::runtime_error(msg.str());
            }
            std::this_thread::sleep_for(std::chrono::microseconds(50));
            flight = inflight();
        }
    }
}

void HTTPReadConfig::issue_range(uint32_t server_ip, uint16_t server_port, const std::string &path,
                                 uint64_t range_begin, uint64_t range_end, bool body_last) {
    await_credit();
    last_request_bytes_.store(static_cast<uint32_t>(range_end - range_begin + 1),
                              std::memory_order_relaxed);

    const auto ip_ascii    = IpToAscii(server_ip);
    const auto begin_ascii = std::to_string(range_begin);
    const auto end_ascii   = std::to_string(range_end);

    // The length CSRs must never claim more characters than were transferred, or the HW walks past
    // the words it was given and builds a garbage Range: header. Check before packing so the error
    // names the offending field.
    if (begin_ascii.size() > HTTP_RANGE_MAX_DIGITS || end_ascii.size() > HTTP_RANGE_MAX_DIGITS) {
        std::ostringstream msg;
        msg << "HTTP range endpoint does not fit in " << HTTP_RANGE_MAX_DIGITS
            << " ASCII digits: begin=" << range_begin << " end=" << range_end;
        throw std::runtime_error(msg.str());
    }

    const size_t header_bytes = HTTP_HEADER_FIXED_BYTES + path.size() + ip_ascii.size() +
                                begin_ascii.size() + end_ascii.size();
    if (header_bytes > HTTP_HEADER_BUFFER_BYTES) {
        std::ostringstream msg;
        msg << "Assembled HTTP request is " << header_bytes << " bytes but the FPGA request buffer "
            << "holds only " << HTTP_HEADER_BUFFER_BYTES << " (path=" << path.size()
            << " ip=" << ip_ascii.size() << " range=" << begin_ascii.size() << "+"
            << end_ascii.size() << "): '" << path << "'";
        throw std::runtime_error(msg.str());
    }

    uint32_t file_len = 0;
    uint32_t file_words[HTTP_FILE_WORDS] {};
    PackAsciiWords(path, file_len, file_words, HTTP_FILE_WORDS, "GET path");

    uint32_t ip_len = 0;
    uint32_t ip_words[HTTP_IP_WORDS] {};
    PackAsciiWords(ip_ascii, ip_len, ip_words, HTTP_IP_WORDS, "Host: address");

    uint32_t range_begin_len = 0;
    uint32_t range_begin_words[HTTP_RANGE_WORDS] {};
    PackAsciiWords(begin_ascii, range_begin_len, range_begin_words, HTTP_RANGE_WORDS,
                   "Range begin");

    uint32_t range_end_len = 0;
    uint32_t range_end_words[HTTP_RANGE_WORDS] {};
    PackAsciiWords(end_ascii, range_end_len, range_end_words, HTTP_RANGE_WORDS, "Range end");

    write_register(libstf::ConfigRegister(HTTP_SERVER_IP, server_ip));
    write_register(libstf::ConfigRegister(HTTP_SERVER_PORT, server_port));
    write_register(libstf::ConfigRegister(HTTP_PORT_HEX, PackPortHex(server_port)));
    write_register(libstf::ConfigRegister(HTTP_IP_HEX_LEN, ip_len));
    for (uint32_t i = 0; i < HTTP_IP_WORDS; i++) {
        write_register(libstf::ConfigRegister(HTTP_IP_HEX_W0 + i, ip_words[i]));
    }
    write_register(libstf::ConfigRegister(HTTP_FILE_LEN, file_len));
    for (uint32_t i = 0; i < HTTP_FILE_WORDS; i++) {
        write_register(libstf::ConfigRegister(HTTP_FILE_W0 + i, file_words[i]));
    }
    write_register(libstf::ConfigRegister(HTTP_REQ_FLAGS, body_last ? 1u : 0u));
    write_register(libstf::ConfigRegister(HTTP_PKG_WORD_COUNT, 16));
    write_register(libstf::ConfigRegister(HTTP_USER_FREQUENCY, 256ULL * 1024ULL * 1024ULL));
    write_register(libstf::ConfigRegister(HTTP_TIME_IN_SECONDS, 0));
    write_register(libstf::ConfigRegister(HTTP_RANGE_BEGIN_LEN, range_begin_len));
    for (uint32_t i = 0; i < HTTP_RANGE_WORDS; i++) {
        // Deferred to just before START -- see HTTP_LEGACY_START.
        if (HTTP_RANGE_BEGIN_W0 + i == HTTP_LEGACY_START) {
            continue;
        }
        write_register(libstf::ConfigRegister(HTTP_RANGE_BEGIN_W0 + i, range_begin_words[i]));
    }
    write_register(libstf::ConfigRegister(HTTP_RANGE_END_LEN, range_end_len));
    for (uint32_t i = 0; i < HTTP_RANGE_WORDS; i++) {
        write_register(libstf::ConfigRegister(HTTP_RANGE_END_W0 + i, range_end_words[i]));
    }
    static_assert(HTTP_LEGACY_START >= HTTP_RANGE_BEGIN_W0 &&
                      HTTP_LEGACY_START < HTTP_RANGE_BEGIN_W0 + HTTP_RANGE_WORDS,
                  "HTTP_LEGACY_START must name a Range-begin word for the deferral above to write it");
    write_register(libstf::ConfigRegister(HTTP_LEGACY_START,
                                          range_begin_words[HTTP_LEGACY_START - HTTP_RANGE_BEGIN_W0]));

    // Barrier before START. The parameter writes above are posted MMIO stores; the START
    // write is just another posted store, so nothing guarantees the parameter registers have
    // been latched by HttpConfig before the START beat samples the cfg snapshot. If START wins
    // the race, the handler builds its GET from a *stale* cfg — the "file path is one run behind"
    // symptom (the bring-up tool papered over this with sleep(1) before START). A CSR read is
    // non-posted and cannot be reordered ahead of the prior writes to the same AXI-Lite device,
    // so it drains them and orders START strictly after every parameter write.
    (void)read_register(HTTP_CLIENT_STATE);

    write_register(libstf::ConfigRegister(HTTP_START, 1));

    // Post-START trace, gated on OASIS_HTTP_DEBUG=1. read_oasis fires this request from a scheduler
    // thread with no DuckDB logging in reach, so without it a request that never left the FPGA is
    // indistinguishable from one whose response never came back -- both just hang. The echo
    // registers are the only proof the parameters were latched at all, since the parameter CSRs
    // themselves are write-only.
    if (http_debug_enabled()) {
        const auto flight = inflight();
        // Bitstream identity in one line. slots=0 means a pre-pipelining bitstream, so if this says
        // 0 when a pipelined one was programmed, the board is not running what you think it is.
        if (flight.legacy()) {
            std::fprintf(stderr, "[oasis-http] bitstream: pre-pipelining (no INFLIGHT register, depth 1)\n");
        } else {
            // Print the cap and the chunk size next to the ring size: their product is the bound
            // on how many bytes the server may have in flight, which is the number that has to stay
            // under the TOE's ~41.5 KB drop threshold.
            std::fprintf(stderr,
                         "[oasis-http] bitstream: %s cap=%u chunk=%llu (<=%llu B in flight)\n",
                         flight.describe().c_str(), unsigned(HttpMaxInflight(flight.slots)),
                         static_cast<unsigned long long>(chunk_bytes()),
                         static_cast<unsigned long long>(HttpMaxInflight(flight.slots) *
                                                         (chunk_bytes() ? chunk_bytes() : 0)));
        }
        std::fprintf(stderr, "[oasis-http] START GET %s range=[%llu,%llu] last=%d ip=0x%08x port=%u\n",
                     path.c_str(), static_cast<unsigned long long>(range_begin),
                     static_cast<unsigned long long>(range_end), int(body_last), server_ip,
                     server_port);
        std::fprintf(stderr, "[oasis-http]   latched: %s\n", request_echo().describe().c_str());
        std::fprintf(stderr, "[oasis-http]   t=0ms      %s\n", describe_status(debug_status()).c_str());

        // The sticky stall bits, reported the moment they change rather than only when a read times
        // out. They are the only evidence for conditions that do NOT stop the query -- rx_fifo_stall
        // above all, which says the decoupling fifo filled and back-pressure reached the TOE anyway.
        // A run that succeeds is not evidence that it did not happen, so it has to be read on the
        // success path or it is never read at all. Printed on transition, not per request: the bits
        // are sticky, so repeating them for every remaining GET would bury the first occurrence.
        const auto stalls = stall();
        if (stalls.any() && stall_reported_ != stalls.raw) {
            stall_reported_ = stalls.raw;
            std::fprintf(stderr, "[oasis-http]   STALL: %s\n", stalls.describe().c_str());
        }
    }
}

// Mirrors the totalWord layout in hardware/src/hdl/http_read/handler.sv. The 4-bit client_state CSR
// multiplexes several sub-FSMs onto one value (2, 6, 9 and 10 each alias two states), so only this
// packed word can say which stage is actually stuck.
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

uint8_t HTTPReadConfig::client_state() {
    return static_cast<uint8_t>(read_register(HTTP_CLIENT_STATE).value() & 0xF);
}

uint32_t HTTPReadConfig::debug_status() {
    return static_cast<uint32_t>(read_register(HTTP_TOTAL_WORD).value());
}

HTTPReadConfig::HTTPInflight HTTPReadConfig::inflight() {
    const auto word = static_cast<uint32_t>(read_register(HTTP_INFLIGHT).value());
    HTTPInflight f {};
    f.occupied    = static_cast<uint8_t>(word & 0xFFu);
    f.slots       = static_cast<uint8_t>((word >> 8) & 0xFFu);
    f.has_pending = (word & (1u << 16)) != 0;
    f.peer_closed = (word & (1u << 17)) != 0;
    f.conn_up     = (word & (1u << 18)) != 0;
    return f;
}

std::string HTTPReadConfig::HTTPInflight::describe() const {
    std::ostringstream oss;
    if (legacy()) {
        return "inflight=<unsupported: pre-pipelining bitstream>";
    }
    oss << "inflight=" << static_cast<unsigned>(occupied) << "/" << static_cast<unsigned>(slots)
        << " conn=" << (conn_up ? "up" : "down") << (has_pending ? " pending" : "")
        << (peer_closed ? " peer-closed" : "");
    return oss.str();
}

HTTPReadConfig::HTTPStall HTTPReadConfig::stall() {
    const auto word = static_cast<uint32_t>(read_register(HTTP_STALL).value());
    HTTPStall s {};
    s.raw              = word;
    s.connect_stalled  = (word & (1u << 0)) != 0;
    s.send_stalled     = (word & (1u << 1)) != 0;
    s.read_stalled     = (word & (1u << 2)) != 0;
    s.init_error       = (word & (1u << 3)) != 0;
    s.send_error       = (word & (1u << 4)) != 0;
    s.resp_unframeable = (word & (1u << 5)) != 0;
    s.dirty_abort      = (word & (1u << 6)) != 0;
    s.status_bad       = (word & (1u << 7)) != 0;
    s.reconnects       = static_cast<uint8_t>((word >> 8) & 0xFFu);
    s.read_slot        = static_cast<uint8_t>((word >> 16) & 0xFFu);
    s.notify_overflow  = (word & (1u << 24)) != 0;
    s.rx_fifo_stall    = (word & (1u << 25)) != 0;
    s.read_timeout     = (word & (1u << 26)) != 0;
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
    if (send_stalled)     oss << " SEND";
    if (read_stalled)     oss << " READ(slot " << static_cast<unsigned>(read_slot) << ")";
    if (init_error)       oss << " init_error";
    if (send_error)       oss << " send_error";
    if (resp_unframeable) oss << " unframeable_response";
    if (dirty_abort)      oss << " dirty_abort";
    if (status_bad)       oss << " bad_http_status";
    if (notify_overflow)  oss << " notify_overflow";
    if (rx_fifo_stall)    oss << " rx_fifo_stall";
    if (read_timeout)     oss << " read_timeout";
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
    if (rx_fifo_stall) {
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

    if (resp_unframeable) {
        oss << "\n    unframeable: a response arrived with no Content-Length, so the hardware could not tell where "
               "its body ends and the next response begins, and stopped rather than guessing. On a "
               "ranged GET of a static object that should be impossible -- check whether the server "
               "answered with Transfer-Encoding: chunked, or whether the reply was an error page";
    }
    if (dirty_abort) {
        oss << ". The connection died in the middle of a body whose bytes had already reached the "
               "decoder. Those cannot be unsent, so the request was NOT replayed -- replaying would "
               "duplicate them in the column. Reprogram to clear";
    }
    if (status_bad) {
        oss << ". The server answered something other than 200/206, so whatever reached the decoder "
               "is an error document, not column data";
    }
    if (notify_overflow) {
        oss << ". The announcement queue overflowed, so segments the TOE announced were dropped and "
               "that response is permanently short. This should be unreachable (NOTIFY_DEPTH in "
               "tcp_session_table.sv vs the shared rx fifo); if it fires, the reader is not draining";
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
    r.requested      = last_request_bytes_.load(std::memory_order_relaxed);
    return r;
}

std::string HTTPReadConfig::HTTPResponse::describe() const {
    std::ostringstream oss;
    oss << "last response: status=" << std::string(status, 3) << (status_ok ? " (ok)" : " (NOT ok)")
        << " Content-Length=" << content_length << " requested=" << requested
        << " body_remaining=" << body_remaining;
    if (unframeable) oss << " UNFRAMEABLE(no Content-Length)";
    if (dirty)       oss << " partially-delivered";
    if (length_mismatch()) {
        oss << ". THE SERVER SENT A DIFFERENT LENGTH THAN WAS REQUESTED -- the response is not the "
               "one this request asked for (a 200 instead of a 206, a range clamped at end of file, "
               "or an error document), so whatever reached the decoder is not this column chunk";
    }
    return oss.str();
}

uint8_t HTTPReadConfig::num_slots() {
    // Fixed by the bitstream, so read it once. A pre-pipelining bitstream has no INFLIGHT register;
    // ConfigReadRegisterFile returns zero for an out-of-range address, which lands here as 0 slots
    // and selects the legacy single-request path.
    if (num_slots_ < 0) {
        num_slots_ = static_cast<int>(inflight().slots);
    }
    return static_cast<uint8_t>(num_slots_);
}

uint8_t HTTPReadConfig::max_inflight() { return HttpMaxInflight(num_slots()); }

HTTPRequestEcho HTTPReadConfig::request_echo() {
    const auto range_begin = read_register(HTTP_ECHO_RANGE_BEGIN).value();
    const auto range_end   = read_register(HTTP_ECHO_RANGE_END).value();
    const auto server      = read_register(HTTP_ECHO_SERVER).value();

    HTTPRequestEcho echo {};
    echo.file_len        = static_cast<uint32_t>(read_register(HTTP_ECHO_FILE_LEN).value());
    echo.file_w0         = static_cast<uint32_t>(read_register(HTTP_ECHO_FILE_W0).value());
    echo.file_w4         = static_cast<uint32_t>(read_register(HTTP_ECHO_FILE_W4).value());
    echo.file_w8         = static_cast<uint32_t>(read_register(HTTP_ECHO_FILE_W8).value());
    echo.range_begin_w0  = static_cast<uint32_t>(range_begin & 0xFFFFFFFFULL);
    echo.range_begin_len = static_cast<uint8_t>((range_begin >> 32) & 0xFF);
    echo.range_end_w0    = static_cast<uint32_t>(range_end & 0xFFFFFFFFULL);
    echo.range_end_len   = static_cast<uint8_t>((range_end >> 32) & 0xFF);
    echo.server_ip       = static_cast<uint32_t>(server & 0xFFFFFFFFULL);
    echo.server_port     = static_cast<uint16_t>((server >> 32) & 0xFFFF);
    return echo;
}

// Renders the little-endian ASCII word pair the hardware latched, so a mismatch is readable
// ("h-10" vs "h-1/") instead of two hex blobs.
std::string HTTPRequestEcho::describe() const {
    auto word_to_ascii = [](uint32_t w) {
        std::string s;
        for (int i = 0; i < 4; i++) {
            const auto c = static_cast<char>((w >> (8 * i)) & 0xFF);
            s += (c >= 0x20 && c < 0x7F) ? c : '.';
        }
        return s;
    };

    std::ostringstream oss;
    oss << "path_len=" << file_len << " path[0:4]='" << word_to_ascii(file_w0) << "'"
        << " path[16:20]='" << word_to_ascii(file_w4) << "'"
        << " path[32:36]='" << word_to_ascii(file_w8) << "'"
        << " range=" << static_cast<unsigned>(range_begin_len) << ":'"
        << word_to_ascii(range_begin_w0) << "'-" << static_cast<unsigned>(range_end_len) << ":'"
        << word_to_ascii(range_end_w0) << "'"
        << " ip=0x" << std::hex << server_ip << std::dec << " port=" << server_port;
    return oss.str();
}

uint64_t HTTPReadConfig::read_stream_register(libstf::stream_t /*stream*/, uint32_t reg) {
    assert(reg < HTTP_READ_CONFIG_REGS);
    return cthread->getCSR(addr_offset + reg);
}

} // namespace oasis
