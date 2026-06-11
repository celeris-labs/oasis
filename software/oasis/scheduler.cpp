#include "oasis/scheduler.hpp"

#include "oasis/oasis_context.hpp"

#include "parcore/configuration.hpp"

#include <algorithm>

namespace oasis {

namespace {

libstf::stream_t default_num_streams(OasisContext &ctx) {
    return ctx.config<parcore::ColumnChunkDecoderConfig>()->num_decoders();
}

size_t default_pipeline_depth(OasisContext &ctx) {
    // TODO: Remove this magic constant. We added the capability to the hardware recently.
    // return ctx.config<parcore::ColumnChunkDecoderConfig>()->maximum_num_enqueued_configs();
    return 64;
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
    // is dispatch_mutex_ -> stream.mutex. Nothing may take them in the opposite order. The
    // completion callback respects this by holding them disjointly (it releases ss.mutex before
    // taking dispatch_mutex_), so it never nests the two and cannot invert the order.
    for (auto &stream : streams_) {
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
        reap(*stream);
    }
}

SplinterResultHandle Scheduler::submit(QuerySplinter splinter) {
    auto channel = std::make_shared<SplinterResultChannel>();
    {
        std::lock_guard<std::mutex> lock(dispatch_mutex_);
        queue_.push_back(Pending{std::move(splinter), channel, std::nullopt});
    }
    dispatch_cv_.notify_one();
    return SplinterResultHandle(std::move(channel));
}

SplinterResultHandle Scheduler::submit_to_stream(libstf::stream_t stream, QuerySplinter splinter) {
    if (stream >= num_streams_) {
        throw std::out_of_range("Scheduler::submit_to_stream stream out of range");
    }

    auto channel = std::make_shared<SplinterResultChannel>();
    {
        std::lock_guard<std::mutex> lock(dispatch_mutex_);
        queue_.push_back(Pending{std::move(splinter), channel, stream});
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
        const size_t load = streams_[s]->enqueued;
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

std::optional<libstf::stream_t> Scheduler::pick_fixed_stream(libstf::stream_t stream) const {
    const size_t depth = queue_depth_.load();
    if (stream >= num_streams_) {
        return std::nullopt;
    }
    if (streams_[stream]->enqueued < depth) {
        return stream;
    }
    return std::nullopt;
}

std::optional<libstf::stream_t> Scheduler::pick_stream_for(const Pending &pending) const {
    if (pending.fixed_stream.has_value()) {
        return pick_fixed_stream(*pending.fixed_stream);
    }
    return pick_stream();
}

void Scheduler::dispatch_loop() {
    std::unique_lock<std::mutex> lock(dispatch_mutex_);
    while (true) {
        // Reap finished slots so freed capacity is visible to pick_stream below. Cheap to sweep all
        // active streams; the dispatcher is the sole reaper, so ~OutputHandle stays on this thread.
        const libstf::stream_t active = std::max<libstf::stream_t>(active_streams_.load(), 1);
        for (libstf::stream_t s = 0; s < active; ++s) {
            std::lock_guard<std::mutex> slock(streams_[s]->mutex);
            reap(*streams_[s]);
        }

        std::optional<libstf::stream_t> stream;
        if (!queue_.empty()) {
            stream = pick_stream_for(queue_.front());
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
        streams_[*stream]->enqueued += 1;

        lock.unlock();
        dispatch_to(*stream, pending);
        lock.lock();
    }
}

void Scheduler::reap(StreamState &ss) {
    for (auto it = ss.in_flight.begin(); it != ss.in_flight.end();) {
        if (it->done) {
            it = ss.in_flight.erase(it); // Destroys the splinter -> ~OutputHandle, on this thread.
        } else {
            ++it;
        }
    }
}

void Scheduler::dispatch_to(libstf::stream_t stream, Pending &pending) {
    StreamState &ss = *streams_[stream];

    // Park the splinter in the in-flight list; the iterator is stable for the callback to flag
    // `done`. The dispatcher already reserved the slot (bumped `enqueued`) under dispatch_mutex_.
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

        {
            std::lock_guard<std::mutex> slock(ss.mutex);
            slot->done = true;
        }
        {
            std::lock_guard<std::mutex> dlock(dispatch_mutex_);
            ss.enqueued -= 1;
        }
        dispatch_cv_.notify_one();
    });

    // Now apply the rest of the operators
    for (auto &op : slot->splinter.operators) {
        if (&*op != &sink) {
            op->apply(stream, ctx_);
        }
    }
}

} // namespace oasis
