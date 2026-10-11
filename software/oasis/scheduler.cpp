#include "oasis/scheduler.hpp"

#include "oasis/oasis_context.hpp"

#include <libstf/logging.hpp>
#include <libstf/profiling.hpp>

#include <algorithm>
#include <cassert>
#include <sstream>
#include <stdexcept>

namespace oasis {

namespace {

const std::string profiler_prefix = "oasis::Scheduler::";

size_t capability_index(StreamCapability capability) {
    return static_cast<size_t>(capability);
}

libstf::stream_t count_decode_streams(const std::vector<StreamDescription> &streams) {
    return static_cast<libstf::stream_t>(
        std::count_if(streams.begin(), streams.end(), [](const StreamDescription &s) {
            return s.capability == StreamCapability::DECODE;
        }));
}

// The initial pipeline depth: the DECODE streams' flow bound (they all share one).
size_t default_pipeline_depth(const std::vector<StreamDescription> &streams) {
    for (const auto &s : streams) {
        if (s.capability == StreamCapability::DECODE) {
            return std::max<size_t>(s.max_flows, 1);
        }
    }
    return 1;
}

bool fits(size_t used, size_t extra, size_t capacity) {
    return used <= capacity && extra <= capacity - used;
}

} // namespace

Scheduler::Scheduler(OasisContext &ctx, std::vector<StreamDescription> streams)
    : ctx_(ctx), num_streams_(static_cast<libstf::stream_t>(streams.size())),
      num_decode_streams_(count_decode_streams(streams)),
      active_streams_(num_decode_streams_),
      queue_depth_(default_pipeline_depth(streams)) {
    streams_.reserve(streams.size());
    for (libstf::stream_t stream = 0; stream < num_streams_; ++stream) {
        auto state         = std::make_unique<StreamState>();
        state->max_flows   = std::max<size_t>(streams[stream].max_flows, 1);
        state->max_configs = streams[stream].max_configs;
        state->max_reads   = streams[stream].max_reads;
        state->max_buffers = streams[stream].max_buffers;
        streams_by_capability_[capability_index(streams[stream].capability)].push_back(stream);
        streams_.push_back(std::move(state));
    }
    dispatcher_ = std::thread([this] { dispatch_loop(); });
}

void Scheduler::set_active_streams(libstf::stream_t active) {
    active_streams_ =
        std::clamp<libstf::stream_t>(active, 1, std::max<libstf::stream_t>(num_decode_streams_, 1));
    dispatch_cv_.notify_one(); // A wider span may unblock a parked dispatcher.
}

void Scheduler::set_pipeline_depth(size_t depth) {
    queue_depth_ = std::max<size_t>(depth, 1);
    dispatch_cv_.notify_one(); // A deeper pipeline may open a slot the dispatcher can fill.
}

size_t Scheduler::queued_flows() const {
    std::lock_guard<std::mutex> lock(dispatch_mutex_);
    size_t total = 0;
    for (const auto &queue : queues_) {
        total += queue.size();
    }
    return total;
}

size_t Scheduler::in_flight_flows() const {
    size_t total = 0;
    for (const auto &ss : streams_) {
        total += ss->enqueued.load(std::memory_order_relaxed);
    }
    return total;
}

Scheduler::~Scheduler() {
    // Stop the dispatcher first so no new flows are placed while we tear down.
    {
        std::lock_guard<std::mutex> lock(dispatch_mutex_);
        stop_ = true;
    }
    dispatch_cv_.notify_one();
    dispatcher_.join();

    // The dispatcher is gone, but flows it already placed may still be in flight, awaiting their
    // hardware interrupts. Wait until every slot is `done` (its last sink's interrupt has run on the
    // interrupt thread, via handle_completion), then reap. handle_completion signals dispatch_cv_, so
    // wait on that.
    //
    // Lock order: this predicate takes stream->mutex while holding dispatch_mutex_, so the contract
    // is dispatch_mutex_ -> stream.mutex. Nothing may take them in the opposite order. handle_completion
    // respects this because it never holds the two together: it mutates the counters lock-free
    // (atomics) and takes dispatch_mutex_ only on its own, after releasing ss.mutex, purely to pair
    // with the wait on dispatch_cv_. As in dispatch_loop, the reaped slots are destroyed only after
    // the locks are dropped, so flow destruction never runs under a scheduler lock.
    for (auto &stream : streams_) {
        std::list<InFlight> finished;
        {
            std::unique_lock<std::mutex> dlock(dispatch_mutex_);
            dispatch_cv_.wait(dlock, [&] {
                std::lock_guard<std::mutex> slock(stream->mutex);
                for (const auto &slot : stream->in_flight) {
                    if (!slot.done) {
                        return false;
                    }
                }
                return true;
            });
            std::lock_guard<std::mutex> slock(stream->mutex);
            reap(*stream, finished);
        }
        finished.clear(); // destroy with no scheduler lock held
    }
}

FlowDemand Scheduler::demand_of(const OperatorFlow &flow) {
    FlowDemand demand;
    for (const auto &op : flow) {
        if (dynamic_cast<const DecodeColumnChunkOperator *>(op.get()) != nullptr) {
            ++demand.configs;
        } else if (dynamic_cast<const SourceOperator *>(op.get()) != nullptr) {
            ++demand.reads;
        } else if (const auto *s = dynamic_cast<const LocalSinkOperator *>(op.get())) {
            assert(s->buffers().size() > 0 && "flow has a sink with no buffers");
            demand.buffers += s->buffers().size();
        }
    }
    return demand;
}

SplinterResultHandle Scheduler::submit(QuerySplinter splinter) {
    libstf::Profiler::open_regions({profiler_prefix + "submit"});
    auto channel    = std::make_shared<SplinterResultChannel>();
    auto completion = std::make_shared<SplinterCompletion>();
    completion->channel = channel;

    // Determine every flow's required capability and demand and validate them before touching the
    // queues, so a rejected splinter leaves no partial trace behind.
    std::vector<Pending> pendings;
    pendings.reserve(splinter.streams.size());
    for (auto &flow : splinter.streams) {
        Pending pending;
        pending.capability = required_capability(flow);
        pending.completion = completion;
        pending.demand     = demand_of(flow);

        const auto &candidates = streams_by_capability_[capability_index(pending.capability)];
        if (candidates.empty()) {
            libstf::Profiler::close_regions({profiler_prefix + "submit"});
            throw std::runtime_error(
                std::string("QuerySplinter contains a flow that requires a stream with the ") +
                to_string(pending.capability) +
                " capability, but this hardware provides no such stream");
        }

        const bool fits_some_stream =
            std::any_of(candidates.begin(), candidates.end(), [&](libstf::stream_t s) {
                const StreamState &ss = *streams_[s];
                return pending.demand.configs <= ss.max_configs &&
                       pending.demand.reads <= ss.max_reads &&
                       pending.demand.buffers <= ss.max_buffers;
            });
        if (!fits_some_stream) {
            libstf::Profiler::close_regions({profiler_prefix + "submit"});
            std::ostringstream msg;
            msg << "Flow needs " << pending.demand.configs << " decoder config(s), "
                << pending.demand.reads << " read request(s) and " << pending.demand.buffers
                << " output buffer(s), more than any " << to_string(pending.capability)
                << " stream's FIFOs hold, so it could never be dispatched";
            throw std::runtime_error(msg.str());
        }
        pending.flow = std::move(flow);
        pendings.push_back(std::move(pending));
    }
    completion->outstanding_flows.store(pendings.size(), std::memory_order_relaxed);

    {
        // Push every flow contiguously so the splinter's flows stay together in their queues.
        std::lock_guard<std::mutex> lock(dispatch_mutex_);
        for (auto &pending : pendings) {
            queues_[capability_index(pending.capability)].push_back(std::move(pending));
        }
    }
    dispatch_cv_.notify_one();
    libstf::Profiler::close_regions({profiler_prefix + "submit"});
    return SplinterResultHandle(std::move(channel));
}

std::optional<libstf::stream_t> Scheduler::pick_stream(StreamCapability capability,
                                                       const FlowDemand &demand) const {
    const auto &candidates = streams_by_capability_[capability_index(capability)];

    // Only the DECODE streams have the runtime knobs: the active span caps the candidates and the
    // pipeline-depth knob lowers the per-stream flow bound (it never raises it past max_flows).
    // The config/read/buffer gates below are the hardware FIFO depths, which are never exceeded:
    // the FIFOs have no backpressure, and entries written beyond the depth are lost.
    const bool tunable = capability == StreamCapability::DECODE;
    size_t     span    = candidates.size();
    if (tunable) {
        span = std::min<size_t>(span, std::max<libstf::stream_t>(active_streams_.load(), 1));
    }
    const size_t depth = queue_depth_.load();

    std::optional<libstf::stream_t> best;
    size_t                          best_load = 0;
    for (size_t c = 0; c < span; ++c) {
        const libstf::stream_t s    = candidates[c];
        const StreamState     &ss   = *streams_[s];
        const size_t           load = ss.enqueued.load(std::memory_order_relaxed);
        if (load >= (tunable ? std::min(depth, ss.max_flows) : ss.max_flows)) {
            continue; // Flow gate full.
        }
        if (!fits(ss.enqueued_configs.load(std::memory_order_relaxed), demand.configs,
                  ss.max_configs)) {
            continue; // Not enough free decoder config slots.
        }
        if (!fits(ss.enqueued_reads.load(std::memory_order_relaxed), demand.reads, ss.max_reads)) {
            continue; // Not enough free read request slots.
        }
        if (!fits(ss.enqueued_buffers.load(std::memory_order_relaxed), demand.buffers,
                  ss.max_buffers)) {
            continue; // Not enough free output-writer (buffer) slots.
        }
        if (!best || load < best_load) {
            best      = s;
            best_load = load;
            if (load == 0) {
                break; // Cannot do better than an idle stream.
            }
        }
    }
    return best;
}

void Scheduler::dispatch_loop() {
    std::unique_lock<std::mutex> lock(dispatch_mutex_);
    while (true) {
        libstf::Profiler::open_regions({profiler_prefix + "dispatch_loop"});
        // Reap finished slots so freed capacity is visible to pick_stream below. Cheap to sweep all
        // streams; the dispatcher is the sole reaper.
        //
        // We splice the done slots out under the locks but destroy them *after* releasing both
        // dispatch_mutex_ and ss.mutex. handle_completion sets `done` on the interrupt thread and may
        // still be in its tail (between setting `done` and notifying); destroying flows outside the
        // locks keeps slot teardown off the scheduler locks and away from that path.
        std::list<InFlight> finished;
        for (libstf::stream_t s = 0; s < num_streams_; ++s) {
            std::lock_guard<std::mutex> slock(streams_[s]->mutex);
            reap(*streams_[s], finished);
        }
        {
            // Destroy the reaped slots with no scheduler lock held (see above). Do it before any
            // re-lock so the dispatcher never holds dispatch_mutex_ across flow teardown.
            lock.unlock();
            finished.clear();
            lock.lock();
        }

        // Find a queued flow whose capability has a stream with room. Capabilities are checked in
        // enum order, but full streams of one capability never block dispatch to another -- each
        // capability only competes with itself.
        std::optional<libstf::stream_t> stream;
        size_t                          queue_idx = 0;
        for (size_t c = 0; c < NUM_STREAM_CAPABILITIES && !stream; ++c) {
            if (queues_[c].empty()) {
                continue;
            }
            stream = pick_stream(static_cast<StreamCapability>(c), queues_[c].front().demand);
            queue_idx = c;
        }

        // Park until there is a queued flow with a placeable class, or until shutdown.
        if (!stream) {
            libstf::Profiler::close_regions({profiler_prefix + "dispatch_loop"});
            bool queues_empty = true;
            for (const auto &queue : queues_) {
                queues_empty = queues_empty && queue.empty();
            }
            if (stop_ && queues_empty) {
                return;
            }
            dispatch_cv_.wait(lock);
            continue;
        }

        // Reserve what the flow occupies (bump the counters) and pull the head, then dispatch with
        // the lock released so the hardware register writes in dispatch_to don't block submitters
        // or callbacks. Only this thread reserves, so no other placement can invalidate the check
        // pick_stream just made.
        Pending pending = std::move(queues_[queue_idx].front());
        queues_[queue_idx].pop_front();
        StreamState &chosen = *streams_[*stream];
        chosen.enqueued.fetch_add(1, std::memory_order_relaxed);
        chosen.enqueued_configs.fetch_add(pending.demand.configs, std::memory_order_relaxed);
        chosen.enqueued_reads.fetch_add(pending.demand.reads, std::memory_order_relaxed);
        chosen.enqueued_buffers.fetch_add(pending.demand.buffers, std::memory_order_relaxed);

        lock.unlock();
        dispatch_to(*stream, pending);
        lock.lock();
        libstf::Profiler::close_regions({profiler_prefix + "dispatch_loop"});
    }
}

void Scheduler::reap(StreamState &ss, std::list<InFlight> &finished) {
    // Splice done slots into `finished` instead of erasing here: splice moves the list nodes without
    // destroying the InFlight (and thus without tearing down its flow/buffers), so the caller can
    // destroy them after dropping the locks. Must be called holding ss.mutex.
    for (auto it = ss.in_flight.begin(); it != ss.in_flight.end();) {
        if (it->done) {
            auto next = std::next(it);
            finished.splice(finished.end(), ss.in_flight, it);
            it = next;
        } else {
            ++it;
        }
    }
}

void Scheduler::dispatch_to(libstf::stream_t stream, Pending &pending) {
    libstf::Profiler::open_regions({profiler_prefix + "dispatch_to"});
    StreamState &ss = *streams_[stream];

    // Park the flow in the in-flight list; the iterator is stable for handle_completion to flag
    // `done`. The dispatcher already reserved the flow's demand (atomically bumped the stream's
    // counters).
    std::vector<LocalSinkOperator *> sinks;
    std::list<InFlight>::iterator    slot;
    {
        libstf::Profiler::open_regions({profiler_prefix + "dispatch_to::setup"});
        std::lock_guard<std::mutex> lock(ss.mutex);
        slot             = ss.in_flight.emplace(ss.in_flight.end());
        slot->flow       = std::move(pending.flow);
        slot->completion = pending.completion;
        slot->demand     = pending.demand;
        for (auto &op : slot->flow) {
            if (auto *s = dynamic_cast<LocalSinkOperator *>(op.get())) {
                sinks.push_back(s);
            }
        }
        assert(!sinks.empty() && "flow has no sink");

        // Record a pending completion per sink buffer *before* any buffer is enqueued so the
        // interrupt that fires once the hardware writes always finds its match. The FIFO order must
        // equal the enqueue (CSR) order below; both run here, on the single dispatcher thread. The
        // final buffer of the final sink concludes the flow.
        for (size_t s_idx = 0; s_idx < sinks.size(); ++s_idx) {
            auto       *s            = sinks[s_idx];
            const auto &buffers      = s->buffers();
            const bool  is_last_sink = (s_idx + 1 == sinks.size());
            for (size_t i = 0; i < buffers.size(); ++i) {
                const bool is_sink_last = (i + 1 == buffers.size());
                const bool is_flow_last = is_last_sink && is_sink_last;
                ss.completions.push_back(PendingCompletion{buffers[i], s->tag(), slot->completion,
                                                           slot, is_sink_last, is_flow_last});
            }
        }
        libstf::Profiler::close_regions({profiler_prefix + "dispatch_to::setup"});
    }

    // Enqueue the sinks' output buffers to the FPGA (CSR writes), in FIFO order, before the sources
    // trigger the transfer so the hardware output writer already has a destination.
    for (auto *s : sinks) {
        s->apply(stream, ctx_);
    }

    // Apply the remaining operators (sources, decode config), which start the transfer.
    for (auto &op : slot->flow) {
        if (dynamic_cast<LocalSinkOperator *>(op.get()) == nullptr) {
            op->apply(stream, ctx_);
        }
    }

    if (libstf::should_log(libstf::LogLevel::DEBUG)) {
        libstf::log(libstf::LogLevel::DEBUG, "Enqueued flow to stream %u",
                    static_cast<unsigned>(stream));
    }
    libstf::Profiler::close_regions({profiler_prefix + "dispatch_to"});
}

void Scheduler::handle_completion(libstf::stream_t stream, uint32_t bytes_written,
                                  [[maybe_unused]] bool last) {
    StreamState &ss = *streams_[stream];

    PendingCompletion pc;
    {
        std::lock_guard<std::mutex> lock(ss.mutex);
        // A completion with nothing pending means a duplicate, misrouted, or stale (previous
        // scan's) interrupt. Popping an empty deque is UB in release builds; drop instead so the
        // anomaly cannot corrupt the completion pipeline.
        if (ss.completions.empty()) {
            assert(false && "interrupt on stream with no pending completion");
            return;
        }
        pc = std::move(ss.completions.front());
        ss.completions.pop_front();
    }

    // This buffer's hardware output-writer slot is free again.
    ss.enqueued_buffers.fetch_sub(1, std::memory_order_relaxed);

    // Surface the buffer to the splinter's consumer, tagged so it lands in the right column.
    pc.buffer->size = bytes_written;
    pc.completion->channel->push_batch(pc.tag, pc.buffer);

    // The hardware sets `last` on the interrupt of the buffer that saw the transfer's final beat --
    // that must be exactly the sink's final buffer. The accounting below trusts the software
    // bookkeeping (pc.last) so a stray hardware flag cannot corrupt the pipeline.
    assert(last == pc.sink_last && "hardware `last` flag disagrees with the sink's final buffer");

    if (pc.last) {
        // Flow done (one interrupt, for the sink's final buffer, concludes each flow). Everything
        // the flow queued ahead of its last buffer has been consumed by now, so its config and read
        // request slots are free again. Take its demand before flagging the slot reapable: the
        // dispatcher destroys the slot as soon as `done` is set.
        const FlowDemand demand = pc.slot->demand;

        // Flag the slot reapable, free the pipeline slot, run the splinter accounting, and wake the
        // dispatcher to reap (and destroy the flow) on its own thread. The counters are atomic, so
        // this never nests dispatch_mutex_ with ss.mutex.
        {
            std::lock_guard<std::mutex> slock(ss.mutex);
            pc.slot->done = true;
        }
        ss.enqueued_configs.fetch_sub(demand.configs, std::memory_order_relaxed);
        ss.enqueued_reads.fetch_sub(demand.reads, std::memory_order_relaxed);
        ss.enqueued.fetch_sub(1, std::memory_order_relaxed);

        // Whole-splinter close: Exactly once, by whichever flow finishes last. acq_rel makes the
        // channel pushes happen-before the observed close.
        if (pc.completion->outstanding_flows.fetch_sub(1, std::memory_order_acq_rel) == 1) {
            pc.completion->channel->close();
        }

        {
            std::lock_guard<std::mutex> dlock(dispatch_mutex_);
        }
        dispatch_cv_.notify_one();
    } else {
        // A freed output-writer slot alone can unpark a dispatcher waiting to place a multi-buffer
        // flow, so wake it even though this flow is not done yet.
        {
            std::lock_guard<std::mutex> dlock(dispatch_mutex_);
        }
        dispatch_cv_.notify_one();
    }
}

} // namespace oasis
