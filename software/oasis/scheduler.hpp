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
    SplinterResultHandle submit(QuerySplinter splinter);

    [[nodiscard]] libstf::stream_t num_streams() const { return num_streams_; }

    void                           set_active_streams(libstf::stream_t active);
    [[nodiscard]] libstf::stream_t active_streams() const { return active_streams_.load(); }

    void                 set_pipeline_depth(size_t depth);
    [[nodiscard]] size_t pipeline_depth() const { return queue_depth_.load(); }

    // Flows waiting in the dispatcher queue (not yet enqueued to the hardware).
    [[nodiscard]] size_t queued_flows() const;

    // Flows currently enqueued across all streams (enqueued in hardware, awaiting completion).
    [[nodiscard]] size_t in_flight_flows() const;

    // Invoked from the interrupt switch for a (non-bypass) stream interrupt. Pops the front pending
    // completion for that stream, pushes the corresponding onto the splinter's result channel, and
    // runs the flow/splinter completion accounting. Runs on the interrupt thread, so it stays
    // allocation-free and never blocks.
    void handle_completion(libstf::stream_t stream, uint32_t bytes_written, bool last);

  private:
    struct SplinterCompletion {
        std::shared_ptr<SplinterResultChannel> channel;
        std::atomic<size_t>                    outstanding_sinks;
    };

    // One in-flight flow on a stream. It owns the flow's operators (including each sink's output
    // buffer) until reaped, plus a shared pointer to the splinter's completion record.
    struct InFlight {
        OperatorFlow                        flow;
        std::shared_ptr<SplinterCompletion> completion;
        std::atomic<size_t>                 flow_outstanding{0};
        bool                                done = false;
    };

    // One enqueued sink output buffer awaiting its hardware interrupt, recorded in the stream's 
    // FIFO in enqueue order. Holds everything handle_completion needs without re-locking the 
    // in-flight list: the buffer to surface, the tag, the splinter completion, and a stable 
    // iterator to the owning in-flight slot for the per-flow accounting.
    struct PendingCompletion {
        std::shared_ptr<libstf::Buffer>     buffer;
        size_t                              tag;
        std::shared_ptr<SplinterCompletion> completion;
        std::list<InFlight>::iterator       slot;
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
        std::mutex                    mutex;
        std::list<InFlight>           in_flight;
        std::deque<PendingCompletion> completions; // enqueued buffers awaiting interrupts, in order
        std::atomic<size_t>           enqueued{0};
    };

    OasisContext                 &ctx_;
    const libstf::stream_t        num_streams_;
    std::atomic<libstf::stream_t> active_streams_;
    std::atomic<size_t>           queue_depth_;

    std::vector<std::unique_ptr<StreamState>> streams_;

    mutable std::mutex      dispatch_mutex_;
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

    // Applies a flow on `stream`: Records a pending completion per sink and enqueues its output
    // buffer to the FPGA, parking the flow in the stream's in-flight list. Called only by the
    // dispatcher, with a slot already reserved (enqueued atomically bumped).
    void dispatch_to(libstf::stream_t stream, Pending &pending);

    // Splices `done` in-flight slots into `finished` (without destroying them, so the caller can
    // destroy them outside the locks -- keeping flow/buffer teardown off the scheduler locks).
    // Must be called holding ss.mutex.
    void reap(StreamState &ss, std::list<InFlight> &finished);
};

} // namespace oasis
