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

void EnsureCelerisContext();
celeris::CelerisContext &GetCelerisContext();

// Per-phase wall time inside RunFpgaRegexPackedBatch, accumulated across batches.
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
	uint64_t mutex_wait_ns = 0;
	uint64_t arm_wait_ns = 0;
	uint64_t config_ns = 0;
	// Time inside acquire_output_handle, a subset of config_ns. Broken out because it
	// allocates a huge page, TLB-maps it and pushes a descriptor, all under the submit
	// lock -- the obvious suspect when many threads serialise there.
	uint64_t acquire_ns = 0;
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
};

// Accumulators for the phases above, incremented from regex_table.cpp.
void AddRegexScanNs(uint64_t ns);
void AddRegexMaterializeNs(uint64_t ns);
void AddRegexStageNs(uint64_t ns);
void AddRegexEmitNs(uint64_t ns);

RegexBatchPhases GetRegexBatchPhases();
void ResetRegexBatchPhases();

// Every string now travels in the payload, including the ones DuckDB inlines
// into the 16 B string_t: there is no descriptor stream for them to ride along in
// any more. That trades 16 B/row of descriptor for len+1 B/row of payload, which
// is a win for anything under 15 B and a much bigger one for everything else,
// since the descriptor used to be sent *as well* as the payload.

uint64_t align_to_64_multiple(uint64_t size);

// One verdict per slot, kept in the card's own packed layout. The collector emits
// bit i for string i (see the parallel-pop note in RunFpgaRegexPackedBatch), so the
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
                                 const std::vector<uint8_t> &regex_blob);

// Blocks until `submission`'s results have landed and returns one verdict per slot,
// in slot order. Releases the submission's arm credit. Idempotent on an already
// collected (or default-constructed) submission, which is what lets a destructor
// drain a window without tracking which entries it already took.
RegexMatchBitmap CollectRegexBatch(RegexSubmission &submission);

// Submit immediately followed by collect. The serial path, kept for callers with
// nothing to overlap (RunFpgaRegexBatch, the SQL scalar function).
RegexMatchBitmap RunFpgaRegexPackedBatch(celeris::CelerisContext &ctx, void *wire_ptr,
                                         const celeris::RegexStreamPacker::Plan &plan, idx_t count,
                                         const std::vector<uint8_t> &regex_blob);

std::vector<bool> RunFpgaRegexBatch(celeris::CelerisContext &ctx, const std::vector<string_t> &inputs,
                                    const std::vector<uint8_t> &regex_blob);

} // namespace duckdb
