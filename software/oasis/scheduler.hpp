#pragma once

#include "oasis/query_splinter.hpp"
#include "oasis/splinter_result.hpp"

#include <libstf/common.hpp>

#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <list>
#include <memory>
#include <mutex>
#include <optional>
#include <thread>
#include <utility>
#include <vector>

namespace oasis {

class OasisContext;

/**
 * Describes one hardware stream the scheduler dispatches onto: the capability it provides and the
 * hardware bounds of its pipeline. For now OasisContext hardcodes the descriptions from the
 * synthesized configuration; eventually they could be auto-discovered from the hardware.
 *
 * The three max_* FIFO bounds below are hard limits: the hardware's write FIFOs have no
 * backpressure, so an entry written beyond the depth is silently lost and its flow never
 * completes. The scheduler therefore never places a flow whose demand (see FlowDemand) does not fit.
 *
 * OUTPUT streams only have an output-writer side (max_buffers): flows are never placed on them, but
 * the sinks of flows on other streams can take their output (LocalSinkOperator::output_stream).
 */
struct StreamDescription {
    StreamCapability capability = StreamCapability::DECODE;
    // Cap on flows in flight. Not a hardware bound itself (the FIFOs below are, and a flow takes
    // several entries); for DECODE streams it seeds the runtime-tunable pipeline depth.
    size_t max_flows = 1;
    // Decoder config FIFO depth: one entry per DecodeColumnChunkOperator of an in-flight flow.
    size_t max_configs = 1;
    // Read request FIFO depth: one entry per source operator of an in-flight flow.
    size_t max_reads = 1;
    // Maximum in-flight output buffers (the hardware output-writer FIFO depth).
    size_t max_buffers = 1;
};

/**
 * What one flow occupies in its stream's hardware FIFOs from dispatch until its last interrupt.
 * Computed once from the flow's operators (Scheduler::demand_of).
 */
struct FlowDemand {
    size_t configs = 0; // decoder configs: one per DecodeColumnChunkOperator
    size_t reads   = 0; // read requests: one per SourceOperator
    size_t buffers = 0; // output-writer buffers of the stream the flow runs on: the sinks' buffers
                        // without an output_stream

    // Output-writer buffers on other streams' output channels: the buffers of the sinks with an
    // output_stream, summed per channel (one entry per channel, in order of first use).
    std::vector<std::pair<libstf::stream_t, size_t>> channel_buffers;

    // All buffers of the flow: its completion is the interrupt of the last one of them.
    [[nodiscard]] size_t total_buffers() const {
        size_t total = buffers;
        for (const auto &[channel, count] : channel_buffers) {
            total += count;
        }
        return total;
    }
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
 * A flow is placed on a stream only when its whole demand (decoder configs, read requests and
 * output buffers, see FlowDemand) fits what the stream's FIFOs have left. Everything it reserved is
 * released when the flow completes. The output buffers of sinks that read another stream's output
 * channel are taken from that channel's FIFO, and the flow completes once the last buffer on any of
 * its channels has completed.
 *
 * Two knobs are tunable at runtime and apply to the DECODE streams: the number of *active* streams
 * (the span the dispatcher load-balances across) and the per-stream pipeline depth. Streams of
 * other capabilities are always active, with depths fixed by their hardware FIFO bounds.
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

    // Emulates a slower FPGA->host link in software: The dispatcher holds back new flows until the
    // output bytes written so far would have drained at `gbps` GB/s. 0 disables the emulation.
    void                 set_egress_limit_gbps(double gbps);
    [[nodiscard]] double egress_limit_gbps() const { return egress_gbps_.load(); }

    // Flows waiting in the dispatcher queues (not yet enqueued to the hardware).
    [[nodiscard]] size_t queued_flows() const;

    // Flows currently enqueued across all streams (enqueued in hardware, awaiting completion).
    [[nodiscard]] size_t in_flight_flows() const;

    // Invoked from the interrupt switch for a stream interrupt. The hardware interrupts once per
    // output buffer. This pops the front pending completion for that stream and pushes the
    // corresponding buffer onto the splinter's result channel. The interrupt for the flow's final
    // buffer (across all the output channels it uses, which complete independently of each other)
    // concludes the flow and runs the flow/splinter completion accounting.
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
        FlowDemand                          demand; // released when the flow's last interrupt lands
        libstf::stream_t                    stream = 0; // The stream the flow runs on (owns the slot)
        // Buffers of the flow whose interrupt has not landed yet, over all its output channels.
        // The interrupt that takes it to zero concludes the flow.
        std::atomic<size_t> buffers_remaining{0};
        bool                done = false;
    };

    // One enqueued sink output buffer awaiting its hardware interrupt, recorded in the FIFO of
    // the output channel it was enqueued to, in enqueue order. Holds everything handle_completion
    // needs without re-locking the in-flight list: the buffer to surface, the tag, the splinter
    // completion, a stable iterator to the owning in-flight slot (which lives on the stream the
    // flow runs on, not necessarily on this channel), and whether this is the sink's final buffer
    // (matching the hardware `last` interrupt flag).
    struct PendingCompletion {
        std::shared_ptr<libstf::Buffer>     buffer;
        size_t                              tag;
        std::shared_ptr<SplinterCompletion> completion;
        std::list<InFlight>::iterator       slot;
        bool                                sink_last = false;
    };

    // A queued flow waiting for the dispatcher to place it on a stream providing its capability.
    // Carries the shared completion record of the splinter it belongs to and its demand (the
    // dispatch gates need it before the flow is placed).
    struct Pending {
        OperatorFlow                        flow;
        std::shared_ptr<SplinterCompletion> completion;
        StreamCapability                    capability = StreamCapability::DECODE;
        FlowDemand                          demand;
    };

    // Per-stream pipeline: The stream's bounds (from its StreamDescription), the list of in-flight
    // flows, and what the in-flight flows currently occupy on this stream. `enqueued` is the
    // load-balancing metric and the flow gate; `enqueued_configs`, `enqueued_reads` and
    // `enqueued_buffers` gate the decoder config, read request and output-writer FIFOs (the latter
    // is also the output channel's own FIFO, shared by every flow that has a sink on it). All are
    // atomic and held under no lock: the dispatcher bumps them when it places a flow and the
    // interrupt thread decrements them as completions land. Keeping them lock-free is what breaks
    // the lock cycle -- handle_completion must never take dispatch_mutex_ while the dispatcher holds
    // dispatch_mutex_ and is waiting for the stream mutex. `in_flight`/`done` are guarded by the
    // stream mutex.
    struct StreamState {
        StreamCapability              capability = StreamCapability::DECODE;
        std::mutex                    mutex;
        std::list<InFlight>           in_flight;
        std::deque<PendingCompletion> completions; // enqueued buffers awaiting interrupts, in order
        std::atomic<size_t>           enqueued{0};
        std::atomic<size_t>           enqueued_configs{0};
        std::atomic<size_t>           enqueued_reads{0};
        std::atomic<size_t>           enqueued_buffers{0};
        size_t                        max_flows   = 1;
        size_t                        max_configs = 1;
        size_t                        max_reads   = 1;
        size_t                        max_buffers = 1;
    };

    OasisContext                 &ctx_;
    const libstf::stream_t        num_streams_;
    const libstf::stream_t        num_decode_streams_; // streams providing DECODE (the tunable span)
    std::atomic<libstf::stream_t> active_streams_;
    std::atomic<size_t>           queue_depth_;
    std::atomic<double>           egress_gbps_{0.0};
    // Egress emulation: steady-clock time (ns) at which the output written so far would have
    // drained through the emulated link. Advanced by handle_completion, read by the dispatcher.
    std::atomic<int64_t>          egress_free_at_ns_{0};

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

    // Returns the least-loaded stream providing `capability` that can accept a flow with `demand`
    // (its flow gate and its config, read and buffer gates all have room). For DECODE the
    // candidates are the active span and the flow gate is the runtime pipeline depth; for other
    // capabilities every providing stream is a candidate, gated by its hardware bounds. The output
    // channels the flow's sinks use must have room for them as well. nullopt if none. Must be
    // called holding dispatch_mutex_.
    std::optional<libstf::stream_t> pick_stream(StreamCapability capability,
                                                const FlowDemand &demand) const;

    // Applies a flow on `stream`: Records a pending completion per sink buffer (on the sink's
    // output channel) and enqueues the buffers to the FPGA, parking the flow in the stream's
    // in-flight list. Called only by the dispatcher, with the demand already reserved on the
    // counters of the stream and of the output channels.
    void dispatch_to(libstf::stream_t stream, Pending &pending);

    // Splices `done` in-flight slots into `finished` (without destroying them, so the caller can
    // destroy them outside the locks -- keeping flow/buffer teardown off the scheduler locks).
    // Must be called holding ss.mutex.
    void reap(StreamState &ss, std::list<InFlight> &finished);

    // What `flow` occupies in its stream's FIFOs while in flight.
    [[nodiscard]] static FlowDemand demand_of(const OperatorFlow &flow);
};

} // namespace oasis
