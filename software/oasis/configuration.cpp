#include <cstring>
#include <string>

#include <oasis/configuration.hpp>

namespace oasis {

constexpr const uint32_t READ_REQ_VADDR_ADDR = 0;
constexpr const uint32_t READ_REQ_SIZE_ADDR  = 1;
constexpr const uint32_t READ_REQ_CTID_ADDR  = 2;

ReadReqConfig::ReadReqConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset,
                               uint32_t num_regs)
    : Config(cthread, addr_offset, num_regs), num_streams_(read_register(1).value()) {}

void ReadReqConfig::set_base_vaddr(uintptr_t base_vaddr) { base_vaddr_ = base_vaddr; }

void ReadReqConfig::set_ctid(libstf::stream_t stream, uint32_t ctid) {
    auto reg_offset = stream * READ_REQ_CONFIG_REGS;
    write_register(libstf::ConfigRegister(reg_offset + READ_REQ_CTID_ADDR, ctid));
}

void ReadReqConfig::enqueue_read(libstf::stream_t stream, size_t vaddr, size_t size) {
    auto reg_offset = stream * READ_REQ_CONFIG_REGS;
    write_register(libstf::ConfigRegister(reg_offset + READ_REQ_VADDR_ADDR, base_vaddr_ + vaddr));
    write_register(libstf::ConfigRegister(reg_offset + READ_REQ_SIZE_ADDR, size));
}

const libstf::stream_t ReadReqConfig::num_streams() const { return num_streams_; }

} // namespace oasis
