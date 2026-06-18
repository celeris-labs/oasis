#pragma once

#include "coyote/cThread.hpp"
#include "libstf/buffer.hpp"
#include "libstf/configuration.hpp"
#include "libstf/memory_pool.hpp"
#include "libstf/tlb_manager.hpp"
#include "oasis/bypass_receiver.hpp"
#include "oasis/scheduler.hpp"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>

namespace oasis {

class OasisContext {
public:
    OasisContext(const OasisContext &) = delete;
    OasisContext &operator=(const OasisContext &) = delete;
    OasisContext(OasisContext &&) = delete;
    OasisContext &operator=(OasisContext &&) = delete;

    static void init(std::shared_ptr<libstf::MemoryPool> memory_pool);
    static void shutdown();
    static OasisContext &ctx();

    std::shared_ptr<libstf::MemoryPool> memory_pool();
    std::shared_ptr<coyote::cThread> cthread();
    std::shared_ptr<libstf::TLBManager> tlb_manager();

    Scheduler &scheduler();
    BypassStreamReceiver &bypass_receiver();

    /**
     * Allocates an output buffer the hardware decoder can write into. `size` is the exact decoded
     * size the buffer reports. Its capacity is rounded up to the next multiple of
     * BYTES_PER_FPGA_TRANSFER (the hardware enqueue path requires a non-zero multiple). Throws if
     * the allocation fails.
     */
    std::shared_ptr<libstf::Buffer> allocate_output_buffer(size_t size);

    /**
     * Maps the buffer into the hardware TLB and enqueues it to the output writer for `stream`.
     */
    void enqueue_output_buffer(libstf::stream_t stream, libstf::Buffer &buffer);

    /**
     * Routes a hardware interrupt: Bypass-stream interrupts go to the BypassStreamReceiver, 
     * everything else goes straight to the scheduler.
     */
    void handle_interrupt(int value);

    template <typename T>
    std::shared_ptr<T> config() {
        return global_config_.get_config<T>();
    }

    bool isRDMAEnabled() const { return rdma_enabled_; }

    libstf::stream_t rdmaBypassStream() const { return bypass_stream_; }

    /**
     * Establishes the RDMA queue pair with the remote server and configures the read-request module
     * with the remote region's base vaddr (only known once the queue pair has been exchanged).
     */
    void initRDMA(const std::string &server, uint16_t port);

    int device_id() const { return device_id_; }
    int vfpga_id() const { return vfpga_id_; }

private:
    static OasisContext *instance_;
    static std::once_flag init_flag_;

    int device_id_;
    int vfpga_id_;

    std::shared_ptr<libstf::MemoryPool> memory_pool_;
    std::shared_ptr<coyote::cThread> cthread_;
    libstf::GlobalConfig global_config_;
    std::shared_ptr<libstf::TLBManager> tlb_manager_;
    std::shared_ptr<libstf::MemConfig> mem_config_;

    bool             rdma_enabled_;
    libstf::stream_t bypass_stream_;

    std::unique_ptr<BypassStreamReceiver> bypass_receiver_;
    std::unique_ptr<Scheduler> scheduler_;

    explicit OasisContext(std::shared_ptr<libstf::MemoryPool> memory_pool);
    ~OasisContext();
};

} // namespace oasis
