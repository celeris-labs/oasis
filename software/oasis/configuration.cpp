#include <cstring>
#include <stdexcept>
#include <string>

#include <oasis/configuration.hpp>

namespace oasis {

constexpr const uint32_t READ_REQ_VADDR_ADDR = 0;
constexpr const uint32_t READ_REQ_SIZE_ADDR  = 1;
constexpr const uint32_t READ_REQ_CTID_ADDR  = 2;

ReadReqConfig::ReadReqConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset,
                               uint32_t num_regs)
    : Config(cthread, addr_offset, num_regs), num_streams_(read_register(1).value()),
      base_vaddrs_(num_streams_, 0) {}

void ReadReqConfig::set_base_vaddr(libstf::stream_t stream, uintptr_t base_vaddr) {
    base_vaddrs_[stream] = base_vaddr;
}

void ReadReqConfig::set_ctid(libstf::stream_t stream, uint32_t ctid) {
    auto reg_offset = stream * READ_REQ_CONFIG_REGS;
    write_register(libstf::ConfigRegister(reg_offset + READ_REQ_CTID_ADDR, ctid));
}

void ReadReqConfig::enqueue_read(libstf::stream_t stream, size_t vaddr, size_t size) {
    auto reg_offset = stream * READ_REQ_CONFIG_REGS;
    write_register(
        libstf::ConfigRegister(reg_offset + READ_REQ_VADDR_ADDR, base_vaddrs_[stream] + vaddr));
    write_register(libstf::ConfigRegister(reg_offset + READ_REQ_SIZE_ADDR, size));
}

const libstf::stream_t ReadReqConfig::num_streams() const { return num_streams_; }

GenericConfig::GenericConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset,
                             uint32_t num_regs)
    : Config(cthread, addr_offset, num_regs) {}

uint64_t GenericConfig::notify_count() {
    return read_register(GENERIC_CONFIG_NOTIFY_COUNT_REG).value();
}

bool GenericConfig::has_bypass_profile() const {
    return num_regs >= GENERIC_CONFIG_BYPASS_PROFILE_REG + NUM_BYPASS_PROFILE_REGS;
}

parcore::StreamProfile GenericConfig::read_bypass_profile() {
    if (!has_bypass_profile()) {
        throw std::runtime_error(
            "Hardware design on device has no bypass StreamProfiler (non-RDMA build?)");
    }

    // Ascending order matters: the hardware resets the profiler when the last counter is read.
    auto base = GENERIC_CONFIG_BYPASS_PROFILE_REG;

    parcore::StreamProfile profile;
    profile.handshakes_cycles = read_register(base + 0).value();
    profile.starved_cycles    = read_register(base + 1).value();
    profile.stalled_cycles    = read_register(base + 2).value();
    profile.idle_cycles       = read_register(base + 3).value();
    profile.last_handshakes   = read_register(base + 4).value();
    return profile;
}

} // namespace oasis
