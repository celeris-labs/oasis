#include <cstring>
#include <string>

#include <oasis/configuration.hpp>
#include <oasis/profiling.hpp>

namespace oasis {

constexpr const uint32_t RDMA_READ_VADDR_ADDR = 0;
constexpr const uint32_t RDMA_READ_SIZE_ADDR = 1;

RDMAReadConfig::RDMAReadConfig(std::shared_ptr<coyote::cThread> cthread,
                               uint32_t addr_offset)
    : Config(cthread, addr_offset) {}

const std::string read_region = "oasis::RDMAReadConfig::read";

void RDMAReadConfig::read(uintptr_t vaddr, size_t size) {
  profiler::open_regions({read_region});
  write_register(libstf::ConfigRegister(RDMA_READ_VADDR_ADDR, vaddr));
  write_register(libstf::ConfigRegister(RDMA_READ_SIZE_ADDR, size));
  profiler::close_regions({read_region});
}

} // namespace oasis
