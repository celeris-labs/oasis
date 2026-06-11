#pragma once

#include "libstf/common.hpp"
#include <coyote/cThread.hpp>
#include <libstf/configuration.hpp>

#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace oasis {

constexpr const uint64_t OASIS_SYSTEM_ID = 0x0A515;

constexpr const uint64_t RDMA_READ_CONFIG_REGS = 2;
constexpr const uint64_t RDMA_READ_CONFIG_ID   = 0x2f966a70f04c0e93;

enum class FilterComparison : uint8_t {
    ALWAYS_TRUE   = 0,
    ALWAYS_FALSE  = 1,
    IN_BETWEEN    = 2,
    IN_RANGE      = 3,
    IN_LIST       = 4,
    ONE_OF        = 5,
    EQUAL          = 20,
    NOT_EQUAL      = 44,
    GREATER        = 36,
    LOWER          = 12,
    GREATER_EQUAL  = 52,
    LOWER_EQUAL    = 28,
};

enum class FilterMode : uint8_t {
    FULL_MATERIALIZATION = 0,
    BITMASK              = 1,
};

class FilterConfig : public libstf::Config {
  public:
    static constexpr size_t MAX_STREAMS        = 4;
    static constexpr size_t NUM_LAYERS         = 3;
    static constexpr size_t NUM_RHS            = 2;
    static constexpr size_t NUM_ADDITIONAL_RHS = 6;

    struct Stream {
        size_t stream;
        libstf::type_t type;
        bool enabled = true;
    };

    struct Predicate {
        size_t stream;
        size_t layer;
        FilterComparison comparison;
        std::array<uint64_t, NUM_RHS> rhs = {0, 0};
    };

    struct AdditionalRhs {
        size_t layer;
        std::array<uint64_t, NUM_ADDITIONAL_RHS> rhs = {};
        uint8_t mask = 0;
    };

    FilterConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset,
                 uint32_t num_regs);

    void configure(const std::vector<Stream> &streams,
                   const std::vector<Predicate> &predicates,
                   const std::vector<AdditionalRhs> &additional_rhs = {},
                   FilterMode mode = FilterMode::FULL_MATERIALIZATION);

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
