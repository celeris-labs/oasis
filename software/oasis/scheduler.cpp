#include "oasis/scheduler.hpp"

#include "oasis/oasis_context.hpp"

#include "parcore/configuration.hpp"

#include <libstf/logging.hpp>
#include <libstf/profiling.hpp>

#include <algorithm>
#include <cassert>

namespace oasis {

namespace {

const std::string profiler_prefix = "oasis::Scheduler::";

libstf::stream_t default_num_streams(OasisContext &ctx) {
    return ctx.config<parcore::ColumnChunkDecoderConfig>()->num_decoders();
}

size_t default_pipeline_depth(OasisContext &ctx) {
    return ctx.config<parcore::ColumnChunkDecoderConfig>()->maximum_num_enqueued_configs();
}

} // namespace

Scheduler::Scheduler(OasisContext &ctx)
    : ctx_(ctx), num_streams_(default_num_streams(ctx)), active_streams_(num_streams_),
      queue_depth_(std::max<size_t>(default_pipeline_depth(ctx), 1)) {
    streams_.reserve(num_streams_);
    for (libstf::stream_t stream = 0; stream < num_streams_; ++stream) {
        streams_.push_back(std::make_unique<StreamState>());
    }
    dispatcher_ = std::thread([this] { dispatch_loop(); });
}

void Scheduler::set_active_streams(libstf::stream_t active) {
    active_streams_ = std::clamp<libstf::stream_t>(active, 1, num_streams_);
    dispatch_cv_.notify_one(); // A wider span may unblock a parked dispatcher.
}

void Scheduler::set_pipeline_depth(size_t depth) {
    queue_depth_ = std::max<size_t>(depth, 1);
    dispatch_cv_.notify_one(); // A deeper pipeline may open a slot the dispatcher can fill.
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
    // respects this because it never holds the two together: it mutates `enqueued` lock-free (atomic)
    // and takes dispatch_mutex_ only on its own, after releasing ss.mutex, purely to pair with the wait
    // on dispatch_cv_. As in dispatch_loop, the reaped slots are destroyed only after the locks are
    // dropped, so flow destruction never runs under a scheduler lock.
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

namespace {

size_t count_sinks(const QuerySplinter &splinter) {
    size_t sinks = 0;
    for (const auto &flow : splinter.streams) {
        for (const auto &op : flow) {
            if (dynamic_cast<const LocalSinkOperator *>(op.get()) != nullptr) {
                ++sinks;
            }
        }
    }
    return sinks;
}

} // namespace

SplinterResultHandle Scheduler::submit(QuerySplinter splinter) {
    libstf::Profiler::open_regions({profiler_prefix + "submit"});
    auto channel    = std::make_shared<SplinterResultChannel>();
    auto completion = std::make_shared<SplinterCompletion>();
    completion->channel = channel;
    completion->outstanding_sinks.store(count_sinks(splinter), std::memory_order_relaxed);

    {
        // Push every flow contiguously so the splinter's flows stay together in the queue.
        std::lock_guard<std::mutex> lock(dispatch_mutex_);
        for (auto &flow : splinter.streams) {
            queue_.push_back(Pending{std::move(flow), completion});
        }
    }
    dispatch_cv_.notify_one();
    libstf::Profiler::close_regions({profiler_prefix + "submit"});
    return SplinterResultHandle(std::move(channel));
}

std::optional<libstf::stream_t> Scheduler::pick_stream() const {
    const libstf::stream_t active = std::max<libstf::stream_t>(active_streams_.load(), 1);
    const size_t           depth  = queue_depth_.load();

    std::optional<libstf::stream_t> best;
    size_t best_load = depth; // Only streams strictly below depth have a free slot.
    for (libstf::stream_t s = 0; s < active; ++s) {
        const size_t load = streams_[s]->enqueued.load(std::memory_order_relaxed);
        if (load < best_load) {
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
        // active streams; the dispatcher is the sole reaper.
        //
        // We splice the done slots out under the locks but destroy them *after* releasing both
        // dispatch_mutex_ and ss.mutex. handle_completion sets `done` on the interrupt thread and may
        // still be in its tail (between setting `done` and notifying); destroying flows outside the
        // locks keeps slot teardown off the scheduler locks and away from that path.
        std::list<InFlight> finished;
        const libstf::stream_t active = std::max<libstf::stream_t>(active_streams_.load(), 1);
        for (libstf::stream_t s = 0; s < active; ++s) {
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

        std::optional<libstf::stream_t> stream;
        if (!queue_.empty()) {
            stream = pick_stream();
        }

        // Park until there is a queued flow *and* a stream with a free slot, or until shutdown.
        if (!stream) {
            libstf::Profiler::close_regions({profiler_prefix + "dispatch_loop"});
            if (stop_ && queue_.empty()) {
                return;
            }
            dispatch_cv_.wait(lock);
            continue;
        }

        // Reserve the slot (bump load) and pull the head, then dispatch with the lock released so
        // the hardware register writes in dispatch_to don't block submitters or callbacks.
        Pending pending = std::move(queue_.front());
        queue_.pop_front();
        streams_[*stream]->enqueued.fetch_add(1, std::memory_order_relaxed);

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
    // `done`. The dispatcher already reserved the slot (atomically bumped `enqueued`).
    std::vector<LocalSinkOperator *> sinks;
    std::list<InFlight>::iterator    slot;
    {
        libstf::Profiler::open_regions({profiler_prefix + "dispatch_to::setup"});
        std::lock_guard<std::mutex> lock(ss.mutex);
        slot             = ss.in_flight.emplace(ss.in_flight.end());
        slot->flow       = std::move(pending.flow);
        slot->completion = pending.completion;
        for (auto &op : slot->flow) {
            if (auto *s = dynamic_cast<LocalSinkOperator *>(op.get())) {
                sinks.push_back(s);
            }
        }
        slot->flow_outstanding.store(sinks.size(), std::memory_order_relaxed);

        // Record a pending completion per sink *before* any buffer is enqueued so the interrupt that
        // fires once the hardware writes always finds its match. The FIFO order must equal the
        // enqueue (CSR) order below; both run here, on the single dispatcher thread.
        for (LocalSinkOperator *sink : sinks) {
            ss.completions.push_back(
                PendingCompletion{sink->buffer(), sink->tag(), slot->completion, slot});
        }
        libstf::Profiler::close_regions({profiler_prefix + "dispatch_to::setup"});
    }
    assert(!sinks.empty() && "flow has no sink");

    // Enqueue each sink's output buffer to the FPGA (CSR writes), in FIFO order, before the sources
    // trigger the transfer so the hardware output writer already has a destination.
    for (LocalSinkOperator *sink : sinks) {
        sink->apply(stream, ctx_);
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

void Scheduler::handle_completion(libstf::stream_t stream, uint32_t bytes_written, bool /*last*/) {
    StreamState &ss = *streams_[stream];

    PendingCompletion pc;
    {
        std::lock_guard<std::mutex> lock(ss.mutex);
        assert(!ss.completions.empty() && "interrupt on stream with no pending completion");
        pc = std::move(ss.completions.front());
        ss.completions.pop_front();
    }

    // Surface the decoded buffer to the splinter's consumer, tagged so it lands in the right column.
    pc.buffer->size = bytes_written;
    pc.completion->channel->push_batch(pc.tag, pc.buffer);

    // Whole-splinter close: Exactly once, by whichever sink (across all flows) finishes last. 
    // acq_rel makes the channel push happen-before the observed close/done.
    if (pc.completion->outstanding_sinks.fetch_sub(1, std::memory_order_acq_rel) == 1) {
        pc.completion->channel->close();
    }

    // Per-flow done: When this flow's last sink completes, flag the slot reapable, free the
    // pipeline slot, and wake the dispatcher to reap (and destroy the flow) on its own thread. The
    // counters are atomic, so this never nests dispatch_mutex_ with ss.mutex.
    if (pc.slot->flow_outstanding.fetch_sub(1, std::memory_order_acq_rel) == 1) {
        {
            std::lock_guard<std::mutex> slock(ss.mutex);
            pc.slot->done = true;
        }
        ss.enqueued.fetch_sub(1, std::memory_order_relaxed);

        {
            std::lock_guard<std::mutex> dlock(dispatch_mutex_);
        }
        dispatch_cv_.notify_one();
    }
}

} // namespace oasis
