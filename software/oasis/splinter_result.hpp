#pragma once

#include <libstf/buffer.hpp>

#include <condition_variable>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <utility>

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
        std::function<void()> cb;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (closed_) {
                return;
            }
            batches_.push_back(std::move(batch));
            cb = take_ready_callback();
        }
        cv_.notify_all();
        // Fire the readiness callback outside the lock: it may run on an unstable producer thread 
        // and must touch no channel state (it only reschedules the waiting task).
        if (cb) {
            cb();
        }
    }

    // Producer: No more batches will be pushed. First close wins.
    void close() {
        std::function<void()> cb;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (closed_) {
                return;
            }
            closed_ = true;
            cb = take_ready_callback();
        }
        cv_.notify_all();
        if (cb) {
            cb();
        }
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

    // Consumer: Register a one-shot callback fired exactly once when the channel next becomes ready
    // (a batch arrives or it closes), and return true. Used to wake a blocked task. The callback 
    // must be cheap and must not touch this channel. Replaces any previously registered callback.
    //
    // If the channel is ALREADY ready, the callback is NOT registered and NOT called; the function
    // returns false. The caller must treat this as "ready now" and re-poll rather than block -- the
    // callback is never invoked synchronously on the registering thread, which would otherwise let 
    // a task reschedule (and re-enter the scan) while it is still executing.
    [[nodiscard]] bool set_ready_callback(std::function<void()> cb) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!batches_.empty() || closed_) {
            return false; // Already ready -- caller should re-poll, not block.
        }
        ready_callback_ = std::move(cb);
        return true;
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

    // Moves out the pending readiness callback (one-shot). Caller must hold mutex_.
    std::function<void()> take_ready_callback() {
        return std::move(ready_callback_);
    }

    std::mutex              mutex_;
    std::condition_variable cv_;
    std::deque<Batch>       batches_;
    bool                    closed_ = false;
    std::function<void()>   ready_callback_;
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

    [[nodiscard]] SplinterResultChannel::PollResult try_get_next_batch() {
        return channel_->try_get_next_batch();
    }

    [[nodiscard]] bool set_ready_callback(std::function<void()> cb) {
        return channel_->set_ready_callback(std::move(cb));
    }

  private:
    std::shared_ptr<SplinterResultChannel> channel_;
};

} // namespace oasis
