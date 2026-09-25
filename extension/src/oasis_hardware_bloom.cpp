#include "oasis_hardware_bloom.hpp"

#include "oasis/oasis_context.hpp"

#include <coyote/cThread.hpp>
#include <libstf/configuration.hpp>

#include <cstdint>
#include <memory>
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

// Mirrors hardware/src/hdl/bf_last_injector_config.sv: three plain registers (enable, first_beat,
// second_beat) controlling the inline TLAST injector on the Bloom filter's input stream in
// vfpga_top.svh, which concatenates however many decoded row-group chunks make up the build and
// probe sides into the two logical transfers the Bloom filter core expects.
class BloomFilterLastInjectorConfig : public libstf::Config {
public:
	static constexpr uint64_t ID = 0xa3f19d2c6b8e0741ULL; // BF_LAST_INJECT_CONFIG_ID (hardware/src/hdl/common.sv)

	BloomFilterLastInjectorConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset, uint32_t num_regs)
	    : libstf::Config(std::move(cthread), addr_offset, num_regs) {
	}

	void configure(bool enable, uint32_t first_beat, uint32_t second_beat) {
		write_register(libstf::ConfigRegister(0, enable ? 1ULL : 0ULL));
		write_register(libstf::ConfigRegister(1, first_beat));
		write_register(libstf::ConfigRegister(2, second_beat));
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

void ConfigureOasisHardwareBloom(oasis::OasisContext &ctx) {
	// Nothing to configure in the Bloom filter itself: its materialization and input commands are
	// pushed per chunk.
	ctx.config<BloomFilterLastInjectorConfig>()->configure(false, 0, 0);
}

} // namespace duckdb
