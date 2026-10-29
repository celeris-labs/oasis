// Board-free check of the HttpConfig readback decoders and the host rules, against register words
// built the way the RTL builds them (hardware/src/hdl/http_read/handler_multi.sv readback section,
// http_config.sv read map). No cThread, no device: only the pure static members of HTTPReadConfig
// and Scheduler::PlaceOnLane are exercised.
//
// Build: cmake -DOASIS_BUILD_TESTS=ON, target csr_decode_check. Exit status 0 iff every check passes.

#include "oasis/configuration.hpp"
#include "oasis/scheduler.hpp"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#include <string>
#include <vector>

using oasis::HTTPReadConfig;

namespace {

int g_fail = 0;
int g_pass = 0;

void check(bool ok, const char *what) {
    if (ok) {
        ++g_pass;
    } else {
        ++g_fail;
        std::printf("FAIL: %s\n", what);
    }
}

#define CHECK(expr) check((expr), #expr)

// Whether f() throws an E.
template <typename E, typename F>
bool throws(F f) {
    try {
        f();
    } catch (const E &) {
        return true;
    }
    return false;
}

// One lane nibble as handler_multi packs it: {fatal, conn_up, entry, arm}.
uint64_t nib(bool fatal, bool up, bool entry, bool arm) {
    return (uint64_t(fatal) << 3) | (uint64_t(up) << 2) | (uint64_t(entry) << 1) | uint64_t(arm);
}

// LANE_POLICY as handler_multi assigns lanePolicyWord.
uint64_t lane_policy_word(unsigned rev, unsigned conns, unsigned qdepth, unsigned stall_cyc,
                          unsigned stall_log2) {
    return uint64_t(rev & 0xFF) | (uint64_t(conns & 0xFF) << 8) | (uint64_t(qdepth & 0xFFFF) << 16) |
           (uint64_t(stall_cyc & 0xFFFFFF) << 32) | (uint64_t(stall_log2 & 0x3F) << 56);
}

void rev2_decoders() {
    // Revision 2, 4 lanes: lane 1 fatal+up, lane 2 arm+entry, occupancy 3/0/7/255.
    const uint64_t occ   = 3ULL | (0ULL << 8) | (7ULL << 16) | (255ULL << 24);
    const uint64_t ready = nib(false, true, true, false) | (nib(true, true, false, false) << 4) |
                           (nib(false, false, true, true) << 8) | (nib(false, true, true, true) << 12);
    const auto l = HTTPReadConfig::DecodeLanes(occ, ready, 4);
    CHECK(l.count == 4);
    CHECK(l.at(0).occ == 3 && l.at(0).conn_up && l.at(0).entry_ready && !l.at(0).arm_ready);
    CHECK(l.at(1).fatal && !l.at(1).arm_ready);
    CHECK(l.at(2).occ == 7 && l.at(2).arm_ready && l.at(2).entry_ready && !l.at(2).conn_up);
    CHECK(l.at(3).occ == 255 && l.at(3).arm_ready);
    CHECK(throws<std::out_of_range>([&] { (void)l.at(4); }));

    // LANE_ERR bit 7 is RX_FIFO_STALL.
    const uint64_t err = 0x81ULL | (0x08ULL << 8);
    const auto     e   = HTTPReadConfig::DecodeLaneErrors(err, 4);
    CHECK(e.at(0).lane_dead && e.at(0).rx_fifo_stall);
    CHECK(e.at(1).resp_err && e.at(1).any());
    CHECK(!e.at(2).any());

    const auto p = HTTPReadConfig::DecodePolicy(lane_policy_word(2, 4, 64, 65536, 16));
    CHECK(p.revision == 2 && p.num_conns == 4 && p.queue_depth == 64);
    CHECK(p.lane_stall_cycles == 65536 && p.lane_stall_log2 == 16);

    // totalWord as handler_multi packs it: {8'd0, rx_err, busy, |tx_refused, |fatal, 1'b0, &conn_up,
    // 6'd0, lane 0's read state, init state, 4'd0}.
    const uint32_t total = (1u << 23) | (1u << 20) | (1u << 18) | (5u << 8) | (3u << 4);
    CHECK(HTTPReadConfig::describe_status(total) ==
          "init=3 lane0_read=5 all_up=1 any_fatal=1 any_tx_refused=0 busy=0 rx_err=1");
    CHECK(HTTPReadConfig::describe_status((1u << 21) | (1u << 22)) ==
          "init=0 lane0_read=0 all_up=0 any_fatal=0 any_tx_refused=1 busy=1 rx_err=0");

    // STALL: bit 24 is rx_dispatch's notify overflow.
    const uint32_t sw = (1u << 24) | (1u << 25) | (1u << 28) | (3u << 8);
    const auto     s  = HTTPReadConfig::DecodeStall(sw);
    CHECK(s.notify_overflow && s.rx_fifo_stall && s.route_stall && !s.read_timeout);
    CHECK(s.reconnects == 3 && s.any() && s.raw == sw);
    CHECK(s.describe().find("rx_dispatch") != std::string::npos);
    CHECK(HTTPReadConfig::DecodeStall(1u << 24).any());
    CHECK(!HTTPReadConfig::DecodeStall(0).any());

    // Host rules: depth = OASIS_HTTP_LANE_DEPTH clamped to the queue.
    CHECK(HTTPReadConfig::LaneDepthFor(4, 64) == 4);
    CHECK(HTTPReadConfig::LaneDepthFor(100, 64) == 64);
    CHECK(HTTPReadConfig::LaneDepthFor(16, 2) == 2);
    CHECK(HTTPReadConfig::LaneDepthFor(0, 64) == 1);
    CHECK(HTTPReadConfig::LaneCreditOk(3, 1, 4));
    CHECK(!HTTPReadConfig::LaneCreditOk(4, 1, 4));
}

// CheckRevision's message for `raw`, or "" when the library drives it.
std::string refusal(unsigned raw) {
    try {
        HTTPReadConfig::CheckRevision(static_cast<uint8_t>(raw));
    } catch (const std::runtime_error &e) {
        return e.what();
    }
    return "";
}

// Revision 2 is driven; any other value is refused at startup with the same message, naming it.
void revisions() {
    CHECK(oasis::HTTP_CSR_REVISION_MULTI == 2);
    const std::string three = refusal(3);
    CHECK(three.find("drives revision 2 (handler_multi) only") != std::string::npos);
    for (unsigned raw : {0u, 1u, 2u, 3u, 4u, 5u, 6u, 7u, 8u, 0x7Fu, 0xFFu}) {
        std::string expect = three;
        expect.replace(expect.find("revision 3"), 10, "revision " + std::to_string(raw));
        CHECK(raw == 2 ? refusal(raw).empty() : refusal(raw) == expect);
    }
}

// A batch's text as it is sent: its GETs back to back, padded to whole beats once, in the last one.
void request_text() {
    const auto g1 = HTTPReadConfig::BuildGet("10.253.74.74", 9000, "/tpch-30/lineitem.parquet", 4, 4128771);
    const auto g2 = HTTPReadConfig::BuildGet("10.253.74.74", 9000, "/tpch-30/lineitem.parquet",
                                             4128772, 5000000);
    CHECK(g1 == "GET /tpch-30/lineitem.parquet HTTP/1.1\r\nHost: 10.253.74.74:9000\r\n"
                "Range: bytes=4-4128771\r\nConnection: keep-alive\r\n\r\n");
    const std::string plain = g1 + g2;
    std::string       text  = plain;
    oasis::PadRequestTextToBeat(text);
    CHECK(text.size() % 64 == 0 && text.size() > plain.size());
    // The padding is a header of the last GET, inserted before the blank line that ends it.
    CHECK(text.compare(0, plain.size() - 2, plain, 0, plain.size() - 2) == 0);
    CHECK(text.find("X-Pad: ", g1.size()) != std::string::npos);
    CHECK(text.compare(text.size() - 4, 4, "\r\n\r\n") == 0);
    std::string again = text;
    oasis::PadRequestTextToBeat(again);
    CHECK(again == text); // already on a beat
}

// At lane depth 1 (OASIS_HTTP_LANE_DEPTH=1) a lane still owing a chunk is NOT a placement candidate --
// the flow waits in the queue (lane_bound_wait) instead of being admitted and then blocking the
// dispatcher inside its arm.
void placement_at_depth() {
    const uint64_t occ   = 1ULL | (0ULL << 8) | (0ULL << 16) | (1ULL << 24);
    const uint64_t ready = nib(false, true, true, false) | (nib(false, true, true, true) << 4) |
                           (nib(false, false, true, true) << 8) | (nib(false, true, true, false) << 12);
    oasis::Scheduler::LaneInputs in;
    in.lanes      = HTTPReadConfig::DecodeLanes(occ, ready, 4);
    in.host_depth = 64;
    in.needed     = 1;
    in.active     = 4;
    in.rr         = 0;

    in.lane_depth = HTTPReadConfig::LaneDepthFor(1, 64);
    auto out      = oasis::Scheduler::PlaceOnLane(in);
    CHECK(out.stream && *out.stream == 1); // first idle lane from the cursor

    in.lanes = HTTPReadConfig::DecodeLanes(1ULL | (1ULL << 8) | (1ULL << 16) | (1ULL << 24), ready, 4);
    out      = oasis::Scheduler::PlaceOnLane(in);
    CHECK(!out.stream && out.lane_bound_wait); // every lane owes a chunk: park, poll

    // Same windows at the default depth 4: a lane owing one chunk still takes more.
    in.lane_depth = HTTPReadConfig::LaneDepthFor(4, 64);
    out           = oasis::Scheduler::PlaceOnLane(in);
    CHECK(out.stream.has_value() && !out.lane_bound_wait);

    // At depth 4 a lane owing 3 chunks takes a 4th, one owing 4 does not.
    const uint64_t all = nib(false, true, true, true) | (nib(false, true, true, true) << 4) |
                         (nib(false, true, true, true) << 8) | (nib(false, true, true, true) << 12);
    in.lanes = HTTPReadConfig::DecodeLanes(3ULL | (4ULL << 8) | (4ULL << 16) | (4ULL << 24), all, 4);
    out      = oasis::Scheduler::PlaceOnLane(in);
    CHECK(out.stream && *out.stream == 0);
    in.lanes = HTTPReadConfig::DecodeLanes(4ULL | (4ULL << 8) | (4ULL << 16) | (4ULL << 24), all, 4);
    out      = oasis::Scheduler::PlaceOnLane(in);
    CHECK(!out.stream && out.lane_bound_wait);
}

// "Range: bytes=a-b" -> a (or UINT64_MAX when absent).
uint64_t range_begin_of(const std::string &request) {
    const std::string key = "Range: bytes=";
    const size_t at = request.find(key);
    if (at == std::string::npos) {
        return UINT64_MAX;
    }
    return std::strtoull(request.c_str() + at + key.size(), nullptr, 10);
}

// "Range: bytes=a-b" -> b - a + 1 (0 when there is no closed range).
uint64_t range_bytes_of(const std::string &request) {
    const std::string key = "Range: bytes=";
    const size_t at = request.find(key);
    if (at == std::string::npos) {
        return 0;
    }
    char *end = nullptr;
    const char *p = request.c_str() + at + key.size();
    const unsigned long long a = std::strtoull(p, &end, 10);
    if (end == p || *end != '-') {
        return 0;
    }
    const char *q = end + 1;
    const unsigned long long b = std::strtoull(q, &end, 10);
    return (end == q || b < a) ? 0 : static_cast<uint64_t>(b - a + 1);
}

// The GETs of `b`, cut at its request_bytes; empty when those do not add up to the text.
std::vector<std::string> requests_of(const HTTPReadConfig::RequestBatch &b) {
    std::vector<std::string> out;
    size_t                   off = 0;
    for (const uint32_t n : b.request_bytes) {
        out.push_back(b.text.substr(off, n));
        off += n;
    }
    return off == b.text.size() ? out : std::vector<std::string> {};
}

// One column chunk [begin, begin+size) through AppendChunkGets at `split` (OASIS_HTTP_CHUNK_BYTES):
// every GET at most `split` bytes and at least 1, contiguous, covering exactly the chunk, ONE
// chunk-length entry (the single tlast the decoder sees), lengths adding up to the text. Returns the
// GET count (0 on any failure).
size_t check_chunk_split(uint64_t begin, uint64_t size, uint64_t split) {
    HTTPReadConfig::RequestBatch b;
    HTTPReadConfig::AppendChunkGets("10.253.74.74", 9000, "/tpch-30/lineitem.parquet", begin,
                                    begin + size - 1, split, b);
    bool ok = b.chunk_bytes.size() == 1 && b.chunk_bytes[0] == size;
    const auto reqs = requests_of(b);
    ok = ok && !reqs.empty() && reqs.size() == b.request_bytes.size();
    uint64_t next = begin, sum = 0;
    for (const auto &r : reqs) {
        const uint64_t n = range_bytes_of(r);
        ok = ok && n >= 1 && (split == 0 || n <= split) && range_begin_of(r) == next;
        ok = ok && r.rfind("GET /tpch-30/lineitem.parquet HTTP/1.1\r\n", 0) == 0;
        next += n;
        sum += n;
    }
    ok = ok && sum == size && next == begin + size;
    const uint64_t expect = (split == 0) ? 1 : (size + split - 1) / split;
    ok = ok && reqs.size() == expect;
    return ok ? reqs.size() : 0;
}

void chunk_split() {
    CHECK(check_chunk_split(4, 5138022, 0) == 1);           // the default: one GET per chunk
    CHECK(check_chunk_split(4, 5138022, 196608) == 27);
    CHECK(check_chunk_split(200000, 1300000, 100000) == 13);
    CHECK(check_chunk_split(4, 1ULL << 20, 400000) == 3);
    CHECK(check_chunk_split(0, 100000, 100000) == 1);       // exactly the split: one GET
    CHECK(check_chunk_split(0, 100001, 100000) == 2);       // one byte over: a 1-byte tail
    CHECK(check_chunk_split(77, 1, 100000) == 1);

    // Two chunks in one batch: two entries, GETs back to back, lengths still add up.
    HTTPReadConfig::RequestBatch b;
    HTTPReadConfig::AppendChunkGets("10.253.74.74", 9000, "/f.parquet", 0, (1ULL << 20) - 1, 196608, b);
    HTTPReadConfig::AppendChunkGets("10.253.74.74", 9000, "/f.parquet", 1ULL << 20,
                                    (1ULL << 20) + 5138021, 196608, b);
    CHECK(b.chunk_bytes.size() == 2 && b.chunk_bytes[0] == (1u << 20) && b.chunk_bytes[1] == 5138022u);
    CHECK(requests_of(b).size() == 6 + 27);
    HTTPReadConfig::RequestBatch whole; // the same two chunks, unsplit
    HTTPReadConfig::AppendChunkGets("h", 1, "/f.parquet", 0, (1ULL << 20) - 1, 0, whole);
    HTTPReadConfig::AppendChunkGets("h", 1, "/f.parquet", 1ULL << 20, (1ULL << 20) + 5138021, 0, whole);
    CHECK(whole.chunk_bytes == b.chunk_bytes && requests_of(whole).size() == 2);

    // A range ending at the top of the 64-bit space does not wrap the cursor.
    HTTPReadConfig::RequestBatch t;
    HTTPReadConfig::AppendChunkGets("h", 1, "/p", UINT64_MAX - 999999, UINT64_MAX, 196608, t);
    CHECK(t.chunk_bytes.size() == 1 && t.chunk_bytes[0] == 1000000u);
    CHECK(requests_of(t).size() == 6);
    // An empty range and one too large for the 32-bit chunk-length entry are refused.
    CHECK(throws<std::runtime_error>(
        [&] { HTTPReadConfig::AppendChunkGets("h", 1, "/p", 10, 9, 0, t); }));
    CHECK(throws<std::runtime_error>(
        [&] { HTTPReadConfig::AppendChunkGets("h", 1, "/p", 0, 1ULL << 32, 0, t); }));
}

} // namespace

int main() {
    rev2_decoders();
    revisions();
    request_text();
    chunk_split();
    placement_at_depth();
    std::printf("csr_decode_check: %d passed, %d failed\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
