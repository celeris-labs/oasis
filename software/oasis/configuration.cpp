#include <cstring>
#include <string>

#include <libstf/profiling.hpp>
#include <oasis/configuration.hpp>

using libstf::profiler;

namespace oasis {

constexpr const uint32_t RDMA_READ_VADDR_ADDR = 0;
constexpr const uint32_t RDMA_READ_SIZE_ADDR = 1;

RDMAReadConfig::RDMAReadConfig(std::shared_ptr<coyote::cThread> cthread,
                               uint32_t addr_offset)
    : Config(cthread, addr_offset), num_streams_(read_register(1).value()) {}

const std::string rdma_read_prefix = "oasis::RDMAReadConfig::";

void RDMAReadConfig::read(libstf::stream_t stream, uintptr_t vaddr,
                          size_t size) {
  profiler::open_regions({rdma_read_prefix + "read"});
  auto offset = stream * RDMA_READ_CONFIG_REGS;
  write_register(libstf::ConfigRegister(offset + RDMA_READ_VADDR_ADDR, vaddr));
  write_register(libstf::ConfigRegister(offset + RDMA_READ_SIZE_ADDR, size));
  profiler::close_regions({rdma_read_prefix + "read"});
}

const libstf::stream_t RDMAReadConfig::num_streams() const {
  return num_streams_;
}

} // namespace oasis
