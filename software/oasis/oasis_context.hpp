#pragma once

#include "coyote/cThread.hpp"
#include "libstf/configuration.hpp"
#include "libstf/memory_pool.hpp"
#include "libstf/output_buffer_manager.hpp"
#include "libstf/tlb_manager.hpp"
#include "oasis/scheduler.hpp"

#include <memory>
#include <mutex>

namespace oasis {

class OasisContext {
public:
    OasisContext(const OasisContext &) = delete;
    OasisContext &operator=(const OasisContext &) = delete;
    OasisContext(OasisContext &&) = delete;
    OasisContext &operator=(OasisContext &&) = delete;

    /// `http_config_bytes` is NOT for callers to pass. Its default is evaluated at the CALL SITE,
    /// i.e. with the headers the caller was compiled against, and init() compares it to the
    /// library's own sizeof(HTTPReadConfig). GlobalConfig::get_config<T>() is a header template, so
    /// a caller compiled against stale oasis headers (a leftover $HOME/opt/include/oasis ahead of
    /// the new ones) instantiates make_shared<HTTPReadConfig> with the OLD size, the linker may pick
    /// that instantiation for the library too, and every member added since writes past the
    /// allocation. That corrupted the heap on the first build-124 bring-up; this turns it into a
    /// clear error. (The extra parameter also changes the symbol, so a caller built against the
    /// old signature fails to link instead of running.)
    static void init(std::shared_ptr<libstf::MemoryPool> memory_pool, size_t obm_buffer_capacity,
                     size_t http_config_bytes = sizeof(HTTPReadConfig));
    static void shutdown();
    static OasisContext &ctx();

    std::shared_ptr<libstf::MemoryPool> memory_pool();
    std::shared_ptr<coyote::cThread> cthread();
    std::shared_ptr<libstf::TLBManager> tlb_manager();
    std::shared_ptr<libstf::OutputBufferManager> output_buffer_manager();

    Scheduler &scheduler();

    template <typename T>
    std::shared_ptr<T> config() {
        return global_config_.get_config<T>();
    }

    bool isRDMAEnabled();
    bool isHTTPEnabled();

    libstf::stream_t rdmaBypassStream();
    libstf::stream_t httpBypassStream();

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
    std::unique_ptr<Scheduler> scheduler_;

    void setup_http();

    OasisContext(std::shared_ptr<libstf::MemoryPool> memory_pool, size_t obm_buffer_capacity);
    ~OasisContext() = default;
};

} // namespace oasis
