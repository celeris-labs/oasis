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
std::atomic<uint64_t> g_config_ns {0};
std::atomic<uint64_t> g_enqueue_ns {0};
std::atomic<uint64_t> g_drain_ns {0};
std::atomic<uint64_t> g_read_ns {0};

using PhaseClock = std::chrono::steady_clock;

uint64_t NanosSince(const PhaseClock::time_point &start) {
	return static_cast<uint64_t>(
	    std::chrono::duration_cast<std::chrono::nanoseconds>(PhaseClock::now() - start).count());
}

} // namespace

RegexBatchPhases GetRegexBatchPhases() {
	RegexBatchPhases p;
	p.batches = g_batches.load(std::memory_order_relaxed);
	p.strings = g_strings.load(std::memory_order_relaxed);
	p.mutex_wait_ns = g_mutex_wait_ns.load(std::memory_order_relaxed);
	p.config_ns = g_config_ns.load(std::memory_order_relaxed);
	p.enqueue_ns = g_enqueue_ns.load(std::memory_order_relaxed);
	p.drain_ns = g_drain_ns.load(std::memory_order_relaxed);
	p.read_ns = g_read_ns.load(std::memory_order_relaxed);
	return p;
}

void ResetRegexBatchPhases() {
	g_batches.store(0, std::memory_order_relaxed);
	g_strings.store(0, std::memory_order_relaxed);
	g_mutex_wait_ns.store(0, std::memory_order_relaxed);
	g_config_ns.store(0, std::memory_order_relaxed);
	g_enqueue_ns.store(0, std::memory_order_relaxed);
	g_drain_ns.store(0, std::memory_order_relaxed);
	g_read_ns.store(0, std::memory_order_relaxed);
}

RegexMatchBitmap RunFpgaRegexPackedBatch(celeris::CelerisContext &ctx, void *wire_ptr,
                                         const celeris::RegexStreamPacker::Plan &plan, idx_t count,
                                         const std::vector<uint8_t> &regex_blob) {
	CALI_CXX_MARK_FUNCTION;
	static std::mutex fpga_mutex;
	CALI_MARK_BEGIN("mutex_wait");
	const auto t_wait = PhaseClock::now();
	std::lock_guard<std::mutex> lock(fpga_mutex);
	g_mutex_wait_ns.fetch_add(NanosSince(t_wait), std::memory_order_relaxed);
	CALI_MARK_END("mutex_wait");

	if (count == 0) {
		return {};
	}

	CALI_MARK_BEGIN("config_setup");
	const auto t_config = PhaseClock::now();
	std::shared_ptr<celeris::RegexConfig> config = ctx.get_config<celeris::RegexConfig>();

	libstf::stream_mask_t active_outputs(0);
	active_outputs.set(0);
	std::shared_ptr<libstf::OutputHandle> output_handle = ctx.get_output_buffer_manager().acquire_output_handle(active_outputs);

	// The pattern is constant for the whole query, so this is 8 MMIO writes on the
	// first batch and none after. regex_top keeps the blob latched and re-arms the
	// engines off batCount instead.
	config->write_regex_blob_if_changed(regex_blob);
	// The padded result count, not the string count: it tells the collector how
	// many bits to emit and, divided by the engine count, how long each engine's
	// run is.
	config->write_bat_count(plan.bat_count);
	g_config_ns.fetch_add(NanosSince(t_config), std::memory_order_relaxed);
	CALI_MARK_END("config_setup");

	CALI_MARK_BEGIN("enqueue");
	const auto t_enqueue = PhaseClock::now();
	// One stream now. The descriptor stream is gone: NUL terminators frame the
	// strings and the chunk interleave assigns them to engines.
	libstf::enqueue_stream_input(ctx.get_cthread(), ctx.get_tlb_manager(), wire_ptr, plan.wire_bytes, 0, true);
	g_enqueue_ns.fetch_add(NanosSince(t_enqueue), std::memory_order_relaxed);
	CALI_MARK_END("enqueue");

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
