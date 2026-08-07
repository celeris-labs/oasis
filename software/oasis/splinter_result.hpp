#pragma once

#include <libstf/buffer.hpp>

#include <condition_variable>
#include <exception>
#include <cstddef>
#include <deque>
#include <functional>
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
        std::function<void()> cb;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (closed_) {
                return;
            }
            batches_.push_back(Batch{tag, std::move(buffer)});
            cb = take_ready_callback();
        }
        cv_.notify_all();
        // Fire the readiness callback outside the lock: it may run on an unstable producer thread 
        // and must touch no channel state (it only reschedules the waiting task).
        if (cb) {
            cb();
        }
    }

    // Producer: the flow died. Stores the exception, closes the channel, and every consumer call
    // from here on rethrows it.
    //
    // Without this a failed flow could only close() -- indistinguishable from a clean end of stream,
    // so a hardware error became a SILENTLY TRUNCATED result rather than an error. The alternative
    // that was actually happening is worse still: the exception escaped the dispatcher thread, which
    // has no handler, and std::terminate killed the process mid-transfer -- leaving the FPGA handler
    // outside ST_IDLE, where only reprogramming the bitstream recovers it.
    //
    // Queued batches are deliberately discarded. The result is incomplete by definition, and handing
    // the consumer a prefix of it is the one outcome worse than either failure above.
    void fail(std::exception_ptr err) {
        std::function<void()> cb;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (closed_) {
                return;
            }
            error_  = std::move(err);
            closed_ = true;
            cb      = take_ready_callback();
        }
        cv_.notify_all();
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
        if (error_) {
            std::rethrow_exception(error_);
        }
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
        if (error_) {
            std::rethrow_exception(error_);
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
    // Set by fail(). Non-null means every consumer call rethrows instead of returning data.
    std::exception_ptr error_;

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

    [[nodiscard]] bool set_ready_callback(std::function<void()> cb) {
        return channel_->set_ready_callback(std::move(cb));
    }

  private:
    std::shared_ptr<SplinterResultChannel> channel_;
};

} // namespace oasis
