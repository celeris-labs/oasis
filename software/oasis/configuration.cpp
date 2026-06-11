#include <cstring>
#include <stdexcept>
#include <string>

#include <libstf/profiling.hpp>
#include <oasis/configuration.hpp>

using libstf::Profiler;

namespace oasis {

constexpr const uint32_t FILTER_RHS_ADDR                 = 0;
constexpr const uint32_t FILTER_OPERATOR_ADDR            = 1;
constexpr const uint32_t FILTER_CONTROL_ADDR             = 2;
constexpr const uint32_t FILTER_ADDITIONAL_RHS_ADDR      = 3;
constexpr const uint32_t FILTER_ADDITIONAL_RHS_MASK_ADDR = 4;

constexpr const size_t FILTER_MAX_STREAMS        = 4;
constexpr const size_t FILTER_NUM_LAYERS         = 3;
constexpr const size_t FILTER_NUM_RHS            = 2;
constexpr const size_t FILTER_NUM_ADDITIONAL_RHS = 6;

FilterConfig::FilterConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset,
                           uint32_t num_regs)
    : Config(cthread, addr_offset, num_regs), num_streams_(read_register(1).value()) {
    if (num_streams_ == 0 || num_streams_ > FILTER_MAX_STREAMS) {
        throw std::runtime_error("Unsupported number of hardware filter streams");
    }
}

void FilterConfig::configure(FilterComparison comparison, int64_t rhs) {
    for (size_t stream = 0; stream < num_streams_; stream++) {
        for (size_t layer = 0; layer < FILTER_NUM_LAYERS; layer++) {
            for (size_t rhs_index = 0; rhs_index < FILTER_NUM_RHS; rhs_index++) {
                const bool active_rhs = stream == 0 && layer == 0 && rhs_index == 0;
                write_register(libstf::ConfigRegister(
                    FILTER_RHS_ADDR, active_rhs ? static_cast<uint64_t>(rhs) : 0));
            }
        }
    }

    for (size_t layer = 0; layer < FILTER_NUM_LAYERS; layer++) {
        uint64_t operator_word = 0;
        for (size_t stream = 0; stream < num_streams_; stream++) {
            auto op = FilterComparison::ALWAYS_TRUE;
            if (stream == 0) {
                op = layer == 0 ? comparison : FilterComparison::ALWAYS_FALSE;
            }
            operator_word |= static_cast<uint64_t>(op) << (stream * 8);
        }
        write_register(libstf::ConfigRegister(FILTER_OPERATOR_ADDR, operator_word));
    }

    for (size_t layer = 0; layer < FILTER_NUM_LAYERS; layer++) {
        for (size_t slot = 0; slot < FILTER_NUM_ADDITIONAL_RHS; slot++) {
            write_register(libstf::ConfigRegister(FILTER_ADDITIONAL_RHS_ADDR, 0));
        }
    }
    write_register(libstf::ConfigRegister(FILTER_ADDITIONAL_RHS_MASK_ADDR, 0));

    const size_t stream_type_lsb = num_streams_;
    const size_t mode_lsb = stream_type_lsb + num_streams_ * 3;
    const size_t valid_bit = mode_lsb + 2;

    uint64_t control_word = 1; // Stream 0 enabled.
    for (size_t stream = 0; stream < num_streams_; stream++) {
        control_word |= static_cast<uint64_t>(libstf::type_t::INT64_T)
                        << (stream_type_lsb + stream * 3);
    }
    control_word |= uint64_t {1} << valid_bit;

    // The control word commits the payload and must be written last.
    write_register(libstf::ConfigRegister(FILTER_CONTROL_ADDR, control_word));
}

constexpr const uint32_t RDMA_READ_VADDR_ADDR = 0;
constexpr const uint32_t RDMA_READ_SIZE_ADDR  = 1;

RDMAReadConfig::RDMAReadConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset,
                               uint32_t num_regs)
    : Config(cthread, addr_offset, num_regs), num_streams_(read_register(1).value()) {}

const std::string rdma_read_prefix = "oasis::RDMAReadConfig::";

void RDMAReadConfig::read(libstf::stream_t stream, uintptr_t vaddr, size_t size) {
    Profiler::open_regions({rdma_read_prefix + "read"});
    auto offset = stream * RDMA_READ_CONFIG_REGS;
    write_register(libstf::ConfigRegister(offset + RDMA_READ_VADDR_ADDR, vaddr));
    write_register(libstf::ConfigRegister(offset + RDMA_READ_SIZE_ADDR, size));
    Profiler::close_regions({rdma_read_prefix + "read"});
}

const libstf::stream_t RDMAReadConfig::num_streams() const { return num_streams_; }

} // namespace oasis
