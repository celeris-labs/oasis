// Board-free check of the HttpConfig readback decoders and the revision-dependent host rules, against
// register words built the way the RTL builds them (hardware/src/hdl/http_read/handler_slots.sv,
// handler_multi.sv and handler_toe.sv readback sections, http_config.sv read map). No cThread, no device: only the pure
// static members of HTTPReadConfig are exercised.
//
// Build: cmake -DOASIS_BUILD_TESTS=ON, target csr_decode_check. Exit status 0 iff every check passes.

#include "oasis/configuration.hpp"
#include "oasis/scheduler.hpp"

#include <array>
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

// CSR revision 4 (pipelined GETs on the slot handler): same map, new host rules.
void rev4_rules() {
    // build-126-shape policy: rev 4, 4 conns, 4 decoders, 256 MiB slots = the whole 1 GiB page.
    const auto sp = HTTPReadConfig::DecodeSlotPolicy(slot_policy_word(4, 4, 4, 28, 14, 64, 10));
    CHECK(sp.valid() && sp.revision == 4 && sp.slot_log2 == 28);
    CHECK(sp.slot_bytes() == (256ULL << 20));
    CHECK(sp.region_bytes() == (1ULL << 30));          // exactly the one huge page, not more
    CHECK(sp.max_get_bytes() == (256ULL << 20) - (64ULL << 10));
    // Stage 2 would publish 25 (24 x 32 MiB = 768 MiB).
    const auto s2 = HTTPReadConfig::DecodeSlotPolicy(slot_policy_word(4, 24, 4, 25, 14, 64, 10));
    CHECK(s2.region_bytes() == 24ULL * (32ULL << 20) && s2.region_bytes() <= (1ULL << 30));

    // Depth: the caller passes HTTP_PIPE_DEFAULT_DEPTH when the variable is unset.
    CHECK(oasis::HTTP_PIPE_DEFAULT_DEPTH == 2 && oasis::HTTP_PIPE_MAX_DEPTH == 4);
    CHECK(HTTPReadConfig::LaneDepthFor(4, oasis::HTTP_PIPE_DEFAULT_DEPTH, 64) == 2);
    CHECK(HTTPReadConfig::LaneDepthFor(4, 3, 64) == 3);
    CHECK(HTTPReadConfig::LaneDepthFor(4, 4, 64) == 4);
    CHECK(HTTPReadConfig::LaneDepthFor(4, 16, 64) == 4);   // clamped to HTTP_PIPE_MAX_DEPTH
    CHECK(HTTPReadConfig::LaneDepthFor(4, 0, 64) == 1);
    CHECK(HTTPReadConfig::LaneDepthFor(4, 4, 2) == 2);     // and to the hardware queue
    CHECK(HTTPReadConfig::LaneDepthFor(3, 4, 64) == 1);    // revision 3 unchanged
    CHECK(HTTPReadConfig::LaneDepthFor(2, 4, 64) == 4);    // revision 2 unchanged

    // Credit: revision 4 does not wait for the slot; occupancy still bounds it.
    CHECK(HTTPReadConfig::LaneCreditOk(4, 1, 1, 2, false)); // one GET in the slot, room for another
    CHECK(!HTTPReadConfig::LaneCreditOk(4, 2, 1, 2, true)); // at depth
    CHECK(!HTTPReadConfig::LaneCreditOk(3, 0, 1, 1, false)); // revision 3 still keys on drained

    // Byte budget.
    const uint64_t B = sp.max_get_bytes();
    CHECK(HTTPReadConfig::SlotBudgetOk(0, 1000, B));
    CHECK(HTTPReadConfig::SlotBudgetOk(B - 1000, 1000, B));
    CHECK(!HTTPReadConfig::SlotBudgetOk(B - 999, 1000, B));
    CHECK(HTTPReadConfig::SlotBudgetOk(0, B + 5, B));         // an empty slot takes an oversize one
    CHECK(!HTTPReadConfig::SlotBudgetOk(1, B + 5, B));        // ...but only an empty one
    CHECK(!HTTPReadConfig::SlotBudgetOk(B, 1, B));
    // 424 KiB GETs (the board's byte-weighted request): ~600 fit before a drain is needed.
    uint64_t used = 0; int n = 0;
    while (HTTPReadConfig::SlotBudgetOk(used, (424ULL << 10) + oasis::HTTP_SLOT_GET_OVERHEAD, B)) {
        used += (424ULL << 10) + oasis::HTTP_SLOT_GET_OVERHEAD;
        n++;
    }
    CHECK(n == 612);

    // Range parsing, off the text the host itself builds.
    const std::string g = "GET /b/f.parquet HTTP/1.1\r\nHost: 10.253.74.74:9000\r\n"
                          "Range: bytes=1000-434175\r\nConnection: keep-alive\r\n\r\n";
    CHECK(HTTPReadConfig::RequestRangeBytes(g) == 433176);
    CHECK(HTTPReadConfig::RequestRangeBytes("GET / HTTP/1.1\r\n\r\n") == 0);
    CHECK(HTTPReadConfig::RequestRangeBytes("Range: bytes=5-\r\n") == 0);      // open range
    CHECK(HTTPReadConfig::RequestRangeBytes("Range: bytes=9-3\r\n") == 0);     // reversed
    CHECK(HTTPReadConfig::RequestRangeBytes("Range: bytes=0-0\r\n") == 1);

    // Placement at revision-4 depth 2: a lane owing one chunk is still a candidate, one owing two
    // is not.
    const uint64_t ready = nib(false, true, true, true) | (nib(false, true, true, true) << 4) |
                           (nib(false, true, true, true) << 8) | (nib(false, true, true, true) << 12);
    oasis::Scheduler::LaneInputs in;
    in.host_depth = 64;
    in.needed     = 1;
    in.active     = 4;
    in.rr         = 0;
    in.lane_depth = HTTPReadConfig::LaneDepthFor(4, oasis::HTTP_PIPE_DEFAULT_DEPTH, 64);
    in.lanes      = HTTPReadConfig::DecodeLanes(1ULL | (1ULL << 8) | (1ULL << 16) | (1ULL << 24), ready, 4);
    auto out      = oasis::Scheduler::PlaceOnLane(in);
    CHECK(out.stream.has_value() && !out.lane_bound_wait);
    in.lanes = HTTPReadConfig::DecodeLanes(2ULL | (2ULL << 8) | (2ULL << 16) | (2ULL << 24), ready, 4);
    out      = oasis::Scheduler::PlaceOnLane(in);
    CHECK(!out.stream && out.lane_bound_wait);
}

// Revision 5 (stage 2): words as handler_slots packs them -- DEC_STATE byte per decoder
// {rdr_state[3:0], stream_busy, tainted, entry_ready, arm_ready}; CONN_MAP byte per connection
// {pend[3:0], tail, cur_dec[2:0]}; CONN_CAUSE [c] residue, [32+c] tainter.
uint64_t dec_byte(bool arm, bool entry, bool tainted, bool busy, unsigned st) {
    return uint64_t(arm) | (uint64_t(entry) << 1) | (uint64_t(tainted) << 2) | (uint64_t(busy) << 3) |
           (uint64_t(st & 0xF) << 4);
}
uint64_t map_byte(unsigned dec, bool tail, unsigned pend) {
    return uint64_t(dec & 7) | (uint64_t(tail) << 3) | (uint64_t(pend & 0xF) << 4);
}

void rev5_rules() {
    // build-127 shape: rev 5, 32 connections, 4 decoders, 2^25 = 32 MiB slots = the 1 GiB page.
    const auto sp = HTTPReadConfig::DecodeSlotPolicy(slot_policy_word(5, 32, 4, 25, 14, 64, 10));
    CHECK(sp.valid() && sp.revision == 5 && sp.n_conns == 32 && sp.n_decoders == 4);
    CHECK(sp.slot_bytes() == (32ULL << 20) && sp.region_bytes() == (1ULL << 30));
    CHECK(sp.max_get_bytes() == (32ULL << 20) - (64ULL << 10));
    CHECK(oasis::HTTP_CSR_REVISION_CONNS == 5);
    // 24 connections also take 25 (30 - clog2(24)): 768 MiB of the page.
    const auto s24 = HTTPReadConfig::DecodeSlotPolicy(slot_policy_word(5, 24, 4, 25, 14, 64, 10));
    CHECK(s24.region_bytes() == 24ULL * (32ULL << 20));

    // DEC_STATE: decoder 0 armable, 1 only entries, 2 TAINTED, 3 busy sending.
    const uint64_t ds = dec_byte(true, true, false, false, 0) | (dec_byte(false, true, false, false, 3) << 8) |
                        (dec_byte(false, true, true, false, 0) << 16) | (dec_byte(false, false, false, true, 4) << 24);
    const uint64_t occ = 1ULL | (5ULL << 8) | (9ULL << 16) | (64ULL << 24);
    const auto l = HTTPReadConfig::DecodeDecState(occ, ds, 4);
    CHECK(l.count == 4);
    CHECK(l.at(0).arm_ready && l.at(0).entry_ready && !l.at(0).fatal && l.at(0).occ == 1);
    CHECK(!l.at(1).arm_ready && l.at(1).entry_ready && !l.at(1).fatal && l.at(1).occ == 5);
    CHECK(l.at(2).fatal && l.at(2).occ == 9);                 // tainted = the host's fatal lane
    CHECK(!l.at(3).arm_ready && !l.at(3).entry_ready && l.at(3).occ == 64);
    CHECK(l.at(0).conn_up && l.at(3).conn_up);                // a decoder is never "connecting"

    // CONN_MAP / CONN_CAUSE, including connections 8, 17 and 31 (other words, top slot).
    std::array<uint64_t, 4> map {};
    map[0] = map_byte(2, true, 3) | (map_byte(1, false, 0) << 8);
    map[1] = map_byte(3, false, 15);                          // conn 8, saturated
    map[2] = map_byte(0, true, 1) << 8;                       // conn 17
    map[3] = map_byte(3, true, 2) << 56;                      // conn 31
    const uint64_t cause = (1ULL << 1) | (1ULL << (32 + 17));
    std::array<uint64_t, 4> o4 {}, e4 {};
    std::array<uint64_t, 2> r2 {};
    auto cs = HTTPReadConfig::DecodeConns(o4, r2, e4, 0, 32);
    HTTPReadConfig::DecodeConnMap(map, cause, cs);
    CHECK(cs.at(0).cur_dec == 2 && cs.at(0).is_tail && cs.at(0).pend == 3);
    CHECK(cs.at(1).cur_dec == 1 && !cs.at(1).is_tail && cs.at(1).pend == 0 && cs.at(1).residue);
    CHECK(cs.at(8).cur_dec == 3 && cs.at(8).pend == 15);
    CHECK(cs.at(17).is_tail && cs.at(17).pend == 1 && cs.at(17).tainter && !cs.at(17).residue);
    CHECK(cs.at(31).cur_dec == 3 && cs.at(31).is_tail && cs.at(31).pend == 2);
    CHECK(!cs.at(30).tainter && cs.at(30).pend == 0);

    // Lane depth at revision 5: only the decoder's queue bounds it (no HTTP_PIPE_MAX_DEPTH cap).
    CHECK(HTTPReadConfig::LaneDepthFor(5, 16, 64) == 16);
    CHECK(HTTPReadConfig::LaneDepthFor(5, 100, 64) == 64);
    CHECK(HTTPReadConfig::LaneDepthFor(5, 0, 64) == 1);
    CHECK(HTTPReadConfig::LaneCreditOk(5, 10, 1, 16, false)); // no slot key, occupancy only

    // PLACEMENT (PickConn). 8 active connections; 0..2 busy on other decoders, 3 free.
    HTTPReadConfig::ConnPickInputs in;
    in.lane = 1; in.active = 8; in.rr = 0; in.conn_depth = 2;
    in.budget = sp.max_get_bytes(); in.need = 500000;
    for (int c = 0; c < 32; c++) { in.drained[c] = true; in.pend[c] = 0; }
    for (int c = 0; c < 3; c++) { in.drained[c] = false; in.pend[c] = 1; in.cur_dec[c] = 0; }
    auto p = HTTPReadConfig::PickConn(in);
    CHECK(p.conn == 3 && p.free && p.next_rr == 4);           // first free from the cursor
    in.rr = 6;
    p = HTTPReadConfig::PickConn(in);
    CHECK(p.conn == 6 && p.free && p.next_rr == 7);           // round robin
    in.rr = 7; in.fatal[7] = true;
    p = HTTPReadConfig::PickConn(in);
    CHECK(p.conn == 3);                                       // a fatal connection is never free
    in.fatal[7] = false;
    // Nothing free: the lane's tail may pipeline -- only if it is really this lane's tail.
    for (int c = 0; c < 32; c++) { in.drained[c] = false; in.pend[c] = 1; in.cur_dec[c] = 0; }
    in.host_tail = 5; in.cur_dec[5] = 1; in.is_tail[5] = true; in.used[5] = 600000;
    p = HTTPReadConfig::PickConn(in);
    CHECK(p.conn == 5 && !p.free);
    in.pend[5] = 2;                                           // at conn_depth
    CHECK(HTTPReadConfig::PickConn(in).conn == -1);
    in.pend[5] = 1; in.is_tail[5] = false;                    // another lane armed since: not tail
    CHECK(HTTPReadConfig::PickConn(in).conn == -1);
    in.is_tail[5] = true; in.cur_dec[5] = 2;                  // its entries are on decoder 2
    CHECK(HTTPReadConfig::PickConn(in).conn == -1);
    in.cur_dec[5] = 1; in.used[5] = in.budget - 1000;         // slot budget exhausted
    CHECK(HTTPReadConfig::PickConn(in).conn == -1);
    in.used[5] = 0; in.fatal[5] = true;
    CHECK(HTTPReadConfig::PickConn(in).conn == -1);
    in.fatal[5] = false; in.host_tail = -1;
    CHECK(HTTPReadConfig::PickConn(in).conn == -1);           // no tail recorded: wait
    // A connection beyond `active` is never used even when free (OASIS_HTTP_CONNS).
    in.drained[20] = true; in.pend[20] = 0;
    CHECK(HTTPReadConfig::PickConn(in).conn == -1);
    in.active = 32;
    CHECK(HTTPReadConfig::PickConn(in).conn == 20);
    // active = 4 of 32: the cursor wraps inside the first four.
    in.active = 4; in.rr = 3;
    for (int c = 0; c < 32; c++) { in.drained[c] = true; in.pend[c] = 0; }
    p = HTTPReadConfig::PickConn(in);
    CHECK(p.conn == 3 && p.next_rr == 0);

    // Scheduler placement over DECODER lanes: decoder 2 tainted, the rest by occupancy.
    oasis::Scheduler::LaneInputs li;
    li.host_depth = 64; li.needed = 1; li.active = 4; li.rr = 0; li.lane_depth = 16;
    const uint64_t ds2 = dec_byte(true, true, false, false, 0) | (dec_byte(true, true, false, false, 0) << 8) |
                         (dec_byte(false, true, true, false, 0) << 16) | (dec_byte(true, true, false, false, 0) << 24);
    li.lanes = HTTPReadConfig::DecodeDecState(9ULL | (3ULL << 8) | (0ULL << 16) | (7ULL << 24), ds2, 4);
    auto po = oasis::Scheduler::PlaceOnLane(li);
    CHECK(po.stream.has_value() && *po.stream == 1);          // least loaded healthy decoder, not 2
}

// Revision 5 with THREE decoders (build-131: 32 connections over 3 decoders). The host has no
// decoder count of its own: lane_count() is SLOT_POLICY[23:16] and the scheduler's streams are
// ColumnChunkDecoderConfig's read register 1, both from the bitstream. What must hold is that a
// count that is not a power of two decodes as itself and that nothing is ever placed on a fourth.
void rev5_three_decoders() {
    const auto sp = HTTPReadConfig::DecodeSlotPolicy(slot_policy_word(5, 32, 3, 25, 14, 64, 10));
    CHECK(sp.valid() && sp.revision == 5 && sp.n_conns == 32 && sp.n_decoders == 3);
    CHECK(sp.slot_bytes() == (32ULL << 20) && sp.max_get_bytes() == (32ULL << 20) - (64ULL << 10));

    // DEC_STATE with a byte in position 3 that no 3-decoder bitstream drives: it is not a lane.
    const uint64_t ds = dec_byte(true, true, false, false, 0) | (dec_byte(true, true, false, false, 0) << 8) |
                        (dec_byte(true, true, false, false, 0) << 16) | (dec_byte(true, true, false, false, 0) << 24);
    const uint64_t occ = 4ULL | (6ULL << 8) | (2ULL << 16) | (0ULL << 24);
    const auto l = HTTPReadConfig::DecodeDecState(occ, ds, sp.n_decoders);
    CHECK(l.count == 3 && l.at(2).occ == 2 && l.at(2).arm_ready);
    bool threw = false;
    try { (void)l.at(3); } catch (const std::exception &) { threw = true; }
    CHECK(threw);

    // Placement over three decoder lanes with four host streams active: the span is three, the
    // least-loaded decoder (2) wins, and the rotation wraps at three, never onto a fourth.
    oasis::Scheduler::LaneInputs li;
    li.host_depth = 64; li.needed = 1; li.active = 4; li.rr = 0;
    // conn depth 2 x ceil(32 / 3) = 22: lane_depth_limit()'s default on this bitstream.
    li.lane_depth = HTTPReadConfig::LaneDepthFor(5, 2 * ((32 + 3 - 1) / 3), 64);
    CHECK(li.lane_depth == 22);
    li.lanes = l;
    auto po = oasis::Scheduler::PlaceOnLane(li);
    CHECK(po.span == 3 && po.stream.has_value() && *po.stream == 2 && po.next_rr == 0);
    li.rr = 2;
    li.lanes = HTTPReadConfig::DecodeDecState(22ULL | (22ULL << 8) | (21ULL << 16), ds, 3);
    po = oasis::Scheduler::PlaceOnLane(li);
    CHECK(po.stream.has_value() && *po.stream == 2 && po.next_rr == 0);
    li.lanes = HTTPReadConfig::DecodeDecState(22ULL | (22ULL << 8) | (22ULL << 16), ds, 3);
    po = oasis::Scheduler::PlaceOnLane(li);
    CHECK(!po.stream && po.lane_bound_wait);                  // all three full: wait, no fourth

    // A connection pipelined on decoder 2 is still that decoder's tail.
    HTTPReadConfig::ConnPickInputs in;
    in.lane = 2; in.active = 32; in.rr = 0; in.conn_depth = 2;
    in.budget = sp.max_get_bytes(); in.need = 500000;
    for (int c = 0; c < 32; c++) { in.drained[c] = false; in.pend[c] = 1; in.cur_dec[c] = 0; }
    in.host_tail = 29; in.cur_dec[29] = 2; in.is_tail[29] = true; in.used[29] = 0;
    CHECK(HTTPReadConfig::PickConn(in).conn == 29);
}


// CSR revision 6 (handler_toe, the TOE keeps a receive ring per session): words as handler_toe.sv
// packs them. LANE_POLICY = {2'd0, 6'(RING_LOG2), 24'(GET_CREDIT), 16'(QUEUE_DEPTH), 8'(NUM_CONNS),
// 8'(CSR_REV)}; the rest of the readback is the revision-2 layout.
uint64_t toe_policy_word(unsigned conns, unsigned qdepth, unsigned credit, unsigned ring_log2,
                         unsigned rev = 6) {
    return uint64_t(rev & 0xFF) | (uint64_t(conns & 0xFF) << 8) | (uint64_t(qdepth & 0xFFFF) << 16) |
           (uint64_t(credit & 0xFFFFFF) << 32) | (uint64_t(ring_log2 & 0x3F) << 56);
}

// "Range: bytes=a-b" -> a (or UINT64_MAX when absent). The end and the length come from
// HTTPReadConfig::RequestRangeBytes.
uint64_t range_begin_of(const std::string &request) {
    const std::string key = "Range: bytes=";
    const size_t at = request.find(key);
    if (at == std::string::npos) {
        return UINT64_MAX;
    }
    return std::strtoull(request.c_str() + at + key.size(), nullptr, 10);
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
        const uint64_t n = HTTPReadConfig::RequestRangeBytes(r);
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
    // --- revision mapping: 6 is driven as 2 (its register map); 0..5 are themselves; 7+ refused ---
    for (unsigned raw = 0; raw <= 5; raw++) {
        const auto r = oasis::HTTPRevision::Classify(static_cast<uint8_t>(raw));
        CHECK(r.raw == raw && r.protocol == raw && !r.toe_ring);
    }
    const auto r6 = oasis::HTTPRevision::Classify(6);
    CHECK(oasis::HTTP_CSR_REVISION_TOE == 6);
    CHECK(r6.raw == 6 && r6.protocol == 2 && r6.toe_ring);
    CHECK(r6.lane_csrs());
    // Nothing slot-related on 6: no slot page / offload / SLOT_BASE (setup_http_slots), no CONN_*
    // reads, no byte budget, no connection placement, no CONN_DRAINED-keyed credit.
    CHECK(!r6.slot_mode() && !r6.slot_pipelined() && !r6.conn_placement());
    CHECK(oasis::HTTPRevision::Classify(3).slot_mode() && oasis::HTTPRevision::Classify(5).conn_placement());
    for (unsigned raw : {7u, 8u, 0x7Fu, 0xFFu}) {
        bool threw = false;
        try {
            (void)oasis::HTTPRevision::Classify(static_cast<uint8_t>(raw));
        } catch (const std::runtime_error &) {
            threw = true;
        }
        CHECK(threw);
    }

    // --- LANE_POLICY: build-136 shape, 4 lanes, queue 64, GET credit 4, 1 MiB rings ---
    const auto p = HTTPReadConfig::DecodePolicy(toe_policy_word(4, 64, 4, 20));
    CHECK(p.valid() && p.toe() && p.revision == 6);
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
        bool threw = false;
        try {
            HTTPReadConfig::AppendChunkGets("h", 1, "/p", 10, 9, cap, t);   // empty range
        } catch (const std::runtime_error &) {
            threw = true;
        }
        CHECK(threw);
        threw = false;
        try {
            HTTPReadConfig::AppendChunkGets("h", 1, "/p", 0, 1ULL << 32, cap, t); // > 32-bit entry
        } catch (const std::runtime_error &) {
            threw = true;
        }
        CHECK(threw);
    }

    // --- lane depth: protocol 2 + the GET credit ---
    CHECK(HTTPReadConfig::LaneDepthFor(r6.protocol, 4, 64, 4) == 4);  // the default
    CHECK(HTTPReadConfig::LaneDepthFor(r6.protocol, 16, 64, 4) == 4); // OASIS_HTTP_LANE_DEPTH=16 clamped
    CHECK(HTTPReadConfig::LaneDepthFor(r6.protocol, 2, 64, 4) == 2);
    CHECK(HTTPReadConfig::LaneDepthFor(r6.protocol, 0, 64, 4) == 1);
    CHECK(HTTPReadConfig::LaneDepthFor(r6.protocol, 16, 2, 4) == 2);  // and the queue
    CHECK(HTTPReadConfig::LaneDepthFor(r6.protocol, 8, 0, 4) == 4);   // queue unknown
    CHECK(HTTPReadConfig::LaneDepthFor(2, 16, 64) == 16);             // revision 2 unchanged
    CHECK(HTTPReadConfig::LaneCreditOk(r6.protocol, 3, 1, 4, false)); // no CONN_DRAINED key
    CHECK(!HTTPReadConfig::LaneCreditOk(r6.protocol, 4, 1, 4, true));

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
    const auto e = HTTPReadConfig::DecodeLaneErrors(err, 4, r6.protocol);
    CHECK(e.at(0).rx_fifo_stall && !e.at(0).slot_overflow && !e.at(0).lane_dead);
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
    in.lane_depth = HTTPReadConfig::LaneDepthFor(r6.protocol, 16, 64, p.get_credit);
    in.lanes      = HTTPReadConfig::DecodeLanes(3ULL | (4ULL << 8) | (4ULL << 16) | (4ULL << 24), all, 4);
    auto out      = oasis::Scheduler::PlaceOnLane(in);
    CHECK(out.stream && *out.stream == 0);
    in.lanes = HTTPReadConfig::DecodeLanes(4ULL | (4ULL << 8) | (4ULL << 16) | (4ULL << 24), all, 4);
    out      = oasis::Scheduler::PlaceOnLane(in);
    CHECK(!out.stream && out.lane_bound_wait);
}

int main() {
    rev2_decoders();
    rev3_decoders();
    rev4_rules();
    rev5_rules();
    rev5_three_decoders();
    rev6_rules();
    request_split();
    placement_at_depth();
    std::printf("csr_decode_check: %d passed, %d failed\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
