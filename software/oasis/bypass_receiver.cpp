#include "oasis/bypass_receiver.hpp"

#include "oasis/oasis_context.hpp"

#include <algorithm>
#include <cassert>
#include <vector>

namespace oasis {

std::shared_ptr<libstf::Buffer> BypassStreamReceiver::Handle::next() {
    std::unique_lock<std::mutex> lock(mutex_);
    cv_.wait(lock, [this] { return !ready_.empty() || outstanding_ == 0; });
    if (ready_.empty()) {
        return nullptr; // Transfer complete and fully drained.
    }
    auto buffer = std::move(ready_.front());
    ready_.pop();
    return buffer;
}

BypassStreamReceiver::BypassStreamReceiver(OasisContext &ctx, libstf::stream_t stream,
                                           size_t max_num_enqueued_buffers)
    : ctx_(ctx), stream_(stream), max_num_enqueued_buffers_(max_num_enqueued_buffers) {
    assert(max_num_enqueued_buffers_ > 0);
}

std::shared_ptr<BypassStreamReceiver::Handle> BypassStreamReceiver::acquire(size_t size) {
    assert(size > 0);

    // Split larger transfers across multiple buffers, each enqueued separately.
    std::vector<std::shared_ptr<libstf::Buffer>> buffers;
    size_t                                       remaining = size;
    while (remaining > 0) {
        size_t chunk = std::min<size_t>(remaining, libstf::MAXIMUM_OUTPUT_WRITER_BUFFER_SIZE);
        buffers.push_back(ctx_.allocate_output_buffer(chunk));
        remaining -= chunk;
    }

    std::shared_ptr<Handle> handle(new Handle(buffers.size()));

    // Record each buffer/handle in the FIFO before enqueueing so an interrupt always finds its
    // match, then fire the enqueue CSR for it. The hardware only has `max_num_enqueued_buffers_`
    // output-buffer slots, so block before each enqueue until a slot is free.
    {
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

void BypassStreamReceiver::handle_completion(uint32_t bytes_written, bool /*last*/) {
    std::shared_ptr<libstf::Buffer> buffer;
    std::shared_ptr<Handle>         handle;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        assert(!enqueued_buffers_.empty() && !enqueued_handles_.empty());
        buffer = std::move(enqueued_buffers_.front());
        handle = std::move(enqueued_handles_.front());
        enqueued_buffers_.pop();
        enqueued_handles_.pop();
        assert(enqueued_count_ > 0);
        --enqueued_count_;
    }
    // A hardware slot just freed up; wake any acquire() blocked waiting to enqueue.
    slots_cv_.notify_one();

    assert(bytes_written <= buffer->capacity);
    buffer->size = bytes_written;

    {
        std::lock_guard<std::mutex> lock(handle->mutex_);
        if (bytes_written > 0) {
            handle->ready_.push(std::move(buffer));
        }
        assert(handle->outstanding_ > 0);
        --handle->outstanding_;
    }
    handle->cv_.notify_all();
}

} // namespace oasis
