#include "oasis/bypass_stream_manager.hpp"

#include "oasis/configuration.hpp"
#include "oasis/oasis_context.hpp"

#include <algorithm>
#include <cassert>
#include <limits>
#include <stdexcept>
#include <vector>

namespace oasis {

std::shared_ptr<libstf::Buffer> BypassStreamManager::Handle::next() {
    std::unique_lock<std::mutex> lock(mutex_);
    cv_.wait(lock, [this] { return !ready_.empty() || outstanding_ == 0; });
    if (ready_.empty()) {
        return nullptr; // Transfer complete and fully drained.
    }
    auto buffer = std::move(ready_.front());
    ready_.pop();
    return buffer;
}

BypassStreamManager::BypassStreamManager(OasisContext &ctx, libstf::stream_t stream,
                                         size_t max_num_enqueued_requests,
                                         size_t max_num_enqueued_buffers)
    : ctx_(ctx), stream_(stream), max_num_enqueued_requests_(max_num_enqueued_requests),
      max_num_enqueued_buffers_(max_num_enqueued_buffers) {
    assert(max_num_enqueued_requests_ > 0);
    assert(max_num_enqueued_buffers_ > 0);
}

std::shared_ptr<BypassStreamManager::Handle> BypassStreamManager::submit(uintptr_t remote_offset,
                                                                         size_t size) {
    assert(size > 0);
    if (size > std::numeric_limits<uint32_t>::max()) {
        throw std::runtime_error("RDMA read size exceeds 32-bit limit");
    }

    // Split larger transfers across multiple buffers and allocate them up front so the handle knows
    // exactly how many completions to expect.
    std::vector<std::shared_ptr<libstf::Buffer>> buffers;
    size_t                                       remaining = size;
    while (remaining > 0) {
        size_t chunk = std::min<size_t>(remaining, libstf::MAXIMUM_OUTPUT_WRITER_BUFFER_SIZE);
        buffers.push_back(ctx_.allocate_output_buffer(chunk));
        remaining -= chunk;
    }
    std::shared_ptr<Handle> handle(new Handle(buffers.size()));

    // Read-request FIFO gate: block until fewer than the read-request config FIFO depth of reads are
    // in flight, then reserve a slot. The slot is released when this read's last buffer completes.
    {
        std::unique_lock<std::mutex> lock(mutex_);
        reads_cv_.wait(lock, [this] { return outstanding_reads_ < max_num_enqueued_requests_; });
        ++outstanding_reads_;
    }

    // Ordered issue: fire the read request, then enqueue its output buffers in order. enqueue_mutex_
    // keeps concurrent submits from interleaving, so the completion FIFO order matches the hardware
    // read order. Record each buffer in the FIFO before its enqueue CSR so an interrupt always finds
    // its match; block before each enqueue until a hardware output-buffer slot is free.
    {
        std::lock_guard<std::mutex> order(enqueue_mutex_);
        ctx_.config<ReadReqConfig>()->enqueue_read(stream_, remote_offset, size);

        std::unique_lock<std::mutex> lock(mutex_);
        for (const auto &buffer : buffers) {
            slots_cv_.wait(lock, [this] { return enqueued_count_ < max_num_enqueued_buffers_; });
            enqueued_buffers_.push(buffer);
            enqueued_handles_.push(handle);
            ++enqueued_count_;
            ctx_.enqueue_output_buffer(stream_, *buffer);
        }
    }

    return handle;
}

void BypassStreamManager::handle_completion(uint32_t bytes_written, bool /*last*/) {
    std::shared_ptr<libstf::Buffer> buffer;
    std::shared_ptr<Handle>         handle;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        assert(!enqueued_buffers_.empty() && !enqueued_handles_.empty() &&
               "Completion interrupt with no pending bypass buffer.");
        buffer = std::move(enqueued_buffers_.front());
        handle = std::move(enqueued_handles_.front());
        enqueued_buffers_.pop();
        enqueued_handles_.pop();
        assert(enqueued_count_ > 0);
        --enqueued_count_;
    }
    // A hardware output-buffer slot just freed up; wake any submit() blocked waiting to enqueue.
    slots_cv_.notify_one();

    assert(bytes_written <= buffer->capacity);
    buffer->size = bytes_written;

    bool read_complete = false;
    {
        std::lock_guard<std::mutex> lock(handle->mutex_);
        if (bytes_written > 0) {
            handle->ready_.push(std::move(buffer));
        }
        assert(handle->outstanding_ > 0);
        read_complete = (--handle->outstanding_ == 0);
    }
    handle->cv_.notify_all();

    // This read's last buffer landed, so the hardware read-request FIFO has retired its request and a
    // read slot is free. Release it and wake a submit() waiting on the read gate. mutex_ and
    // handle->mutex_ are never held together, so this stays free of nested-lock ordering.
    if (read_complete) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            assert(outstanding_reads_ > 0);
            --outstanding_reads_;
        }
        reads_cv_.notify_one();
    }
}

} // namespace oasis
