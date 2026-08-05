#include "oasis/scheduler.hpp"

#include "oasis/configuration.hpp"
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
    // On an HTTP bitstream the source is the FPGA's HTTP client, so the depth that matters is how
    // many ranged GETs that client can hold, not how many configs the decoder will queue.
    //
    // The handler keeps a ring of request slots, but how many the host may USE is max_inflight(),
    // not num_slots() -- that cap, times the range-split size, is what bounds how many bytes the
    // server can have in flight against the TOE's shared receive FIFO. See the comment on
    // HTTP_DEFAULT_MAX_INFLIGHT in configuration.cpp.
    //
    // Note one column chunk may already expand into several ranged GETs inside HTTPReadConfig::read
    // (it splits at chunk_bytes()), so this depth counts DECODER configs, not GETs; the GET-level
    // pipelining happens below it.
    //
    // Depth must never EXCEED that cap. HTTPReadConfig::read blocks until there is credit, so
    // over-queueing here would not corrupt anything -- it would just park the dispatcher thread
    // inside read() instead of leaving the flow queued where it belongs. Sizing to the cap keeps
    // that blocking path a backstop rather than the normal case.
    //
    // A pre-pipelining bitstream reports 0 slots. There, one request at a time is the only safe
    // depth: that handler sampled its start trigger as a one-cycle pulse in ST_IDLE, so a second
    // request issued mid-transfer is dropped and never retried.
    if (ctx.isHTTPEnabled()) {
        const auto depth = ctx.config<HTTPReadConfig>()->max_inflight();
        return depth == 0 ? 1 : static_cast<size_t>(depth);
    }
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

    // The dispatcher is gone, but flows it already placed may still be in flight with callbacks
    // pending. Wait until every slot's callback has run, then reap. Erasing only after `done`
    // guarantees ~OutputHandle (which joins the callback thread) never runs while that callback is
    // still executing. The callback signals dispatch_cv_, so wait on that.
    //
    // Lock order: this predicate takes stream->mutex while holding dispatch_mutex_, so the contract
    // is dispatch_mutex_ -> stream.mutex. Nothing may take them in the opposite order. The completion
    // callback respects this because it never holds the two together: it mutates `enqueued`
    // lock-free (atomic) and takes dispatch_mutex_ only on its own, after releasing ss.mutex, purely
    // to pair with the wait on dispatch_cv_. As in dispatch_loop, the reaped slots are destroyed
    // (join()ing their callback threads) only after the locks are dropped.
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
        finished.clear(); // destroy / join with no scheduler lock held
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
        // active streams; the dispatcher is the sole reaper, so ~OutputHandle stays on this thread.
        //
        // We splice the done slots out under the locks but destroy them *after* releasing both
        // dispatch_mutex_ and ss.mutex. ~OutputHandle join()s the slot's callback thread, and that
        // thread may still be finishing -- needing ss.mutex (to set `done`) or just running. If we
        // destroyed (joined) while holding the locks, a callback thread blocked on one of them could
        // never finish, deadlocking the join. Destroying outside the locks removes that whole class.
        std::list<InFlight> finished;
        const libstf::stream_t active = std::max<libstf::stream_t>(active_streams_.load(), 1);
        for (libstf::stream_t s = 0; s < active; ++s) {
            std::lock_guard<std::mutex> slock(streams_[s]->mutex);
            reap(*streams_[s], finished);
        }
        {
            // Destroy the reaped slots with no scheduler lock held (see above). Do it before any
            // re-lock so the dispatcher never holds dispatch_mutex_ across a join.
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
    // destroying the InFlight (and thus without ~OutputHandle / join()), so the caller can destroy
    // them after dropping the locks. Must be called holding ss.mutex.
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

    // Park the flow in the in-flight list; the iterator is stable for the callbacks to flag `done`
    // and accumulate handles. The dispatcher already reserved the slot (atomically bumped `enqueued`).
    std::vector<LocalSinkOperator *> sinks;
    std::list<InFlight>::iterator    slot;
    {
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
        slot->handles.reserve(sinks.size());
    }
    assert(!sinks.empty() && "flow has no sink");
    SplinterCompletion *completion = slot->completion.get();

    // Each sink must `apply()` first (acquire its OutputHandle) so its completion callback can be
    // registered *before* the source triggers the transfer. add_callback is not retroactive: if
    // mark_done fired first, the callback would be lost.
    for (LocalSinkOperator *sink : sinks) {
        sink->apply(stream, ctx_);
        slot->handles.push_back(sink->handle());
        libstf::OutputHandle *handle = sink->handle().get();
        size_t                tag    = sink->tag();

        // The callback fires on the handle's own thread (via the hardware interrupt path) once this
        // sink's transfer is done. It drains the output into the splinter's channel (tagged), then:
        //  - decrements the splinter-wide sink count, closing the channel on the last one (the
        //    splinter's single completion);
        //  - decrements this flow's own sink count, and when that hits zero flags the slot reapable,
        //    frees the pipeline slot, and wakes the dispatcher to reap (and destroy the handles) on
        //    its own thread.
        // Both counters are atomic, so this never nests dispatch_mutex_ with ss.mutex. acq_rel makes
        // the channel pushes happen-before the observed close/done.
        handle->add_callback([this, &ss, stream, slot, completion, handle, tag](libstf::stream_t) {
            while (handle->stream_has_more_output(stream)) {
                completion->channel->push_batch(tag, handle->get_next_stream_output(stream));
            }
            // Whole-splinter close: exactly once, by whichever sink (across all flows) finishes last.
            if (completion->outstanding_sinks.fetch_sub(1, std::memory_order_acq_rel) == 1) {
                completion->channel->close();
            }

            // Per-flow done: when this flow's last sink drains, flag the slot reapable and free the
            // pipeline slot. The dispatcher reaps `done` slots but destroys them (and join()s this
            // thread) only *after* dropping its locks, so this thread can always finish even if the
            // reap races us here.
            if (slot->flow_outstanding.fetch_sub(1, std::memory_order_acq_rel) == 1) {
                {
                    std::lock_guard<std::mutex> slock(ss.mutex);
                    slot->done = true;
                }
                ss.enqueued.fetch_sub(1, std::memory_order_relaxed);

                {
                    std::lock_guard<std::mutex> dlock(dispatch_mutex_);
                }
                dispatch_cv_.notify_one();
            }
        });
    }

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

} // namespace oasis
