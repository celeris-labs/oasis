#pragma once

#include "celeris/celeris_context.hpp"
#include "celeris/operators/regex/regex_config.hpp" // REGEX_CONFIG_BLOB_BYTES
#include "celeris/operators/regex/regex_stream.hpp"
#include "syslog_undef.hpp" // must follow the celeris include, precede the duckdb ones

#include "duckdb/common/types/string_type.hpp"
#include "libstf/buffer.hpp"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <memory>
#include <vector>

namespace duckdb {

static constexpr uint64_t REGEX_FPGA_BEAT_BYTES = 64;

// Rows per batch.
//
// 16384, lowered from 65536. The old value existed to amortise a fixed ~134 us device
// round trip over as many strings as possible -- with one batch on the card at a time,
// fewer and larger batches was strictly better. Continuous streaming removes that fixed
// cost: the measured round trip is now ~7.6 us, so there is almost nothing left to
// amortise, and smaller batches win instead by spreading work more evenly over the scan
// threads and keeping more transfers in flight.
//
// Measured at 32 threads over 608 MB, four runs each: 16384 gave 0.137-0.147 s
// (~4.2 GB/s) against 0.156-0.157 s (~3.9 GB/s) at 65536. Below ~12288 it turns back
// down as per-batch overhead starts to dominate again.
//
// Still bounded by the result FIFO: (kRegexMaxStringsPerEngine - 1) x 64 engines, one
// slot per engine being reserved for the terminated filler run. Overridable per session
// with oasis_regex_batch_rows.
static constexpr idx_t REGEX_FPGA_MAX_ACCUM_COUNT = 1ULL << 14;

// How much wire buffer one scan thread holds. This is a host-memory bound and
// nothing more: the 1 MiB REGEX_FPGA_RAW_BATCH_LIMIT it replaces was the
// german_string_decoder Dictionary's BRAM depth showing through into the host,
// and the card no longer stores the payload at all.
//
// It is per thread and comes out of the huge-page pool, so it is not free: at 32
// threads this is 128 MiB. Deliberately left at 4 MiB even though the row cap is now
// 131072: raising it to 16 MiB was measured neutral-to-negative end to end (c_comment
// 64.0 -> 69.6 ms) while costing 512 MiB of huge pages at 32 threads, from a pool that
// leaks. Short columns do not need it -- 131072 x 17 B is 2.2 MB -- and long ones are
// exactly where the extra memory buys least. Overridable with
// oasis_regex_wire_buffer_bytes.
static constexpr uint64_t REGEX_FPGA_WIRE_BUFFER_BYTES = 4ULL << 20;

// Transfers one scan thread keeps on the card. See the long note on
// RegexFpgaScanLocalState::max_in_flight: this and the scan's thread cap are a single
// decision, because their product is bounded by kRegexMaxSubmissionsInFlight.
static constexpr idx_t REGEX_FPGA_DEFAULT_IN_FLIGHT = 2;

// Wire bytes a batch aims for, which is what actually decides a transfer's size; the row
// cap above is a backstop for the result FIFO, not the target.
//
// A transfer costs a fixed ~25 us of serial host work in Coyote's single interrupt thread
// (epoll wake, two ioctls, the OutputBufferManager's lock and two condvar wakes), so it has
// to carry enough wire to be worth that -- and it must not carry so much that one batch of
// scan-and-pack, which is the pipeline's fill time, becomes long. Both bounds are in
// bytes, not rows, so a row cap gets the trade-off right for exactly one column width:
//
//   72 B column, 16384 rows   1.20 MB   95 us of DMA   what the row cap used to give
//   16 B column, 16384 rows   0.28 MB   22 us          below the interrupt floor
//
// Measured on the 72 B benchmark column at 16 threads, paired over 20 rounds of
// benchmark_runner: 1.20 MB 25.64 ms, 0.90 MB 25.38, 0.77 MB 25.43, 0.60 MB 25.21,
// 0.45 MB 25.49, while 1.79 MB and 2.39 MB cost 3.1% and 5.7%. The curve is flat from
// ~0.45 to ~0.9 MB and everything inside it is within the run-to-run noise, so this sits
// in the middle of the flat part rather than on the nominal minimum -- the shape is a
// property of the interrupt floor and the fill, the exact minimum is a property of one
// column width.
static constexpr uint64_t REGEX_FPGA_TARGET_WIRE_BYTES = 640ULL << 10;

// How many of a scan thread's opening batches are shrunk, and by how much: batch k of
// the first REGEX_FPGA_FILL_RAMP_STEPS targets TARGET >> (STEPS - k), so at 3 steps a
// thread would submit 80 KB, then 160, then 320, before settling at the full 640 KB.
//
// **Zero, and that is measured.** The idea is sound and the instrument agrees with it: the
// card reads nothing until the first transfer is enqueued, which with a flat target is one
// whole batch of scan-and-pack on every thread at once, and the ramp does remove that.
// Measured with the link-occupancy counters, mean time to a thread's first submission went
// 0.87 ms -> 0.28 ms and the opening gap 1.25 ms -> 0.85 ms. It bought nothing:
//
//   ramp 0 (off)   25.26-25.45 ms   --                    reference
//   ramp 1         25.51 ms         +0.59%   8 of 18 rounds
//   ramp 2         25.40 ms         +0.44%   5 of 18 rounds
//   ramp 3         25.75 ms         +1.32%   9 of 20 rounds
//   ramp 5         26.56 ms         +4.06%   0 of 20 rounds
//
// (paired rounds of benchmark_runner, 4 timed runs each; an A/A of the same config over
// 12 rounds reads +1.34%, so steps 1-3 are indistinguishable from off and step 5 is a
// real loss.) Nothing at any step count wins, and the loss at the far end tracks the
// extra transfers at ~11-13 us of wall each -- the end-to-end cost of one transfer.
//
// Why the removed idle does not come back as wall: at depth 2 a thread that submits two
// tiny transfers has a full window and must block on the card before it can pack again, so
// the ramp trades link idle at the start for thread idle immediately after -- and the
// thread idle is what the pipeline is actually short of. Raising the window instead is not
// available: T*W is bounded by the arm-credit pool.
//
// Left in place, and overridable with OASIS_REGEX_FILL_RAMP, because the shape of the
// result is the argument for not trying it again.
static constexpr idx_t REGEX_FPGA_FILL_RAMP_STEPS = 0;

void EnsureCelerisContext();
celeris::CelerisContext &GetCelerisContext();

// Per-phase wall time inside SubmitRegexBatch/CollectRegexBatch, accumulated across batches.
// Everything here happens under the global fpga_mutex, so it is serialized across
// threads and is exactly the cost that shows up as "device time" in a
// scan/pack/device decomposition. Four clock reads per batch is nothing against a
// batch measured in hundreds of microseconds, so this is always on.
//
// mutex_wait is time queued behind another thread and is only meaningful above one
// thread; the rest are the phases of one batch's round trip.
//
// The lock now covers config + enqueue only; drain happens outside it (see
// SubmitRegexBatch). An earlier attempt at that hung within seconds at 32 threads,
// because nothing bounded how many *unaccepted* arms could pile up -- see the
// arm-credit note on kRegexMaxSubmissionsInFlight below, which is what makes it safe.
//
// mutex_wait is time queued behind another thread's submit; arm_wait is time queued
// on the arm credit, i.e. genuine device backlog rather than host contention. Telling
// those two apart is the whole point of pipelining, so they are counted separately.
struct RegexBatchPhases {
	uint64_t batches = 0;
	uint64_t strings = 0;
	// Bytes actually put on the wire, i.e. the sum of the finalized rectangles. This is
	// what the link is charged for, and it is NOT the column's byte count: every string
	// carries a NUL and every engine's stream is rounded up to a 256 B chunk. Tracking it
	// is what makes "how far below the PCIe ceiling is this" a measurement rather than an
	// estimate.
	uint64_t wire_bytes = 0;
	uint64_t mutex_wait_ns = 0;
	uint64_t arm_wait_ns = 0;
	uint64_t config_ns = 0;
	// Time inside acquire_output_handle, a subset of config_ns. Broken out because it
	// allocates a huge page, TLB-maps it and pushes a descriptor, all under the submit
	// lock -- the obvious suspect when many threads serialise there.
	uint64_t acquire_ns = 0;
	// config_ns split three ways, all of it inside the submit lock: the config lookup,
	// registering the output handle with the OutputBufferManager, and the two AXI-Lite
	// writes. 8.8 us of serialized work per batch was worth taking apart.
	uint64_t getconfig_ns = 0;
	uint64_t handle_ns = 0;
	uint64_t csr_ns = 0;
	uint64_t enqueue_ns = 0;
	uint64_t drain_ns = 0;
	uint64_t read_ns = 0;
	// Host scan-path phases, accumulated across threads. Timed per chunk rather than per
	// row: a clock read is ~20 ns against a ~27 ns append, so per-row timing would cost
	// more than the thing it measures.
	uint64_t scan_ns = 0;        // storage.Scan
	uint64_t materialize_ns = 0; // MaterializeRetainedColumns
	uint64_t stage_ns = 0;       // the per-row staging loop, including packer.append
	uint64_t emit_ns = 0;        // AppendMatchedRows, turning a bitmap into output rows
	// Per-query setup, summed across threads: the whole of RegexFpgaScanInitLocal, and
	// the huge-page wire-buffer allocation inside it. DuckDB destroys the local states at
	// the end of every query, so anything here is paid again on the next one -- which is
	// the difference between a once-per-session cost to exclude from a throughput number
	// and a per-query one to fix.
	uint64_t initlocal_ns = 0;
	uint64_t wirealloc_ns = 0;
	// Wall time during which NO transfer was outstanding process-wide, i.e. the card had
	// nothing enqueued to read. A transfer counts as outstanding from the moment its DMA
	// descriptor is posted until its results have been drained, so this is a *lower*
	// bound on link idle: the input DMA finishes some time before the results land.
	// It is the number that says whether the operator is device-bound or pipeline-bound.
	uint64_t link_idle_ns = 0;
	// Wall time since the last ResetRegexBatchPhases(), so link_idle_ns has a denominator.
	uint64_t wall_ns = 0;
	// Peak and time-integrated depth of the outstanding window, for the same question
	// from the other side: depth_ns / wall_ns is the mean number of transfers the card
	// had queued.
	uint64_t depth_ns = 0;
	uint64_t max_depth = 0;
	// Shape of the idle, not just its total: one long gap per query (a pipeline that
	// fills slowly) and a thousand short ones (a pipeline that keeps running dry) need
	// different fixes and look identical in link_idle_ns.
	uint64_t idle_events = 0;
	uint64_t max_idle_ns = 0;
	// Shape of the fill and the drain, measured from the query's first
	// RegexFpgaScanInitGlobal: when each scan thread first submitted, and when each
	// finished. link_idle_ns says the card had nothing to read; these say whether that
	// is one slow pipeline fill (fill_min large) or a straggler (fill_max >> fill_min),
	// and whether the tail is a ragged finish (done_max >> done_min).
	uint64_t fill_min_ns = 0;
	uint64_t fill_mean_ns = 0;
	uint64_t fill_max_ns = 0;
	uint64_t fill_threads = 0;
	uint64_t done_min_ns = 0;
	uint64_t done_mean_ns = 0;
	uint64_t done_max_ns = 0;

	// Row dispositions for the FSST compressed passthrough.  Bucketed by *reason*, not a
	// single "fell back" count, because the reasons have unrelated fixes and two of them
	// look identical in aggregate throughput:
	//
	//   ~86% compressed        working as designed; the rest is the inherent straddle below
	//   0% compressed          the database was written by a build without the FSST fork,
	//                          so every segment is zeroTerminated=0 and cannot be NUL-framed
	//   low, rows_outlier      outlier threshold, nothing to do with compression
	//   low, rows_not_fsst     the column landed on Uncompressed/Dictionary/DICT_FSST
	//
	// Without the split, "no speedup" is indistinguishable from "wrong binary wrote the
	// data" -- the silent-measurement failure the huge-page preflight exists to prevent.
	uint64_t rows_compressed = 0;    // FSST vector, zeroTerminated, shipped compressed
	uint64_t rows_not_fsst = 0;      // not an FSST vector at all
	uint64_t rows_mode0 = 0;         // FSST vector, but zeroTerminated=0: no NUL framing
	uint64_t rows_outlier = 0;       // diverted to host RE2 on length
};

// Accumulators for the phases above, incremented from regex_table.cpp.
void AddRegexScanNs(uint64_t ns);
void AddRegexMaterializeNs(uint64_t ns);
void AddRegexStageNs(uint64_t ns);
void AddRegexEmitNs(uint64_t ns);
void AddRegexInitLocalNs(uint64_t ns);
void AddRegexWireAllocNs(uint64_t ns);

// One call per staged row, recording which path it took.  See RegexBatchPhases above for
// why this is bucketed rather than a boolean.
enum class RegexRowPath : uint8_t { COMPRESSED, NOT_FSST, MODE0, OUTLIER };
void NoteRegexRowPath(RegexRowPath path, uint64_t rows = 1);

// Marks the start of a query's regex scan (first RegexFpgaScanInitGlobal) and clears the
// fill/drain stats; NoteRegexFirstSubmit and NoteRegexThreadDone record one thread's
// offsets from it.
void NoteRegexQueryStart();
void NoteRegexFirstSubmit();
void NoteRegexThreadDone();

RegexBatchPhases GetRegexBatchPhases();
void ResetRegexBatchPhases();

// Every string now travels in the payload, including the ones DuckDB inlines
// into the 16 B string_t: there is no descriptor stream for them to ride along in
// any more. That trades 16 B/row of descriptor for len+1 B/row of payload, which
// is a win for anything under 15 B and a much bigger one for everything else,
// since the descriptor used to be sent *as well* as the payload.

uint64_t align_to_64_multiple(uint64_t size);

// One verdict per slot, kept in the card's own packed layout. The collector emits
// bit i for string i (see the parallel-pop note in SubmitRegexBatch), so the
// device buffer is already in destination order and the read-back is a memcpy.
//
// This replaced a std::vector<bool> that was filled a bit at a time. That loop
// skipped whole zero bytes, so it was nearly free on a selective pattern but cost a
// read-modify-write per match on a dense one -- ~1.9 ns/match, which showed up as
// the operator losing 1.32x of its throughput going from 0% to 100% selectivity.
// The device datapath is identical either way (stream profiles match to two
// decimals across 0/25/100%), so that slope was pure host overhead.
struct RegexMatchBitmap {
	std::vector<uint8_t> bits;
	idx_t count = 0;

	void assign_zero(idx_t n) {
		count = n;
		bits.assign((n + 7) / 8, 0);
	}
	// `src_bytes` is what the card returned; anything it does not cover reads false.
	void assign_from_device(const uint8_t *src, size_t src_bytes, idx_t n) {
		count = n;
		const size_t needed = (static_cast<size_t>(n) + 7) / 8;
		const size_t copied = std::min(needed, src_bytes);
		bits.resize(needed);
		std::memcpy(bits.data(), src, copied);
		if (copied < needed) {
			std::memset(bits.data() + copied, 0, needed - copied);
		}
	}
	bool test(idx_t i) const {
		return (bits[i >> 3] >> (i & 7)) & 1;
	}
};

// How many batches may sit between submit and collect, process-wide.
//
// This is a correctness bound, not a tuning knob, and what sets it is how the card
// receives an arm. batCount used to be a libstf ConfigWriteReadyRegister: a
// single-entry mailbox whose own header warns it "does not apply back pressure to the
// GlobalConfig. So values may be lost." A second write arriving while regex_top had not
// yet accepted the first silently overwrote it, and a lost arm is not a wrong answer
// but a wedged array -- the collector waits on a count nobody sent. Two credits were the
// most that could be allowed against that: one running batch, one pending arm.
//
// batCount is now a queue REGEX_BAT_COUNT_DEPTH (32) deep in regex_config.sv, so arms
// are lossless and this bound moves to what the rest of the path allows, which is
// REGEX_BAT_COUNT_DEPTH (32) -- the queue has no back-pressure, so overrunning it drops
// an arm. This bound is exact, not approximate: a credit is held for exactly the window
// between pushing an arm and collecting the results that pop it, so at most this many
// entries can ever be in the queue. 32 therefore fills it without exceeding it.
//
// It must also be at least the number of scan threads, or threads block here instead of
// packing: at 32 threads with 16 credits the scan spent 138 ms waiting on credits.
// Raising it past the RTL queue depth needs the FIFO deepened first.
//
// A credit is released in CollectRegexBatch.
static constexpr uint32_t kRegexMaxSubmissionsInFlight = 32;

// A batch handed to the card and not yet collected. Submission order is global and
// fixed at submit time: OutputBufferManager matches buffers to handles positionally
// (enqueued_handles[stream].front()), so a handle acquired second receives the
// second transfer's results whatever the threads do afterwards.
//
// Every submission holds one arm credit. It MUST be collected -- dropping one on the
// floor both leaks the credit and, worse, strands its handle at the head of the
// OBM's positional queue, where the next transfer's results are then delivered into
// an object nobody is reading. Collecting is what releases both.
struct RegexSubmission {
	std::shared_ptr<libstf::OutputHandle> handle;
	idx_t    count = 0;
	uint32_t bat_count = 0;
	// Global submission order, for diagnostics only.
	uint64_t seq = 0;

	bool valid() const { return handle != nullptr; }
};

// Takes one arm credit if the pool is not empty, without blocking.
//
// A caller that fails to get one and has transfers of its own outstanding MUST collect
// one of them rather than wait: the pool is shared, so blocking here while holding
// credits is what deadlocks the whole scan.
bool TryAcquireRegexArmCredit();


// Blocks until a credit is free. Only safe when the caller has nothing outstanding to
// collect -- otherwise it can be waiting on credits that only it could release.
void AcquireRegexArmCredit();

// Only one FSST symbol table may be in flight on the card at a time.
//
// The card holds ONE symbol table shared by all 64 engines, and rem_symbol_header rewrites
// it as soon as the next transfer's header arrives -- which is long before the engines have
// finished decoding the previous transfer. Each engine buffers 2 KB of un-decoded input
// (INPUT_FIFO_ADDR_BITS = 5), `tlast` only means the splitter accepted the beats, and under
// the passthrough an engine consumes code bytes 3-5x slower than the wire delivers them
// (one code expands to ~2.9 bytes on FSST's average), so its FIFO is permanently full and
// there is ALWAYS un-decoded data at a transfer boundary. sym_hold is a fixed
// START_HOLD_CYCLES countdown on engine *input* and does not cover it.
//
// When consecutive transfers carry the same table the rewrite is a no-op. When they differ,
// the tail of the earlier transfer decodes against the later table. Measured on
// p_substring_72_10_15728k: at 16384-row batches this loses terminators and wedges the
// array; at 1024-row batches it silently undercounts (1571197 vs 1572864 at 16 threads).
//
// One scan thread rarely trips it, because consecutive batches come from the same
// ColumnSegment and share a decoder; two threads read different row groups and interleave.
// So this gate is what makes the passthrough correct above one thread. `decoder` is the
// batch's FSST decoder pointer, or nullptr for plaintext -- with the passthrough off every
// transfer passes nullptr, they all match, and nothing serialises.
//
// The cost is a drain of the in-flight window at every table change, which is why the RTL
// fix (double-buffer the symbol RAM and flip per engine at its own transfer boundary) is
// still worth doing.
bool TryAcquireRegexTableSlot(const void *decoder);

// Blocks until the card's table is `decoder` or nothing is outstanding. Same rule as
// AcquireRegexArmCredit: only safe when the caller has nothing of its own left to collect.
void AcquireRegexTableSlot(const void *decoder);

// Releases one slot; the last release lets a different table through.
void ReleaseRegexTableSlot(const void *decoder);

// Arms the card for a batch already packed into `wire_ptr` by a RegexStreamPacker and
// enqueues its DMA, then returns without waiting for results. `count` is the number
// of real strings; `plan` carries the padded result geometry the card needs.
//
// `wire_ptr` must stay alive and unmodified until the matching CollectRegexBatch
// returns: the DMA reads it asynchronously.
//
// The caller must already hold one arm credit (TryAcquireRegexArmCredit /
// AcquireRegexArmCredit); CollectRegexBatch releases it.
RegexSubmission SubmitRegexBatch(celeris::CelerisContext &ctx, void *wire_ptr,
                                 const celeris::RegexStreamPacker::Plan &plan, idx_t count,
                                 const std::vector<uint8_t> &regex_blob, bool fsst_compressed = false);

// Blocks until `submission`'s results have landed and returns one verdict per slot,
// in slot order. Releases the submission's arm credit. Idempotent on an already
// collected (or default-constructed) submission, which is what lets a destructor
// drain a window without tracking which entries it already took.
RegexMatchBitmap CollectRegexBatch(RegexSubmission &submission);

} // namespace duckdb
