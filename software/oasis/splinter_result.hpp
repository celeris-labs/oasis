#pragma once

#include <libstf/buffer.hpp>

#include <condition_variable>
#include <cstddef>
#include <deque>
#include <memory>
#include <mutex>
#include <optional>
#include <utility>

namespace oasis {

/**
 * Streaming channel between a worker and the consumer's SplinterResultHandle. A single splinter 
 * owns one channel. Its flows drain on different hardware streams and push their output buffers 
 * here as the hardware finishes each one. The channel closes exactly once, when the last flow 
 * finishes -- so the splinter yields one completion.
 *
 * Buffers arrive in completion order across hardware streams, NOT in submission order, so each 
 * batch carries a `tag` (the sink's tag) identifying which output it is. The consumer may then 
 * reorder batches by tag if needed. It can start working on early batches while the hardware is 
 * still producing later ones.
 */
class SplinterResultChannel {
  public:
    // One drained output buffer, tagged with its sink's tag (e.g. projected-column index).
    struct Batch {
        size_t                          tag = 0;
        std::shared_ptr<libstf::Buffer> buffer;
    };

    // Producer: Append one tagged batch. Ignored once the channel is closed.
    void push_batch(size_t tag, std::shared_ptr<libstf::Buffer> buffer) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (closed_) {
                return;
            }
            batches_.push_back(Batch{tag, std::move(buffer)});
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
        return pop_locked();
    }

    // Result of a non-blocking poll: `ready` is false when neither a batch nor a clean close is
    // available yet (the consumer should come back later). When `ready` is true, `batch` holds the
    // next batch, or nullopt if the stream closed with nothing left.
    struct PollResult {
        bool                 ready = false;
        std::optional<Batch> batch;
    };

    // Consumer: Non-blocking variant of get_next_batch(). Returns ready=false if the next batch has
    // not arrived but the stream is still open.
    PollResult try_get_next_batch() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (batches_.empty() && !closed_) {
            return {false, std::nullopt};
        }
        return {true, pop_locked()};
    }

    // Consumer: Block until the channel is ready (a batch arrives or it closes) without consuming it.
    // Returns immediately if already ready. Used to park a waiting task; the caller re-polls (via
    // try_get_next_batch) once this returns. The wakeup is always observed on the waiting thread, so
    // no work runs on the producer thread.
    void wait_ready() {
        std::unique_lock<std::mutex> lock(mutex_);
        cv_.wait(lock, [this] { return !batches_.empty() || closed_; });
    }

  private:
    // Pops the front batch (or nullopt at clean close). Caller must hold mutex_ and have ensured the
    // wait predicate (!batches_.empty() || closed_) holds.
    std::optional<Batch> pop_locked() {
        if (!batches_.empty()) {
            Batch batch = std::move(batches_.front());
            batches_.pop_front();
            return batch;
        }
        return std::nullopt;
    }

    std::mutex              mutex_;
    std::condition_variable cv_;
    std::deque<Batch>       batches_;
    bool                    closed_ = false;
};

/**
 * Handle from Scheduler::submit(). Pull batches incrementally to overlap consumer work with the
 * splinter still draining. Batches arrive in completion order across the splinter's hardware
 * streams (NOT submission order), so use Batch::tag to reorder them if needed.
 */
class SplinterResultHandle {
  public:
    SplinterResultHandle() = default;
    explicit SplinterResultHandle(std::shared_ptr<SplinterResultChannel> channel)
        : channel_(std::move(channel)) {}

    // Block until the next batch is ready and return it; nullopt once the splinter is exhausted.
    [[nodiscard]] std::optional<SplinterResultChannel::Batch> get_next_batch() {
        return channel_->get_next_batch();
    }

    [[nodiscard]] SplinterResultChannel::PollResult try_get_next_batch() {
        return channel_->try_get_next_batch();
    }

    void wait_ready() {
        channel_->wait_ready();
    }

  private:
    std::shared_ptr<SplinterResultChannel> channel_;
};

} // namespace oasis
