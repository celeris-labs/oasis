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
std::atomic<uint64_t> g_mutex_wait_ns {0};
std::atomic<uint64_t> g_arm_wait_ns {0};
std::atomic<uint64_t> g_config_ns {0};
std::atomic<uint64_t> g_acquire_ns {0};
std::atomic<uint64_t> g_scan_ns {0};
std::atomic<uint64_t> g_materialize_ns {0};
std::atomic<uint64_t> g_stage_ns {0};
std::atomic<uint64_t> g_emit_ns {0};
std::atomic<uint64_t> g_enqueue_ns {0};
std::atomic<uint64_t> g_drain_ns {0};
std::atomic<uint64_t> g_read_ns {0};

using PhaseClock = std::chrono::steady_clock;

uint64_t NanosSince(const PhaseClock::time_point &start) {
	return static_cast<uint64_t>(
	    std::chrono::duration_cast<std::chrono::nanoseconds>(PhaseClock::now() - start).count());
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
	uint32_t available_ = kRegexMaxSubmissionsInFlight;
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

RegexBatchPhases GetRegexBatchPhases() {
	RegexBatchPhases p;
	p.batches = g_batches.load(std::memory_order_relaxed);
	p.strings = g_strings.load(std::memory_order_relaxed);
	p.mutex_wait_ns = g_mutex_wait_ns.load(std::memory_order_relaxed);
	p.arm_wait_ns = g_arm_wait_ns.load(std::memory_order_relaxed);
	p.config_ns = g_config_ns.load(std::memory_order_relaxed);
	p.acquire_ns = g_acquire_ns.load(std::memory_order_relaxed);
	p.scan_ns = g_scan_ns.load(std::memory_order_relaxed);
	p.materialize_ns = g_materialize_ns.load(std::memory_order_relaxed);
	p.stage_ns = g_stage_ns.load(std::memory_order_relaxed);
	p.emit_ns = g_emit_ns.load(std::memory_order_relaxed);
	p.enqueue_ns = g_enqueue_ns.load(std::memory_order_relaxed);
	p.drain_ns = g_drain_ns.load(std::memory_order_relaxed);
	p.read_ns = g_read_ns.load(std::memory_order_relaxed);
	return p;
}

void ResetRegexBatchPhases() {
	g_batches.store(0, std::memory_order_relaxed);
	g_strings.store(0, std::memory_order_relaxed);
	g_mutex_wait_ns.store(0, std::memory_order_relaxed);
	g_arm_wait_ns.store(0, std::memory_order_relaxed);
	g_config_ns.store(0, std::memory_order_relaxed);
	g_acquire_ns.store(0, std::memory_order_relaxed);
	g_scan_ns.store(0, std::memory_order_relaxed);
	g_materialize_ns.store(0, std::memory_order_relaxed);
	g_stage_ns.store(0, std::memory_order_relaxed);
	g_emit_ns.store(0, std::memory_order_relaxed);
	g_enqueue_ns.store(0, std::memory_order_relaxed);
	g_drain_ns.store(0, std::memory_order_relaxed);
	g_read_ns.store(0, std::memory_order_relaxed);
}

bool TryAcquireRegexArmCredit() {
	return g_arm_credits.try_acquire();
}

void AcquireRegexArmCredit() {
	g_arm_wait_ns.fetch_add(g_arm_credits.acquire(), std::memory_order_relaxed);
}

RegexSubmission SubmitRegexBatch(celeris::CelerisContext &ctx, void *wire_ptr,
                                 const celeris::RegexStreamPacker::Plan &plan, idx_t count,
                                 const std::vector<uint8_t> &regex_blob) {
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

	// Allocate and TLB-map this transfer's output buffer BEFORE taking the lock.
	//
	// The handle registration has to stay ordered -- the OBM matches buffers to handles
	// positionally -- but the allocation and the TLB ioctl behind it do not, and they are
	// what the critical section was actually made of: 18.0 ms of a 18.9 ms section at 32
	// threads, with threads queued 118 ms behind it. Split, the ordered part is a queue
	// push and one descriptor write.
	CALI_MARK_BEGIN("prepare_output");
	const auto t_acquire = PhaseClock::now();
	const size_t output_bytes = (static_cast<size_t>(plan.bat_count) + 7) / 8;
	libstf::Buffer prepared = ctx.get_output_buffer_manager().prepare_output_buffer(0, output_bytes);
	g_acquire_ns.fetch_add(NanosSince(t_acquire), std::memory_order_relaxed);
	CALI_MARK_END("prepare_output");

	CALI_MARK_BEGIN("mutex_wait");
	const auto t_wait = PhaseClock::now();
	std::unique_lock<std::mutex> lock(g_fpga_mutex);
	g_mutex_wait_ns.fetch_add(NanosSince(t_wait), std::memory_order_relaxed);
	CALI_MARK_END("mutex_wait");

	RegexSubmission submission;
	submission.count = count;
	submission.bat_count = plan.bat_count;

	CALI_MARK_BEGIN("config_setup");
	const auto t_config = PhaseClock::now();
	std::shared_ptr<celeris::RegexConfig> config = ctx.get_config<celeris::RegexConfig>();

	// Stream 0 is UNMANAGED (see celeris_context.cpp), so it must go through the
	// size-based overload: the mask-based one is for managed streams only and trips an
	// assert that release builds compile out, then hands back a full-capacity buffer
	// instead of an exactly-sized one. The card writes one bit per padded result, so
	// ceil(bat_count/8) bytes is exactly what this batch will produce -- and one
	// correctly-sized buffer per handle is what lets several batches be outstanding.
	//
	// The registration has to stay inside this lock. OutputBufferManager matches arriving
	// buffers to handles positionally, so acquire order must equal enqueue order; two
	// threads registering outside the lock and enqueueing inside it would hand each
	// other's results over with no error anywhere. Only the allocation moved out.
	submission.handle = ctx.get_output_buffer_manager().acquire_output_handle(0, prepared);

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
	config->write_bat_count(plan.bat_count);
	g_config_ns.fetch_add(NanosSince(t_config), std::memory_order_relaxed);
	CALI_MARK_END("config_setup");

	CALI_MARK_BEGIN("enqueue");
	const auto t_enqueue = PhaseClock::now();
	// One stream now. The descriptor stream is gone: NUL terminators frame the
	// strings and the chunk interleave assigns them to engines.
	libstf::enqueue_stream_input(ctx.get_cthread(), ctx.get_tlb_manager(), wire_ptr, plan.wire_bytes, 0, true);
	submission.seq = g_seq.fetch_add(1, std::memory_order_relaxed);
	g_submitted.fetch_add(1, std::memory_order_relaxed);
	Diag("SUBMIT", submission.seq);
	g_enqueue_ns.fetch_add(NanosSince(t_enqueue), std::memory_order_relaxed);
	CALI_MARK_END("enqueue");

	// Everything past this point is per-handle and needs no shared state, so the lock
	// ends here and the next thread can arm while this batch is still on the card.
	return submission;
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

RegexMatchBitmap RunFpgaRegexPackedBatch(celeris::CelerisContext &ctx, void *wire_ptr,
                                         const celeris::RegexStreamPacker::Plan &plan, idx_t count,
                                         const std::vector<uint8_t> &regex_blob) {
	CALI_CXX_MARK_FUNCTION;
	if (count == 0) {
		return {};
	}
	// Nothing outstanding to collect, so blocking for a credit is safe here.
	CALI_MARK_BEGIN("arm_wait");
	AcquireRegexArmCredit();
	CALI_MARK_END("arm_wait");
	RegexSubmission submission = SubmitRegexBatch(ctx, wire_ptr, plan, count, regex_blob);
	return CollectRegexBatch(submission);
}

std::vector<bool> RunFpgaRegexBatch(celeris::CelerisContext &ctx, const std::vector<string_t> &inputs,
                                    const std::vector<uint8_t> &regex_blob) {
	CALI_CXX_MARK_FUNCTION;
	const idx_t count = inputs.size();
	if (count == 0) {
		return {};
	}

	CALI_MARK_BEGIN("compute_sizes");
	std::vector<uint64_t> lengths;
	lengths.reserve(count);
	for (idx_t i = 0; i < count; i++) {
		lengths.push_back(static_cast<uint64_t>(inputs[i].GetSize()));
	}
	const uint64_t wire_bytes = celeris::RegexStreamPacker::required_bytes(lengths.data(), count);
	CALI_MARK_END("compute_sizes");

	CALI_MARK_BEGIN("allocate_buffers");
	libstf::Status status;
	std::shared_ptr<libstf::Buffer> wire_buffer = libstf::make_buffer(ctx.get_memory_pool(), wire_bytes, status);
	if (!status.ok()) {
		throw InternalException("Failed to allocate FPGA regex wire buffer");
	}
	CALI_MARK_END("allocate_buffers");

	CALI_MARK_BEGIN("pack_inputs");
	celeris::RegexStreamPacker packer;
	packer.reset(static_cast<uint8_t *>(wire_buffer->ptr), wire_bytes);
	for (idx_t i = 0; i < count; i++) {
		packer.append(inputs[i].GetData(), inputs[i].GetSize());
	}
	const celeris::RegexStreamPacker::Plan plan = packer.finalize();
	CALI_MARK_END("pack_inputs");

	const RegexMatchBitmap bitmap = RunFpgaRegexPackedBatch(ctx, wire_buffer->ptr, plan, count, regex_blob);
	std::vector<bool> results(count, false);
	for (idx_t i = 0; i < count; i++) {
		results[i] = bitmap.test(i);
	}
	return results;
}

} // namespace duckdb
