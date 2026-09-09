#include "regex_fpga_batch.hpp"

#include "celeris/configuration.hpp"
#include "duckdb/common/exception.hpp"
#include "libstf/memory_pool.hpp"
#include "libstf/util.hpp"

#include <algorithm>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <map>
#include <mutex>
#include <thread>
#include <output_handle.hpp>

#include "oasis_profiling.hpp"

namespace duckdb {

void EnsureCelerisContext() {
	try {
		celeris::CelerisContext::get_ctx();
	} catch (const std::exception &) {
#ifdef EN_SIMULATION
		std::cout << "simulation enabled\n";
		std::unique_ptr<libstf::MemoryPool> mem_pool = std::make_unique<libstf::SimpleMemoryPool>();
		celeris::CelerisContext::init(std::move(mem_pool), libstf::BYTES_PER_FPGA_TRANSFER);
#else
		std::unique_ptr<libstf::MemoryPool> mem_pool = std::make_unique<libstf::HugePageMemoryPool>();
		// One output buffer holds at most REGEX_FPGA_MAX_ACCUM_COUNT match bits (65536 / 8 = 8 KiB),
		// so the FPGA's minimum transfer granularity is already 8x more than we can ever use.
		// Oversizing here is costly: libstf's OBM enqueues a fresh buffer of this size on every
		// interrupt but only reclaims one when bytes_written > 0, so each empty interrupt leaks
		// exactly this many bytes out of the huge-page pool.
		celeris::CelerisContext::init(std::move(mem_pool), libstf::BYTES_PER_FPGA_TRANSFER);
#endif
	}
}

celeris::CelerisContext &GetCelerisContext() {
	EnsureCelerisContext();
	return celeris::CelerisContext::get_ctx();
}

uint64_t align_to_64_multiple(uint64_t size) {
	if (size == 0) {
		return 0;
	}
	return ((size + REGEX_FPGA_BEAT_BYTES - 1) / REGEX_FPGA_BEAT_BYTES) * REGEX_FPGA_BEAT_BYTES;
}

namespace {

// Accumulators for RegexBatchPhases. Relaxed ordering: these are diagnostics, and
// every increment already happens under fpga_mutex except mutex_wait itself.
std::atomic<uint64_t> g_batches {0};
std::atomic<uint64_t> g_strings {0};
std::atomic<uint64_t> g_wire_bytes {0};
std::atomic<uint64_t> g_mutex_wait_ns {0};
std::atomic<uint64_t> g_arm_wait_ns {0};
std::atomic<uint64_t> g_config_ns {0};
std::atomic<uint64_t> g_acquire_ns {0};
std::atomic<uint64_t> g_getconfig_ns {0};
std::atomic<uint64_t> g_handle_ns {0};
std::atomic<uint64_t> g_csr_ns {0};
std::atomic<uint64_t> g_scan_ns {0};
std::atomic<uint64_t> g_materialize_ns {0};
std::atomic<uint64_t> g_stage_ns {0};
std::atomic<uint64_t> g_emit_ns {0};
std::atomic<uint64_t> g_initlocal_ns {0};
std::atomic<uint64_t> g_wirealloc_ns {0};
std::atomic<uint64_t> g_enqueue_ns {0};
std::atomic<uint64_t> g_drain_ns {0};
std::atomic<uint64_t> g_read_ns {0};

// FSST passthrough row dispositions -- see RegexBatchPhases in the header.
std::atomic<uint64_t> g_rows_compressed {0};
std::atomic<uint64_t> g_rows_not_fsst {0};
std::atomic<uint64_t> g_rows_mode0 {0};
std::atomic<uint64_t> g_rows_outlier {0};

using PhaseClock = std::chrono::steady_clock;

// Link occupancy.
//
// The one question a stage decomposition cannot answer above one thread: was the card
// ever left with nothing to read? Every submitted-but-uncollected transfer is one the
// card either has not started, is reading, or has answered but nobody has picked up, so
// the window being empty is the only state in which the input DMA is provably idle.
//
// Kept under its own mutex rather than as lock-free atomics: the update is a
// compare-and-timestamp pair that has to be atomic *together*, and it happens twice per
// batch against a batch measured in tens of microseconds.
std::mutex g_depth_mutex;
uint32_t g_depth = 0;
uint32_t g_max_depth = 0;
PhaseClock::time_point g_depth_mark;   // last time g_depth changed
PhaseClock::time_point g_wall_start;
uint64_t g_link_idle_ns_v = 0;
uint64_t g_depth_ns_v = 0;              // integral of g_depth dt, for the mean depth
uint64_t g_idle_events_v = 0;
uint64_t g_max_idle_ns_v = 0;

// Fill and drain shape, per scan thread.
//
// link_idle_ns says the card had nothing enqueued; it does not say why. The two ends of
// a query are different problems: at the start every thread has to scan and pack a whole
// batch before anything can be submitted, and at the end threads stop at different times
// and the window empties one thread at a time. These record, relative to the first
// RegexFpgaScanInitGlobal of the query, when each thread first submitted and when it
// finished -- so "the pipeline fills slowly" can be told from "one thread starts late".
std::mutex g_fill_mutex;
PhaseClock::time_point g_query_start;
uint64_t g_fill_min_ns = 0, g_fill_max_ns = 0, g_fill_sum_ns = 0, g_fill_n = 0;
uint64_t g_done_min_ns = 0, g_done_max_ns = 0, g_done_sum_ns = 0, g_done_n = 0;

uint64_t NanosSince(const PhaseClock::time_point &start) {
	return static_cast<uint64_t>(
	    std::chrono::duration_cast<std::chrono::nanoseconds>(PhaseClock::now() - start).count());
}

// Advances the depth integral to `now` and applies `delta` to the window depth. Must be
// called with g_depth_mutex held.
void AccountDepth(const PhaseClock::time_point &now, int delta) {
	const uint64_t dt = static_cast<uint64_t>(
	    std::chrono::duration_cast<std::chrono::nanoseconds>(now - g_depth_mark).count());
	if (g_depth == 0) {
		g_link_idle_ns_v += dt;
		// Only a gap that is actually ended by a submit is one idle event; the
		// bring-up-to-date call from the reader passes delta == 0 and must not count.
		if (delta > 0 && dt > 0) {
			g_idle_events_v++;
			if (dt > g_max_idle_ns_v) {
				g_max_idle_ns_v = dt;
			}
			if (std::getenv("OASIS_REGEX_IDLE_TRACE") && dt > 50000) {
				std::fprintf(stderr, "[regexidle] gap %8.3f ms after %llu submissions\n",
				             double(dt) / 1e6,
				             (unsigned long long)g_batches.load(std::memory_order_relaxed));
			}
		}
	}
	g_depth_ns_v += dt * uint64_t(g_depth);
	g_depth_mark = now;
	if (delta > 0) {
		g_depth++;
		if (g_depth > g_max_depth) {
			g_max_depth = g_depth;
		}
	} else if (delta < 0 && g_depth > 0) {
		g_depth--;
	}
}

// Hang diagnostics, enabled by OASIS_REGEX_DIAG. Deliberately unconditional counters
// (relaxed atomics, a few ns) so the printout can name exact sequence numbers: the
// question these answer is whether a stalled run is blocked waiting for a *credit*
// (host-side starvation -- every credit held by a thread that is itself waiting for
// one) or inside the drain (the card owes results it never delivered). Those have
// opposite fixes, and from outside the process they look identical.
std::atomic<uint64_t> g_seq {0};
std::atomic<uint64_t> g_submitted {0};
std::atomic<uint64_t> g_collect_enter {0};
std::atomic<uint64_t> g_collect_exit {0};

bool DiagOn() {
	static const bool on = std::getenv("OASIS_REGEX_DIAG") != nullptr;
	return on;
}

void Diag(const char *what, uint64_t seq) {
	if (!DiagOn()) {
		return;
	}
	std::fprintf(stderr, "[regexdiag] %-14s seq=%-6llu submitted=%llu collect_enter=%llu collect_exit=%llu\n",
	             what, (unsigned long long)seq, (unsigned long long)g_submitted.load(std::memory_order_relaxed),
	             (unsigned long long)g_collect_enter.load(std::memory_order_relaxed),
	             (unsigned long long)g_collect_exit.load(std::memory_order_relaxed));
}

// Bounds the number of batches between submit and collect process-wide. See
// kRegexMaxSubmissionsInFlight for why this is a correctness bound on the RTL's
// single-entry arm mailbox and not a throughput knob.
//
// Hand-rolled rather than std::counting_semaphore: the extension is built at C++17.
// The arm-credit budget. Normally kRegexMaxSubmissionsInFlight; overridable so the queue
// bound can be tested in both directions without a rebuild.
//
// This is a diagnostic, not a tuning knob, and raising it past REGEX_STRINGS_IN_BATCH_DEPTH
// (32, in common.sv) is deliberately unsafe: ConfigWriteFIFO leaves the FIFO's `.i_ready()`
// unconnected, so an arm written into a full queue is dropped with no error, and rem_engines
// then waits on a count nobody sent -- an armed, drained, idle array that never retires.
// Lowering it instead widens the margin, which is the control for the same experiment.
inline uint32_t ArmCreditBudget() {
	static const uint32_t budget = [] {
		if (const char *s = std::getenv("OASIS_REGEX_ARM_CREDITS")) {
			const long v = std::strtol(s, nullptr, 10);
			if (v > 0 && v <= 4096) {
				std::fprintf(stderr, "[regexdiag] arm credits overridden to %ld (default %u)\n", v,
				             kRegexMaxSubmissionsInFlight);
				return static_cast<uint32_t>(v);
			}
		}
		return static_cast<uint32_t>(kRegexMaxSubmissionsInFlight);
	}();
	return budget;
}

class ArmCredits {
public:
	// Returns nanoseconds spent waiting, so the caller can tell "queued behind the
	// device" apart from "queued behind another host thread".
	uint64_t acquire() {
		std::unique_lock<std::mutex> lock(mutex_);
		if (available_ > 0) {
			available_--;
			return 0;
		}
		const auto start = PhaseClock::now();
		blocked_++;
		if (DiagOn()) {
			std::fprintf(stderr, "[regexdiag] %-14s blocked=%u available=0 submitted=%llu collect_enter=%llu collect_exit=%llu\n",
			             "ARM_BLOCK", blocked_, (unsigned long long)g_submitted.load(std::memory_order_relaxed),
			             (unsigned long long)g_collect_enter.load(std::memory_order_relaxed),
			             (unsigned long long)g_collect_exit.load(std::memory_order_relaxed));
		}
		cv_.wait(lock, [this] { return available_ > 0; });
		blocked_--;
		available_--;
		return NanosSince(start);
	}

	// Non-blocking. The caller uses this to discover that the pool is empty while it
	// still has work of its own it could collect -- see AcquireRegexArmCredit.
	bool try_acquire() {
		std::lock_guard<std::mutex> lock(mutex_);
		if (available_ == 0) {
			return false;
		}
		available_--;
		return true;
	}

	void release() {
		{
			std::lock_guard<std::mutex> lock(mutex_);
			available_++;
		}
		cv_.notify_one();
	}

private:
	std::mutex mutex_;
	std::condition_variable cv_;
	uint32_t available_ = ArmCreditBudget();
	uint32_t blocked_ = 0;
};

ArmCredits g_arm_credits;

// Serialises the arm + enqueue sequence. There is one cThread process-wide
// (celeris_context.cpp) and one input stream, and postCmd writes shared config
// registers with no internal lock, so config and enqueue cannot interleave across
// threads. It also fixes submission order, which is what the OBM's positional
// handle queue relies on -- hence the handle acquire is inside it too.
std::mutex g_fpga_mutex;

} // namespace

void AddRegexScanNs(uint64_t ns) { g_scan_ns.fetch_add(ns, std::memory_order_relaxed); }
void AddRegexMaterializeNs(uint64_t ns) { g_materialize_ns.fetch_add(ns, std::memory_order_relaxed); }
void AddRegexStageNs(uint64_t ns) { g_stage_ns.fetch_add(ns, std::memory_order_relaxed); }
void AddRegexEmitNs(uint64_t ns) { g_emit_ns.fetch_add(ns, std::memory_order_relaxed); }
void AddRegexInitLocalNs(uint64_t ns) { g_initlocal_ns.fetch_add(ns, std::memory_order_relaxed); }
void AddRegexWireAllocNs(uint64_t ns) { g_wirealloc_ns.fetch_add(ns, std::memory_order_relaxed); }

void NoteRegexRowPath(RegexRowPath path, uint64_t rows) {
	switch (path) {
	case RegexRowPath::COMPRESSED:
		g_rows_compressed.fetch_add(rows, std::memory_order_relaxed);
		break;
	case RegexRowPath::NOT_FSST:
		g_rows_not_fsst.fetch_add(rows, std::memory_order_relaxed);
		break;
	case RegexRowPath::MODE0:
		g_rows_mode0.fetch_add(rows, std::memory_order_relaxed);
		break;
	case RegexRowPath::OUTLIER:
		g_rows_outlier.fetch_add(rows, std::memory_order_relaxed);
		break;
	}
}

RegexBatchPhases GetRegexBatchPhases() {
	RegexBatchPhases p;
	p.batches = g_batches.load(std::memory_order_relaxed);
	p.strings = g_strings.load(std::memory_order_relaxed);
	p.wire_bytes = g_wire_bytes.load(std::memory_order_relaxed);
	p.mutex_wait_ns = g_mutex_wait_ns.load(std::memory_order_relaxed);
	p.arm_wait_ns = g_arm_wait_ns.load(std::memory_order_relaxed);
	p.config_ns = g_config_ns.load(std::memory_order_relaxed);
	p.acquire_ns = g_acquire_ns.load(std::memory_order_relaxed);
	p.getconfig_ns = g_getconfig_ns.load(std::memory_order_relaxed);
	p.handle_ns = g_handle_ns.load(std::memory_order_relaxed);
	p.csr_ns = g_csr_ns.load(std::memory_order_relaxed);
	p.scan_ns = g_scan_ns.load(std::memory_order_relaxed);
	p.materialize_ns = g_materialize_ns.load(std::memory_order_relaxed);
	p.stage_ns = g_stage_ns.load(std::memory_order_relaxed);
	p.emit_ns = g_emit_ns.load(std::memory_order_relaxed);
	p.initlocal_ns = g_initlocal_ns.load(std::memory_order_relaxed);
	p.wirealloc_ns = g_wirealloc_ns.load(std::memory_order_relaxed);
	p.enqueue_ns = g_enqueue_ns.load(std::memory_order_relaxed);
	p.drain_ns = g_drain_ns.load(std::memory_order_relaxed);
	p.read_ns = g_read_ns.load(std::memory_order_relaxed);
	p.rows_compressed = g_rows_compressed.load(std::memory_order_relaxed);
	p.rows_not_fsst = g_rows_not_fsst.load(std::memory_order_relaxed);
	p.rows_mode0 = g_rows_mode0.load(std::memory_order_relaxed);
	p.rows_outlier = g_rows_outlier.load(std::memory_order_relaxed);
	{
		// Bring the integrals up to date before reading them, or a window that has been
		// empty since the last submit reports zero idle.
		std::lock_guard<std::mutex> lock(g_depth_mutex);
		AccountDepth(PhaseClock::now(), 0);
		p.link_idle_ns = g_link_idle_ns_v;
		p.depth_ns = g_depth_ns_v;
		p.max_depth = g_max_depth;
		p.idle_events = g_idle_events_v;
		p.max_idle_ns = g_max_idle_ns_v;
		p.wall_ns = static_cast<uint64_t>(
		    std::chrono::duration_cast<std::chrono::nanoseconds>(g_depth_mark - g_wall_start).count());
	}
	{
		std::lock_guard<std::mutex> lock(g_fill_mutex);
		p.fill_min_ns = g_fill_min_ns;
		p.fill_max_ns = g_fill_max_ns;
		p.fill_mean_ns = g_fill_n ? g_fill_sum_ns / g_fill_n : 0;
		p.fill_threads = g_fill_n;
		p.done_min_ns = g_done_min_ns;
		p.done_max_ns = g_done_max_ns;
		p.done_mean_ns = g_done_n ? g_done_sum_ns / g_done_n : 0;
	}
	return p;
}

void ResetRegexBatchPhases() {
	g_batches.store(0, std::memory_order_relaxed);
	g_strings.store(0, std::memory_order_relaxed);
	g_wire_bytes.store(0, std::memory_order_relaxed);
	g_mutex_wait_ns.store(0, std::memory_order_relaxed);
	g_arm_wait_ns.store(0, std::memory_order_relaxed);
	g_config_ns.store(0, std::memory_order_relaxed);
	g_acquire_ns.store(0, std::memory_order_relaxed);
	g_getconfig_ns.store(0, std::memory_order_relaxed);
	g_handle_ns.store(0, std::memory_order_relaxed);
	g_csr_ns.store(0, std::memory_order_relaxed);
	g_scan_ns.store(0, std::memory_order_relaxed);
	g_materialize_ns.store(0, std::memory_order_relaxed);
	g_stage_ns.store(0, std::memory_order_relaxed);
	g_emit_ns.store(0, std::memory_order_relaxed);
	g_initlocal_ns.store(0, std::memory_order_relaxed);
	g_wirealloc_ns.store(0, std::memory_order_relaxed);
	g_enqueue_ns.store(0, std::memory_order_relaxed);
	g_drain_ns.store(0, std::memory_order_relaxed);
	g_read_ns.store(0, std::memory_order_relaxed);
	g_rows_compressed.store(0, std::memory_order_relaxed);
	g_rows_not_fsst.store(0, std::memory_order_relaxed);
	g_rows_mode0.store(0, std::memory_order_relaxed);
	g_rows_outlier.store(0, std::memory_order_relaxed);
	{
		std::lock_guard<std::mutex> lock(g_depth_mutex);
		const auto now = PhaseClock::now();
		g_wall_start = now;
		g_depth_mark = now;
		g_link_idle_ns_v = 0;
		g_depth_ns_v = 0;
		g_max_depth = g_depth;
		g_idle_events_v = 0;
		g_max_idle_ns_v = 0;
	}
}

void NoteRegexQueryStart() {
	std::lock_guard<std::mutex> lock(g_fill_mutex);
	g_query_start = PhaseClock::now();
	g_fill_min_ns = g_fill_max_ns = g_fill_sum_ns = g_fill_n = 0;
	g_done_min_ns = g_done_max_ns = g_done_sum_ns = g_done_n = 0;
}

void NoteRegexFirstSubmit() {
	std::lock_guard<std::mutex> lock(g_fill_mutex);
	const uint64_t ns = NanosSince(g_query_start);
	if (g_fill_n == 0 || ns < g_fill_min_ns) {
		g_fill_min_ns = ns;
	}
	if (ns > g_fill_max_ns) {
		g_fill_max_ns = ns;
	}
	g_fill_sum_ns += ns;
	g_fill_n++;
}

void NoteRegexThreadDone() {
	std::lock_guard<std::mutex> lock(g_fill_mutex);
	const uint64_t ns = NanosSince(g_query_start);
	// OASIS_REGEX_FILL_TRACE: one line per thread as it retires, with the wire bytes
	// submitted process-wide so far. The slope between consecutive lines is the link
	// rate the remaining threads are sustaining, which is how a ragged tail shows up as
	// throughput rather than as idle -- the window is never empty during it, so
	// link_idle_ns cannot see it.
	if (std::getenv("OASIS_REGEX_FILL_TRACE")) {
		std::fprintf(stderr, "[regexfill] thread done %2llu at %8.3f ms  wire %7.1f MB\n",
		             (unsigned long long)(g_done_n + 1), double(ns) / 1e6,
		             double(g_wire_bytes.load(std::memory_order_relaxed)) / 1e6);
	}
	if (g_done_n == 0 || ns < g_done_min_ns) {
		g_done_min_ns = ns;
	}
	if (ns > g_done_max_ns) {
		g_done_max_ns = ns;
	}
	g_done_sum_ns += ns;
	g_done_n++;
}

bool TryAcquireRegexArmCredit() {
	return g_arm_credits.try_acquire();
}

void AcquireRegexArmCredit() {
	g_arm_wait_ns.fetch_add(g_arm_credits.acquire(), std::memory_order_relaxed);
}

RegexSubmission SubmitRegexBatch(celeris::CelerisContext &ctx, void *wire_ptr,
                                 const celeris::RegexStreamPacker::Plan &plan, idx_t count,
                                 const std::vector<uint8_t> &regex_blob, bool fsst_compressed) {
	CALI_CXX_MARK_FUNCTION;
	if (count == 0) {
		return {};
	}

	// The caller must already hold exactly one arm credit for this submission; it is
	// released by the matching CollectRegexBatch.
	//
	// Acquiring here instead was a deadlock. The credits are process-wide but each
	// scan thread only collects once *its own* window is full, so N threads could take
	// every credit while all of them were still short of their window -- every credit
	// held by a thread blocked waiting for one more, and no thread ever reaching the
	// call that would release one. Ownership sits with the caller precisely so it can
	// collect its own oldest transfer instead of blocking. See AcquireRegexArmCredit.

	// Size this transfer's output buffer. The allocation itself now happens inside
	// acquire_output_handle, below.
	//
	// This used to allocate and TLB-map here, before the lock, via a libstf
	// prepare_output_buffer() that split the allocation off from the ordered registration:
	// the allocation and the TLB ioctl were 18.0 ms of an 18.9 ms critical section at 32
	// threads, with threads queued 118 ms behind it. That split only ever existed as an
	// uncommitted local edit to libstf, so nothing outside one developer's ~/opt could build
	// against it; this path is back on upstream's fused acquire_output_handle(stream, size),
	// which does the allocation under libstf's own enqueued_buffers_mutex. Restoring the
	// split means landing prepare_output_buffer in libstf proper.
	CALI_MARK_BEGIN("prepare_output");
	const auto t_acquire = PhaseClock::now();
	const size_t output_bytes = (static_cast<size_t>(plan.strings_in_batch) + 7) / 8;
	g_acquire_ns.fetch_add(NanosSince(t_acquire), std::memory_order_relaxed);
	CALI_MARK_END("prepare_output");

	CALI_MARK_BEGIN("mutex_wait");
	const auto t_wait = PhaseClock::now();
	std::unique_lock<std::mutex> lock(g_fpga_mutex);
	g_mutex_wait_ns.fetch_add(NanosSince(t_wait), std::memory_order_relaxed);
	CALI_MARK_END("mutex_wait");

	RegexSubmission submission;
	submission.count = count;
	submission.bat_count = plan.strings_in_batch;

	CALI_MARK_BEGIN("config_setup");
	const auto t_config = PhaseClock::now();
	std::shared_ptr<celeris::RegexConfig> config = ctx.get_config<celeris::RegexConfig>();
	const auto t_getcfg = PhaseClock::now();
	g_getconfig_ns.fetch_add(
	    uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(t_getcfg - t_config).count()),
	    std::memory_order_relaxed);

	// Stream 0 is UNMANAGED (see celeris_context.cpp), so it must go through the
	// size-based overload: the mask-based one is for managed streams only and trips an
	// assert that release builds compile out, then hands back a full-capacity buffer
	// instead of an exactly-sized one. The card writes one bit per padded result, so
	// ceil(bat_count/8) bytes is exactly what this batch will produce -- and one
	// correctly-sized buffer per handle is what lets several batches be outstanding.
	//
	// This has to stay inside this lock. OutputBufferManager matches arriving buffers to
	// handles positionally, so acquire order must equal enqueue order; two threads
	// registering outside the lock and enqueueing inside it would hand each other's results
	// over with no error anywhere. The allocation and TLB mapping happen in here too -- see
	// the note above.
	submission.handle = ctx.get_output_buffer_manager().acquire_output_handle(0, output_bytes);
	const auto t_handle = PhaseClock::now();
	g_handle_ns.fetch_add(
	    uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(t_handle - t_getcfg).count()),
	    std::memory_order_relaxed);

	// The pattern is constant for the whole query, so this is 35 MMIO writes on the
	// first submission and none after. regex_top latches the blob and arms the engines
	// once; a transfer does not re-arm the pattern.
	//
	// Writing a *different* pattern with transfers outstanding is not safe, and this
	// does not currently prevent it: RegexConfig's cached blob is process-wide, so two
	// concurrent queries with different patterns would rewrite it on every submission.
	// regex_top holds the write until the arm queue drains, so the card cannot be
	// wedged by it, but the transfers submitted in between are matched against the
	// pattern already loaded. The fix is to drain the in-flight window before writing a
	// differing blob -- acquire every arm credit rather than one. Not done here because
	// it needs a lock-free way to see the pending change before taking the lock, and
	// concurrent multi-pattern queries were already wrong before this path existed.
	config->write_regex_blob_if_changed(regex_blob);
	// The padded result count, not the string count: it tells the collector how many
	// bits to emit before it flushes and marks this transfer's last output beat.
	//
	// This must precede the enqueue below and must not be skipped. rem_engines gates
	// its input on the arm queue being non-empty, so a transfer whose DMA is delivered
	// ahead of its arm -- which happens routinely, since AXI-Lite and DMA are
	// independent paths -- back-pressures until the count lands rather than being
	// walked under whatever the array was last doing.
	// The arm entry's top bit tells the card this transfer's payload opens with a symbol
	// table and is FSST codes rather than plaintext. It rides here, not in the config
	// blob, because the blob is 2240 bits with zero slack and is latched once per query
	// while this varies per transfer. REGEX_ARM_TABLE_BIT in common.sv is the same bit.
	config->write_strings_in_batch(plan.strings_in_batch |
	                               (fsst_compressed ? (uint32_t(1) << 31) : uint32_t(0)));
	g_csr_ns.fetch_add(NanosSince(t_handle), std::memory_order_relaxed);
	g_config_ns.fetch_add(NanosSince(t_config), std::memory_order_relaxed);
	CALI_MARK_END("config_setup");

	CALI_MARK_BEGIN("enqueue");
	const auto t_enqueue = PhaseClock::now();
	// One stream now. The descriptor stream is gone: NUL terminators frame the
	// strings and the chunk interleave assigns them to engines.
	libstf::enqueue_stream_input(ctx.get_cthread(), ctx.get_tlb_manager(), wire_ptr, plan.wire_bytes, 0, true);
	g_wire_bytes.fetch_add(plan.wire_bytes, std::memory_order_relaxed);
	{
		std::lock_guard<std::mutex> depth_lock(g_depth_mutex);
		AccountDepth(PhaseClock::now(), +1);
	}
	submission.seq = g_seq.fetch_add(1, std::memory_order_relaxed);
	g_submitted.fetch_add(1, std::memory_order_relaxed);
	Diag("SUBMIT", submission.seq);
	// Geometry of this transfer, so a wedge can be matched against the RTL's `in` tap.
	// That tap freezes on tlast (regex_top.sv:203), so after a hang it holds the beat
	// count of the last transfer whose delivery actually completed; comparing it with the
	// wire_bytes logged here says whether the stuck batch reached the card at all.
	if (DiagOn()) {
		// rd_completed is Coyote's cumulative LOCAL_READ completion count. Only
		// enqueue_stream_input posts LOCAL_READs, so it should track submissions. If it
		// stalls at N while submissions climb past N, the DMA for that transfer never
		// completed and the loss is host/driver side; if it counts past the stuck
		// transfer, the DMA finished and the bytes were lost inside the shell or the
		// user logic instead. That is the fork the `in` tap cannot resolve on its own.
		const uint32_t rd_done =
		    ctx.get_cthread()->checkCompleted(coyote::CoyoteOper::LOCAL_READ);
		std::fprintf(stderr,
		             "[regexdiag] GEOM           seq=%-6llu wire_bytes=%llu beats=%llu armed=%u rd_completed=%u\n",
		             (unsigned long long)submission.seq, (unsigned long long)plan.wire_bytes,
		             (unsigned long long)(plan.wire_bytes / 64), plan.strings_in_batch, rd_done);
	}
	g_enqueue_ns.fetch_add(NanosSince(t_enqueue), std::memory_order_relaxed);
	CALI_MARK_END("enqueue");

	// Everything past this point is per-handle and needs no shared state, so the lock
	// ends here and the next thread can arm while this batch is still on the card.
	return submission;
}

// See TryAcquireRegexTableSlot in the header for why this exists.
//
// The double-buffered symbol RAM makes this gate redundant: rem_symbol_header stalls its
// own IDLE->HEADER transition while the bank it would overwrite is still busy, so the card
// backpressures instead of corrupting the tail of the previous transfer. Keep the gate as
// the default until that is proven on hardware; OASIS_REGEX_TABLE_GATE=0 turns it off.
static bool RegexTableGateEnabled() {
	static const bool enabled = [] {
		const char *env = std::getenv("OASIS_REGEX_TABLE_GATE");
		return !(env && env[0] == '0');
	}();
	return enabled;
}

std::mutex g_table_mutex;
std::condition_variable g_table_cv;
// Distinct symbol tables currently on the card, and how many transfers each is holding.
// A table occupies one of the RTL's symbol-RAM banks for as long as any of its transfers
// is uncollected, so the number of *distinct* tables is what must be capped -- transfers
// sharing a table share its bank and are unlimited.
std::map<const void *, uint64_t> g_table_inflight;

// How many distinct tables may be live at once. One is the conservative gate: the card
// then only ever holds the table it is decoding, and the double-buffered symbol RAM is
// never exercised. The RTL has two banks, so two *should* be safe and is what makes the
// double buffering worth having -- OASIS_REGEX_TABLE_SLOTS=2 is the experiment that says
// whether the second bank actually works. Zero means unlimited (gate off).
static uint64_t RegexTableSlots() {
	static const uint64_t slots = [] () -> uint64_t {
		const char *env = std::getenv("OASIS_REGEX_TABLE_SLOTS");
		if (env) {
			const auto parsed = std::strtoull(env, nullptr, 10);
			return parsed;
		}
		// Back-compatible with the original switch: TABLE_GATE=0 turns the gate off.
		const char *gate = std::getenv("OASIS_REGEX_TABLE_GATE");
		if (gate && gate[0] == '0') {
			return 0;
		}
		return 1;
	}();
	return slots;
}

static bool TableSlotAvailable(const void *decoder) {
	const uint64_t slots = RegexTableSlots();
	if (g_table_inflight.find(decoder) != g_table_inflight.end()) {
		return true;  // already resident, so it costs no new bank
	}
	return g_table_inflight.size() < slots;
}

bool TryAcquireRegexTableSlot(const void *decoder) {
	if (RegexTableSlots() == 0) {
		return true;
	}
	std::lock_guard<std::mutex> lock(g_table_mutex);
	if (!TableSlotAvailable(decoder)) {
		return false;
	}
	g_table_inflight[decoder]++;
	return true;
}

void AcquireRegexTableSlot(const void *decoder) {
	if (RegexTableSlots() == 0) {
		return;
	}
	std::unique_lock<std::mutex> lock(g_table_mutex);
	g_table_cv.wait(lock, [&] { return TableSlotAvailable(decoder); });
	g_table_inflight[decoder]++;
}

void ReleaseRegexTableSlot(const void *decoder) {
	if (RegexTableSlots() == 0) {
		return;
	}
	std::lock_guard<std::mutex> lock(g_table_mutex);
	auto it = g_table_inflight.find(decoder);
	D_ASSERT(it != g_table_inflight.end() && it->second > 0);
	if (it == g_table_inflight.end()) {
		return;
	}
	if (--it->second == 0) {
		g_table_inflight.erase(it);
		g_table_cv.notify_all();
	}
}

RegexMatchBitmap CollectRegexBatch(RegexSubmission &submission) {
	CALI_CXX_MARK_FUNCTION;
	if (!submission.valid()) {
		// Either a zero-row batch that was never armed, or a submission already
		// collected. Both are no-ops, which is what lets a teardown loop drain a
		// window without tracking what it has already taken.
		RegexMatchBitmap empty;
		empty.assign_zero(submission.count);
		return empty;
	}

	// Taken by value and cleared immediately, so every exit path below -- including
	// an exception out of the drain -- leaves the submission collected and releases
	// the credit exactly once.
	std::shared_ptr<libstf::OutputHandle> output_handle = std::move(submission.handle);
	const idx_t count = submission.count;
	submission.handle = nullptr;

	struct CreditGuard {
		~CreditGuard() { g_arm_credits.release(); }
	} credit_guard;

	g_collect_enter.fetch_add(1, std::memory_order_relaxed);
	Diag("DRAIN_ENTER", submission.seq);

	CALI_MARK_BEGIN("drain_output");
	const auto t_drain = PhaseClock::now();
	std::shared_ptr<libstf::Buffer> output_buffer;
	uint64_t drained_buffers = 0;
	uint64_t drained_bytes = 0;
	while (output_handle->any_stream_has_more_output()) {
		std::shared_ptr<libstf::Buffer> buf = output_handle->get_next_stream_output(0);
		if (buf) {
			drained_buffers++;
			drained_bytes += buf->size;
			if (output_buffer == nullptr) {
				output_buffer = buf;
			}
		}
	}
	g_drain_ns.fetch_add(NanosSince(t_drain), std::memory_order_relaxed);
	{
		std::lock_guard<std::mutex> depth_lock(g_depth_mutex);
		AccountDepth(PhaseClock::now(), -1);
	}
	g_collect_exit.fetch_add(1, std::memory_order_relaxed);
	Diag("DRAIN_EXIT", submission.seq);
	g_batches.fetch_add(1, std::memory_order_relaxed);
	g_strings.fetch_add(static_cast<uint64_t>(count), std::memory_order_relaxed);
	CALI_MARK_END("drain_output");

	if (output_buffer == nullptr) {
		RegexMatchBitmap empty;
		empty.assign_zero(count);
		return empty;
	}

	// Diagnostic: the card must hand back exactly one buffer holding at least
	// ceil(count/8) bytes. A short buffer would be silently zero-filled below --
	// reading as "no match" and losing exactly the kind of stray matches we see --
	// and a second buffer would be dropped entirely. Both are host/interface faults
	// as opposed to bad matching logic, so distinguishing them says where the bug is.
	// Costs one comparison per batch; prints only when something is actually wrong.
	if (const char *diag = std::getenv("OASIS_REGEX_DIAG")) {
		(void)diag;
		const uint64_t needed = (static_cast<uint64_t>(count) + 7) / 8;
		if (drained_buffers != 1 || drained_bytes < needed) {
			std::fprintf(stderr, "REGEX_DIAG count=%llu needed=%llu buffers=%llu bytes=%llu first=%llu\n",
			             (unsigned long long)count, (unsigned long long)needed,
			             (unsigned long long)drained_buffers, (unsigned long long)drained_bytes,
			             (unsigned long long)(output_buffer ? output_buffer->size : 0));
		}
	}

	// Discriminator for where the stray-match loss comes from. If the drain loop can
	// return before the card's DMA has fully landed, the bitmap we copy is partially
	// stale -- a host/driver synchronisation race. Sleeping here before the copy makes
	// that race disappear; a fault in the matching logic itself is unaffected by waiting.
	if (const char *us = std::getenv("OASIS_REGEX_READ_DELAY_US")) {
		const long delay = std::strtol(us, nullptr, 10);
		if (delay > 0) {
			std::this_thread::sleep_for(std::chrono::microseconds(delay));
		}
	}

	CALI_MARK_BEGIN("read_results");
	const auto t_read = PhaseClock::now();
	// Bit i IS string i. The collector pops all 64 engines on the same cycle and
	// strings are dealt round-robin, so engine k's p-th result is string 64p+k --
	// a pop emits 64 strings contiguously and in order. The card therefore hands
	// back the bitmap already in destination order and this is a straight copy,
	// independent of how many strings actually matched.
	RegexMatchBitmap results;
	results.assign_from_device(reinterpret_cast<const uint8_t *>(output_buffer->ptr), output_buffer->size, count);
	g_read_ns.fetch_add(NanosSince(t_read), std::memory_order_relaxed);
	CALI_MARK_END("read_results");
	return results;
}

} // namespace duckdb
