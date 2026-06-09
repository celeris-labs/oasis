#include "oasis/oasis_context.hpp"

#include "parcore/configuration.hpp"

#include <stdexcept>
#include <unistd.h>

namespace oasis {

constexpr auto DEFAULT_DEVICE_ID = 0;
constexpr auto DEFAULT_VFPGA_ID  = 0;

OasisContext *OasisContext::instance_ = nullptr;
std::once_flag OasisContext::init_flag_;

static void handle_fpga_interrupt(int value) {
    // The nullptr is a bit ugly but this function is private and can only be
    // called from the cthread, which means the private constructor was executed
    // and the context has been initialized!
    //
    // Note that we needed to implement the "handle_fpga_interrupt" function as a
    // static function due to a limitation in Coyote. The reason is that we need
    // to register a function pointer with Coyote to call when an interrupt is
    // triggered on the FPGA. However, Coyote only accepts a raw function pointer.
    // Raw function points can only be created in C++ from static methods. See
    // https://isocpp.org/wiki/faq/pointers-to-members#fnptr-vs-memfnptr-types
    // In particular, they cannot be created from what's called a
    // pointer-to-member-function:
    // > NOTE: do not attempt to "cast" a pointer-to-member-function into a
    // > pointer-to-function; the result is undefined and probably disastrous.
    //   (From above link)
    OasisContext::ctx().output_buffer_manager()->handle_fpga_interrupt(value);
}

static libstf::stream_mask_t computeManagedStreams(libstf::GlobalConfig &global_config) {
    // Decoder streams are managed (the OBM pre-allocates / tops up buffers for them). When RDMA is
    // wired in, there is one extra MemConfig stream past the decoders -- the bypass stream used by
    // RDMAFileSystem -- and that one is unmanaged because its transfer size is known per request.
    // Note: The instance is not ready at this point so we cannot call isRDMAEnabled(...)
    auto mem_config = global_config.get_config<libstf::MemConfig>();
    auto cc_config = global_config.get_config<parcore::ColumnChunkDecoderConfig>();
    libstf::stream_mask_t managed = ~libstf::stream_mask_t(0);
    if (mem_config->num_streams() > cc_config->num_decoders()) {
        managed.reset(cc_config->num_decoders());
    }
    return managed;
}

OasisContext::OasisContext(std::shared_ptr<libstf::MemoryPool> memory_pool,
                           size_t obm_buffer_capacity)
    : device_id_(DEFAULT_DEVICE_ID)
    , vfpga_id_(DEFAULT_VFPGA_ID)
    , memory_pool_(std::move(memory_pool))
    , cthread_(std::make_shared<coyote::cThread>(vfpga_id_, getpid(), device_id_, &handle_fpga_interrupt))
    , global_config_(cthread())
    , tlb_manager_(std::make_shared<libstf::TLBManager>(cthread(), memory_pool_))
    , output_buffer_manager_(std::make_shared<libstf::OutputBufferManager>(cthread(),
                             global_config_.get_config<libstf::MemConfig>(),
                             memory_pool_, tlb_manager_,
                             computeManagedStreams(global_config_), 2, obm_buffer_capacity)) {
    // Pre-map huge pages to FPGA TLB
    auto *huge_pool = dynamic_cast<libstf::HugePageMemoryPool *>(memory_pool_.get());
    if (huge_pool) {
        tlb_manager_->ensure_tlb_mapping(huge_pool->initial_address(), huge_pool->total_capacity());
    }

    output_buffer_manager_->flush_buffers();

    scheduler_ = std::make_unique<Scheduler>(*this);
}

void OasisContext::init(std::shared_ptr<libstf::MemoryPool> memory_pool, size_t obm_buffer_capacity) {
    std::call_once(init_flag_, [memory_pool = std::move(memory_pool), obm_buffer_capacity]() mutable {
        instance_ = new OasisContext(std::move(memory_pool), obm_buffer_capacity);
    });
}

void OasisContext::shutdown() {
    delete instance_;
    instance_ = nullptr;
}

OasisContext &OasisContext::ctx() {
    if (!instance_) {
        throw std::runtime_error("OasisContext not initialized. Call init() first.");
    }
    return *instance_;
}

std::shared_ptr<libstf::MemoryPool> OasisContext::memory_pool() {
    return memory_pool_;
}

std::shared_ptr<coyote::cThread> OasisContext::cthread() {
    return cthread_;
}

std::shared_ptr<libstf::TLBManager> OasisContext::tlb_manager() {
    return tlb_manager_;
}

std::shared_ptr<libstf::OutputBufferManager> OasisContext::output_buffer_manager() {
    return output_buffer_manager_;
}

Scheduler &OasisContext::scheduler() {
    return *scheduler_;
}

bool OasisContext::isRDMAEnabled() {
    // The hardware exposes one MemConfig stream per column-chunk decoder plus an extra bypass
    // stream when RDMA is wired in. If the counts match, RDMA wasn't synthesized into this shell.
    auto mem_config = config<libstf::MemConfig>();
    auto cc_config = config<parcore::ColumnChunkDecoderConfig>();
    return !(mem_config->num_streams() == cc_config->num_decoders());
}

libstf::stream_t OasisContext::rdmaBypassStream() {
    return config<parcore::ColumnChunkDecoderConfig>()->num_decoders();
}

} // namespace oasis
