#pragma once

#include "libstf/common.hpp"
#include <coyote/cThread.hpp>
#include <libstf/configuration.hpp>

namespace oasis {

constexpr const uint64_t OASIS_SYSTEM_ID = 0x0A515;

constexpr const uint64_t RDMA_READ_CONFIG_REGS = 2;
constexpr const uint64_t RDMA_READ_CONFIG_ID   = 0x2f966a70f04c0e93;

/**
 * Configues a hardware RDMARead module to properly process the next page
 */
class RDMAReadConfig : public libstf::Config {
  public:
    RDMAReadConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset,
                   uint32_t num_regs);

    /**
     * Triggers a remote read using the RDMARead module.
     *
     * Offsets are relative to the base virtual address of the remote RDMA region. initRDMA must 
     * have exchanged queue pairs before the first read().
     *
     * @param stream The Coyote stream on which to perform the read.
     * @param offset The offset, relative to the remote region's base vaddr, to read from.
     * @param size   The number of bytes to read.
     */
    void read(libstf::stream_t stream, size_t offset, size_t size);

    const libstf::stream_t num_streams() const;

    static constexpr uint64_t ID = RDMA_READ_CONFIG_ID;

  private:
    libstf::stream_t num_streams_;
};

} // namespace oasis
