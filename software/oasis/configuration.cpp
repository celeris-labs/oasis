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

static bool is_supported_filter_type(libstf::type_t type) {
    return type == libstf::type_t::INT32_T || type == libstf::type_t::INT64_T ||
           type == libstf::type_t::FLOAT_T || type == libstf::type_t::DOUBLE_T;
}

PipelineConfig::PipelineConfig(std::shared_ptr<coyote::cThread> cthread,
                               uint32_t addr_offset, uint32_t num_regs)
    : Config(cthread, addr_offset, num_regs) {}

void PipelineConfig::set_filter_enabled(bool enabled) {
    write_register(libstf::ConfigRegister(0, enabled));
}

FilterConfig::FilterConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset,
                           uint32_t num_regs)
    : Config(cthread, addr_offset, num_regs), num_streams_(read_register(1).value()) {
    if (num_streams_ == 0 || num_streams_ > MAX_STREAMS) {
        throw std::runtime_error("Unsupported number of hardware filter streams");
    }
}

void FilterConfig::configure(const std::vector<Stream> &streams,
                             const std::vector<Predicate> &predicates,
                             const std::vector<AdditionalRhs> &additional_rhs,
                             FilterMode mode) {
    using LayerRhs = std::array<std::array<uint64_t, NUM_RHS>, NUM_LAYERS>;
    using LayerOps = std::array<FilterComparison, NUM_LAYERS>;

    std::array<LayerRhs, MAX_STREAMS> rhs_values = {};
    std::array<LayerOps, MAX_STREAMS> operators = {};
    std::array<libstf::type_t, MAX_STREAMS> stream_types = {};
    std::array<bool, MAX_STREAMS> stream_enabled = {};
    std::array<std::array<uint64_t, NUM_ADDITIONAL_RHS>, NUM_LAYERS> additional_rhs_values = {};
    std::array<uint8_t, NUM_LAYERS> additional_rhs_masks = {};
    std::array<bool, NUM_LAYERS> layer_has_predicate = {};
    auto write = [&](uint32_t address, uint64_t value) {
        write_register(libstf::ConfigRegister(address, value));
    };

    stream_types.fill(libstf::type_t::INT64_T);

    for (const auto &predicate : predicates) {
        if (predicate.stream >= num_streams_ || predicate.layer >= NUM_LAYERS) {
            throw std::out_of_range("Filter predicate index is out of range");
        }
        layer_has_predicate[predicate.layer] = true;
    }

    for (size_t stream = 0; stream < num_streams_; stream++) {
        for (size_t layer = 0; layer < NUM_LAYERS; layer++) {
            operators[stream][layer] = layer_has_predicate[layer]
                                           ? FilterComparison::ALWAYS_TRUE
                                           : FilterComparison::ALWAYS_FALSE;
        }
    }

    for (const auto &stream : streams) {
        if (stream.stream >= num_streams_) {
            throw std::out_of_range("Filter stream index is out of range");
        }
        if (!is_supported_filter_type(stream.type)) {
            throw std::invalid_argument("Unsupported filter stream type");
        }
        stream_types[stream.stream] = stream.type;
        stream_enabled[stream.stream] = stream.enabled;
    }

    for (const auto &predicate : predicates) {
        operators[predicate.stream][predicate.layer] = predicate.comparison;
        rhs_values[predicate.stream][predicate.layer] = predicate.rhs;
    }

    for (const auto &additional : additional_rhs) {
        if (additional.layer >= NUM_LAYERS) {
            throw std::out_of_range("Filter additional RHS layer is out of range");
        }
        if (additional.mask >= (uint8_t {1} << NUM_ADDITIONAL_RHS)) {
            throw std::out_of_range("Filter additional RHS mask is out of range");
        }
        additional_rhs_values[additional.layer] = additional.rhs;
        additional_rhs_masks[additional.layer] = additional.mask;
    }

    for (size_t stream = 0; stream < num_streams_; stream++) {
        for (size_t layer = 0; layer < NUM_LAYERS; layer++) {
            for (size_t rhs_index = 0; rhs_index < NUM_RHS; rhs_index++) {
                write(FILTER_RHS_ADDR, rhs_values[stream][layer][rhs_index]);
            }
        }
    }

    for (size_t layer = 0; layer < NUM_LAYERS; layer++) {
        uint64_t operator_word = 0;
        for (size_t stream = 0; stream < num_streams_; stream++) {
            operator_word |= static_cast<uint64_t>(operators[stream][layer]) << (stream * 8);
        }
        write(FILTER_OPERATOR_ADDR, operator_word);
    }

    for (const auto &layer_rhs : additional_rhs_values) {
        for (const auto value : layer_rhs) {
            write(FILTER_ADDITIONAL_RHS_ADDR, value);
        }
    }

    uint64_t additional_rhs_mask_word = 0;
    for (size_t layer = 0; layer < NUM_LAYERS; layer++) {
        additional_rhs_mask_word |= static_cast<uint64_t>(additional_rhs_masks[layer])
                                    << (layer * 8);
    }
    write(FILTER_ADDITIONAL_RHS_MASK_ADDR, additional_rhs_mask_word);

    const size_t stream_type_lsb = num_streams_;
    const size_t mode_lsb = stream_type_lsb + num_streams_ * 3;
    const size_t valid_bit = mode_lsb + 2;

    uint64_t control_word = 0;
    for (size_t stream = 0; stream < num_streams_; stream++) {
        control_word |= static_cast<uint64_t>(stream_enabled[stream]) << stream;
        control_word |= (static_cast<uint64_t>(stream_types[stream]) & 0x7)
                        << (stream_type_lsb + stream * 3);
    }
    control_word |= static_cast<uint64_t>(mode) << mode_lsb;
    control_word |= uint64_t {1} << valid_bit;

    write(FILTER_CONTROL_ADDR, control_word); // Commits the payload.
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
