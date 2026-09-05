#pragma once

#include "oasis/query_splinter.hpp"
#include "oasis/splinter_result.hpp"

#include <libstf/common.hpp>

#include <array>
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
 * Describes one hardware stream the scheduler dispatches onto: the capability it provides and the
 * hardware bounds of its pipeline. For now OasisContext hardcodes the descriptions from the
 * synthesized configuration; eventually they could be auto-discovered from the hardware.
 */
struct StreamDescription {
    StreamCapability capability = StreamCapability::DECODE;
    // Maximum in-flight flows (the hardware request/config FIFO depth). For DECODE streams this
    // seeds the runtime-tunable pipeline depth.
    size_t max_flows = 1;
    // Maximum in-flight output buffers (the hardware output-writer FIFO depth).
    size_t max_buffers = 1;
};

/**
 * Bridges unbounded query concurrency to the fixed stream count. Callers submit QuerySplinters and
 * get a future in return. The scheduler owns the hardware streams, each described by the
 * capability it provides and its pipeline bounds (see StreamDescription).
 *
 * Flows are capability-matched to streams (see StreamCapability): decode flows are load-balanced
 * across the DECODE streams, raw source->sink flows can only run on a BYPASS stream. Each
 * capability has its own dispatch queue so a capability whose streams are full never head-of-line
 * blocks the other.
 *
 * Two knobs are tunable at runtime and apply to the DECODE streams: the number of *active* streams
 * (the span the dispatcher load-balances across) and the per-stream pipeline depth. Streams of
 * other capabilities are always active, with depths fixed by their hardware FIFO bounds
 * (max_flows/max_buffers).
 */
class Scheduler {
  public:
    // `streams` describes all available hardware streams, indexed by hardware stream id.
    Scheduler(OasisContext &ctx, std::vector<StreamDescription> streams);
    ~Scheduler();

    Scheduler(const Scheduler &)            = delete;
    Scheduler &operator=(const Scheduler &) = delete;

    // Expands the splinter into its flows, determines each flow's required capability (see
    // StreamCapability), and pushes each onto its capability's unbounded queue, returning instantly
    // with a future. The splinter completes (its single result channel closes) only once every flow
    // has drained. Throws if a flow requires a capability no stream provides, or could never fit
    // any providing stream's bounds.
    SplinterResultHandle submit(QuerySplinter splinter);

    [[nodiscard]] libstf::stream_t num_streams() const { return num_streams_; }
    [[nodiscard]] libstf::stream_t num_decode_streams() const { return num_decode_streams_; }

    void                           set_active_streams(libstf::stream_t active);
    [[nodiscard]] libstf::stream_t active_streams() const { return active_streams_.load(); }

    void                 set_pipeline_depth(size_t depth);
    [[nodiscard]] size_t pipeline_depth() const { return queue_depth_.load(); }

    // Flows waiting in the dispatcher queues (not yet enqueued to the hardware).
    [[nodiscard]] size_t queued_flows() const;

    // Flows currently enqueued across all streams (enqueued in hardware, awaiting completion).
    [[nodiscard]] size_t in_flight_flows() const;

    // Invoked from the interrupt switch for a stream interrupt. The hardware interrupts once per
    // output buffer. This pops the front pending completion for that stream and pushes the
    // corresponding buffer onto the splinter's result channel. The interrupt for the sink's final
    // buffer concludes the flow (the hardware marks it with `last`) and runs the flow/splinter
    // completion accounting.
    void handle_completion(libstf::stream_t stream, uint32_t bytes_written, bool last);

  private:
    struct SplinterCompletion {
        std::shared_ptr<SplinterResultChannel> channel;
        std::atomic<size_t>                    outstanding_flows;
    };

    // One in-flight flow on a stream. It owns the flow's operators (including the sink's output
    // buffers) until reaped, plus a shared pointer to the splinter's completion record.
    struct InFlight {
        OperatorFlow                        flow;
        std::shared_ptr<SplinterCompletion> completion;
        bool                                done = false;
    };

    // One enqueued sink output buffer awaiting its hardware interrupt, recorded in the stream's
    // FIFO in enqueue order. Holds everything handle_completion needs without re-locking the
    // in-flight list: the buffer to surface, the tag, the splinter completion, a stable iterator
    // to the owning in-flight slot, and whether this is the sink's final buffer (whose interrupt
    // concludes the flow).
    struct PendingCompletion {
        std::shared_ptr<libstf::Buffer>     buffer;
        size_t                              tag;
        std::shared_ptr<SplinterCompletion> completion;
        std::list<InFlight>::iterator       slot;
        bool                                last = false;
    };

    // A queued flow waiting for the dispatcher to place it on a stream providing its capability.
    // Carries the shared completion record of the splinter it belongs to and its sink's buffer
    // count (the buffer-slot dispatch gate needs it before the flow is placed).
    struct Pending {
        OperatorFlow                        flow;
        std::shared_ptr<SplinterCompletion> completion;
        StreamCapability                    capability  = StreamCapability::DECODE;
        size_t                              num_buffers = 0;
    };

    // Per-stream pipeline: The stream's bounds (from its StreamDescription), the list of in-flight
    // flows, and the count of flows/buffers currently enqueued on this stream. `enqueued` is the
    // load-balancing metric and the flow FIFO gate. `enqueued_buffers` gates the OutputWRiter
    // FIFO. Both are atomic and held under no lock: the dispatcher bumps them when it places a flow
    // and the interrupt thread decrements them as completions land. Keeping them lock-free is what
    // breaks the lock cycle -- handle_completion must never take dispatch_mutex_ while the
    // dispatcher holds dispatch_mutex_ and is waiting for the stream mutex. `in_flight`/`done` are
    // guarded by the stream mutex.
    struct StreamState {
        std::mutex                    mutex;
        std::list<InFlight>           in_flight;
        std::deque<PendingCompletion> completions; // enqueued buffers awaiting interrupts, in order
        std::atomic<size_t>           enqueued{0};
        std::atomic<size_t>           enqueued_buffers{0};
        size_t                        max_flows   = 1;
        size_t                        max_buffers = 1;
    };

    OasisContext                 &ctx_;
    const libstf::stream_t        num_streams_;
    const libstf::stream_t        num_decode_streams_; // streams providing DECODE (the tunable span)
    std::atomic<libstf::stream_t> active_streams_;
    std::atomic<size_t>           queue_depth_;

    std::vector<std::unique_ptr<StreamState>> streams_;
    // Hardware stream ids providing each capability, in id order. Indexed by StreamCapability.
    std::array<std::vector<libstf::stream_t>, NUM_STREAM_CAPABILITIES> streams_by_capability_;

    mutable std::mutex      dispatch_mutex_;
    std::condition_variable dispatch_cv_;
    // One queue per capability, so full streams of one capability never block dispatch to the
    // other. Indexed by StreamCapability.
    std::array<std::deque<Pending>, NUM_STREAM_CAPABILITIES> queues_;
    bool                    stop_ = false;
    std::thread             dispatcher_;

    // The dispatcher loop: Pops a queue head whose capability has a stream with a free slot, and
    // dispatches there. Parks on dispatch_cv_ when no queued flow is placeable. Reaps finished
    // slots before measuring load.
    void dispatch_loop();

    // Returns the least-loaded stream providing `capability` that can accept a flow whose sink
    // spans `num_buffers` buffers (its flow gate and buffer gate both have room). For DECODE the
    // candidates are the active span and the flow gate is the runtime pipeline depth; for other
    // capabilities every providing stream is a candidate, gated by its hardware bounds. nullopt if
    // none. Must be called holding dispatch_mutex_.
    std::optional<libstf::stream_t> pick_stream(StreamCapability capability,
                                                size_t           num_buffers) const;

    // Applies a flow on `stream`: Records a pending completion per sink buffer and enqueues the
    // buffers to the FPGA, parking the flow in the stream's in-flight list. Called only by the
    // dispatcher, with a slot already reserved (enqueued/enqueued_buffers atomically bumped).
    void dispatch_to(libstf::stream_t stream, Pending &pending);

    // Splices `done` in-flight slots into `finished` (without destroying them, so the caller can
    // destroy them outside the locks -- keeping flow/buffer teardown off the scheduler locks).
    // Must be called holding ss.mutex.
    void reap(StreamState &ss, std::list<InFlight> &finished);
};

} // namespace oasis
