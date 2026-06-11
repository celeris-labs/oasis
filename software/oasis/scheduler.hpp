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
 * submit_to_stream() is the same scheduling mechanism, but pins the splinter to one specific stream.
 * This is needed for special hardware paths such as the Bloomfilter, which is physically wired to
 * stream 0.
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
    SplinterResultHandle submit_to_stream(libstf::stream_t stream, QuerySplinter splinter);

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
        std::optional<libstf::stream_t>        fixed_stream;
    };

    // Per-stream pipeline: The list of in-flight splinters and the count of splinters currently
    // enqueued on this stream. `enqueued` is the load-balancing metric. It is guarded by
    // dispatch_mutex_ (not the stream mutex) so the dispatcher can read every stream's load while
    // choosing the least-loaded one without taking per-stream locks. `in_flight`/`done` are guarded
    // by the stream mutex.
    struct StreamState {
        std::mutex          mutex;
        std::list<InFlight> in_flight;
        size_t              enqueued = 0; // guarded by dispatch_mutex_
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

    // The dispatcher loop: Pops the queue head, picks a stream with a free pipeline slot, and
    // dispatches there. For fixed-stream splinters, only that stream is considered. Parks on
    // dispatch_cv_ when the queue is empty or the required stream is full. Reaps finished slots
    // before measuring load.
    void dispatch_loop();

    // Returns the least-loaded active stream that has a free pipeline slot, or nullopt if all are
    // full. Must be called holding dispatch_mutex_.
    std::optional<libstf::stream_t> pick_stream() const;

    // Returns fixed stream if it has a free pipeline slot, otherwise nullopt.
    // Must be called holding dispatch_mutex_.
    std::optional<libstf::stream_t> pick_fixed_stream(libstf::stream_t stream) const;

    // Selects a stream for a pending splinter. Must be called holding dispatch_mutex_.
    std::optional<libstf::stream_t> pick_stream_for(const Pending &pending) const;

    // Applies a splinter on `stream` and registers its completion callback, parking it in the
    // stream's in-flight list. Called only by the dispatcher, with a slot already reserved
    // (enqueued bumped) under dispatch_mutex_.
    void dispatch_to(libstf::stream_t stream, Pending &pending);

    // Erases in-flight slots whose callback has run. Must be called holding ss.mutex.
    void reap(StreamState &ss);
};

} // namespace oasis