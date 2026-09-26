#include "oasis_hardware_bloom.hpp"

#include "oasis/oasis_context.hpp"
#include "parcore/configuration.hpp"

#include <coyote/cThread.hpp>
#include <libstf/configuration.hpp>

#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>

namespace duckdb {

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

} // namespace duckdb
