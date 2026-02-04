#pragma once

#include <coyote/cThread.hpp>
#include <libstf/configuration.hpp>

namespace oasis {

constexpr const uint64_t RDMA_READ_CONFIG_NUM_REGS = 2;
constexpr const uint64_t RDMA_READ_CONFIG_ID = 0x2f966a70f04c0e93;

/**
 * Configues a hardware RDMARead module to properly process the next page
 */
class RDMAReadConfig : public libstf::Config {
public:
  RDMAReadConfig(std::shared_ptr<coyote::cThread> cthread,
                 uint32_t addr_offset);

  /**
   * Triggers a remote read using the RDMARead module.
   *
   * @param vaddr The address at which the read should be performed.
   * @param size  The number of bytes to read.
   */
  void read(uintptr_t vaddr, size_t size);

  static constexpr uint64_t ID = RDMA_READ_CONFIG_ID;
};

} // namespace oasis
