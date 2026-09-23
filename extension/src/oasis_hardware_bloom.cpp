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
};

// Mirrors celeris's StreamConfig (celeris/../libstf/hardware/src/hdl/config/stream_config.sv)
// instantiated with NUM_STREAMS=1 in vfpga_top.svh, selecting whether decoder-stream 0 routes
// through the Bloom filter (select=0) or bypasses it (select=1).
class BloomFilterStreamConfig : public libstf::Config {
public:
	static constexpr uint64_t ID = 1; // STREAM_CONFIG_ID (parcore/libstf/hardware/src/hdl/common.sv)

	BloomFilterStreamConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset, uint32_t num_regs)
	    : libstf::Config(std::move(cthread), addr_offset, num_regs) {
	}

	void select_bypass() {
		constexpr uint64_t BYPASS_SELECT = 1;
		constexpr uint64_t DATA_TYPE_BITS = 3;
		write_register(libstf::ConfigRegister(0, BYPASS_SELECT << DATA_TYPE_BITS));
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

void ConfigureOasisHardwareBloom() {
	auto &ctx = oasis::OasisContext::ctx();

	ctx.config<BloomFilterConfig>()->configure_materialization(0, false);
	ctx.config<BloomFilterStreamConfig>()->select_bypass();
	ctx.config<BloomFilterLastInjectorConfig>()->configure(false, 0, 0);
}

void EnqueueOasisHardwareBloomBypass() {
	oasis::OasisContext::ctx().config<BloomFilterStreamConfig>()->select_bypass();
}

} // namespace duckdb
