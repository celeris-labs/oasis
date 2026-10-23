// Board-free check of the HttpConfig readback decoders and the revision-dependent host rules, against
// register words built the way the RTL builds them (hardware/src/hdl/http_read/handler_multi.sv and
// handler_toe.sv readback sections, http_config.sv read map). No cThread, no device: only the pure
// static members of HTTPReadConfig and Scheduler::PlaceOnLane are exercised.
//
// Build: cmake -DOASIS_BUILD_TESTS=ON, target csr_decode_check. Exit status 0 iff every check passes.

#include "oasis/configuration.hpp"
#include "oasis/scheduler.hpp"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#include <string>

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

// One lane nibble as handler_multi / handler_toe pack it: {fatal, conn_up, entry, arm}.
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

    // LANE_ERR bit 7 means RX_FIFO_STALL at revision 2.
    const uint64_t err = 0x81ULL | (0x08ULL << 8);
    const auto     e   = HTTPReadConfig::DecodeLaneErrors(err, 4);
    CHECK(e.at(0).lane_dead && e.at(0).rx_fifo_stall);
    CHECK(e.at(1).resp_err && e.at(1).any());
    CHECK(!e.at(2).any());

    const auto p = HTTPReadConfig::DecodePolicy(lane_policy_word(2, 4, 64, 65536, 16));
    CHECK(!p.toe() && p.revision == 2 && p.num_conns == 4 && p.queue_depth == 64);
    CHECK(p.lane_stall_cycles == 65536 && p.lane_stall_log2 == 16);

    // totalWord as both handlers pack it: {8'd0, rx_err, busy, |tx_refused, |fatal, 1'b0, &conn_up,
    // 6'd0, lane 0's read state, init state, 4'd0}.
    const uint32_t total = (1u << 23) | (1u << 20) | (1u << 18) | (5u << 8) | (3u << 4);
    CHECK(HTTPReadConfig::describe_status(total) ==
          "init=3 lane0_read=5 all_up=1 any_fatal=1 any_tx_refused=0 busy=0 rx_err=1");
    CHECK(HTTPReadConfig::describe_status((1u << 21) | (1u << 22)) ==
          "init=0 lane0_read=0 all_up=0 any_fatal=0 any_tx_refused=1 busy=1 rx_err=0");

    // Revision-2 host rules: depth = OASIS_HTTP_LANE_DEPTH clamped to the queue, no GET cap.
    CHECK(HTTPReadConfig::LaneDepthFor(4, 64) == 4);
    CHECK(HTTPReadConfig::LaneDepthFor(100, 64) == 64);
    CHECK(HTTPReadConfig::LaneDepthFor(0, 64) == 1);
    CHECK(HTTPReadConfig::LaneCreditOk(3, 1, 4));
    CHECK(!HTTPReadConfig::LaneCreditOk(4, 1, 4));
    CHECK(HTTPReadConfig::EffectiveSplit(0, 0) == 0);
    CHECK(HTTPReadConfig::EffectiveSplit(196608, 0) == 196608);
}

void request_split() {
    HTTPReadConfig::RequestBatch b;
    const auto g1 = HTTPReadConfig::BuildGet("10.253.74.74", 9000, "/tpch-30/lineitem.parquet", 4, 4128771);
    const auto g2 = HTTPReadConfig::BuildGet("10.253.74.74", 9000, "/tpch-30/lineitem.parquet",
                                             4128772, 5000000);
    b.text = g1 + g2;
    b.chunk_bytes.push_back(5000000 - 4 + 1);
    b.request_bytes = {static_cast<uint32_t>(g1.size()), static_cast<uint32_t>(g2.size())};
    auto r = HTTPReadConfig::SplitRequests(b);
    CHECK(r.size() == 2 && r[0] == g1 && r[1] == g2);
    for (auto &s : r) {
        oasis::PadRequestTextToBeat(s);
        CHECK(s.size() % 64 == 0);
        CHECK(s.compare(s.size() - 4, 4, "\r\n\r\n") == 0);
        CHECK(s.rfind("GET ", 0) == 0);
    }

    CHECK(HTTPReadConfig::SplitRequests(HTTPReadConfig::RequestBatch {}).empty());

    // Lengths that do not add up to the text are refused, both ways.
    HTTPReadConfig::RequestBatch bad = b;
    bad.request_bytes.back() -= 1;
    CHECK(throws<std::runtime_error>([&] { (void)HTTPReadConfig::SplitRequests(bad); }));
    bad.request_bytes.back() += 2;
    CHECK(throws<std::runtime_error>([&] { (void)HTTPReadConfig::SplitRequests(bad); }));
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

    // Same windows at revision 2 depth 4: a lane owing one chunk still takes more.
    in.lane_depth = HTTPReadConfig::LaneDepthFor(4, 64);
    out           = oasis::Scheduler::PlaceOnLane(in);
    CHECK(out.stream.has_value() && !out.lane_bound_wait);
}

// CSR revision 6 (handler_toe, the TOE keeps a receive ring per session): words as handler_toe.sv
// packs them. LANE_POLICY = {2'd0, 6'(RING_LOG2), 24'(GET_CREDIT), 16'(QUEUE_DEPTH), 8'(NUM_CONNS),
// 8'(CSR_REV)}; the rest of the readback is the revision-2 layout.
uint64_t toe_policy_word(unsigned conns, unsigned qdepth, unsigned credit, unsigned ring_log2,
                         unsigned rev = 6) {
    return uint64_t(rev & 0xFF) | (uint64_t(conns & 0xFF) << 8) | (uint64_t(qdepth & 0xFFFF) << 16) |
           (uint64_t(credit & 0xFFFFFF) << 32) | (uint64_t(ring_log2 & 0x3F) << 56);
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

// One column chunk [begin, begin+size) through AppendChunkGets at `split`: every GET at most `split`
// bytes and at least 1, contiguous, covering exactly the chunk, ONE chunk-length entry (the single
// tlast the decoder sees), lengths adding up to the text. Returns the GET count (0 on any failure).
size_t check_chunk_split(uint64_t begin, uint64_t size, uint64_t split) {
    HTTPReadConfig::RequestBatch b;
    HTTPReadConfig::AppendChunkGets("10.253.74.74", 9000, "/tpch-30/lineitem.parquet", begin,
                                    begin + size - 1, split, b);
    bool ok = b.chunk_bytes.size() == 1 && b.chunk_bytes[0] == size;
    const auto reqs = HTTPReadConfig::SplitRequests(b);
    ok = ok && reqs.size() == b.request_bytes.size();
    uint64_t next = begin, sum = 0;
    for (auto r : reqs) {
        const uint64_t n = range_bytes_of(r);
        ok = ok && n >= 1 && (split == 0 || n <= split) && range_begin_of(r) == next;
        ok = ok && r.rfind("GET /tpch-30/lineitem.parquet HTTP/1.1\r\n", 0) == 0;
        next += n;
        sum += n;
        oasis::PadRequestTextToBeat(r);
        ok = ok && r.size() % 64 == 0 && r.compare(r.size() - 4, 4, "\r\n\r\n") == 0;
    }
    ok = ok && sum == size && next == begin + size;
    const uint64_t expect = (split == 0) ? 1 : (size + split - 1) / split;
    ok = ok && reqs.size() == expect;
    return ok ? reqs.size() : 0;
}

void rev6_rules() {
    // --- revisions: 2 and 6 are driven, every other one is refused ---
    CHECK(oasis::HTTP_CSR_REVISION_TOE == 6);
    for (unsigned raw : {0u, 1u, 2u, 3u, 4u, 5u, 6u, 7u, 8u, 0x7Fu, 0xFFu}) {
        std::string what;
        try {
            HTTPReadConfig::CheckRevision(static_cast<uint8_t>(raw));
        } catch (const std::runtime_error &e) {
            what = e.what();
        }
        const bool driven = raw == 2 || raw == 6;
        CHECK(driven ? what.empty() : what.find("reports CSR revision") != std::string::npos);
    }

    // --- LANE_POLICY: revision 6, 4 lanes, queue 64, GET credit 4, 1 MiB rings ---
    const auto p = HTTPReadConfig::DecodePolicy(toe_policy_word(4, 64, 4, 20));
    CHECK(p.toe() && p.revision == 6);
    CHECK(p.num_conns == 4 && p.queue_depth == 64 && p.get_credit == 4 && p.ring_log2 == 20);
    CHECK(p.lane_stall_cycles == 0 && p.lane_stall_log2 == 0); // no HOL watchdog to misreport
    // Field boundaries do not bleed.
    const auto pmax = HTTPReadConfig::DecodePolicy(toe_policy_word(255, 65535, 0xFFFFFF, 63));
    CHECK(pmax.num_conns == 255 && pmax.queue_depth == 65535 && pmax.get_credit == 0xFFFFFF &&
          pmax.ring_log2 == 63 && pmax.revision == 6);
    // A revision-2 word keeps its revision-2 meaning.
    const auto p2 = HTTPReadConfig::DecodePolicy(lane_policy_word(2, 4, 64, 65536, 16));
    CHECK(!p2.toe() && p2.get_credit == 0 && p2.ring_log2 == 0 && p2.lane_stall_cycles == 65536);
    CHECK(p.describe().find("get_credit=4") != std::string::npos);
    CHECK(p.describe().find("GET cap 241664 B") != std::string::npos);

    // --- the GET cap and the window rule ---
    const uint64_t cap = HTTPReadConfig::ToeGetCap(20, 4);
    CHECK(cap == 241664);                                         // 236 KiB
    CHECK(cap == (236ULL << 10));
    CHECK(4 * (cap + oasis::HTTP_TOE_GET_OVERHEAD) == (1ULL << 20) - (64ULL << 10)); // = budget_err line
    CHECK(4 * (cap + oasis::HTTP_TOE_GET_OVERHEAD) <= (1ULL << 20) - 16 - 4096);    // window rule
    CHECK(HTTPReadConfig::ToeGetCap(20, 1) == (1ULL << 20) - (64ULL << 10) - 4096);
    CHECK(HTTPReadConfig::ToeGetCap(21, 4) == ((2ULL << 20) - (64ULL << 10)) / 4 - 4096);
    CHECK(HTTPReadConfig::ToeGetCap(17, 1) == (128ULL << 10) - (64ULL << 10) - 4096);
    CHECK(HTTPReadConfig::ToeGetCap(17, 16) == 0);                // nothing left for a body
    CHECK(HTTPReadConfig::ToeGetCap(20, 0) == 0);                 // unusable words
    CHECK(HTTPReadConfig::ToeGetCap(16, 4) == 0);
    CHECK(HTTPReadConfig::ToeGetCap(31, 4) == 0);
    CHECK(HTTPReadConfig::ToeGetCap(0, 0) == 0);
    // The split the host uses: the cap, even with OASIS_HTTP_CHUNK_BYTES unset (0 = "no split"); an
    // explicit smaller split wins, a larger one is capped.
    CHECK(HTTPReadConfig::EffectiveSplit(0, cap) == cap);
    CHECK(HTTPReadConfig::EffectiveSplit(196608, cap) == 196608);
    CHECK(HTTPReadConfig::EffectiveSplit(1ULL << 20, cap) == cap);

    // --- column chunks split into GETs of at most the cap, one tlast each ---
    CHECK(check_chunk_split(4, 1ULL << 20, cap) == 5);            // 1 MiB -> 4 x 236 KiB + rest
    CHECK(check_chunk_split(123456789, 5138022, cap) == 22);       // 4.9 MiB -> 22 GETs
    CHECK(check_chunk_split(0, cap, cap) == 1);                    // exactly the cap: one GET
    CHECK(check_chunk_split(0, cap + 1, cap) == 2);                // one byte over: a 1-byte tail
    CHECK(check_chunk_split(77, 1, cap) == 1);
    CHECK(check_chunk_split(4, 424ULL << 10, cap) == 2);
    CHECK(check_chunk_split(4, 5138022, 0) == 1);                  // revision 2: no split
    CHECK(check_chunk_split(4, 5138022, 196608) == 27);            // explicit split, same rules
    {
        // Two chunks in one batch: two entries, GETs back to back, lengths still add up.
        HTTPReadConfig::RequestBatch b;
        HTTPReadConfig::AppendChunkGets("10.253.74.74", 9000, "/f.parquet", 0, (1ULL << 20) - 1, cap, b);
        HTTPReadConfig::AppendChunkGets("10.253.74.74", 9000, "/f.parquet", 1ULL << 20,
                                        (1ULL << 20) + 5138021, cap, b);
        CHECK(b.chunk_bytes.size() == 2 && b.chunk_bytes[0] == (1u << 20) && b.chunk_bytes[1] == 5138022u);
        CHECK(HTTPReadConfig::SplitRequests(b).size() == 5 + 22);
        // A range ending at the top of the 64-bit space does not wrap the cursor.
        HTTPReadConfig::RequestBatch t;
        HTTPReadConfig::AppendChunkGets("h", 1, "/p", UINT64_MAX - 999999, UINT64_MAX, cap, t);
        CHECK(t.chunk_bytes.size() == 1 && t.chunk_bytes[0] == 1000000u);
        CHECK(HTTPReadConfig::SplitRequests(t).size() == 5);
        // An empty range and one too large for the 32-bit chunk-length entry are refused.
        CHECK(throws<std::runtime_error>(
            [&] { HTTPReadConfig::AppendChunkGets("h", 1, "/p", 10, 9, cap, t); }));
        CHECK(throws<std::runtime_error>(
            [&] { HTTPReadConfig::AppendChunkGets("h", 1, "/p", 0, 1ULL << 32, cap, t); }));
    }

    // --- lane depth: protocol 2 + the GET credit ---
    CHECK(HTTPReadConfig::LaneDepthFor(4, 64, 4) == 4);   // the default
    CHECK(HTTPReadConfig::LaneDepthFor(16, 64, 4) == 4);  // OASIS_HTTP_LANE_DEPTH=16 clamped
    CHECK(HTTPReadConfig::LaneDepthFor(2, 64, 4) == 2);
    CHECK(HTTPReadConfig::LaneDepthFor(0, 64, 4) == 1);
    CHECK(HTTPReadConfig::LaneDepthFor(16, 2, 4) == 2);   // and the queue
    CHECK(HTTPReadConfig::LaneDepthFor(16, 64) == 16);    // revision 2: no credit clamp
    CHECK(HTTPReadConfig::LaneCreditOk(3, 1, 4));
    CHECK(!HTTPReadConfig::LaneCreditOk(4, 1, 4));

    // --- STALL: bit 24 is toe_rx's order|len|budget error on 6, the notify overflow below ---
    const uint32_t sw = (1u << 24) | (1u << 25) | (1u << 28) | (3u << 8);
    const auto s6 = HTTPReadConfig::DecodeStall(sw, true);
    CHECK(s6.toe && s6.toe_rx_err && !s6.notify_overflow && s6.rx_fifo_stall && s6.route_stall);
    CHECK(s6.reconnects == 3 && s6.any() && s6.raw == sw);
    CHECK(s6.describe().find("toe_rx_err") != std::string::npos);
    CHECK(s6.describe().find("rx_dispatch") == std::string::npos);    // no revision-2 essay on 6
    const auto s2 = HTTPReadConfig::DecodeStall(sw, false);
    CHECK(!s2.toe && !s2.toe_rx_err && s2.notify_overflow && s2.route_stall);
    CHECK(HTTPReadConfig::DecodeStall(1u << 24, true).any());
    CHECK(!HTTPReadConfig::DecodeStall(0, true).any());

    // --- per-lane words keep the revision-2 layout; LANE_ERR bit 7 = the lane fifo refused a beat ---
    const uint64_t err = 0x80ULL | (0x48ULL << 8);  // lane 0 fifo, lane 1 resp_err + read_timeout
    const auto e = HTTPReadConfig::DecodeLaneErrors(err, 4);
    CHECK(e.at(0).rx_fifo_stall && !e.at(0).lane_dead);
    CHECK(e.at(1).resp_err && e.at(1).read_timeout && !e.at(1).rx_fifo_stall);
    const uint64_t ready = nib(false, true, true, false) | (nib(false, true, true, true) << 4) |
                           (nib(true, true, true, false) << 8) | (nib(false, false, true, true) << 12);
    const auto l = HTTPReadConfig::DecodeLanes(2ULL | (1ULL << 8) | (0ULL << 16), ready, 4);
    CHECK(!l.at(0).arm_ready && l.at(0).entry_ready);   // credit exhausted or text still sending
    CHECK(l.at(1).arm_ready && l.at(2).fatal);

    // --- placement at the revision-6 depth: a lane owing 3 chunks takes a 4th, one owing 4 does not ---
    const uint64_t all = nib(false, true, true, true) | (nib(false, true, true, true) << 4) |
                         (nib(false, true, true, true) << 8) | (nib(false, true, true, true) << 12);
    oasis::Scheduler::LaneInputs in;
    in.host_depth = 64;
    in.needed     = 1;
    in.active     = 4;
    in.rr         = 0;
    in.lane_depth = HTTPReadConfig::LaneDepthFor(16, 64, p.get_credit);
    in.lanes      = HTTPReadConfig::DecodeLanes(3ULL | (4ULL << 8) | (4ULL << 16) | (4ULL << 24), all, 4);
    auto out      = oasis::Scheduler::PlaceOnLane(in);
    CHECK(out.stream && *out.stream == 0);
    in.lanes = HTTPReadConfig::DecodeLanes(4ULL | (4ULL << 8) | (4ULL << 16) | (4ULL << 24), all, 4);
    out      = oasis::Scheduler::PlaceOnLane(in);
    CHECK(!out.stream && out.lane_bound_wait);
}

} // namespace

int main() {
    rev2_decoders();
    rev6_rules();
    request_split();
    placement_at_depth();
    std::printf("csr_decode_check: %d passed, %d failed\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
