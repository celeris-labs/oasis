#pragma once

#include "coyote/cThread.hpp"
#include "libstf/configuration.hpp"
#include "libstf/memory_pool.hpp"
#include "libstf/output_buffer_manager.hpp"
#include "libstf/tlb_manager.hpp"

#include <memory>
#include <mutex>

namespace oasis {

class OasisContext {
public:
    OasisContext(const OasisContext &) = delete;
    OasisContext &operator=(const OasisContext &) = delete;
    OasisContext(OasisContext &&) = delete;
    OasisContext &operator=(OasisContext &&) = delete;

    static void init(std::shared_ptr<libstf::MemoryPool> memory_pool, size_t obm_buffer_capacity);
    static void shutdown();
    static OasisContext &ctx();

    std::shared_ptr<libstf::MemoryPool> memory_pool();
    std::shared_ptr<coyote::cThread> cthread();
    std::shared_ptr<libstf::TLBManager> tlb_manager();
    std::shared_ptr<libstf::OutputBufferManager> output_buffer_manager();

    template <typename T>
    std::shared_ptr<T> config() {
        return global_config_.get_config<T>();
    }

    bool isRDMAEnabled();

    /**
     * Id of the RDMA bypass stream -- the last MemConfig stream, sitting past the decoders. Only 
     * valid when isRDMAEnabled() is true.
     */
    libstf::stream_t rdmaBypassStream();

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
    std::shared_ptr<libstf::OutputBufferManager> output_buffer_manager_;

    OasisContext(std::shared_ptr<libstf::MemoryPool> memory_pool, size_t obm_buffer_capacity);
    ~OasisContext() = default;
};

} // namespace oasis
