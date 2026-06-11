#pragma once

#include <libstf/buffer.hpp>

#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <optional>

namespace oasis {

/**
 * Streaming channel between a worker and the consumer's SplinterResultHandle. As the worker drains
 * the splinter's OutputHandle, it pushes each batch (a libstf::Buffer) into this queue and closes 
 * the channel once the transfer is exhausted. The consumer pops batches off the front, blocking
 * only until the next one arrives -- so it can start working on early batches while the FPGA is
 * still producing later ones.
 */
class SplinterResultChannel {
  public:
    using Batch = std::shared_ptr<libstf::Buffer>;

    // Producer: Append one batch. Ignored once the channel is closed.
    void push_batch(Batch batch) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (closed_) {
                return;
            }
            batches_.push_back(std::move(batch));
        }
        cv_.notify_all();
    }

    // Producer: No more batches will be pushed. First close wins.
    void close() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (closed_) {
                return;
            }
            closed_ = true;
        }
        cv_.notify_all();
    }

    // Consumer: Block until the next batch is available or the stream ends. Returns the batch, or
    // nullopt once the stream closed cleanly with nothing left.
    std::optional<Batch> get_next_batch() {
        std::unique_lock<std::mutex> lock(mutex_);
        cv_.wait(lock, [this] { return !batches_.empty() || closed_; });
        if (!batches_.empty()) {
            Batch batch = std::move(batches_.front());
            batches_.pop_front();
            return batch;
        }
        return std::nullopt;
    }

  private:
    std::mutex              mutex_;
    std::condition_variable cv_;
    std::deque<Batch>       batches_;
    bool                    closed_ = false;
};

/**
 * Handle from Scheduler::submit(). Pull batches incrementally to overlap consumer work with the
 * splinter still draining on its stream: get_next_batch() blocks until the next batch and returns
 * it, or nullopt once the stream is exhausted. Splinters may finish on different streams out of
 * order, so for in-order results pull the handles in submit order.
 */
class SplinterResultHandle {
  public:
    SplinterResultHandle() = default;
    explicit SplinterResultHandle(std::shared_ptr<SplinterResultChannel> channel)
        : channel_(std::move(channel)) {}

    // Block until the next batch is ready and return it; nullopt once the stream is exhausted.
    [[nodiscard]] std::optional<std::shared_ptr<libstf::Buffer>> get_next_batch() {
        return channel_->get_next_batch();
    }

  private:
    std::shared_ptr<SplinterResultChannel> channel_;
};

} // namespace oasis
