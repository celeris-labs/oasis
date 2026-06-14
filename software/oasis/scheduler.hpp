#pragma once

#include "oasis/prefetch_registry.hpp"
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
 * Two knobs are tunable at runtime: the number of *active* streams (the span the dispatcher load-
 * balances across) and the per-stream pipeline depth.
 */
class Scheduler {
  public:
    explicit Scheduler(OasisContext &ctx);
    ~Scheduler();

    Scheduler(const Scheduler &)            = delete;
    Scheduler &operator=(const Scheduler &) = delete;

    // Expands the splinter into its flows and pushes each onto an unbounded queue, returning
    // instantly with a future. The splinter completes (its single result channel closes) only once
    // every flow has drained.
    //
    // `prefetch_key` ties this splinter to a PrefetchNode (the submitting scan). When `last` is set,
    // this is that scan's final splinter: as soon as the dispatcher pulls it off the queue it kicks
    // off prefetch for every dependent scan that just became ready (notify_dependents_last_splinter).
    // Driving this from the dispatcher starts the successors' FPGA warmup the instant the predecessor
    // stops submitting, without burdening the submitting worker thread. Both default off, so callers
    // that do not participate in prefetch submit exactly as before.
    SplinterResultHandle submit(QuerySplinter splinter, PrefetchNode *prefetch_key = nullptr, bool last = false);

    [[nodiscard]] libstf::stream_t num_streams() const { return num_streams_; }

    void                           set_active_streams(libstf::stream_t active);
    [[nodiscard]] libstf::stream_t active_streams() const { return active_streams_.load(); }

    void                 set_pipeline_depth(size_t depth);
    [[nodiscard]] size_t pipeline_depth() const { return queue_depth_.load(); }

    std::shared_ptr<PrefetchRegistry> get_or_create_prefetch_registry(const void *executor_key);
    std::shared_ptr<PrefetchRegistry> find_prefetch_registry(const void *executor_key);
    void                              drop_prefetch_registry(const void *executor_key);

  private:
    struct SplinterCompletion {
        std::shared_ptr<SplinterResultChannel> channel;
        std::atomic<size_t>                    outstanding_sinks;
    };

    // One in-flight flow on a stream. It owns the flow's operators and OutputHandle(s) (one per
    // sink) until reaped, plus a shared pointer to the splinter's completion record.
    struct InFlight {
        OperatorFlow                                       flow;
        std::vector<std::shared_ptr<libstf::OutputHandle>> handles;
        std::shared_ptr<SplinterCompletion>                completion;
        std::atomic<size_t>                                flow_outstanding{0};
        bool                                               done = false;
    };

    // A queued flow waiting for the dispatcher to place it on a stream. Carries the shared
    // completion record of the splinter it belongs to.
    struct Pending {
        OperatorFlow                        flow;
        std::shared_ptr<SplinterCompletion> completion;
    };

    // Per-stream pipeline: The list of in-flight flows and the count of flows currently enqueued on
    // this stream. `enqueued` is the load-balancing metric. It is atomic and held under no lock: the
    // dispatcher bumps it when it places a flow and the flow's last completion callback decrements
    // it when the flow finishes. Keeping it lock-free is what breaks the lock cycle --
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

    std::mutex                                                          prefetch_mutex_;
    std::unordered_map<const void *, std::shared_ptr<PrefetchRegistry>> prefetch_registries_;

    // The dispatcher loop: Pops the queue head, picks the least-loaded active stream with a free
    // pipeline slot, and dispatches there. Parks on dispatch_cv_ when the queue is empty or every
    // active stream is full. Reaps finished slots before measuring load.
    void dispatch_loop();

    // Returns the least-loaded active stream that has a free pipeline slot, or nullopt if all are
    // full. Must be called holding dispatch_mutex_.
    std::optional<libstf::stream_t> pick_stream() const;

    // Applies a flow on `stream` and registers a completion callback per sink, parking it in the
    // stream's in-flight list. Called only by the dispatcher, with a slot already reserved
    // (enqueued atomically bumped).
    void dispatch_to(libstf::stream_t stream, Pending &pending);

    // Splices in-flight slots whose callback has run into `finished` (without destroying them, so
    // the caller can destroy them outside the locks -- ~OutputHandle join()s the callback thread).
    // Must be called holding ss.mutex.
    void reap(StreamState &ss, std::list<InFlight> &finished);
};

} // namespace oasis
