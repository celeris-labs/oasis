#include "oasis/scheduler.hpp"

#include "oasis/oasis_context.hpp"

#include "parcore/configuration.hpp"

#include <libstf/logging.hpp>

#include <algorithm>

namespace oasis {

namespace {

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
    // Stop the dispatcher first so no new splinters are placed while we tear down.
    {
        std::lock_guard<std::mutex> lock(dispatch_mutex_);
        stop_ = true;
    }
    dispatch_cv_.notify_one();
    dispatcher_.join();

    // The dispatcher is gone, but splinters it already placed may still be in flight with callbacks
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

SplinterResultHandle Scheduler::submit(QuerySplinter splinter) {
    auto channel = std::make_shared<SplinterResultChannel>();
    {
        std::lock_guard<std::mutex> lock(dispatch_mutex_);
        queue_.push_back(Pending{std::move(splinter), channel});
    }
    dispatch_cv_.notify_one();
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

        // Park until there is a queued splinter *and* a stream with a free slot, or until shutdown.
        if (!stream) {
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
    StreamState &ss = *streams_[stream];

    // Park the splinter in the in-flight list; the iterator is stable for the callback to flag
    // `done`. The dispatcher already reserved the slot (atomically bumped `enqueued`).
    std::list<InFlight>::iterator slot;
    {
        std::lock_guard<std::mutex> lock(ss.mutex);
        slot =
            ss.in_flight.insert(ss.in_flight.end(), InFlight{std::move(pending.splinter), false});
    }
    const auto &channel = pending.channel;

    // The sink must apply first (acquire the OutputHandle) so the completion callback can be
    // registered *before* the source triggers the transfer. add_callback is not retroactive: if
    // mark_done fired first, the callback would be lost.
    HostBufferSinkOperator &sink = slot->splinter.sink();
    sink.apply(stream, ctx_);
    libstf::OutputHandle *handle = sink.handle().get();

    // Resolve off the dispatcher's critical path: The callback fires on the handle's own thread
    // (via the FPGA interrupt path) once the transfer is done. It drains the output into the
    // channel then closes the channel, flags the slot done, releases the stream's pipeline slot
    // (decrement enqueued), and wakes the dispatcher, which reaps the
    // slot (and destroys the handle) on its own thread.
    handle->add_callback([this, &ss, stream, slot, channel, handle](libstf::stream_t) {
        while (handle->stream_has_more_output(stream)) {
            channel->push_batch(handle->get_next_stream_output(stream));
        }
        channel->close();

        // Flag the slot reapable and free the pipeline slot. `enqueued` is atomic so this never
        // nests with ss.mutex. The dispatcher reaps `done` slots but now destroys them (and join()s
        // this thread) only *after* dropping its locks, so this thread can always finish even if the
        // reap races us here.
        {
            std::lock_guard<std::mutex> slock(ss.mutex);
            slot->done = true;
        }
        ss.enqueued.fetch_sub(1, std::memory_order_relaxed);

        // Wake the dispatcher. Take dispatch_mutex_ on its own (ss.mutex already released, no
        // nesting) so the wakeup pairs with the dispatcher's wait and cannot be lost between its
        // predicate check and dispatch_cv_.wait().
        {
            std::lock_guard<std::mutex> dlock(dispatch_mutex_);
        }
        dispatch_cv_.notify_one();
    });

    // Now apply the rest of the operators
    for (auto &op : slot->splinter.operators) {
        if (&*op != &sink) {
            op->apply(stream, ctx_);
        }
    }

    if (libstf::should_log(libstf::LogLevel::DEBUG)) {
        libstf::log(libstf::LogLevel::DEBUG, "Enqueued %s to stream %u", 
                    slot->splinter.to_string().c_str(), static_cast<unsigned>(stream));
    }
}

} // namespace oasis
