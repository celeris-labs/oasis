#pragma once

#include "oasis/query_splinter.hpp"
#include "oasis/splinter_result.hpp"

#include <libstf/common.hpp>

#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <list>
#include <memory>
#include <mutex>
#include <optional>
#include <thread>
#include <vector>

namespace oasis {

class OasisContext;

/**
 * Bridges unbounded query concurrency to the fixed stream count. Callers submit QuerySplinters and
 * get a future in return. The scheduler owns the streams.
 *
 * submit() pushes the given splinter onto an unbounded queue and returns instantly with a future.
 * A dispatcher thread drains that queue: It pops the head and dispatches it to the *least-loaded*
 * stream -- the active stream with the fewest splinters currently in-flight. If every active stream
 * is at pipeline_depth() already, the dispatcher parks until a completion frees a slot, then
 * dispatches the head there.
 *
 * Two knobs are tunable at runtime: the number of *active* streams (the span the dispatcher load-
 * balances across) and the per-stream pipeline depth.
 */
class Scheduler {
  public:
    explicit Scheduler(OasisContext &ctx);
    ~Scheduler();

    Scheduler(const Scheduler &)            = delete;
    Scheduler &operator=(const Scheduler &) = delete;

    SplinterResultHandle submit(QuerySplinter splinter);

    // Enqueues every splinter under a single lock acquisition so they are contiguous in the queue.
    std::vector<SplinterResultHandle> submit(std::vector<QuerySplinter> splinters);

    [[nodiscard]] libstf::stream_t num_streams() const { return num_streams_; }

    void                           set_active_streams(libstf::stream_t active);
    [[nodiscard]] libstf::stream_t active_streams() const { return active_streams_.load(); }

    void                 set_pipeline_depth(size_t depth);
    [[nodiscard]] size_t pipeline_depth() const { return queue_depth_.load(); }

  private:
    // One in-flight splinter on a stream. It owns the splinter (and thus its OutputHandle and any
    // staged input) until reaped.
    struct InFlight {
        QuerySplinter splinter;
        bool          done = false;
    };

    // A queued splinter waiting for the dispatcher to place it on a stream.
    struct Pending {
        QuerySplinter                          splinter;
        std::shared_ptr<SplinterResultChannel> channel;
    };

    // Per-stream pipeline: The list of in-flight splinters and the count of splinters currently
    // enqueued on this stream. `enqueued` is the load-balancing metric. It is atomic and held under
    // no lock: the dispatcher bumps it when it places a splinter and the completion callback
    // decrements it when a splinter finishes. Keeping it lock-free is what breaks the lock cycle --
    // the callback must never take dispatch_mutex_ while the dispatcher holds dispatch_mutex_ and is
    // waiting for the stream mutex (see dispatch_loop / the completion callback). As a load metric it
    // tolerates being read slightly stale in pick_stream. `in_flight`/`done` are guarded by the
    // stream mutex.
    struct StreamState {
        std::mutex          mutex;
        std::list<InFlight> in_flight;
        std::atomic<size_t> enqueued{0};
    };

    OasisContext                 &ctx_;
    const libstf::stream_t        num_streams_;
    std::atomic<libstf::stream_t> active_streams_;
    std::atomic<size_t>           queue_depth_;

    std::vector<std::unique_ptr<StreamState>> streams_;

    std::mutex              dispatch_mutex_;
    std::condition_variable dispatch_cv_;
    std::deque<Pending>     queue_;
    bool                    stop_ = false;
    std::thread             dispatcher_;

    // The dispatcher loop: Pops the queue head, picks the least-loaded active stream with a free
    // pipeline slot, and dispatches there. Parks on dispatch_cv_ when the queue is empty or every
    // active stream is full. Reaps finished slots before measuring load.
    void dispatch_loop();

    // Returns the least-loaded active stream that has a free pipeline slot, or nullopt if all are
    // full. Must be called holding dispatch_mutex_.
    std::optional<libstf::stream_t> pick_stream() const;

    // Applies a splinter on `stream` and registers its completion callback, parking it in the
    // stream's in-flight list. Called only by the dispatcher, with a slot already reserved
    // (enqueued atomically bumped).
    void dispatch_to(libstf::stream_t stream, Pending &pending);

    // Splices in-flight slots whose callback has run into `finished` (without destroying them, so
    // the caller can destroy them outside the locks -- ~OutputHandle join()s the callback thread).
    // Must be called holding ss.mutex.
    void reap(StreamState &ss, std::list<InFlight> &finished);
};

} // namespace oasis
