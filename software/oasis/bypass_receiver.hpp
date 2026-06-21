#pragma once

#include <libstf/buffer.hpp>
#include <libstf/common.hpp>
#include <libstf/memory_pool.hpp>

#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <queue>

namespace oasis {

class OasisContext;

/**
 * Receives output for the RDMA bypass stream. This stream's transfer size is known up front by the
 * caller.
 */
class BypassStreamReceiver {
  public:
    class Handle {
        friend class BypassStreamReceiver;

      public:
        // Blocks until the next buffer of this transfer is written, or returns nullptr once the
        // transfer is complete and fully drained.
        std::shared_ptr<libstf::Buffer> next();

      private:
        std::mutex                           mutex_;
        std::condition_variable              cv_;
        std::queue<std::shared_ptr<libstf::Buffer>> ready_;
        size_t                               outstanding_; // Buffers still expected from the FPGA

        explicit Handle(size_t outstanding) : outstanding_(outstanding) {}
    };

    BypassStreamReceiver(OasisContext &ctx, libstf::stream_t stream, size_t max_num_enqueued_buffers);

    // Allocates exact-size buffer(s) totalling `size` bytes (split at MAXIMUM_OUTPUT_WRITER_BUFFER_SIZE),
    // enqueues each to the hardware, and returns a handle to drain them. Blocks until enough of the
    // hardware's buffer slots are free to hold this transfer's chunks. Thread-safe.
    std::shared_ptr<Handle> acquire(size_t size);

    // Invoked from the interrupt switch for an interrupt on the bypass stream. Pops the front
    // enqueued buffer and hands it to the owning read's handle.
    void handle_completion(uint32_t bytes_written, bool last);

  private:
    OasisContext         &ctx_;
    const libstf::stream_t stream_;
    const size_t           max_num_enqueued_buffers_; // Number of hardware output-buffer slots.

    // FIFO of enqueued buffers and the handle each belongs to, in enqueue (== interrupt) order.
    std::mutex                           mutex_;
    std::condition_variable              slots_cv_;          // Signalled when slots are freed.
    size_t                               enqueued_count_{0}; // Buffers currently enqueued to the FPGA.
    std::queue<std::shared_ptr<libstf::Buffer>> enqueued_buffers_;
    std::queue<std::shared_ptr<Handle>>  enqueued_handles_;
};

} // namespace oasis
