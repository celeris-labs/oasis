#pragma once

#include "libstf/common.hpp"
#include <coyote/cThread.hpp>
#include <libstf/configuration.hpp>

#include <cstdint>

namespace oasis {

constexpr const uint64_t OASIS_SYSTEM_ID = 0x0A515;

constexpr const uint64_t RDMA_READ_CONFIG_REGS = 2;
constexpr const uint64_t RDMA_READ_CONFIG_ID   = 0x2f966a70f04c0e93;

enum class FilterComparison : uint8_t {
    ALWAYS_TRUE  = 0,
    ALWAYS_FALSE = 1,
    EQUAL         = 20,
    NOT_EQUAL     = 44,
    GREATER       = 36,
    LOWER         = 12,
    GREATER_EQUAL = 52,
    LOWER_EQUAL   = 28,
};

class FilterConfig : public libstf::Config {
  public:
    FilterConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset,
                 uint32_t num_regs);

    void configure(FilterComparison comparison, int64_t rhs);

    static constexpr uint64_t ID = 5;

  private:
    size_t num_streams_;
};

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
     * @param stream The Coyote stream on which to perform the read.
     * @param vaddr  The address at which the read should be performed.
     * @param size   The number of bytes to read.
     */
    void read(libstf::stream_t stream, uintptr_t vaddr, size_t size);

    const libstf::stream_t num_streams() const;

    static constexpr uint64_t ID = RDMA_READ_CONFIG_ID;

  private:
    libstf::stream_t num_streams_;
};

} // namespace oasis
