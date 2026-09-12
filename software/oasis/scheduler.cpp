#include "oasis/scheduler.hpp"

#include "oasis/configuration.hpp"
#include "oasis/oasis_context.hpp"

#include "parcore/configuration.hpp"

#include <libstf/logging.hpp>
#include <libstf/profiling.hpp>

#include <algorithm>
#include <cassert>
#include <chrono>
#include <exception>
#include <utility>
#include <vector>

namespace oasis {

namespace {

const std::string profiler_prefix = "oasis::Scheduler::";

// How long the dispatcher parks when it has work, a free host pipeline slot, and no lane with
// credit.
//
// IT MUST BE BOUNDED. Every other reason the dispatcher parks is ended by host code that signals
// dispatch_cv_: a submit pushes work, a completion callback frees a pipeline slot. Lane credit is
// not like that -- a lane's occupancy falls when the HARDWARE retires a response, which runs no host
// code and signals nothing. An indefinite wait here would sleep straight through the credit it is
// waiting for and only wake on the next unrelated event, which on the last flows of a query is never.
//
// 100 us against two CSR reads per wake is at most ~20k reads/s while genuinely starved, and zero
// otherwise; the loop does not spin, it sleeps. Shorter buys nothing: nothing on the critical path of
// one batch runs here -- await_lane_credit inside submit_batch does that, at its own 20 us -- this
// only decides how quickly a lane that just drained is noticed by the NEXT placement.
constexpr auto kLaneRetry = std::chrono::microseconds(100);

// How long every lane may refuse credit before the dispatcher stops being polite about it.
//
// Without this, lane-aware picking would trade a loud failure for a silent hang: the pre-WP5 loop
// dispatched regardless and blocked inside await_lane_credit, which gives up after HTTP_CREDIT_TIMEOUT
// and throws naming the lane, its sticky errors and the stall word. A pick that merely SKIPS a lane
// that never drains would poll forever instead, with no query ever failing and nothing in the log.
//
// So after this long with work queued, a free host slot and not one lane able to take it, the
// dispatcher places the flow anyway on the least-loaded healthy lane and lets the hardware wait
// report what is wrong. Matched to HTTP_CREDIT_TIMEOUT in configuration.cpp: a shorter grace would
// fire on a pipeline that is merely slow, and this deliberately does not diagnose anything itself --
// it hands the question to the code that already knows how to answer it.
constexpr auto kLaneStallGrace = std::chrono::seconds(30);

// How long ~Scheduler waits, in total, for flows already in flight to retire.
//
// IT MUST BE BOUNDED, for the same reason kLaneStallGrace exists and for a sharper one. The slots
// this waits on retire from a completion callback fired by the hardware interrupt path -- and a lane
// the handler has declared FATAL never fires it: handler_multi tears that session down and
// deliberately does not reopen it, because a dirty abort cannot be replayed. So the predicate
// "every slot is done" is not merely slow to become true, it is false forever, and the unbounded
// wait that used to be here turned one dead lane into a process that could not exit.
//
// Matched to kLaneStallGrace, and it is a TOTAL deadline across all streams rather than per stream,
// so a wedged board costs the teardown this once and not once per decoder.
constexpr auto kDrainTimeout = std::chrono::seconds(30);

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
    // TWO DIFFERENT RESOURCES, and conflating them deadlocks the pipeline.
    //
    // max_inflight() is how many chunk LENGTHS the HTTP handler can hold -- 64, and cheap, because
    // an entry is a byte count. maximum_num_enqueued_configs() is how many column chunks the
    // DECODER will accept, and every flow the scheduler dispatches also acquires an output buffer.
    // The depth has to respect both.
    //
    // This returned max_inflight() alone. That was harmless while it evaluated to 1 (the old
    // bytes-in-flight cap) or 4 (the old ring), and became a deadlock the moment it started
    // reporting the chunk-queue depth: 64 flows in flight, 64 decoder configs enqueued and 64
    // output buffers claimed, against a decoder that takes far fewer. The decoder then stops
    // accepting, chunks never reach tlast so they never retire, and back-pressure runs all the way
    // out to the TOE -- observed as inflight=46/64 with rx_fifo_stall set and the receive window
    // collapsing to below the drop threshold.
    //
    // It failed at a different query each run because what matters is how many column chunks have
    // accumulated, not which query asked for them.
    const auto decoder_depth =
        ctx.config<parcore::ColumnChunkDecoderConfig>()->maximum_num_enqueued_configs();
    if (ctx.isHTTPEnabled()) {
        const auto http_depth = ctx.config<HTTPReadConfig>()->max_inflight();
        if (http_depth == 0) {
            return 1;   // pre-pipelining bitstream: one request at a time is the only safe depth
        }
        return std::min<size_t>(static_cast<size_t>(http_depth), decoder_depth);
    }
    return decoder_depth;
}

} // namespace

// The per-lane view the dispatch loop works from. It is a value, not a handle: both admission bits
// are monotone in the host's favour (only a config beat the host itself writes can clear either), so
// a sample stays true until this thread acts on it, and the pick needs no lock and no re-read.
struct Scheduler::LaneSnapshot {
    /// False on every bitstream without per-lane registers, and on a sample that could not be taken.
    /// The pick then falls back to pick_stream(), i.e. to exactly the pre-WP5 behaviour.
    bool                      valid = false;
    HTTPReadConfig::HTTPLanes lanes {};
};

Scheduler::Scheduler(OasisContext &ctx)
    : ctx_(ctx), num_streams_(default_num_streams(ctx)), active_streams_(num_streams_),
      queue_depth_(std::max<size_t>(default_pipeline_depth(ctx), 1)) {
    streams_.reserve(num_streams_);
    for (libstf::stream_t stream = 0; stream < num_streams_; ++stream) {
        streams_.push_back(std::make_unique<StreamState>());
    }

    // Resolve the lane geometry ONCE, before the dispatcher exists. Every value here is fixed by the
    // programmed bitstream (or by the environment), the accessors cache their first read, and doing
    // it here means the loop below never has to ask whether the per-lane registers may be touched --
    // which matters because on a bitstream without them that question is answered by a bus error,
    // not by zeros. default_pipeline_depth() above already read CSRs, so this adds no new ordering
    // requirement on when the Scheduler may be built.
    if (ctx.isHTTPEnabled()) {
        http_ = ctx.config<HTTPReadConfig>();
        // Both conditions, not just the revision. A revision-2 bitstream with ONE lane still routes
        // by the decoder index rather than by a lane, so there is no per-lane window that a decode
        // stream can be metered against, and lane-aware picking would be metering the wrong thing.
        lane_aware_ = http_->lane_csrs_available() && http_->lane_count() > 1;
        if (lane_aware_) {
            lane_count_       = http_->lane_count();
            lane_depth_       = std::max<size_t>(http_->lane_depth_limit(), 1);
            max_batch_chunks_ = std::max<size_t>(http_->max_batch_chunks(), 1);
            libstf::log(libstf::LogLevel::INFO,
                        "Scheduler: lane-aware dispatch over %u lane(s), depth %zu entries per lane "
                        "(OASIS_HTTP_LANE_DEPTH), host pipeline depth %zu per stream",
                        static_cast<unsigned>(lane_count_), lane_depth_, queue_depth_.load());
        }
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
    // pending. Wait (bounded -- see kDrainTimeout) until every slot's callback has run, then reap.
    // Erasing only after `done` guarantees ~OutputHandle (which joins the callback thread) never
    // runs while that callback is still executing. The callback signals dispatch_cv_, so wait on
    // that.
    //
    // Lock order: this predicate takes stream->mutex while holding dispatch_mutex_, so the contract
    // is dispatch_mutex_ -> stream.mutex. Nothing may take them in the opposite order. The completion
    // callback respects this because it never holds the two together: it mutates `enqueued`
    // lock-free (atomic) and takes dispatch_mutex_ only on its own, after releasing ss.mutex, purely
    // to pair with the wait on dispatch_cv_. As in dispatch_loop, the reaped slots are destroyed
    // (join()ing their callback threads) only after the locks are dropped.
    const auto deadline = std::chrono::steady_clock::now() + kDrainTimeout;
    for (auto &stream : streams_) {
        std::list<InFlight> finished;
        size_t              abandoned_here = 0;
        {
            std::unique_lock<std::mutex> dlock(dispatch_mutex_);
            const bool drained = dispatch_cv_.wait_until(dlock, deadline, [&] {
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
            if (!drained && !stream->in_flight.empty()) {
                // ABANDON the stragglers, do not destroy them. ~OutputHandle join()s the callback
                // thread, and the whole reason we are here is that the callback is never going to
                // run -- joining it would hang the destructor exactly as the unbounded wait did.
                //
                // The leak is deliberate and is the lesser evil. It is not free: the callback lambda
                // captures `this`, so if the hardware ever DID fire it after this returns it would
                // touch a destroyed Scheduler. That cannot happen for the case this exists for (a
                // fatal lane's session is gone, no interrupt is coming), and against a hypothetical
                // late callback stands a process that certainly cannot exit. Documented rather than
                // hidden: if a late-callback crash is ever seen on teardown, this is where it is.
                static auto *abandoned = new std::list<InFlight>();
                abandoned_here         = stream->in_flight.size();
                abandoned->splice(abandoned->end(), stream->in_flight);
            }
        }
        if (abandoned_here != 0) {
            libstf::log(libstf::LogLevel::ERROR,
                        "Scheduler: %zu flow(s) never retired after %llds; abandoning them so "
                        "teardown can finish. A lane the hardware declared fatal does not fire the "
                        "completion its slot is waiting for -- look for the lane fatal error above.",
                        abandoned_here,
                        static_cast<long long>(
                            std::chrono::duration_cast<std::chrono::seconds>(kDrainTimeout).count()));
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

// Two CSR reads, once per dispatch iteration, with nothing locked.
//
// It is deliberately NOT per candidate: lanes() folds every lane's occupancy and admission bits into
// one pair of registers precisely so that a scan over four lanes costs the same as a look at one, and
// re-reading per candidate would put four hardware round trips into a decision that has to be cheap
// enough to run at kLaneRetry.
//
// A failure to read is not fatal here. Reporting it from this thread would kill the dispatcher (it
// has no handler above it) and take the whole session with it; falling back to the host-load pick
// instead means the flow is placed and the SAME hardware fault is met by await_lane_credit inside
// dispatch_to, where dispatch_loop already routes exceptions to the query that asked.
Scheduler::LaneSnapshot Scheduler::sample_lanes() {
    LaneSnapshot view;
    if (!lane_aware_) {
        return view; // revision 0, one lane, or no HTTP at all: read nothing, decide as before
    }
    try {
        view.lanes = http_->lanes();
        view.valid = view.lanes.count > 0;
    } catch (const std::exception &e) {
        if (libstf::should_log(libstf::LogLevel::DEBUG)) {
            libstf::log(libstf::LogLevel::DEBUG,
                        "Scheduler: per-lane CSR sample failed (%s); placing by host load this "
                        "iteration",
                        e.what());
        }
        view.valid = false;
    }
    return view;
}

// Column-chunk entries the queue head will reserve on a lane.
//
// A batch reserves room for ALL of its entries before it pushes any of them -- the arm that starts
// the transfer is written last, so a batch that fills the queue part way through deadlocks against
// its own arm -- and that reservation is what the lane's credit has to cover. Capped at
// max_batch_chunks_ because a flow larger than that is split into sub-batches inside the operator,
// and only the first of them has to be admitted for the flow to start making progress; the rest
// self-pace against entries the previous sub-batch is already draining.
size_t Scheduler::pending_lane_entries(const Pending &pending) const {
    size_t chunks = 0;
    for (const auto &op : pending.flow) {
        if (const auto *src = dynamic_cast<const HTTPBatchSourceOperator *>(op.get())) {
            chunks += src->chunk_count();
        }
    }
    if (chunks == 0) {
        // A flow with no HTTP source -- in row-group batch mode every flow but the last is decode
        // plus sink -- reserves nothing on a lane, so it asks for no credit, exactly as
        // await_lane_credit(needed == 0) returns immediately. It is still gated on a free HOST slot,
        // which is what a decoder config and an output buffer actually cost.
        return 0;
    }
    return std::min(chunks, max_batch_chunks_);
}

// Place by lane credit: the least-loaded lane that can still owe `needed` more responses.
//
// Stream index IS lane index (see the class comment), so choosing the lane chooses the stream, and
// the decode stream follows it rather than the other way round. Only the first `lanes.count` streams
// are candidates: `stream % lanes` would route a fifth stream's request text to lane 0 while its
// column chunk was configured on decoder 4, and the bytes would reach a decoder set up for a
// different column -- silent corruption rather than a failure. A bitstream with fewer lanes than
// decoders simply gets fewer streams used.
//
// Outcomes, and they park differently:
//   - a lane with credit          -> that stream
//   - lanes healthy but all full  -> nothing, lane_bound_wait: POLL, hardware frees this silently
//   - no stream with a host slot  -> nothing, no flag: SLEEP, a completion callback frees this
//   - grace expired               -> the least-loaded healthy lane anyway, `forced`
//   - every candidate lane fatal  -> one of them, `fatal`, so the failure surfaces now
//
// Pure: no scheduler state is read or written, so the whole rule can be exercised against synthetic
// lane windows with no board (as HTTPReadConfig::DecodeLanes is).
Scheduler::LanePlacement Scheduler::PlaceOnLane(const LaneInputs &in) {
    LanePlacement out;
    out.next_rr           = in.rr;
    const libstf::stream_t active = std::max<libstf::stream_t>(in.active, 1);
    const auto             span =
        static_cast<libstf::stream_t>(std::min<unsigned>(active, in.lanes.count));
    out.span = span;
    if (span == 0) {
        return out;
    }

    // Exactly await_lane_credit's rule, and it must stay exactly it: a batch bigger than the host's
    // pipelining cap is legal -- the cap is a policy, the lane's queue is the hardware limit -- and
    // it simply gets the lane to itself instead of never being admissible.
    const size_t limit = std::max<size_t>(std::max<size_t>(in.lane_depth, 1), in.needed);

    std::optional<libstf::stream_t> ready, waiting, fatal;
    size_t                          ready_occ = 0, waiting_occ = 0;

    // Start the scan at the rotation cursor so that among equally loaded lanes the pick advances
    // instead of always landing on the lowest index. With `<` below, the first lane reached at the
    // best occupancy wins, which makes the rotation the tie-break.
    for (libstf::stream_t i = 0; i < span; ++i) {
        const auto s = static_cast<libstf::stream_t>((in.rr + i) % span);
        if (in.host_load[s] >= in.host_depth) {
            continue; // no HOST slot: decoder configs and output buffers, not lane credit
        }
        const auto &l = in.lanes.at(static_cast<uint8_t>(s));
        if (l.fatal) {
            // Out of the game until the host reissues. Remembered only so that a queue with NO other
            // option fails loudly instead of polling a dead board; as long as any other lane can
            // take work, a fatal lane costs nothing but its own throughput.
            if (!fatal) {
                fatal = s;
            }
            continue;
        }
        const size_t occ = l.occ;
        // conn_up is false on a lane that has never been armed -- the arm is what opens the
        // connection -- so it cannot be a hard skip or the FIRST batch could never be placed
        // anywhere. It is only meaningful together with occupancy: a lane that owes responses and
        // has no session is mid-connect or mid-reconnect, and piling more entries on it while it is
        // neither sending nor receiving only deepens the queue it has to work through. Idle and
        // unconnected is the normal cold state and is fully admissible.
        const bool connecting = !l.conn_up && occ > 0;
        if (occ + in.needed <= limit && !connecting) {
            if (!ready || occ < ready_occ) {
                ready     = s;
                ready_occ = occ;
            }
        } else if (!waiting || occ < waiting_occ) {
            waiting     = s;
            waiting_occ = occ;
        }
    }

    if (ready) {
        out.stream  = ready;
        out.occ     = ready_occ;
        out.next_rr = static_cast<libstf::stream_t>((*ready + 1) % span);
        return out;
    }

    if (waiting) {
        out.occ = waiting_occ;
        if (!in.credit_expired) {
            // Healthy lanes, none with room. Normal, and normally over in microseconds -- but the
            // hardware frees it without telling anyone, so the caller polls (kLaneRetry).
            out.lane_bound_wait = true;
            return out;
        }
        out.stream  = waiting;
        out.forced  = true;
        out.next_rr = static_cast<libstf::stream_t>((*waiting + 1) % span);
        return out;
    }

    if (fatal) {
        // Every candidate lane is dead. Waiting cannot help -- a fatal lane never retires anything --
        // so place the flow on one NOW and let await_lane_credit throw the decoded reason (a
        // head-of-line kill, which means reissue the whole batch, or an unreplayable read error).
        // That exception reaches the query that asked, via dispatch_loop, and the loop keeps running
        // so work already in flight on other streams still drains. Reissue is deliberately not
        // attempted here: a clear failure beats a silent retry of a batch whose bytes are gone.
        out.stream = fatal;
        out.fatal  = true;
        out.occ    = in.lanes.at(static_cast<uint8_t>(*fatal)).occ;
        return out;
    }

    // Every stream is at its host pipeline depth. A completion callback frees that and signals
    // dispatch_cv_, so the caller may sleep indefinitely -- exactly as it did before lanes existed.
    return out;
}

// The dispatcher's side of PlaceOnLane: gather the inputs, keep the stall deadline, report.
std::optional<libstf::stream_t> Scheduler::pick_lane_stream(const LaneSnapshot &view, size_t needed,
                                                            bool &lane_bound_wait) {
    lane_bound_wait = false;

    LaneInputs in;
    in.lanes      = view.lanes;
    in.host_depth = queue_depth_.load();
    in.lane_depth = lane_depth_;
    in.needed     = needed;
    in.active     = std::max<libstf::stream_t>(active_streams_.load(), 1);
    in.rr         = lane_rr_;
    for (libstf::stream_t s = 0; s < in.active && s < HTTP_LANE_SLOTS && s < num_streams_; ++s) {
        // Read slightly stale by design: `enqueued` is lock-free precisely so the completion
        // callback never has to take dispatch_mutex_ while the dispatcher holds it (see StreamState).
        in.host_load[s] = streams_[s]->enqueued.load(std::memory_order_relaxed);
    }

    // The stall deadline. It starts the first time there is work, a free host slot and no lane with
    // credit, and is cleared by any placement. On shutdown it is skipped: the destructor is blocked
    // on this loop draining the queue, and a lane that is not draining gets reported by
    // await_lane_credit either way, so going straight there costs the teardown 30 s less.
    const auto now = std::chrono::steady_clock::now();
    if (lane_stall_since_ == std::chrono::steady_clock::time_point {}) {
        in.credit_expired = stop_;
    } else {
        in.credit_expired = stop_ || (now - lane_stall_since_ >= kLaneStallGrace);
    }

    const LanePlacement out = PlaceOnLane(in);

    if (out.span < in.active && !lane_span_warned_) {
        lane_span_warned_ = true;
        libstf::log(libstf::LogLevel::WARNING,
                    "Scheduler: %u active streams but only %u HTTP lane(s); streams %u and above "
                    "are left idle. A chunk configured on a decoder with no lane of its own would "
                    "have its request text routed to lane (stream %% lanes) and its bytes decoded "
                    "as a different column.",
                    static_cast<unsigned>(in.active), static_cast<unsigned>(out.span),
                    static_cast<unsigned>(out.span));
    }

    if (out.lane_bound_wait) {
        if (lane_stall_since_ == std::chrono::steady_clock::time_point {}) {
            lane_stall_since_ = now;
        }
        lane_bound_wait = true;
        return std::nullopt;
    }

    lane_rr_ = out.next_rr;
    if (out.stream) {
        if (out.forced) {
            // Zero when the shutdown path forced this on the first starved iteration, where the
            // stall clock was never started -- not "since the epoch".
            const auto stalled_for =
                (lane_stall_since_ == std::chrono::steady_clock::time_point {})
                    ? std::chrono::seconds(0)
                    : std::chrono::duration_cast<std::chrono::seconds>(now - lane_stall_since_);
            libstf::log(libstf::LogLevel::WARNING,
                        "Scheduler: no HTTP lane admitted work for %llds (best lane %u at occupancy "
                        "%zu, needs %zu); placing there anyway so the hardware wait reports why",
                        static_cast<long long>(stalled_for.count()),
                        static_cast<unsigned>(*out.stream), out.occ, needed);
        } else if (out.fatal && libstf::should_log(libstf::LogLevel::DEBUG)) {
            libstf::log(libstf::LogLevel::DEBUG,
                        "Scheduler: every candidate HTTP lane is fatal; placing on lane %u so the "
                        "failure is reported to the query rather than waited on",
                        static_cast<unsigned>(*out.stream));
        }
        lane_stall_since_ = std::chrono::steady_clock::time_point {};
    }
    return out.stream;
}

// Report a lane that went fatal with work already dispatched to it.
//
// THE HANG THIS EXISTS FOR. handler_multi declares a lane fatal when a read fails in a way it cannot
// replay -- a head-of-line kill, or a dirty abort where body bytes already reached the decoder -- and
// then tears the session down and deliberately does NOT reopen it (BR_CLOSE with close_only, which is
// what holds clear_framing high). Every flow already on that lane is orphaned at that instant: its
// completion callback fires from the hardware interrupt path and no interrupt is ever coming, so the
// slot never goes `done`, `enqueued` never comes back down, the splinter's outstanding_sinks never
// reaches zero, and the channel is never closed.
//
// Nothing else notices, and that is the subtle part. throw_lane_fatal() is on the ADMISSION path
// (await_cfg_ready), which only runs when the host pushes another beat AT that lane -- and
// PlaceOnLane skips fatal lanes by design, so as long as one healthy lane remains the admission path
// is never taken for the dead one again. The one place that knows how to report the failure is the
// one place the scheduler now guarantees it will never reach. The query then blocks forever in
// SplinterResultChannel::get_next_batch(), which is how a hardware fault the board diagnosed
// correctly, and printed sticky flags for, became a silent hang with nothing in the log.
//
// So it is reported here, off the per-iteration lane sample the dispatcher already takes.
//
// ONLY THE CHANNEL IS FAILED. The in-flight slot is deliberately left alone: the callback owns
// `flow_outstanding`, `outstanding_sinks` and `enqueued`, and retiring the slot from this thread
// would race a callback that might still fire (after a reprogram, or a late retire) into a double
// decrement of counters it has no lock on. ~Scheduler bounds its own wait for those slots instead.
void Scheduler::fail_flows_on_fatal_lanes(const LaneSnapshot &view,
                                          std::unique_lock<std::mutex> &lock) {
    if (!view.valid || !http_) {
        return;
    }

    // Collect under the lock, act outside it. fail() runs the channel's readiness callback, which
    // reschedules a consumer task, and throw_lane_fatal() reads CSRs -- neither belongs under
    // dispatch_mutex_, for exactly the reasons sample_lanes() is taken unlocked.
    std::vector<std::pair<uint8_t, std::shared_ptr<SplinterResultChannel>>> victims;
    uint32_t   reporting = 0;
    const auto span      = std::min<size_t>(view.lanes.count, streams_.size());
    for (uint8_t s = 0; s < span; ++s) {
        const uint32_t bit = 1u << s;
        if (!view.lanes.at(s).fatal) {
            // Only a reprogram clears a fatal lane, and that builds a new Scheduler -- but clearing
            // the bit costs nothing and keeps this an edge detector rather than a latch.
            lane_fatal_reported_ &= ~bit;
            continue;
        }
        if (lane_fatal_reported_ & bit) {
            continue; // already reported; do not re-walk the list every kLaneRetry
        }
        reporting |= bit;
        std::lock_guard<std::mutex> slock(streams_[s]->mutex);
        for (auto &slot : streams_[s]->in_flight) {
            if (!slot.done && slot.completion && slot.completion->channel) {
                victims.emplace_back(s, slot.completion->channel);
            }
        }
    }
    if (reporting == 0) {
        return;
    }
    lane_fatal_reported_ |= reporting;

    lock.unlock();
    // Everything below runs on the dispatcher thread, which has no handler above it: an escaping
    // exception is std::terminate, i.e. exactly the outcome the rest of this function exists to
    // prevent. fail() runs a consumer-supplied readiness callback and log() formats -- both are
    // meant to be safe, and neither is worth betting the process on. The lane is already latched in
    // lane_fatal_reported_, so a failure here costs the report, not correctness.
    try {
        for (uint8_t s = 0; s < HTTP_LANE_SLOTS; ++s) {
            if ((reporting & (1u << s)) == 0) {
                continue;
            }
            // The decoded diagnosis, not a bare "lane is fatal": whether this was a head-of-line kill
            // (the batch is gone, reissue it) or an unreplayable read error, plus the sticky causes.
            // It reads CSRs and can itself throw, which is why it is wrapped rather than called bare.
            std::exception_ptr err;
            try {
                http_->throw_lane_fatal(s, "an in-flight batch");
            } catch (...) {
                err = std::current_exception();
            }

            size_t failed = 0;
            for (auto &victim : victims) {
                if (victim.first == s) {
                    victim.second->fail(err); // idempotent: first close wins
                    ++failed;
                }
            }
            libstf::log(libstf::LogLevel::ERROR,
                        "Scheduler: HTTP lane %u went fatal with %zu flow(s) in flight; failing them "
                        "rather than waiting for a completion the hardware will never send.",
                        static_cast<unsigned>(s), failed);
        }
    } catch (...) {
        try {
            libstf::log(libstf::LogLevel::ERROR,
                        "Scheduler: could not report a fatal HTTP lane; queries already dispatched "
                        "to it may still wait for a completion that will not come.");
        } catch (...) { // NOLINT -- nothing useful is left to do, and terminate is not an option
        }
    }
    lock.lock();
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
        LaneSnapshot view;
        {
            // Destroy the reaped slots with no scheduler lock held (see above). Do it before any
            // re-lock so the dispatcher never holds dispatch_mutex_ across a join.
            //
            // The same unlocked window takes the hardware's per-lane view: two CSR reads, ONCE per
            // iteration rather than once per candidate, and outside every scheduler lock. Holding
            // dispatch_mutex_ across a hardware read would stall every submit() and every completion
            // callback for as long as the bus takes; holding a stream mutex would additionally
            // invert the dispatch_mutex_ -> stream.mutex order the destructor depends on. The
            // snapshot stays usable after the relock because both admission bits are monotone in the
            // host's favour -- nothing but a beat this thread writes can clear either.
            lock.unlock();
            finished.clear();
            view = sample_lanes();
            lock.lock();
        }

        // A lane may have gone fatal since the last iteration with flows already placed on it. They
        // will never retire, and this is the only thread that looks -- see the function comment.
        fail_flows_on_fatal_lanes(view, lock);

        std::optional<libstf::stream_t> stream;
        // Whether an empty pick means "the hardware has no room" (poll) or "the host has no slot"
        // (sleep until a completion says otherwise). Only the lane-aware path can set it.
        bool lane_bound_wait = false;
        if (!queue_.empty()) {
            stream = view.valid
                         ? pick_lane_stream(view, pending_lane_entries(queue_.front()),
                                            lane_bound_wait)
                         : pick_stream();
        }

        // Park until there is a queued flow *and* a stream with a free slot, or until shutdown.
        if (!stream) {
            libstf::Profiler::close_regions({profiler_prefix + "dispatch_loop"});
            if (stop_ && queue_.empty()) {
                return;
            }
            if (lane_bound_wait) {
                // Lane credit comes back when the hardware retires a response. No host code runs and
                // nothing signals dispatch_cv_, so this wait MUST have a timeout -- see kLaneRetry.
                dispatch_cv_.wait_for(lock, kLaneRetry);
            } else {
                dispatch_cv_.wait(lock);
            }
            continue;
        }

        // Reserve the slot (bump load) and pull the head, then dispatch with the lock released so
        // the hardware register writes in dispatch_to don't block submitters or callbacks.
        Pending pending = std::move(queue_.front());
        queue_.pop_front();
        streams_[*stream]->enqueued.fetch_add(1, std::memory_order_relaxed);

        lock.unlock();
        // dispatch_to runs operator apply() -- which talks to the FPGA and throws on any hardware
        // fault (a credit timeout, a wedged handler, an exhausted huge-page pool). This thread has
        // no handler above it, so an escaping exception meant std::terminate: the process died
        // mid-transfer and left the handler outside ST_IDLE, costing a reprogram to recover. Route
        // it to the consumer instead, where it surfaces as an ordinary query error, and keep the
        // dispatcher running so the remaining flows and the shutdown path still work.
        try {
            dispatch_to(*stream, pending);
        } catch (...) {
            if (pending.completion && pending.completion->channel) {
                pending.completion->channel->fail(std::current_exception());
            }
        }
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
            // Same reasoning as dispatch_loop, on the interrupt path: this runs on the handle's own
            // thread with nothing above it, so a throw here would terminate the process too. The
            // bookkeeping below MUST still run either way or the slot never retires.
            try {
                while (handle->stream_has_more_output(stream)) {
                    completion->channel->push_batch(tag, handle->get_next_stream_output(stream));
                }
            } catch (...) {
                completion->channel->fail(std::current_exception());
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

    // Nothing has been triggered yet, so if an apply() throws no completion callback will EVER fire
    // for this slot -- it would sit in in_flight forever holding a pipeline slot, and `enqueued`
    // would never come back down, so the dispatcher would stop placing work on this stream. Retire
    // it here, then let the exception continue to dispatch_loop, which owns telling the consumer.
    try {
        for (auto &op : slot->flow) {
            if (dynamic_cast<LocalSinkOperator *>(op.get()) == nullptr) {
                op->apply(stream, ctx_);
            }
        }
    } catch (...) {
        {
            std::lock_guard<std::mutex> slock(ss.mutex);
            slot->done = true;
        }
        ss.enqueued.fetch_sub(1, std::memory_order_relaxed);
        libstf::Profiler::close_regions({profiler_prefix + "dispatch_to"});
        throw;
    }

    if (libstf::should_log(libstf::LogLevel::DEBUG)) {
        libstf::log(libstf::LogLevel::DEBUG, "Enqueued flow to stream %u",
                    static_cast<unsigned>(stream));
    }
    libstf::Profiler::close_regions({profiler_prefix + "dispatch_to"});
}

} // namespace oasis
