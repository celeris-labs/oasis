// Board-free check of the HttpConfig readback decoders and the revision-dependent host rules, against
// register words built the way the RTL builds them (hardware/src/hdl/http_read/handler_slots.sv and
// handler_multi.sv readback sections, http_config.sv read map). No cThread, no device: only the pure
// static members of HTTPReadConfig are exercised.
//
// Build: cmake -DOASIS_BUILD_TESTS=ON, target csr_decode_check. Exit status 0 iff every check passes.

#include "oasis/configuration.hpp"
#include "oasis/scheduler.hpp"

#include <array>
#include <cstdint>
#include <cstdio>
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

// One lane/connection nibble as handler_{multi,slots} pack it: {fatal, conn_up, entry, arm}.
uint64_t nib(bool fatal, bool up, bool entry, bool arm) {
    return (uint64_t(fatal) << 3) | (uint64_t(up) << 2) | (uint64_t(entry) << 1) | uint64_t(arm);
}

// SLOT_POLICY exactly as handler_slots assigns slotPolicyWord.
uint64_t slot_policy_word(unsigned rev, unsigned conns, unsigned decs, unsigned slot_log2,
                          unsigned rd_log2, unsigned entry_depth, unsigned fifo_log2) {
    return uint64_t(rev & 0xFF) | (uint64_t(conns & 0xFF) << 8) | (uint64_t(decs & 0xFF) << 16) |
           (uint64_t(slot_log2 & 0x3F) << 24) | (uint64_t(rd_log2 & 0x3F) << 30) |
           (uint64_t(entry_depth & 0xFFFF) << 36) | (uint64_t(fifo_log2 & 0x3F) << 52);
}

// LANE_POLICY as both handlers assign lanePolicyWord.
uint64_t lane_policy_word(unsigned rev, unsigned conns, unsigned qdepth, unsigned stall_cyc,
                          unsigned stall_log2) {
    return uint64_t(rev & 0xFF) | (uint64_t(conns & 0xFF) << 8) | (uint64_t(qdepth & 0xFFFF) << 16) |
           (uint64_t(stall_cyc & 0xFFFFFF) << 32) | (uint64_t(stall_log2 & 0x3F) << 56);
}

void rev2_decoders() {
    // build-119 / build-125: 4 lanes, lane 1 fatal+up, lane 2 arm+entry, occupancy 3/0/7/255.
    const uint64_t occ   = 3ULL | (0ULL << 8) | (7ULL << 16) | (255ULL << 24);
    const uint64_t ready = nib(false, true, true, false) | (nib(true, true, false, false) << 4) |
                           (nib(false, false, true, true) << 8) | (nib(false, true, true, true) << 12);
    const auto l = HTTPReadConfig::DecodeLanes(occ, ready, 4);
    CHECK(l.count == 4);
    CHECK(l.at(0).occ == 3 && l.at(0).conn_up && l.at(0).entry_ready && !l.at(0).arm_ready);
    CHECK(l.at(1).fatal && !l.at(1).arm_ready);
    CHECK(l.at(2).occ == 7 && l.at(2).arm_ready && l.at(2).entry_ready && !l.at(2).conn_up);
    CHECK(l.at(3).occ == 255 && l.at(3).arm_ready);
    bool threw = false;
    try {
        (void)l.at(4);
    } catch (const std::out_of_range &) {
        threw = true;
    }
    CHECK(threw);

    // LANE_ERR bit 7 means RX_FIFO_STALL at revision 2.
    const uint64_t err = 0x81ULL | (0x08ULL << 8);
    const auto     e   = HTTPReadConfig::DecodeLaneErrors(err, 4, 2);
    CHECK(e.at(0).lane_dead && e.at(0).rx_fifo_stall && !e.at(0).slot_overflow);
    CHECK(e.at(1).resp_err && e.at(1).any());
    CHECK(!e.at(2).any());
    // The default revision argument is 2, which is what every pre-WP4 caller meant.
    CHECK(HTTPReadConfig::DecodeLaneErrors(err, 4).at(0).rx_fifo_stall);

    const auto p = HTTPReadConfig::DecodePolicy(lane_policy_word(2, 4, 64, 65536, 16));
    CHECK(p.valid() && p.revision == 2 && p.num_conns == 4 && p.queue_depth == 64);
    CHECK(p.lane_stall_cycles == 65536 && p.lane_stall_log2 == 16);

    // Revision-2 host rules are what shipped: depth = OASIS_HTTP_LANE_DEPTH clamped to the queue,
    // no drained term, no GET cap.
    CHECK(HTTPReadConfig::LaneDepthFor(2, 4, 64) == 4);
    CHECK(HTTPReadConfig::LaneDepthFor(2, 100, 64) == 64);
    CHECK(HTTPReadConfig::LaneDepthFor(2, 0, 64) == 1);
    CHECK(HTTPReadConfig::LaneDepthFor(0, 4, 64) == 1);   // pre-lane bitstream
    CHECK(HTTPReadConfig::LaneCreditOk(2, 3, 1, 4, false)); // drained is ignored below rev 3
    CHECK(!HTTPReadConfig::LaneCreditOk(2, 4, 1, 4, true));
    CHECK(HTTPReadConfig::EffectiveSplit(0, 0) == 0);
    CHECK(HTTPReadConfig::EffectiveSplit(196608, 0) == 196608);

    // A policy word from a revision-2 bitstream is not a slot policy.
    CHECK(!HTTPReadConfig::DecodeSlotPolicy(lane_policy_word(2, 4, 64, 65536, 16)).valid());
}

void rev3_decoders() {
    // build-124: rev 3, 4 conns, 4 decoders, 4 MiB slots, RD_MAX 16 KiB, ENTRY_DEPTH 64, 1024-beat fifo.
    const auto sp = HTTPReadConfig::DecodeSlotPolicy(slot_policy_word(3, 4, 4, 22, 14, 64, 10));
    CHECK(sp.valid());
    CHECK(sp.revision == 3 && sp.n_conns == 4 && sp.n_decoders == 4);
    CHECK(sp.slot_log2 == 22 && sp.rd_max_log2 == 14 && sp.entry_depth == 64 && sp.wr_fifo_log2 == 10);
    CHECK(sp.slot_bytes() == (4ULL << 20));
    CHECK(sp.region_bytes() == (16ULL << 20));
    CHECK(sp.max_get_bytes() == (4ULL << 20) - (64ULL << 10));
    // Stage 2 shape decodes too (24 conns), and field boundaries do not bleed.
    const auto s2 = HTTPReadConfig::DecodeSlotPolicy(slot_policy_word(3, 24, 4, 22, 14, 65535, 63));
    CHECK(s2.n_conns == 24 && s2.entry_depth == 65535 && s2.wr_fifo_log2 == 63 && s2.slot_log2 == 22);

    // Per-connection words, 32-wide form: conn 0 drained+arm+entry+up, conn 1 busy (armed, not
    // drained), conn 2 fatal with SLOT_OVERFLOW, conn 17 lives in READY word 1 / ERR word 2.
    std::array<uint64_t, 4> occ {}, err {};
    std::array<uint64_t, 2> ready {};
    occ[0]   = 0ULL | (1ULL << 8) | (2ULL << 16);
    ready[0] = nib(false, true, true, true) | (nib(false, true, true, false) << 4) |
               (nib(true, false, false, false) << 8);
    ready[1] = nib(false, true, false, true) << (4 * (17 - 16));
    err[0]   = (0x80ULL << 16);        // conn 2: bit 7 = SLOT_OVERFLOW at rev 3
    err[2]   = (0x40ULL << (8 * (17 - 16))); // conn 17: READ_TIMEOUT
    const uint64_t drained = (1ULL << 0) | (1ULL << 17) | (1ULL << (32 + 2));
    const auto c = HTTPReadConfig::DecodeConns(occ, ready, err, drained, 24);
    CHECK(c.count == 24);
    CHECK(c.at(0).drained && c.at(0).arm_ready && c.at(0).entry_ready && c.at(0).conn_up);
    CHECK(c.at(1).occ == 1 && !c.at(1).drained && !c.at(1).arm_ready && c.at(1).conn_up);
    CHECK(c.at(2).fatal && c.at(2).overflow && c.at(2).err_raw == 0x80 && c.at(2).occ == 2);
    CHECK(c.at(17).drained && c.at(17).arm_ready && !c.at(17).entry_ready && c.at(17).err_raw == 0x40);
    CHECK(!c.at(16).drained && c.at(16).err_raw == 0 && !c.at(16).arm_ready);
    bool threw = false;
    try {
        (void)c.at(24);
    } catch (const std::out_of_range &) {
        threw = true;
    }
    CHECK(threw);
    CHECK(HTTPReadConfig::DecodeConns(occ, ready, err, drained, 40).count == 32); // clamped

    // Revision 3 keeps 16..20 in their revision-2 shape for conns 0..7: laneReadyWord is
    // {32'd0, connReadyWord[0][31:0]} and laneErrWord is connErrWord[0]. Decoding them with the
    // revision-2 decoder must agree with the revision-3 one -- except bit 7, which is REDEFINED.
    const auto l = HTTPReadConfig::DecodeLanes(occ[0], ready[0] & 0xFFFFFFFFULL, 4);
    for (uint8_t i = 0; i < 4; i++) {
        CHECK(l.at(i).arm_ready == c.at(i).arm_ready && l.at(i).fatal == c.at(i).fatal &&
              l.at(i).occ == c.at(i).occ);
    }
    const auto e3 = HTTPReadConfig::DecodeLaneErrors(err[0], 4, 3);
    CHECK(e3.at(2).slot_overflow && !e3.at(2).rx_fifo_stall);
    const auto e2 = HTTPReadConfig::DecodeLaneErrors(err[0], 4, 2);
    CHECK(e2.at(2).rx_fifo_stall && !e2.at(2).slot_overflow);

    // Revision-3 host rules: depth 1 per connection whatever the environment asks, credit needs
    // the slot drained, GETs capped at slot - 64 KiB.
    CHECK(HTTPReadConfig::LaneDepthFor(3, 4, 64) == 1);
    CHECK(HTTPReadConfig::LaneDepthFor(3, 1, 64) == 1);
    CHECK(HTTPReadConfig::LaneCreditOk(3, 0, 1, 1, true));
    CHECK(!HTTPReadConfig::LaneCreditOk(3, 0, 1, 1, false)); // armed, response still in the slot
    CHECK(!HTTPReadConfig::LaneCreditOk(3, 1, 1, 1, true));  // previous chunk not retired
    CHECK(HTTPReadConfig::LaneCreditOk(3, 0, 3, 3, true));   // a 3-chunk batch gets the lane alone
    const uint64_t cap = sp.max_get_bytes();
    CHECK(HTTPReadConfig::EffectiveSplit(0, cap) == cap);          // default: one GET per chunk, capped
    CHECK(HTTPReadConfig::EffectiveSplit(196608, cap) == 196608);  // explicit smaller split wins
    CHECK(HTTPReadConfig::EffectiveSplit(8ULL << 20, cap) == cap); // explicit larger split is capped
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

    // No lengths recorded -> the whole text is one request (a batch built by pre-WP4 code).
    HTTPReadConfig::RequestBatch one;
    one.text = g1;
    CHECK(HTTPReadConfig::SplitRequests(one).size() == 1);
    CHECK(HTTPReadConfig::SplitRequests(HTTPReadConfig::RequestBatch {}).empty());

    // Lengths that do not add up to the text are refused, both ways.
    HTTPReadConfig::RequestBatch bad = b;
    bad.request_bytes.back() -= 1;
    bool threw = false;
    try {
        (void)HTTPReadConfig::SplitRequests(bad);
    } catch (const std::runtime_error &) {
        threw = true;
    }
    CHECK(threw);
    bad.request_bytes.back() += 2;
    threw = false;
    try {
        (void)HTTPReadConfig::SplitRequests(bad);
    } catch (const std::runtime_error &) {
        threw = true;
    }
    CHECK(threw);
}


// The scheduler is unchanged by WP4; what changes is the lane depth it is handed. At revision 3 that
// is 1, so a lane still owing a chunk is NOT a placement candidate -- the flow waits in the queue
// (lane_bound_wait) instead of being admitted and then blocking the dispatcher inside its arm.
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

    in.lane_depth = HTTPReadConfig::LaneDepthFor(3, 4, 64);
    auto out      = oasis::Scheduler::PlaceOnLane(in);
    CHECK(out.stream && *out.stream == 1); // first idle lane from the cursor

    in.lanes = HTTPReadConfig::DecodeLanes(1ULL | (1ULL << 8) | (1ULL << 16) | (1ULL << 24), ready, 4);
    out      = oasis::Scheduler::PlaceOnLane(in);
    CHECK(!out.stream && out.lane_bound_wait); // every lane owes a chunk: park, poll

    // Same windows at revision 2 depth 4: a lane owing one chunk still takes more.
    in.lane_depth = HTTPReadConfig::LaneDepthFor(2, 4, 64);
    out           = oasis::Scheduler::PlaceOnLane(in);
    CHECK(out.stream.has_value() && !out.lane_bound_wait);
}

} // namespace

int main() {
    rev2_decoders();
    rev3_decoders();
    request_split();
    placement_at_depth();
    std::printf("csr_decode_check: %d passed, %d failed\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
