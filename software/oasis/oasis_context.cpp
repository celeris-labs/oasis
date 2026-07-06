#include "oasis/oasis_context.hpp"

#include "oasis/configuration.hpp"
#include "parcore/configuration.hpp"

#include <libstf/profiling.hpp>

#include <algorithm>
#include <sstream>
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
    OasisContext::ctx().handle_interrupt(value);
}

OasisContext::OasisContext(std::shared_ptr<libstf::MemoryPool> memory_pool)
    : device_id_(DEFAULT_DEVICE_ID)
    , vfpga_id_(DEFAULT_VFPGA_ID)
    , memory_pool_(std::move(memory_pool))
    , cthread_(std::make_shared<coyote::cThread>(vfpga_id_, getpid(), device_id_, &handle_fpga_interrupt))
    , global_config_(cthread())
    , tlb_manager_(std::make_shared<libstf::TLBManager>(cthread(), memory_pool_))
    , mem_config_(global_config_.get_config<libstf::MemConfig>())
    , rdma_enabled_(false)
    , bypass_stream_(0) {

    // Verify the bitstream loaded on the device is actually an Oasis system.
    if (global_config_.system_id() != OASIS_SYSTEM_ID) {
        std::ostringstream msg;
        msg << "Hardware design on device is not an Oasis system: expected system id 0x" << std::hex
            << OASIS_SYSTEM_ID << " but device reports 0x" << global_config_.system_id();
        throw std::runtime_error(msg.str());
    }

    auto cc_config = config<parcore::ColumnChunkDecoderConfig>();
    // The hardware exposes one MemConfig stream per column-chunk decoder plus an extra bypass
    // stream when RDMA is wired in. If the counts match, RDMA wasn't synthesized into this shell.
    rdma_enabled_ = mem_config_->num_streams() != cc_config->num_decoders();
    // ID of the RDMA bypass stream -- the last MemConfig stream, sitting past the decoders.
    bypass_stream_ = cc_config->num_decoders();

    // TODO: Give each stream a distinct ctid so concurrent reads run on separate RDMA queue pairs.
    auto read_req_config = config<ReadReqConfig>();
    for (libstf::stream_t stream = 0; stream < read_req_config->num_streams(); ++stream) {
        read_req_config->set_pid(stream, 0);
    }

    // Pre-map huge pages to FPGA TLB
    auto *huge_pool = dynamic_cast<libstf::HugePageMemoryPool *>(memory_pool_.get());
    if (huge_pool) {
        tlb_manager_->ensure_tlb_mapping(huge_pool->initial_address(), huge_pool->total_capacity());
    }

    // Clear any stale buffers left enqueued in hardware from a previous run.
    mem_config_->flush_buffers();

    // The bypass manager must exist before the scheduler so any interrupt has somewhere to route.
    bypass_manager_ = std::make_unique<BypassStreamManager>(*this, bypass_stream_,
        ReadReqConfig::MAXIMUM_NUM_ENQUEUED_REQUESTS, mem_config_->maximum_num_enqueued_buffers());
    scheduler_       = std::make_unique<Scheduler>(*this);
}

OasisContext::~OasisContext() {
    scheduler_.reset();
    bypass_manager_.reset();
}

void OasisContext::init(std::shared_ptr<libstf::MemoryPool> memory_pool) {
    std::call_once(init_flag_, [memory_pool = std::move(memory_pool)]() mutable {
        libstf::Profiler::init();
        libstf::Profiler::start();
        instance_ = new OasisContext(std::move(memory_pool));
    });
}

void OasisContext::shutdown() {
    delete instance_;
    instance_ = nullptr;
    libstf::Profiler::flush();
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

Scheduler &OasisContext::scheduler() {
    return *scheduler_;
}

BypassStreamManager &OasisContext::bypass_manager() {
    return *bypass_manager_;
}

void OasisContext::initRDMA(const std::string &server, uint16_t port) {
    // Minimal stub region for initRDMA -- the hardware writes straight into the caller's buffers, so
    // no host-side staging buffer is used, but Coyote still requires a region to set up the QP.
    constexpr uint32_t RDMA_INIT_STUB_SIZE = 4096;

    void *staging_buffer = nullptr;
    if (!memory_pool_->allocate(RDMA_INIT_STUB_SIZE, &staging_buffer).ok()) {
        std::ostringstream msg;
        msg << "Failed to allocate RDMA staging buffer of " << RDMA_INIT_STUB_SIZE << " bytes";
        throw std::runtime_error(msg.str());
    }
    if (!cthread_->initRDMA(RDMA_INIT_STUB_SIZE, port, server.c_str(), staging_buffer)) {
        std::ostringstream msg;
        msg << "Coyote initRDMA failed for server " << server << ":" << port;
        throw std::runtime_error(msg.str());
    }

    // The remote region's base vaddr is only known once the queue pair has been exchanged.
    config<ReadReqConfig>()->set_base_vaddr(
        reinterpret_cast<uintptr_t>(cthread_->getQpair()->remote.vaddr));
}

std::shared_ptr<libstf::Buffer> OasisContext::allocate_output_buffer(size_t size) {
    size_t capacity = ((std::max<size_t>(size, 1) + libstf::BYTES_PER_FPGA_TRANSFER - 1) /
                       libstf::BYTES_PER_FPGA_TRANSFER) *
                      libstf::BYTES_PER_FPGA_TRANSFER;
    void          *ptr;
    libstf::Status status = memory_pool_->allocate(capacity, &ptr);
    if (!status.ok()) {
        std::ostringstream msg;
        msg << "OasisContext::allocate_output_buffer could not allocate a " << capacity
            << " byte output buffer: " << status.message();
        throw std::runtime_error(msg.str());
    }
    return libstf::make_buffer(memory_pool_, ptr, size, capacity);
}

void OasisContext::enqueue_output_buffer(libstf::stream_t stream, libstf::Buffer &buffer) {
    tlb_manager_->ensure_tlb_mapping(reinterpret_cast<std::byte *>(buffer.ptr), buffer.capacity);
    mem_config_->enqueue_buffer(stream, buffer);
}

void OasisContext::handle_interrupt(int value) {
    libstf::Profiler::open_regions({"oasis::OasisContext::handle_interrupt"});
    // The FPGA encodes the interrupt as: [stream_id | bytes_written | last], from the low bit up.
    const libstf::stream_t stream_id =
        value & ((1u << libstf::FPGA_INTERRUPT_STREAM_ID_BITS) - 1);
    const uint32_t bytes_written =
        (value >> libstf::FPGA_INTERRUPT_STREAM_ID_BITS) &
        ((1u << libstf::FPGA_INTERRUPT_TRANSFER_SIZE_BITS) - 1);
    const bool last = ((value >> (libstf::FPGA_INTERRUPT_STREAM_ID_BITS +
                                  libstf::FPGA_INTERRUPT_TRANSFER_SIZE_BITS)) &
                       1) != 0;

    if (rdma_enabled_ && stream_id == bypass_stream_) {
        bypass_manager_->handle_completion(bytes_written, last);
    } else {
        scheduler_->handle_completion(stream_id, bytes_written, last);
    }
    libstf::Profiler::close_regions({"oasis::OasisContext::handle_interrupt"});
}

} // namespace oasis
