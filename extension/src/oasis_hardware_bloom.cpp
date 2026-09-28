#include "oasis_hardware_bloom.hpp"

#include "duckdb/common/assert.hpp"
#include "duckdb/common/exception.hpp"
#include "oasis/oasis_context.hpp"
#include "parcore/configuration.hpp"

#include <coyote/cThread.hpp>
#include <libstf/configuration.hpp>

#include <atomic>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>

namespace duckdb {

const char *BloomStreamSelectName(BloomStreamSelect select) {
	switch (select) {
	case BloomStreamSelect::FILTER:
		return "filter";
	case BloomStreamSelect::BYPASS:
		return "bypass";
	case BloomStreamSelect::BUILD:
		return "build";
	case BloomStreamSelect::MATERIALIZE:
		return "materialize";
	}
	return "unknown";
}

namespace {

// Mirrors celeris's BFConfig (celeris/hardware/src/hdl/config/bloomfilter_config.sv): register 0
// takes the materialization commands (one per probe chunk, see PushBloomMaterializeCommand),
// register 1 the input commands.
class BloomFilterConfig : public libstf::Config {
public:
	static constexpr uint64_t ID = 6; // BLOOMFILTER_CONFIG_ID (celeris/hardware/src/hdl/common.sv)

	BloomFilterConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset, uint32_t num_regs)
	    : libstf::Config(std::move(cthread), addr_offset, num_regs) {
	}

	// {num_columns, enable}: a chunk is only materialized if enabled with at least one column
	void push_materialize_command(uint32_t num_columns) {
		uint64_t value = (uint64_t(num_columns) << 1) | (num_columns != 0 ? 1ULL : 0ULL);
		write_register(libstf::ConfigRegister(0, value));
	}

	void push_input_command(BloomInputCommand cmd) {
		write_register(libstf::ConfigRegister(1, static_cast<uint64_t>(cmd)));
	}

	// Read register 5: sticky command queue overflows, bit 0 input commands, bit 1 materialization
	// commands
	bool command_queue_overflowed() {
		return (read_register(5).value() & 0b11ULL) != 0;
	}
};

// Mirrors celeris's StreamConfig (parcore/libstf/hardware/src/hdl/config/stream_config.sv)
// instantiated with NUM_STREAMS=1 in vfpga_top.svh, selecting where decoder-stream 0 routes its
// transfer (see BloomStreamSelect).
class BloomFilterStreamConfig : public libstf::Config {
public:
	static constexpr uint64_t ID = 1; // STREAM_CONFIG_ID (parcore/libstf/hardware/src/hdl/common.sv)

	BloomFilterStreamConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset, uint32_t num_regs)
	    : libstf::Config(std::move(cthread), addr_offset, num_regs) {
	}

	// Value layout is (select << 3) | data_type, matching stream_conf_t's packed layout (data_type
	// is 3 bits, unused here).
	void select(BloomStreamSelect select) {
		constexpr uint64_t DATA_TYPE_BITS = 3;
		write_register(libstf::ConfigRegister(0, static_cast<uint64_t>(select) << DATA_TYPE_BITS));
	}
};

static std::atomic<bool> bloom_filter_in_use {false};

} // namespace

void PushBloomInputCommand(oasis::OasisContext &ctx, BloomInputCommand cmd) {
	ctx.config<BloomFilterConfig>()->push_input_command(cmd);
}

void PushBloomMaterializeCommand(oasis::OasisContext &ctx, uint32_t num_columns) {
	ctx.config<BloomFilterConfig>()->push_materialize_command(num_columns);
}

bool BloomCommandQueueOverflowed(oasis::OasisContext &ctx) {
	return ctx.config<BloomFilterConfig>()->command_queue_overflowed();
}

void CheckOasisHardwareBloom(oasis::OasisContext &ctx) {
	const auto num_decoders = ctx.config<parcore::ColumnChunkDecoderConfig>()->num_decoders();
	if (num_decoders != 1) {
		throw std::runtime_error("Oasis requires a hardware design with exactly one column chunk decoder "
		                         "(the Bloom filter's stream select is on decoder stream 0), but it has " +
		                         std::to_string(num_decoders));
	}
}

BloomFilterStreamSelectOperator::BloomFilterStreamSelectOperator(BloomStreamSelect select,
                                                                 std::optional<uint32_t> materialize_columns,
                                                                 bool end_side)
    : select_(select), materialize_columns_(materialize_columns), end_side_(end_side) {
	D_ASSERT(materialize_columns_.has_value() == (select_ == BloomStreamSelect::FILTER));
	D_ASSERT(!end_side_ || IsKeyChunk());
}

void BloomFilterStreamSelectOperator::apply(libstf::stream_t, oasis::OasisContext &ctx) {
	ctx.config<BloomFilterStreamConfig>()->select(select_);
	if (IsKeyChunk()) {
		PushBloomInputCommand(ctx, BloomInputCommand::CONTINUE);
	}
	if (materialize_columns_) {
		PushBloomMaterializeCommand(ctx, *materialize_columns_);
	}
	if (end_side_) {
		PushBloomInputCommand(ctx, BloomInputCommand::END);
	}
}

void BloomFilterStreamSelectOperator::print(std::ostream &os) const {
	os << "BloomFilterStreamSelect(" << BloomStreamSelectName(select_);
	if (materialize_columns_) {
		os << ", materialize " << *materialize_columns_;
	}
	if (end_side_) {
		os << ", END";
	}
	os << ")";
}

bool BloomFilterStreamSelectOperator::IsKeyChunk() const {
	return select_ == BloomStreamSelect::FILTER || select_ == BloomStreamSelect::BUILD;
}

bool IsBloomMaterializableChunk(const parcore::metadata::ColumnChunk &cc) {
	return libstf::size_of(parcore::metadata::to_libstf_type(cc.type)) == 8 && !cc.has_def_levels &&
	       !cc.has_rep_levels;
}

bool IsBloomKeyColumn(const parcore::metadata::Metadata &meta, size_t col_id) {
	for (const auto &group : meta.groups) {
		const auto &cc = group.chunks[col_id];
		if (cc.type != parcore::metadata::Type::INT64_T || cc.has_def_levels || cc.has_rep_levels) {
			return false;
		}
	}
	return true;
}

size_t CountBloomKeptRows(const libstf::Buffer &mask, size_t num_rows) {
	if (mask.size < (num_rows + 7) / 8) {
		throw InternalException("Bloom filter mask has %llu bytes for %llu rows", (unsigned long long)mask.size,
		                        (unsigned long long)num_rows);
	}
	const auto *bytes = static_cast<const uint8_t *>(mask.ptr);
	size_t kept = 0;
	for (size_t b = 0; b < num_rows / 8; b++) {
		kept += __builtin_popcount(bytes[b]);
	}
	if (num_rows % 8 != 0) {
		kept += __builtin_popcount(bytes[num_rows / 8] & ((1u << (num_rows % 8)) - 1));
	}
	return kept;
}

bool TryAcquireBloomFilter() {
	bool in_use = false;
	return bloom_filter_in_use.compare_exchange_strong(in_use, true, std::memory_order_acquire);
}

void ReleaseBloomFilter() {
	bloom_filter_in_use.store(false, std::memory_order_release);
}

} // namespace duckdb
