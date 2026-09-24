#include "oasis_hardware_bloom.hpp"

#include "oasis/oasis_context.hpp"

#include <coyote/cThread.hpp>
#include <libstf/configuration.hpp>

#include <cstdint>
#include <memory>
#include <utility>

namespace duckdb {

namespace {

// Mirrors celeris's BFConfig (celeris/hardware/src/hdl/config/bloomfilter_config.sv): a single
// write register combining a 32-bit materialization column count with a 1-bit materialization
// enable flag.
//
// KNOWN LIMITATION (deferred, not fixed here): celeris's MaskMaterializer (the consumer of
// num_columns/enable_materialization inside BloomfilterOperator, see
// celeris/hardware/src/hdl/bloomfilter/mask_materializer.sv) hardwires both signals' `ready` to 0
// and never re-arms its latch (cols_remaining_valid only clears on a full system reset), so only
// the very first value ever written to this register takes effect -- every later write just queues
// up behind it, unconsumed, for the life of the hardware context. That's fine for now since
// materialization is disabled and never re-configured, but it means num_columns/enable can't
// actually differ across different Bloom-accelerated joins yet: making that work needs
// MaskMaterializer itself to pop and re-latch at each new logical use, the same per-use
// consumption BloomFilterStreamSelectOperator's select channel already gets right. Tracked for
// whenever real materialization support is built; not addressed in this commit.
class BloomFilterConfig : public libstf::Config {
public:
	static constexpr uint64_t ID = 6; // BLOOMFILTER_CONFIG_ID (celeris/hardware/src/hdl/common.sv)

	BloomFilterConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset, uint32_t num_regs)
	    : libstf::Config(std::move(cthread), addr_offset, num_regs) {
	}

	void configure_materialization(uint32_t num_columns, bool enable) {
		uint64_t value = (uint64_t(num_columns) << 1) | (enable ? 1ULL : 0ULL);
		write_register(libstf::ConfigRegister(0, value));
	}

	void push_input_command(BloomInputCommand cmd) {
		write_register(libstf::ConfigRegister(1, static_cast<uint64_t>(cmd)));
	}

	// Read register 5, bit 0: sticky input command queue overflow
	bool input_command_queue_overflowed() {
		return (read_register(5).value() & 1ULL) != 0;
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

bool BloomInputCommandQueueOverflowed(oasis::OasisContext &ctx) {
	return ctx.config<BloomFilterConfig>()->input_command_queue_overflowed();
}

void ConfigureOasisHardwareBloom(oasis::OasisContext &ctx) {
	ctx.config<BloomFilterConfig>()->configure_materialization(0, false);
	ctx.config<BloomFilterLastInjectorConfig>()->configure(false, 0, 0);
}

} // namespace duckdb
