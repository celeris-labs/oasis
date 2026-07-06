#pragma once

#include <libstf/buffer.hpp>
#include <libstf/common.hpp>

#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <queue>

namespace oasis {

class OasisContext;

/**
 * Owns the RDMA bypass stream. Callers submit an RDMA read (remote offset + size) and get back a
 * handle to drain the result.
 *
 * The bypass stream is a single in-order channel: its output writer fills enqueued buffers in order
 * and the RC queue pair returns read responses in request order, so completions arrive strictly in
 * enqueue order (handle_completion relies on this to match interrupts to buffers by FIFO position).
 * A read is therefore never reordered ahead of an earlier one -- a large read can delay the
 * completion of reads issued after it. We accept that head-of-line behaviour here. Two independent
 * hardware FIFOs are throttled so nothing is silently dropped: no more read requests are in flight
 * than the read-request config FIFO can hold (`max_num_enqueued_requests_`), and no more output
 * buffers are enqueued than the output writer's queue can hold (`max_num_enqueued_buffers_`).
 */
class BypassStreamManager {
  public:
    class Handle {
        friend class BypassStreamManager;

      public:
        // Blocks until the next buffer of this transfer is written, or returns nullptr once the
        // transfer is complete and fully drained.
        std::shared_ptr<libstf::Buffer> next();

      private:
        std::mutex                                  mutex_;
        std::condition_variable                     cv_;
        std::queue<std::shared_ptr<libstf::Buffer>> ready_;
        size_t                                      outstanding_; // Buffers still expected from the FPGA

        explicit Handle(size_t outstanding) : outstanding_(outstanding) {}
    };

    BypassStreamManager(OasisContext &ctx, libstf::stream_t stream, size_t max_num_enqueued_requests,
                        size_t max_num_enqueued_buffers);

    BypassStreamManager(const BypassStreamManager &)            = delete;
    BypassStreamManager &operator=(const BypassStreamManager &) = delete;

    // Issues an RDMA read of `size` bytes starting at `remote_offset` (relative to the remote
    // region's base vaddr) and returns a handle to drain it. Blocks while the hardware read-request
    // FIFO is full, then fires the read and enqueues its output buffers. Thread-safe.
    std::shared_ptr<Handle> submit(uintptr_t remote_offset, size_t size);

    // Invoked from the interrupt switch for an interrupt on the bypass stream. Pops the front
    // enqueued buffer and hands it to the owning read's handle.
    void handle_completion(uint32_t bytes_written, bool last);

  private:
    OasisContext          &ctx_;
    const libstf::stream_t stream_;
    const size_t           max_num_enqueued_requests_;
    const size_t           max_num_enqueued_buffers_;

    // Serializes the issue of a read (fire request CSR + enqueue its output buffers) across callers so
    // the hardware read order -- and the completion FIFO order behind it -- stays consistent. Held for
    // the whole ordered section, so it is not released across the per-buffer slot wait.
    std::mutex enqueue_mutex_;

    // Guards the counters and completion FIFO, shared with handle_completion on the interrupt thread.
    // Released across condition-variable waits so completions can make progress.
    std::mutex              mutex_;
    std::condition_variable reads_cv_; // Signalled when a read slot is freed.
    std::condition_variable slots_cv_; // Signalled when an output-buffer slot is freed.
    size_t                  enqueued_count_{0};    // Output buffers currently enqueued to the FPGA.
    size_t                  outstanding_reads_{0}; // Reads issued but not yet fully drained.

    // FIFO of enqueued buffers and the handle each belongs to, in enqueue (== interrupt) order.
    std::queue<std::shared_ptr<libstf::Buffer>> enqueued_buffers_;
    std::queue<std::shared_ptr<Handle>>         enqueued_handles_;
};

} // namespace oasis
