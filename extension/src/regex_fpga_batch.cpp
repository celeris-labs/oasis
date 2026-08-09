#include "regex_fpga_batch.hpp"

#include "celeris/configuration.hpp"
#include "duckdb/common/exception.hpp"
#include "libstf/memory_pool.hpp"
#include "libstf/util.hpp"

#include <cstring>
#include <iostream>
#include <mutex>
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

uint64_t RegexFpgaNonInlinedRawCost(const string_t &input) {
	return input.IsInlined() ? 0 : static_cast<uint64_t>(input.GetSize()) + 1;
}

uint64_t align_to_64_multiple(uint64_t tight_nonlin_size) {
	if (tight_nonlin_size == 0) {
		return 0;
	}
	return ((tight_nonlin_size + REGEX_FPGA_BEAT_BYTES - 1) / REGEX_FPGA_BEAT_BYTES) * REGEX_FPGA_BEAT_BYTES;
}

void RegexFpgaPackString(string_t *descriptor, char *raw_base, uint64_t raw_off, const string_t &input) {
	std::memcpy(descriptor, &input, sizeof(string_t));
	if (!input.IsInlined()) {
		descriptor->SetPointer(reinterpret_cast<char *>(raw_off));
		char *dest = raw_base + raw_off;
		const idx_t length = input.GetSize();
		std::memcpy(dest, input.GetData(), length);
		dest[length] = '\0';
	}
}

// rem_engines_async packs up to 512 one-bit match flags per 64-byte output word.
// Bit i (LSB-first within each byte) corresponds to input string i.
static bool ReadMatchBit(const uint8_t *output_bytes, size_t output_size, idx_t string_index) {
	const size_t byte_offset = string_index / 8;
	const size_t bit_in_byte = string_index % 8;
	if (byte_offset >= output_size) {
		return false;
	}
	return (output_bytes[byte_offset] >> bit_in_byte) & 1;
}

std::vector<bool> RunFpgaRegexPackedBatch(celeris::CelerisContext &ctx, void *struct_ptr, idx_t count, void *raw_ptr,
                                          uint64_t raw_used, const std::vector<uint8_t> &regex_blob) {
	CALI_CXX_MARK_FUNCTION;
	static std::mutex fpga_mutex;
	CALI_MARK_BEGIN("mutex_wait");
	std::lock_guard<std::mutex> lock(fpga_mutex);
	CALI_MARK_END("mutex_wait");

	if (count == 0) {
		return {};
	}

	CALI_MARK_BEGIN("config_setup");
	std::shared_ptr<celeris::RegexConfig> config = ctx.get_config<celeris::RegexConfig>();

	libstf::stream_mask_t active_outputs(0);
	active_outputs.set(0);
	std::shared_ptr<libstf::OutputHandle> output_handle = ctx.get_output_buffer_manager().acquire_output_handle(active_outputs);

	config->write_bat_count(static_cast<uint32_t>(count));
	config->write_regex_blob(regex_blob);
	CALI_MARK_END("config_setup");

	const uint64_t data_buffer_size = align_to_64_multiple(raw_used);

	CALI_MARK_BEGIN("enqueue");
	libstf::enqueue_stream_input(ctx.get_cthread(), ctx.get_tlb_manager(), struct_ptr, count * sizeof(string_t), 0,
	                             true);
	if (data_buffer_size > 0) {
		libstf::enqueue_stream_input(ctx.get_cthread(), ctx.get_tlb_manager(), raw_ptr, data_buffer_size, 1, true);
	}
	CALI_MARK_END("enqueue");

	CALI_MARK_BEGIN("drain_output");
	std::shared_ptr<libstf::Buffer> output_buffer;
	while (output_handle->any_stream_has_more_output()) {
		std::shared_ptr<libstf::Buffer> buf = output_handle->get_next_stream_output(0);
		if (buf && output_buffer == nullptr) {
			output_buffer = buf;
		}
	}
	CALI_MARK_END("drain_output");

	if (output_buffer == nullptr) {
		return std::vector<bool>(count, false);
	}

	CALI_MARK_BEGIN("read_results");
	const uint8_t *output_bytes = reinterpret_cast<const uint8_t *>(output_buffer->ptr);
	const size_t output_size = output_buffer->size;
	std::vector<bool> results(count, false);
	for (idx_t i = 0; i < count; i++) {
		results[i] = ReadMatchBit(output_bytes, output_size, i);
	}
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
	uint64_t tight_nonlin_size = 0;
	for (idx_t i = 0; i < count; i++) {
		tight_nonlin_size += RegexFpgaNonInlinedRawCost(inputs[i]);
	}

	const uint64_t data_buffer_size = align_to_64_multiple(tight_nonlin_size);
	CALI_MARK_END("compute_sizes");

	CALI_MARK_BEGIN("allocate_buffers");
	libstf::Status status;
	std::shared_ptr<libstf::Buffer> struct_buffer =
	    libstf::make_buffer(ctx.get_memory_pool(), count * sizeof(string_t), status);
	if (!status.ok()) {
		throw InternalException("Failed to allocate FPGA regex descriptor buffer");
	}

	std::shared_ptr<libstf::Buffer> raw_buffer;
	if (data_buffer_size > 0) {
		raw_buffer = libstf::make_buffer(ctx.get_memory_pool(), data_buffer_size, status);
		if (!status.ok()) {
			throw InternalException("Failed to allocate FPGA regex payload buffer");
		}
		std::memset(raw_buffer->ptr, 0, data_buffer_size);
	}
	CALI_MARK_END("allocate_buffers");

	CALI_MARK_BEGIN("pack_inputs");
	uint64_t data_off = 0;
	auto *descriptors = reinterpret_cast<string_t *>(struct_buffer->ptr);
	for (idx_t i = 0; i < count; i++) {
		RegexFpgaPackString(&descriptors[i], static_cast<char *>(raw_buffer ? raw_buffer->ptr : nullptr), data_off,
		                    inputs[i]);
		data_off += RegexFpgaNonInlinedRawCost(inputs[i]);
	}
	CALI_MARK_END("pack_inputs");

	return RunFpgaRegexPackedBatch(ctx, struct_buffer->ptr, count, raw_buffer ? raw_buffer->ptr : nullptr, data_off,
	                               regex_blob);
}

} // namespace duckdb
