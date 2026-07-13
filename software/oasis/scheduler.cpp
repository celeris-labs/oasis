#include "oasis/scheduler.hpp"

#include "oasis/oasis_context.hpp"

#include <libstf/logging.hpp>
#include <libstf/profiling.hpp>

#include <algorithm>
#include <cassert>
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

// The initial pipeline depth: the DECODE streams' hardware flow bound (they all share one).
size_t default_pipeline_depth(const std::vector<StreamDescription> &streams) {
    for (const auto &s : streams) {
        if (s.capability == StreamCapability::DECODE) {
            return std::max<size_t>(s.max_flows, 1);
        }
    }
    return 1;
}

} // namespace

Scheduler::Scheduler(OasisContext &ctx, std::vector<StreamDescription> streams)
    : ctx_(ctx), num_streams_(static_cast<libstf::stream_t>(streams.size())),
      num_decode_streams_(count_decode_streams(streams)),
      active_streams_(num_decode_streams_),
      queue_depth_(default_pipeline_depth(streams)) {
    streams_.reserve(streams.size());
    for (libstf::stream_t stream = 0; stream < num_streams_; ++stream) {
        auto state       = std::make_unique<StreamState>();
        state->max_flows   = std::max<size_t>(streams[stream].max_flows, 1);
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

SplinterResultHandle Scheduler::submit(QuerySplinter splinter) {
    libstf::Profiler::open_regions({profiler_prefix + "submit"});
    auto channel    = std::make_shared<SplinterResultChannel>();
    auto completion = std::make_shared<SplinterCompletion>();
    completion->channel = channel;

    // Determine every flow's required capability and validate it before touching the queues, so a
    // rejected splinter leaves no partial trace behind.
    std::vector<Pending> pendings;
    pendings.reserve(splinter.streams.size());
    for (auto &flow : splinter.streams) {
        Pending pending;
        pending.capability = required_capability(flow);
        pending.completion = completion;
        const LocalSinkOperator *sink = nullptr;
        for (const auto &op : flow) {
            if (const auto *s = dynamic_cast<const LocalSinkOperator *>(op.get())) {
                assert(sink == nullptr && "flow has more than one sink");
                sink = s;
            }
        }
        assert(sink != nullptr && "flow has no sink");
        pending.num_buffers    = sink->buffers().size();
        const auto &candidates = streams_by_capability_[capability_index(pending.capability)];
        if (candidates.empty()) {
            throw std::runtime_error(
                std::string("QuerySplinter contains a flow that requires a stream with the ") +
                to_string(pending.capability) +
                " capability, but this hardware provides no such stream");
        }
        const bool fits_some_stream =
            std::any_of(candidates.begin(), candidates.end(), [&](libstf::stream_t s) {
                return pending.num_buffers <= streams_[s]->max_buffers;
            });
        if (!fits_some_stream) {
            throw std::runtime_error(
                std::string("Flow's sink spans more buffers than any ") +
                to_string(pending.capability) +
                " stream's output-writer slots, so it could never be dispatched");
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
                                                       size_t           num_buffers) const {
    const auto &candidates = streams_by_capability_[capability_index(capability)];

    // Only the DECODE streams have the runtime knobs: the active span caps the candidates and the
    // pipeline-depth knob replaces the per-stream hardware flow bound.
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
        if (load >= (tunable ? depth : ss.max_flows)) {
            continue; // Flow gate full.
        }
        if (ss.max_buffers - ss.enqueued_buffers.load(std::memory_order_relaxed) < num_buffers) {
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
            stream = pick_stream(static_cast<StreamCapability>(c), queues_[c].front().num_buffers);
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

        // Reserve the slot (bump load) and pull the head, then dispatch with the lock released so
        // the hardware register writes in dispatch_to don't block submitters or callbacks.
        Pending pending = std::move(queues_[queue_idx].front());
        queues_[queue_idx].pop_front();
        streams_[*stream]->enqueued.fetch_add(1, std::memory_order_relaxed);
        streams_[*stream]->enqueued_buffers.fetch_add(pending.num_buffers,
                                                      std::memory_order_relaxed);

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
    // `done`. The dispatcher already reserved the slot (atomically bumped
    // `enqueued`/`enqueued_buffers`).
    LocalSinkOperator            *sink = nullptr;
    std::list<InFlight>::iterator slot;
    {
        libstf::Profiler::open_regions({profiler_prefix + "dispatch_to::setup"});
        std::lock_guard<std::mutex> lock(ss.mutex);
        slot             = ss.in_flight.emplace(ss.in_flight.end());
        slot->flow       = std::move(pending.flow);
        slot->completion = pending.completion;
        for (auto &op : slot->flow) {
            if (auto *s = dynamic_cast<LocalSinkOperator *>(op.get())) {
                sink = s;
            }
        }
        assert(sink != nullptr && "flow has no sink");

        // Record a pending completion per sink buffer *before* any buffer is enqueued so the
        // interrupt that fires once the hardware writes always finds its match. The FIFO order must
        // equal the enqueue (CSR) order below; both run here, on the single dispatcher thread. The
        // final buffer's completion concludes the flow.
        const auto &buffers = sink->buffers();
        for (size_t i = 0; i < buffers.size(); ++i) {
            ss.completions.push_back(PendingCompletion{buffers[i], sink->tag(), slot->completion,
                                                       slot, i + 1 == buffers.size()});
        }
        libstf::Profiler::close_regions({profiler_prefix + "dispatch_to::setup"});
    }

    // Enqueue the sink's output buffers to the FPGA (CSR writes), in FIFO order, before the sources
    // trigger the transfer so the hardware output writer already has a destination.
    sink->apply(stream, ctx_);

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

    // The hardware sets `last` on the interrupt of the buffer that saw the flow's final beat --
    // that must be exactly the sink's final buffer. The accounting below trusts the software
    // bookkeeping (pc.last) so a stray hardware flag cannot corrupt the pipeline.
    assert(last == pc.last && "hardware `last` flag disagrees with the sink's final buffer");

    if (pc.last) {
        // Flow done (one interrupt, for the sink's final buffer, concludes each flow): flag the
        // slot reapable, free the pipeline slot, run the splinter accounting, and wake the
        // dispatcher to reap (and destroy the flow) on its own thread. The counters are atomic, so
        // this never nests dispatch_mutex_ with ss.mutex.
        {
            std::lock_guard<std::mutex> slock(ss.mutex);
            pc.slot->done = true;
        }
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
