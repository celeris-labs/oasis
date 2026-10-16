#include "oasis/oasis_context.hpp"

#include <algorithm>
#include <cstdio>
#include <cstdlib>

#include "oasis/configuration.hpp"
#include "parcore/configuration.hpp"

#include <libstf/logging.hpp>
#include <libstf/profiling.hpp>

#include <coyote/cOps.hpp>

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
    OasisContext::ctx().output_buffer_manager()->handle_fpga_interrupt(value);
}

static libstf::stream_mask_t computeManagedStreams(libstf::GlobalConfig &global_config) {
    // Decoder streams are managed. When HTTP (or RDMA) is wired in, the extra MemConfig stream
    // past the decoders is the bypass stream and is unmanaged (transfer size known per request).
    auto mem_config = global_config.get_config<libstf::MemConfig>();
    auto cc_config = global_config.get_config<parcore::ColumnChunkDecoderConfig>();
    libstf::stream_mask_t managed = ~libstf::stream_mask_t(0);
    if (mem_config->num_streams() > cc_config->num_decoders()) {
        managed.reset(cc_config->num_decoders());
    }
    return managed;
}


// How many output buffers to keep enqueued per stream.
//
// This was a hardcoded 2 while the scheduler dispatches up to 64 flows, and every flow's sink needs
// a buffer for the decoder to write its results into. Flows past the second had nowhere to put
// their output, so the decoder stalled on its OUTPUT side -- observed directly as
// out_stalled=1632080 against out_starved=150185, with the counters frozen.
//
// It deadlocks rather than throttling. The two buffers are released only when the scan collects
// them, the scan collects its HEAD row group, and if the head's columns are among the flows that
// never got a buffer, nothing is ever released. Everything downstream follows: the decoder stops
// accepting input, the reader stops draining, the rx fifo fills, the advertised window crosses
// rx_engine's 24000-byte floor and the connection dies in go-back-N.
//
// At 8 MiB a buffer, 64 of them is 512 MiB against 32 GiB of huge pages -- the 2 was never a
// memory decision. Clamped to what the bitstream reports it can hold.
static size_t computeObmBuffers(libstf::GlobalConfig &global_config) {
    size_t desired = 64;
    if (const char *e = std::getenv("OASIS_OBM_BUFFERS")) {
        const long v = std::strtol(e, nullptr, 10);
        if (v > 0) {
            desired = static_cast<size_t>(v);
        }
    }
    const size_t hw_max = global_config.get_config<libstf::MemConfig>()->maximum_num_enqueued_buffers();
    if (hw_max > 0 && desired > hw_max) {
        desired = hw_max;
    }
    return desired < 2 ? 2 : desired;
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
                             computeManagedStreams(global_config_),
                             computeObmBuffers(global_config_), obm_buffer_capacity)) {
    // Verify the bitstream loaded on the device is actually an Oasis system.
    if (global_config_.system_id() != OASIS_SYSTEM_ID) {
        std::ostringstream msg;
        msg << "Hardware design on device is not an Oasis system: expected system id 0x" << std::hex
            << OASIS_SYSTEM_ID << " but device reports 0x" << global_config_.system_id();
        throw std::runtime_error(msg.str());
    }

    // BEFORE anything else is mapped: on an HBM-slot bitstream the slot page must be the first
    // buffer this process maps. See setup_http_slots().
    if (isHTTPEnabled()) {
        setup_http_slots();
    }

    // Pre-map huge pages to FPGA TLB
    auto *huge_pool = dynamic_cast<libstf::HugePageMemoryPool *>(memory_pool_.get());
    if (huge_pool) {
        tlb_manager_->ensure_tlb_mapping(huge_pool->initial_address(), huge_pool->total_capacity());
    }

    output_buffer_manager_->flush_buffers();

    scheduler_ = std::make_unique<Scheduler>(*this);
}

void OasisContext::init(std::shared_ptr<libstf::MemoryPool> memory_pool, size_t obm_buffer_capacity,
                        size_t http_config_bytes) {
    if (http_config_bytes != sizeof(HTTPReadConfig)) {
        std::ostringstream msg;
        msg << "liboasis/header mismatch: the caller was compiled with sizeof(HTTPReadConfig) = "
            << http_config_bytes << ", this liboasis has " << sizeof(HTTPReadConfig)
            << ". The caller picked up stale oasis headers (check the include order: an old "
               "$HOME/opt/include/oasis ahead of the new install). Rebuild it against the headers "
               "installed with this library; running on would corrupt the heap.";
        throw std::runtime_error(msg.str());
    }
    std::call_once(init_flag_, [memory_pool = std::move(memory_pool), obm_buffer_capacity]() mutable {
        // Configure and start Caliper before constructing the context: the constructor flushes buffers
        // and starts the scheduler, both of which can fire interrupts whose Profiler regions
        // (handle_fpga_interrupt, enqueue_buffer_for_stream, ...) we want captured. No-ops unless libstf
        // was built with -DLIBSTF_WITH_PROFILING=ON.
        libstf::Profiler::init();
        libstf::Profiler::start();
        instance_ = new OasisContext(std::move(memory_pool), obm_buffer_capacity);
    });
}

void OasisContext::shutdown() {
    delete instance_;
    instance_ = nullptr;
    libstf::Profiler::flush();
}

// CSR revision 3 (handler_slots, ADR-5): give the hardware its connection slots in card memory.
//
// Every TCP segment the board receives is DMA'd by slot_writer into its connection's slot, at
// SLOT_BASE + (conn << SLOT_LOG2), over the CARD stream; the per-decoder readers pull responses back
// out of the same addresses. Those are VIRTUAL addresses, translated by the vFPGA's TLB, so the slot
// array has to be a real mapped buffer of this process -- and several facts about how Coyote maps it
// decide how:
//
//   * It is its OWN 1 GiB huge page (getMem HPF: the shell's pg_l_bits = 30), never a piece of the
//     libstf pool. A CARD-stream access migrates the whole page and flips its TLB entry to card
//     memory; a pool page shared with output buffers would be migrated away under the host.
//   * It is mapped by THIS cThread. The slot DMA descriptors carry pid 0 hardcoded (CARD_PID in
//     slot_dma_shell.sv) and the pid keys the TLB lookup, so the page must be in ctid 0's table --
//     the same assumption OutputWriter has made since build-93. A process that is not ctid 0 is
//     refused rather than allowed to have the board write into another process's memory.
//   * It is mapped FIRST, before the pool, and never freed while the context lives. With EN_MEM the
//     driver allocates a card shadow for every mapped buffer, and its allocator walks a static ring
//     without checking `used`: map/unmap/map can overlap. First-and-forever is the mitigation.
//   * It is OFFLOADED to the card once, here (LOCAL_OFFLOAD). Otherwise the first segment the
//     writer DMAs takes a page fault on the datapath, which stalls the shared TOE receive fifo for
//     milliseconds (ADR-5 risk 7).
//
// Then SLOT_BASE_LO/HI are written, before any arm can be. On a bitstream below revision 3 none of
// this runs and nothing is allocated.
void OasisContext::setup_http_slots() {
    auto http = config<HTTPReadConfig>();
    // CSR revision 6 (handler_toe): the TOE keeps the receive rings itself, in card memory it owns.
    // There is no slot array, so no page is mapped, nothing is offloaded and SLOT_BASE (write ids
    // 42/43, which this bitstream does not have) is never written. slot_mode() is false here as well
    // (revision() reports 2); this branch says so explicitly, validates the GET cap before the first
    // query (toe_get_cap() throws on an unusable LANE_POLICY), and names the datapath in the log.
    if (http->toe_ring()) {
        const auto p = http->policy();
        char line[256];
        std::snprintf(line, sizeof(line),
                      "OasisContext: TOE receive ring bitstream (CSR rev %u, revision-2 register map): "
                      "%u lane(s), GET credit %u per lane, ring 2^%u B per session, GETs capped at %llu B; "
                      "no slot page, no card memory of ours",
                      unsigned(http->raw_revision()), unsigned(p.num_conns), unsigned(p.get_credit),
                      unsigned(p.ring_log2), static_cast<unsigned long long>(http->toe_get_cap()));
        std::fprintf(stderr, "[oasis] %s\n", line);
        libstf::log(libstf::LogLevel::INFO, "%s", line);
        return;
    }
    if (!http->slot_mode()) {
        return;
    }
    const auto policy = http->slot_policy();
    if (!policy.valid() || policy.n_conns == 0) {
        throw std::runtime_error("FPGA reports CSR revision 3 (HBM slots) but its SLOT_POLICY is "
                                 "unusable [" + policy.describe() + "]");
    }

    constexpr uint64_t SLOT_PAGE_BYTES = 1ULL << 30; // shell pg_l_bits, the HPF page size
    const uint64_t     region          = policy.region_bytes();
    if (region > SLOT_PAGE_BYTES) {
        std::ostringstream msg;
        msg << "FPGA slot array is " << region << " bytes (" << policy.describe()
            << "), more than the one 1 GiB huge page this library maps for it";
        throw std::runtime_error(msg.str());
    }
    if (cthread_->getCtid() != 0) {
        std::ostringstream msg;
        msg << "HBM slot bitstream: this process's Coyote thread is ctid " << cthread_->getCtid()
            << ", but the slot DMA descriptors use pid 0 (slot_dma_shell.sv CARD_PID). The board would "
               "look the slot addresses up in another thread's page table. Run one Oasis process "
               "per vFPGA.";
        throw std::runtime_error(msg.str());
    }

    void *page = cthread_->getMem({coyote::CoyoteAllocType::HPF, SLOT_PAGE_BYTES});
    if (page == nullptr) {
        throw std::runtime_error(
            "HBM slot bitstream: could not allocate the 1 GiB huge page for the connection slots. "
            "It comes on top of the libstf pool (LIBSTF_HUGE_PAGES, default 4), so the system needs "
            "one more free 1 GiB page than the pool takes -- check "
            "/sys/kernel/mm/hugepages/hugepages-1048576kB/free_hugepages -- and the driver's card "
            "pool must hold pool + 1 pages (patch 0003).");
    }
    // ONE offload, at the page start, whatever the region. The driver (offload_user_pages) finds the
    // buffer this process mapped at that address -- it keys them by their START address -- and
    // migrates the WHOLE buffer: all 1 GiB of this page, every slot, in one migration and one TLB
    // entry. The length only has to get past cThread::invoke, which THROWS above MAX_TRANSFER_SIZE
    // (128 MiB; the ioctl carries the length as 32 bits), so it is capped. Never offload the page in
    // pieces: an address past the start matches no buffer, and the patch-0004 driver then loops in
    // the kernel forever (build-131, 2026-09-25: soft lockup in offload_user_pages, board rebooted);
    // a patch-0005 driver refuses the call instead and invoke throws.
    const uint64_t offload_len = std::min<uint64_t>(region, coyote::MAX_TRANSFER_SIZE);
    cthread_->invoke(coyote::CoyoteOper::LOCAL_OFFLOAD, coyote::syncSg{page, offload_len});
    http_slot_page_ = page;
    http->set_slot_base(reinterpret_cast<uint64_t>(page));

    // stderr as well as the log sink: the context is built while the extension LOADS, before any
    // statement could have enabled DuckDB's logger, so an INFO line there is never seen -- and which
    // datapath a run used is exactly what a log has to be able to prove afterwards. Once per process.
    char line[256];
    std::snprintf(line, sizeof(line),
                  "OasisContext: HBM slot bitstream (CSR rev %u%s): %u connection slot(s) of %llu KiB "
                  "at %p, offloaded to card memory; GETs capped at %llu KiB",
                  unsigned(policy.revision),
                  http->conn_placement() ? ", host-placed connections"
                  : http->slot_pipelined() ? ", pipelined GETs" : ", one GET per connection",
                  unsigned(policy.n_conns),
                  static_cast<unsigned long long>(policy.slot_bytes() >> 10), page,
                  static_cast<unsigned long long>(policy.max_get_bytes() >> 10));
    std::fprintf(stderr, "[oasis] %s\n", line);
    libstf::log(libstf::LogLevel::INFO, "%s", line);
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

libstf::stream_t OasisContext::httpBypassStream() {
    return config<parcore::ColumnChunkDecoderConfig>()->num_decoders();
}

bool OasisContext::isHTTPEnabled() {
    return global_config_.has_config(HTTP_READ_CONFIG_ID);
}

} // namespace oasis
