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

// HttpConfig write ids (http_config.sv). handler_multi and handler_toe read no others.
constexpr const uint32_t HTTP_SERVER_IP       = 0;
constexpr const uint32_t HTTP_SERVER_PORT     = 1;
constexpr const uint32_t HTTP_START           = 39;
constexpr const uint32_t HTTP_REQ_TOTAL_BYTES = 40; // request text bytes of an arm; 0 marks an entry
constexpr const uint32_t HTTP_REQ_CHUNK_BYTES = 41; // [31:0] column chunk bytes, [35:32] the lane

// HttpConfig read ids.
constexpr const uint32_t HTTP_TOTAL_WORD     = 2;
constexpr const uint32_t HTTP_INFLIGHT       = 10;
constexpr const uint32_t HTTP_STALL          = 11;
constexpr const uint32_t HTTP_RESP           = 12;
constexpr const uint32_t HTTP_BODY_REMAINING = 13;
constexpr const uint32_t HTTP_CONTENT_LENGTH = 14;
constexpr const uint32_t HTTP_QUEUE_DEPTH    = 15; // chunk entries per lane, not saturated at 255
constexpr const uint32_t HTTP_LANE_OCC       = 16; // a byte per lane: entries owed
constexpr const uint32_t HTTP_LANE_READY     = 17; // a nibble per lane, bits below
constexpr const uint32_t HTTP_LANE_STATE     = 18; // nibbles: tcp_read [31:0], http_req_stream [63:32]
constexpr const uint32_t HTTP_LANE_ERR       = 19; // a sticky byte per lane
constexpr const uint32_t HTTP_LANE_POLICY    = 20; // what the bitstream was built with

constexpr const unsigned HTTP_LANE_ARM_READY   = 0;
constexpr const unsigned HTTP_LANE_ENTRY_READY = 1;
constexpr const unsigned HTTP_LANE_CONN_UP     = 2;
constexpr const unsigned HTTP_LANE_FATAL       = 3;

// How long a lane may refuse a beat or credit before the host reports it as stopped. Long enough
// that a slow object server never trips it.
constexpr const auto HTTP_CREDIT_TIMEOUT = std::chrono::seconds(30);

// Requests one stream may keep in flight. 0 = the queue depth the bitstream reports. Pipelining on a
// lane is safe because each lane is one persistent session, so responses come back in request order;
// across lanes, rx_dispatch (revision 2) or the TOE's per-session rings (revision 6) keep them apart.
// OASIS_HTTP_MAX_INFLIGHT overrides.
constexpr const uint8_t HTTP_DEFAULT_MAX_INFLIGHT = 0;

// Largest byte range of one GET. 0 = one GET per column chunk: a GET costs the object store a roughly
// fixed time, so fewer, larger requests are faster. Revision 6 caps every GET at toe_get_cap()
// regardless. OASIS_HTTP_CHUNK_BYTES overrides.
constexpr const uint64_t HTTP_DEFAULT_CHUNK_BYTES = 0;

// Chunk entries one lane may owe. HTTP/1.1 pipelining on one session is strictly ordered (the server
// answers a request fully before it reads the next), so depth beyond a handful gains nothing and
// costs response bytes in flight (revision 2: in the receive fifo the lanes share; revision 6: in the
// lane's TOE ring). The lanes overlap with each other. OASIS_HTTP_LANE_DEPTH overrides.
constexpr const uint64_t HTTP_DEFAULT_LANE_DEPTH = 4;

// Environment variable `name` as a positive integer, or `fallback` when it is unset, empty, zero or
// negative.
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

// One lane's states from read id 18: tcp_read's, and http_req_stream's, by name.
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

void CheckLane(uint8_t l, uint8_t count) {
    if (l >= count) {
        throw std::out_of_range("HTTP lane " + std::to_string(l) + " does not exist: this bitstream has " +
                                std::to_string(count) + " lane(s)");
    }
}

} // namespace

HTTPReadConfig::HTTPReadConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset,
                                 uint32_t num_regs)
    : Config(cthread, addr_offset, num_regs) {}

// ---- Request text ---------------------------------------------------------------------------------

std::string HTTPReadConfig::BuildGet(const std::string &host, uint16_t port, const std::string &path,
                                     uint64_t range_begin, uint64_t range_end) {
    std::ostringstream oss;
    oss << "GET " << path << " HTTP/1.1\r\n"
        << "Host: " << host << ":" << port << "\r\n"
        << "Range: bytes=" << range_begin << "-" << range_end << "\r\n"
        << "Connection: keep-alive\r\n\r\n";
    return oss.str();
}

void HTTPReadConfig::append_chunk(uint32_t server_ip, uint16_t server_port, const std::string &path,
                                  uint64_t offset, uint64_t size, RequestBatch &batch) {
    // Ranges are inclusive, so an empty chunk would become a request for the rest of the object.
    if (size == 0) {
        throw std::runtime_error("HTTP column chunk of 0 bytes at offset " + std::to_string(offset) +
                                 " in '" + path + "'");
    }
    AppendChunkGets(IpToAscii(server_ip), server_port, path, offset, offset + size - 1, split_bytes(),
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
    // The chunk-length entry is 32 bits wide (REQ_CHUNK_BYTES[31:0]).
    const uint64_t total = range_end - range_begin + 1;
    if (total > UINT32_MAX) {
        throw std::runtime_error("HTTP column chunk of " + std::to_string(total) +
                                 " bytes does not fit the 32-bit chunk-length entry");
    }
    // One entry for the whole chunk, however many GETs it splits into: the decoder sees one tlast.
    batch.chunk_bytes.push_back(static_cast<uint32_t>(total));

    // Written so that a range ending at the top of the 64-bit space cannot wrap the cursor.
    for (uint64_t begin = range_begin;;) {
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

// Coyote's DMA moves whole 64-byte beats. Padding the text with a header the server ignores makes the
// transfer end exactly at the text, so http_req_stream has no tail to drain.
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

// ---- Writing beats --------------------------------------------------------------------------------

// HttpConfig does not back-pressure: a START written while the previous beat is unconsumed replaces
// it. So the caller writes every parameter of the beat, req_total_bytes included (it tells an entry
// from an arm, and LANE_READY answers for the beat the live registers describe), then waits here,
// then pulses START. One read per poll: both admission bits and the fatal flag are in the lane's
// nibble of read id 17. Fatal first: ARM_READY stays low forever on a lane that went fatal while
// armed.
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

// LANE_ERR bit 0 tells the two kinds of fatal lane apart: rx_dispatch's head-of-line watchdog killed
// it (bytes went missing mid-response), or a read failed that the hardware cannot replay.
void HTTPReadConfig::throw_lane_fatal(uint8_t lane, const char *what) {
    const auto errs       = lane_errors();
    const auto state_word = read_register(HTTP_LANE_STATE).value();
    const auto e          = errs.at(lane);

    std::ostringstream msg;
    msg << "FPGA HTTP lane " << unsigned(lane) << " is fatal while waiting for " << what << ": ";
    if (e.lane_dead) {
        msg << "rx_dispatch's head-of-line watchdog killed it after it held the shared receive path "
               "for LANE_STALL_CYCLES, so bytes were lost mid-response; the decoder behind it "
               "stopped consuming";
    } else {
        msg << "a read failed in a way the hardware cannot replay; the lane stays down until the "
               "board is reprogrammed";
    }
    msg << " [" << e.describe() << "; " << DescribeLaneState(state_word, lane) << "; "
        << stall().describe() << "]";
    throw std::runtime_error(msg.str());
}

// Per lane, because inflightWord's occupancy is the maximum over lanes: a busy neighbour would block
// an idle lane, and a stopped lane would hide behind a draining one.
void HTTPReadConfig::await_lane_credit(uint8_t lane, size_t needed) {
    const char *what = "a batch of chunk-length entries";
    if (needed == 0) {
        return;
    }

    const size_t limit    = std::max<size_t>(lane_depth_limit(), needed);
    const auto   deadline = std::chrono::steady_clock::now() + HTTP_CREDIT_TIMEOUT;
    while (true) {
        const auto l = lanes().at(lane);
        // A fatal lane retires nothing, so its occupancy never falls.
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

void HTTPReadConfig::push_entries(const RequestBatch &batch, uint8_t lane) {
    if (batch.chunk_bytes.empty()) {
        return;
    }
    // The entries are freed only by responses, which need the arm that follows them, so a batch
    // larger than the queue could never drain, and room for all of it is reserved first.
    if (batch.chunk_bytes.size() > max_batch_chunks()) {
        std::ostringstream msg;
        msg << "HTTP batch of " << batch.chunk_bytes.size() << " column chunks exceeds the hardware "
            << "queue (" << max_batch_chunks() << "); it must be split, or the entries deadlock "
            << "against the arm";
        throw std::runtime_error(msg.str());
    }
    await_lane_credit(lane, batch.chunk_bytes.size());

    // Every beat carries its lane in REQ_CHUNK_BYTES[35:32]; req_total_bytes 0 marks an entry.
    const uint64_t lane_field = static_cast<uint64_t>(lane & 0xF) << 32;
    for (const uint32_t bytes : batch.chunk_bytes) {
        write_register(
            libstf::ConfigRegister(HTTP_REQ_CHUNK_BYTES, static_cast<uint64_t>(bytes) | lane_field));
        write_register(libstf::ConfigRegister(HTTP_REQ_TOTAL_BYTES, 0u));
        await_cfg_ready("chunk-length entry", lane, LaneAdmit::Entry);
        write_register(libstf::ConfigRegister(HTTP_START, 1));
    }
}

void HTTPReadConfig::arm_transfer(uint32_t server_ip, uint16_t server_port, uint32_t text_bytes,
                                  uint8_t lane) {
    // The arm carries its lane like the entries do; it ignores the low 32 bits.
    const uint64_t lane_field = static_cast<uint64_t>(lane & 0xF) << 32;
    write_register(libstf::ConfigRegister(HTTP_SERVER_IP, server_ip));
    write_register(libstf::ConfigRegister(HTTP_SERVER_PORT, server_port));
    write_register(libstf::ConfigRegister(HTTP_REQ_CHUNK_BYTES, lane_field));
    write_register(
        libstf::ConfigRegister(HTTP_REQ_TOTAL_BYTES, static_cast<uint64_t>(text_bytes)));
    await_cfg_ready("transfer arm", lane, LaneAdmit::Arm);
    write_register(libstf::ConfigRegister(HTTP_START, 1));
}

// HttpConfig hands the handler the live register values, so the next write (the next GET's arm, or
// the next flow's entry) would change what this arm means until the handler has taken it. ARM_READY
// falling is the proof: it was high before the START, and taking the arm makes the lane's request
// stream busy until its text is sent, which this thread does only after this returns. Two reads per
// poll (16, 17).
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

// ---- What the bitstream reports -------------------------------------------------------------------

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
    // Read before anything touches read ids 16 to 20: below revision 2 those reads are a resp_error.
    if (revision_ == 0) {
        const uint8_t raw = inflight().revision;
        CheckRevision(raw);
        revision_ = raw;
    }
    return revision_;
}

uint8_t HTTPReadConfig::lane_count() {
    // From LANE_POLICY, which has NUM_CONNS untruncated (inflightWord[23:20] is four bits).
    if (lane_count_ == 0) {
        const auto conns = policy().num_conns;
        if (conns == 0 || conns > HTTP_MAX_LANES) {
            throw std::runtime_error("FPGA HTTP handler reports " + std::to_string(conns) +
                                     " lanes (LANE_POLICY); this library drives 1 to " +
                                     std::to_string(HTTP_MAX_LANES));
        }
        lane_count_ = conns;
    }
    return lane_count_;
}

uint8_t HTTPReadConfig::lane_for_stream(libstf::stream_t stream) {
    if (stream >= lane_count()) {
        throw std::runtime_error("decode stream " + std::to_string(stream) + " has no HTTP lane: the "
                                 "bitstream has " + std::to_string(lane_count()));
    }
    return static_cast<uint8_t>(stream);
}

size_t HTTPReadConfig::max_batch_chunks() {
    if (max_batch_chunks_ == 0) {
        max_batch_chunks_ = static_cast<uint32_t>(read_register(HTTP_QUEUE_DEPTH).value());
        if (max_batch_chunks_ == 0) {
            throw std::runtime_error("FPGA HTTP handler reports a chunk queue depth of 0 (read id 15)");
        }
    }
    return max_batch_chunks_;
}

size_t HTTPReadConfig::lane_depth_limit() {
    if (lane_depth_ != 0) {
        return lane_depth_;
    }
    const size_t hw      = max_batch_chunks();
    const bool   env_set = std::getenv("OASIS_HTTP_LANE_DEPTH") != nullptr &&
                           *std::getenv("OASIS_HTTP_LANE_DEPTH") != '\0';
    const size_t want    = static_cast<size_t>(EnvOr("OASIS_HTTP_LANE_DEPTH", HTTP_DEFAULT_LANE_DEPTH));
    const size_t credit  = toe_ring() ? static_cast<size_t>(policy().get_credit) : 0;
    if (toe_ring() && credit == 0) {
        throw std::runtime_error("FPGA reports CSR revision 6 (TOE receive ring) but LANE_POLICY "
                                 "carries GET_CREDIT 0 [" + policy().describe() + "]");
    }
    lane_depth_ = LaneDepthFor(want, hw, credit);
    if (toe_ring()) {
        // On stderr too: the context is built while the extension loads, before DuckDB logs.
        char line[200];
        std::snprintf(line, sizeof(line),
                      "HTTPReadConfig: CSR revision 6 (TOE receive rings): lane depth %zu, GETs capped "
                      "at %llu B (split %llu B)",
                      lane_depth_, static_cast<unsigned long long>(toe_get_cap()),
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

uint64_t HTTPReadConfig::toe_get_cap() {
    if (!toe_ring()) {
        return 0;
    }
    if (toe_cap_ == 0) {
        const auto p   = policy();
        const auto cap = p.toe() ? ToeGetCap(p.ring_log2, p.get_credit) : 0;
        // A guessed GET size could close a lane's TOE window for good, so refuse instead.
        if (cap == 0) {
            throw std::runtime_error("FPGA reports CSR revision 6 (TOE receive ring) but its "
                                     "LANE_POLICY word gives no usable GET cap [" + p.describe() + "]");
        }
        toe_cap_ = cap;
    }
    return toe_cap_;
}

uint8_t HTTPReadConfig::max_inflight() {
    const uint8_t  depth      = inflight().depth;
    const uint64_t configured = EnvOr("OASIS_HTTP_MAX_INFLIGHT", HTTP_DEFAULT_MAX_INFLIGHT);
    return (configured == 0 || configured >= depth) ? depth : static_cast<uint8_t>(configured);
}

bool HTTPReadConfig::LaneCreditOk(size_t occ, size_t needed, size_t limit) {
    return occ + needed <= limit;
}

size_t HTTPReadConfig::LaneDepthFor(size_t want, size_t hw, size_t get_credit) {
    if (get_credit != 0) {
        hw = std::min(hw, get_credit);
    }
    return std::max<size_t>(1, std::min(want, hw));
}

uint64_t HTTPReadConfig::ToeGetCap(uint8_t ring_log2, uint32_t get_credit) {
    // 2^17 is the smallest ring that leaves a body after the slack and one header; 2^30 is far past
    // any TOE. Outside that the word is garbage.
    if (get_credit == 0 || ring_log2 < 17 || ring_log2 > 30) {
        return 0;
    }
    const uint64_t budget  = (1ULL << ring_log2) - HTTP_TOE_RING_SLACK;
    const uint64_t per_get = budget / get_credit;
    return per_get > HTTP_TOE_GET_OVERHEAD ? per_get - HTTP_TOE_GET_OVERHEAD : 0;
}

// ---- Readback -------------------------------------------------------------------------------------

HTTPReadConfig::HTTPInflight HTTPReadConfig::inflight() {
    const auto word = static_cast<uint32_t>(read_register(HTTP_INFLIGHT).value());
    HTTPInflight f {};
    f.occupied    = static_cast<uint8_t>(word & 0xFFu);
    f.depth       = static_cast<uint8_t>((word >> 8) & 0xFFu);
    f.has_pending = (word & (1u << 16)) != 0;
    f.peer_closed = (word & (1u << 17)) != 0;
    f.conn_up     = (word & (1u << 18)) != 0;
    f.revision    = static_cast<uint8_t>((word >> 24) & 0xFFu);
    return f;
}

HTTPReadConfig::HTTPLanes HTTPReadConfig::lanes() {
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

HTTPReadConfig::HTTPStall HTTPReadConfig::stall() {
    return DecodeStall(static_cast<uint32_t>(read_register(HTTP_STALL).value()), toe_ring());
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

HTTPReadConfig::HTTPLanes HTTPReadConfig::DecodeLanes(uint64_t occ_word, uint64_t ready_word,
                                                     uint8_t count) {
    HTTPLanes l {};
    l.count = (count > HTTP_MAX_LANES) ? HTTP_MAX_LANES : count;
    for (uint8_t i = 0; i < l.count; i++) {
        const auto nib        = static_cast<unsigned>((ready_word >> (4u * i)) & 0xFu);
        l.lane[i].occ         = static_cast<uint8_t>((occ_word >> (8u * i)) & 0xFFu);
        l.lane[i].arm_ready   = (nib & (1u << HTTP_LANE_ARM_READY)) != 0;
        l.lane[i].entry_ready = (nib & (1u << HTTP_LANE_ENTRY_READY)) != 0;
        l.lane[i].conn_up     = (nib & (1u << HTTP_LANE_CONN_UP)) != 0;
        l.lane[i].fatal       = (nib & (1u << HTTP_LANE_FATAL)) != 0;
    }
    return l;
}

HTTPReadConfig::HTTPLaneErrors HTTPReadConfig::DecodeLaneErrors(uint64_t err_word, uint8_t count) {
    HTTPLaneErrors e {};
    e.count = (count > HTTP_MAX_LANES) ? HTTP_MAX_LANES : count;
    for (uint8_t i = 0; i < e.count; i++) {
        const auto byte         = static_cast<uint8_t>((err_word >> (8u * i)) & 0xFFu);
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
    p.revision    = static_cast<uint8_t>(policy_word & 0xFFu);
    p.num_conns   = static_cast<uint8_t>((policy_word >> 8) & 0xFFu);
    p.queue_depth = static_cast<uint16_t>((policy_word >> 16) & 0xFFFFu);
    // Revision 6 has no head-of-line watchdog and puts its GET credit and ring size there instead.
    if (p.revision == HTTP_CSR_REVISION_TOE) {
        p.get_credit = static_cast<uint32_t>((policy_word >> 32) & 0xFFFFFFu);
        p.ring_log2  = static_cast<uint8_t>((policy_word >> 56) & 0x3Fu);
        return p;
    }
    p.lane_stall_cycles = static_cast<uint32_t>((policy_word >> 32) & 0xFFFFFFu);
    p.lane_stall_log2   = static_cast<uint8_t>((policy_word >> 56) & 0x3Fu);
    return p;
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
    s.toe              = toe_ring;
    s.notify_overflow  = !toe_ring && (word & (1u << 24)) != 0;
    s.toe_rx_err       = toe_ring && (word & (1u << 24)) != 0;
    s.rx_fifo_stall    = (word & (1u << 25)) != 0;
    s.read_timeout     = (word & (1u << 26)) != 0;
    s.align_starved    = (word & (1u << 27)) != 0;
    s.route_stall      = (word & (1u << 28)) != 0;
    return s;
}

const HTTPReadConfig::HTTPLane &HTTPReadConfig::HTTPLanes::at(uint8_t l) const {
    CheckLane(l, count);
    return lane[l];
}

const HTTPReadConfig::HTTPLaneError &HTTPReadConfig::HTTPLaneErrors::at(uint8_t l) const {
    CheckLane(l, count);
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
    oss << "inflight=" << static_cast<unsigned>(occupied) << "/" << static_cast<unsigned>(depth)
        << " conn=" << (conn_up ? "up" : "down") << (has_pending ? " pending" : "")
        << (peer_closed ? " peer-closed" : "") << " rev=" << static_cast<unsigned>(revision);
    return oss.str();
}

// The flags on one line, then one line of explanation per condition that is set: several sticky
// bits latch together over a long query.
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

    if (connect_stalled && !init_error) {
        oss << "\n    connect_stalled: openStatus never arrived; the TOE is retrying the SYN, most "
               "likely on an ephemeral port the server still holds in TIME_WAIT";
    }
    if (send_error) {
        oss << "\n    send_error: the TOE refused tx buffer room for a request; the handler re-sends, "
               "so nothing is lost, but requests are queued faster than the tx path drains";
    }
    if (resp_unframeable) {
        oss << "\n    unframeable: a response had no Content-Length (chunked encoding or an error "
               "page), so its end could not be found";
    }
    if (dirty_abort) {
        oss << "\n    dirty_abort: a lane went fatal (a dirty abort, an unreplayable read error or a "
               "head-of-line kill); lane_errors() says which and why";
    }
    if (status_bad) {
        oss << "\n    bad_http_status: the server answered neither 200 nor 206, so the decoder got an "
               "error document; response() has the digits (416: range past EOF, 400: malformed "
               "request, 5xx: the server)";
    }
    if (notify_overflow) {
        oss << "\n    notify_overflow: rx_dispatch dropped segment announcements, so a response is "
               "short; the reader is not draining";
    }
    if (toe_rx_err) {
        oss << "\n    toe_rx_err: toe_rx saw an order error (data with no readPkg outstanding), a length "
               "error, or a budget error (a lane's unread ring bytes passed the window budget: a GET "
               "above the cap, too many GETs, or an origin that ignored Range)";
    }
    if (rx_fifo_stall) {
        oss << (toe ? "\n    rx_fifo_stall: a lane fifo refused a beat toe_rx had reserved room for; "
                      "LANE_ERR bit 7 names the lane"
                    : "\n    rx_fifo_stall: a lane fifo filled and back-pressured the TOE; the parser "
                      "does not drain fast enough (RX_FIFO_DEPTH in tcp_read.sv)");
    }
    if (read_timeout) {
        oss << "\n    read_timeout: a read waited with nothing arriving and aborted; with work "
               "outstanding the lane goes fatal and the batch must be reissued from the host";
    }
    if (align_starved) {
        oss << "\n    align_starved: body bytes arrived with no chunk length queued, so two columns "
               "may share a decoder stream; treat the results of this run as suspect";
    }
    if (route_stall) {
        oss << (toe ? "\n    route_stall: toe_rx routed a beat to a lane that refused it; its room "
                      "reservation is wrong"
                    : "\n    route_stall: rx_dispatch was refused by a lane despite its space check, "
                      "so the other lanes wait behind it (the lane with rx_fifo_stall)");
    }
    return oss.str();
}

std::string HTTPReadConfig::HTTPResponse::describe() const {
    std::ostringstream oss;
    oss << "last response: status=" << std::string(status, 3) << (status_ok ? " (ok)" : " (NOT ok)")
        << " Content-Length=" << content_length << " body_remaining=" << body_remaining;
    if (unframeable) oss << " UNFRAMEABLE(no Content-Length)";
    if (dirty)       oss << " partially-delivered";
    return oss.str();
}

// Mirrors totalWord in handler_multi.sv and handler_toe.sv; the bits not named here read 0. Bit 23
// is rxd_overflow on revision 2 and toe_rx's contract or budget error on revision 6.
std::string HTTPReadConfig::describe_status(uint32_t status) {
    std::ostringstream oss;
    oss << "init=" << ((status >> 4) & 0xFu) << " lane0_read=" << ((status >> 8) & 0xFu)
        << " all_up=" << ((status >> 18) & 1u) << " any_fatal=" << ((status >> 20) & 1u)
        << " any_tx_refused=" << ((status >> 21) & 1u) << " busy=" << ((status >> 22) & 1u)
        << " rx_err=" << ((status >> 23) & 1u);
    return oss.str();
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
      << (toe_ring() ? ", TOE receive rings" : "") << ", read ids 0.." << last << "):\n";
    std::vector<uint64_t> w(static_cast<size_t>(last) + 1, 0);
    for (int i = 0; i <= last; i++) {
        w[i] = read_register(static_cast<uint32_t>(i)).value();
        o << "  [" << std::setw(2) << i << "] " << hex(w[i]) << "\n";
    }
    o << "  status(2):   " << describe_status(static_cast<uint32_t>(w[HTTP_TOTAL_WORD])) << "\n";
    o << "  inflight:    " << inflight().describe() << "\n";
    o << "  stall:       " << stall().describe() << "\n";
    o << "  response:    " << response().describe()
      << " (digits and lengths from lane 0, flags over all lanes)\n";
    const uint8_t n = lane_count();
    o << "  " << DecodeLanes(w[HTTP_LANE_OCC], w[HTTP_LANE_READY], n).describe() << "\n";
    o << "  " << DecodeLaneErrors(w[HTTP_LANE_ERR], n).describe() << "\n";
    for (uint8_t l = 0; l < n; l++) {
        o << "  lane " << unsigned(l) << " state: " << DescribeLaneState(w[HTTP_LANE_STATE], l) << "\n";
    }
    o << "  " << DecodePolicy(w[HTTP_LANE_POLICY]).describe() << "\n";
    if (toe_ring()) {
        const auto f = static_cast<uint32_t>(w[HTTP_INFLIGHT]);
        o << "  revision 6: INFLIGHT[16] some lane has notified bytes not yet asked for = "
          << ((f >> 16) & 1u) << ", INFLIGHT[17] some lane's FIN has settled = " << ((f >> 17) & 1u)
          << "; LANE_ERR bit 0 is unused, bit 7 = the lane fifo refused a routed beat\n";
        o << "  host: lane depth " << lane_depth_ << " (0 = not computed yet), split "
          << (toe_cap_ != 0 ? EffectiveSplit(ConfiguredChunkBytes(), toe_cap_) : 0) << " B\n";
    }
    return o.str();
}

} // namespace oasis
