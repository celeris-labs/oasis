#include "oasis/scheduler.hpp"

#include "oasis/configuration.hpp"
#include "oasis/oasis_context.hpp"

#include "parcore/configuration.hpp"

#include <libstf/logging.hpp>
#include <libstf/profiling.hpp>

#include <cstdio>
#include <cstdlib>
#include <sstream>
#include <unistd.h>
#include <algorithm>
#include <cassert>
#include <chrono>
#include <exception>
#include <stdexcept>
#include <utility>
#include <vector>

namespace oasis {

namespace {

const std::string profiler_prefix = "oasis::Scheduler::";

// How long the dispatcher parks when it has work and a free host slot but no lane has credit. It must
// be bounded: lane credit comes back when the hardware retires a response, which signals nothing.
constexpr auto kLaneRetry = std::chrono::microseconds(100);

// How long every lane may refuse credit before the dispatcher places the flow anyway, on the
// least-loaded healthy lane, so that await_lane_credit reports the lane that stopped draining
// instead of the dispatcher polling forever. Matches HTTP_CREDIT_TIMEOUT.
constexpr auto kLaneStallGrace = std::chrono::seconds(30);

// How long ~Scheduler waits in total (not per stream) for flows in flight to retire. It must be
// bounded: a fatal lane never fires the completion of the flows on it.
constexpr auto kDrainTimeout = std::chrono::seconds(30);

libstf::stream_t default_num_streams(OasisContext &ctx) {
    return ctx.config<parcore::ColumnChunkDecoderConfig>()->num_decoders();
}

size_t default_pipeline_depth(OasisContext &ctx) {
    // On an HTTP bitstream also bounded by the HTTP handler's queue (max_inflight()). Both limits
    // hold: a flow takes a chunk entry and a decoder config, and a decoder given more configs than
    // it takes stops accepting, so its chunks never reach tlast.
    const auto decoder_depth =
        ctx.config<parcore::ColumnChunkDecoderConfig>()->maximum_num_enqueued_configs();
    if (ctx.isHTTPEnabled()) {
        const auto http_depth = ctx.config<HTTPReadConfig>()->max_inflight();
        return std::min<size_t>(static_cast<size_t>(http_depth), decoder_depth);
    }
    return decoder_depth;
}

} // namespace

Scheduler::Scheduler(OasisContext &ctx)
    : ctx_(ctx), num_streams_(default_num_streams(ctx)), active_streams_(num_streams_),
      queue_depth_(std::max<size_t>(default_pipeline_depth(ctx), 1)) {
    streams_.reserve(num_streams_);
    for (libstf::stream_t stream = 0; stream < num_streams_; ++stream) {
        streams_.push_back(std::make_unique<StreamState>());
    }

    // The lane geometry, read once before the dispatcher exists. With one lane there is nothing to
    // choose between, so placement stays on host load.
    if (ctx.isHTTPEnabled()) {
        http_ = ctx.config<HTTPReadConfig>();
        lane_aware_ = http_->lane_count() > 1;
        if (lane_aware_) {
            lane_depth_       = http_->lane_depth_limit();
            max_batch_chunks_ = http_->max_batch_chunks();
            libstf::log(libstf::LogLevel::INFO,
                        "Scheduler: lane-aware dispatch over %u lane(s), depth %zu entries per lane "
                        "(OASIS_HTTP_LANE_DEPTH), host pipeline depth %zu per stream",
                        static_cast<unsigned>(http_->lane_count()), lane_depth_, queue_depth_.load());
        }
    }

    dispatcher_ = std::thread([this] { dispatch_loop(); });

    // The no-progress watchdog: on every HTTP bitstream, so a lane that goes fatal with nothing
    // queued is still reported and SIGINT reaches a blocked scan. The state dump is on by default
    // only on revision 6, whose GET credit makes a stalled lane show up here first; it reads every
    // decoder's profile, which stops the profiler, so elsewhere only OASIS_STALL_DUMP_S turns it on.
    const char *env      = std::getenv("OASIS_STALL_DUMP_S");
    const bool  dump_set = env != nullptr && *env != '\0';
    watchdog_on_         = http_ != nullptr || dump_set;
    if (dump_set) {
        stall_dump_s_ = std::max(0.0, std::atof(env));
    } else if (!(http_ && http_->toe_ring())) {
        stall_dump_s_ = 0.0;
    }
    if (watchdog_on_) {
        note_progress();
        watchdog_ = std::thread([this] { watchdog_loop(); });
    }
}

void Scheduler::note_progress() {
    last_progress_ns_.store(std::chrono::duration_cast<std::chrono::nanoseconds>(
                                std::chrono::steady_clock::now().time_since_epoch())
                                .count(),
                            std::memory_order_relaxed);
}

// The no-progress watchdog. Every 500 ms it
// 1. kicks every consumer blocked on a splinter channel (SplinterResultChannel::kick): DuckDB checks
//    the interrupt flag only when a task runs, so this is what lets SIGINT end a scan blocked on a
//    flow the hardware never finishes. The unwind drops only the scan's handle; the flow, its request
//    text and its output buffers stay with this Scheduler until the flow retires (or ~Scheduler
//    abandons it);
// 2. wakes the dispatcher, so fail_flows_on_fatal_lanes() runs while the queue is empty too;
// 3. dumps the full state once per stall, when flows are outstanding and nothing has retired or
//    been dispatched for stall_dump_s_ seconds: to stderr, and to $OASIS_DUMP_DIR/ if set.
void Scheduler::watchdog_loop() {
    const auto tick     = std::chrono::milliseconds(500);
    bool       dumped   = false;
    int64_t    dumped_at = 0;
    while (true) {
        {
            std::unique_lock<std::mutex> lk(watchdog_mutex_);
            if (watchdog_cv_.wait_for(lk, tick, [this] { return watchdog_stop_; })) {
                return;
            }
        }
        std::vector<std::shared_ptr<SplinterResultChannel>> channels;
        bool busy = false;
        {
            std::lock_guard<std::mutex> lock(dispatch_mutex_);
            busy = !queue_.empty();
            for (auto &st : streams_) {
                // An out-of-service stream keeps its failed flow forever; that is not a stall.
                busy = busy || (st->enqueued.load(std::memory_order_relaxed) != 0 &&
                                !st->out_of_service.load(std::memory_order_relaxed));
            }
            auto it = live_channels_.begin();
            while (it != live_channels_.end()) {
                if (auto c = it->lock()) {
                    channels.push_back(std::move(c));
                    ++it;
                } else {
                    it = live_channels_.erase(it);
                }
            }
        }
        try {
            for (auto &c : channels) {
                c->kick();
            }
        } catch (...) { // a consumer callback must never take this thread down
        }
        channels.clear();
        if (http_) {
            dispatch_cv_.notify_one();
        }

        const int64_t now = std::chrono::duration_cast<std::chrono::nanoseconds>(
                                std::chrono::steady_clock::now().time_since_epoch())
                                .count();
        if (!busy) {
            note_progress(); // idle is not a stall; the clock starts when work is outstanding
            dumped = false;
            continue;
        }
        const int64_t last = last_progress_ns_.load(std::memory_order_relaxed);
        if (dumped && last > dumped_at) {
            dumped = false; // progress since the last dump: arm again
        }
        const double stalled_s = double(now - last) / 1e9;
        if (dumped || stall_dump_s_ <= 0.0 || stalled_s < stall_dump_s_) {
            continue;
        }
        dumped    = true;
        dumped_at = now;
        std::string text;
        try {
            text = describe_stall(stalled_s);
        } catch (const std::exception &e) {
            text = std::string("oasis stall dump failed: ") + e.what() + "\n";
        }
        std::fprintf(stderr, "%s", text.c_str());
        std::fflush(stderr);
        if (const char *dir = std::getenv("OASIS_DUMP_DIR"); dir != nullptr && *dir != '\0') {
            const std::string path = std::string(dir) + "/oasis-stall-" + std::to_string(getpid()) +
                                     "-" + std::to_string(now / 1000000000) + ".txt";
            if (FILE *f = std::fopen(path.c_str(), "w")) {
                std::fputs(text.c_str(), f);
                std::fclose(f);
                std::fprintf(stderr, "[oasis] stall dump written to %s\n", path.c_str());
            }
        }
    }
}

std::string Scheduler::describe_stall(double stalled_s) {
    std::ostringstream o;
    if (stalled_s < 0) {
        o << "\n===== [oasis] EXIT state dump, pid " << getpid() << " =====\n";
    } else {
        o << "\n===== [oasis] NO PROGRESS for " << stalled_s
          << " s (no flow retired or dispatched) -- state dump, pid " << getpid() << " =====\n";
    }
    o << HttpLaneTrafficSummary() << "\n";
    {
        std::lock_guard<std::mutex> lock(dispatch_mutex_);
        o << "host: " << queue_.size() << " flow(s) queued, not yet placed; lane-aware="
          << lane_aware_ << " lane_depth=" << lane_depth_ << " host_depth=" << queue_depth_.load()
          << "\n";
        for (size_t s = 0; s < streams_.size(); ++s) {
            auto &st = *streams_[s];
            std::lock_guard<std::mutex> slock(st.mutex);
            o << "  stream " << s << ": enqueued=" << st.enqueued.load() << ", in-flight "
              << st.in_flight.size() << "\n";
            for (auto &slot : st.in_flight) {
                o << "    flow done=" << slot.done << " sinks_outstanding="
                  << slot.flow_outstanding.load() << ":";
                for (const auto &op : slot.flow) {
                    o << " ";
                    op->print(o);
                }
                o << "\n";
            }
        }
    }
    if (http_) {
        o << http_->debug_dump();
    }
    try {
        auto dec = ctx_.config<parcore::ColumnChunkDecoderConfig>();
        for (libstf::stream_t s = 0; s < num_streams_; ++s) {
            const auto p = dec->read_profile(s);
            o << "  decoder " << unsigned(s) << " in: hs=" << p.in.handshakes_cycles
              << " starved=" << p.in.starved_cycles << " stalled=" << p.in.stalled_cycles
              << " idle=" << p.in.idle_cycles << " | out: hs=" << p.out.handshakes_cycles
              << " starved=" << p.out.starved_cycles << " stalled=" << p.out.stalled_cycles
              << " idle=" << p.out.idle_cycles << "\n";
        }
    } catch (const std::exception &e) {
        o << "  decoder profiles unavailable: " << e.what() << "\n";
    }
    o << "===== end of state dump =====\n";
    return o.str();
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
    // OASIS_EXIT_DUMP: the watchdog's state dump, once, at teardown.
    if (const char *e = std::getenv("OASIS_EXIT_DUMP"); e != nullptr && *e != '\0' && *e != '0') {
        try {
            std::fprintf(stderr, "%s", describe_stall(-1.0).c_str());
        } catch (...) {
        }
    }
    if (watchdog_.joinable()) {
        {
            std::lock_guard<std::mutex> lk(watchdog_mutex_);
            watchdog_stop_ = true;
        }
        watchdog_cv_.notify_all();
        watchdog_.join();
    }
    // Stop the dispatcher first so no new flows are placed while we tear down.
    {
        std::lock_guard<std::mutex> lock(dispatch_mutex_);
        stop_ = true;
    }
    dispatch_cv_.notify_one();
    dispatcher_.join();

    // The dispatcher is gone, but flows it already placed may still be in flight with callbacks
    // pending. Wait (bounded, see kDrainTimeout) until every slot's callback has run, then reap.
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
            dispatch_cv_.wait_until(dlock, deadline, [&] {
                if (stream->out_of_service.load()) {
                    return true; // its failed flow never retires
                }
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
            if (!stream->in_flight.empty()) {
                // Abandon the stragglers rather than destroy them: their sink callbacks capture
                // `this` and the slot, and their request-text buffers may still be read by a DMA. A
                // callback that fired after this returns would touch a destroyed Scheduler; on a
                // fatal lane none is coming.
                static auto *abandoned = new std::list<InFlight>();
                abandoned_here         = stream->in_flight.size();
                abandoned->splice(abandoned->end(), stream->in_flight);
            }
        }
        if (abandoned_here != 0) {
            libstf::log(libstf::LogLevel::ERROR,
                        "Scheduler: abandoning %zu flow(s) that never retired so teardown can "
                        "finish. A lane the hardware declared fatal, or a failed dispatch, leaves its "
                        "flows without a completion -- look for that error above.",
                        abandoned_here);
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
        if (watchdog_on_) {
            live_channels_.push_back(channel);
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
        if (streams_[s]->out_of_service.load(std::memory_order_relaxed)) {
            continue;
        }
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

bool Scheduler::any_stream_in_service() const {
    const libstf::stream_t active = std::max<libstf::stream_t>(active_streams_.load(), 1);
    for (libstf::stream_t s = 0; s < active; ++s) {
        if (!streams_[s]->out_of_service.load(std::memory_order_relaxed)) {
            return true;
        }
    }
    return false;
}

// Two CSR reads per dispatch iteration, not per candidate lane. A read that fails is not reported
// here (the dispatcher has no handler above it): the flow is placed by host load, and the same fault
// meets await_lane_credit inside dispatch_to, whose exception reaches the query.
std::optional<HTTPReadConfig::HTTPLanes> Scheduler::sample_lanes() {
    if (!http_) {
        return std::nullopt;
    }
    try {
        return http_->lanes();
    } catch (const std::exception &e) {
        if (libstf::should_log(libstf::LogLevel::DEBUG)) {
            libstf::log(libstf::LogLevel::DEBUG,
                        "Scheduler: per-lane CSR sample failed (%s); placing by host load this "
                        "iteration",
                        e.what());
        }
        return std::nullopt;
    }
}

// Chunk entries the queue head reserves on a lane before its arm, capped at max_batch_chunks_: a
// larger flow is split into batches, and only the first has to be admitted.
size_t Scheduler::pending_lane_entries(const Pending &pending) const {
    size_t chunks = 0;
    for (const auto &op : pending.flow) {
        if (const auto *src = dynamic_cast<const HTTPBatchSourceOperator *>(op.get())) {
            chunks += src->chunk_count();
        }
    }
    if (chunks == 0) {
        // No HTTP source (in row-group batch mode every flow but the last): only a host slot needed.
        return 0;
    }
    return std::min(chunks, max_batch_chunks_);
}

// The least-loaded lane that can still owe `needed` more entries; stream S is lane S. Outcomes:
//   - a lane with credit          -> that stream
//   - lanes healthy but all full  -> nothing, lane_bound_wait: poll, the hardware frees credit silently
//   - no stream with a host slot  -> nothing: sleep, a completion callback frees one
//   - grace expired               -> the least-loaded healthy lane anyway, `forced`
//   - every candidate lane fatal  -> one of them, so the failure surfaces now
Scheduler::LanePlacement Scheduler::PlaceOnLane(const LaneInputs &in) {
    LanePlacement out;
    out.next_rr           = in.rr;
    const libstf::stream_t active = std::max<libstf::stream_t>(in.active, 1);
    const auto             span =
        static_cast<libstf::stream_t>(std::min<unsigned>(active, in.lanes.count));
    if (span == 0) {
        return out;
    }

    // await_lane_credit's rule: a batch above the host's cap gets the lane to itself.
    const size_t limit = std::max<size_t>(std::max<size_t>(in.lane_depth, 1), in.needed);

    std::optional<libstf::stream_t> ready, waiting, fatal;
    size_t                          ready_occ = 0, waiting_occ = 0;

    // Scan from the rotation cursor: among equally loaded lanes the first one reached wins.
    for (libstf::stream_t i = 0; i < span; ++i) {
        const auto s = static_cast<libstf::stream_t>((in.rr + i) % span);
        if (in.host_load[s] >= in.host_depth) {
            continue; // no host slot (decoder configs and output buffers)
        }
        const auto &l = in.lanes.at(static_cast<uint8_t>(s));
        if (l.fatal) {
            // Taken only when no other lane is a candidate, so the failure surfaces.
            if (!fatal) {
                fatal = s;
            }
            continue;
        }
        const size_t occ = l.occ;
        // A lane that owes entries and has no session is reconnecting; an idle unconnected lane is
        // the cold state (the arm opens the session) and takes work.
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
            out.lane_bound_wait = true;
            return out;
        }
        out.stream  = waiting;
        out.forced  = true;
        out.next_rr = static_cast<libstf::stream_t>((*waiting + 1) % span);
        return out;
    }

    if (fatal) {
        // Every candidate lane is fatal: await_lane_credit throws the decoded reason to the query.
        out.stream = fatal;
        out.occ    = in.lanes.at(static_cast<uint8_t>(*fatal)).occ;
        return out;
    }

    return out;
}

// Gathers PlaceOnLane's inputs, keeps the stall deadline and logs a forced placement.
std::optional<libstf::stream_t> Scheduler::pick_lane_stream(const HTTPReadConfig::HTTPLanes &lanes,
                                                            size_t needed, bool &lane_bound_wait) {
    lane_bound_wait = false;

    LaneInputs in;
    in.lanes      = lanes;
    in.host_depth = queue_depth_.load();
    in.lane_depth = lane_depth_;
    in.needed     = needed;
    in.active     = std::max<libstf::stream_t>(active_streams_.load(), 1);
    in.rr         = lane_rr_;
    for (libstf::stream_t s = 0; s < in.active && s < HTTP_LANE_SLOTS && s < num_streams_; ++s) {
        in.host_load[s] = streams_[s]->out_of_service.load(std::memory_order_relaxed)
                              ? in.host_depth
                              : streams_[s]->enqueued.load(std::memory_order_relaxed);
    }

    // The stall deadline starts when no lane has credit and is cleared by any placement. On shutdown
    // the flow is placed at once: await_lane_credit reports a lane that is not draining either way.
    const auto now = std::chrono::steady_clock::now();
    if (lane_stall_since_ == std::chrono::steady_clock::time_point {}) {
        in.credit_expired = stop_;
    } else {
        in.credit_expired = stop_ || (now - lane_stall_since_ >= kLaneStallGrace);
    }

    const LanePlacement out = PlaceOnLane(in);

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
            // Zero when shutdown forced it before the stall clock started.
            const auto stalled_for =
                (lane_stall_since_ == std::chrono::steady_clock::time_point {})
                    ? std::chrono::seconds(0)
                    : std::chrono::duration_cast<std::chrono::seconds>(now - lane_stall_since_);
            libstf::log(libstf::LogLevel::WARNING,
                        "Scheduler: no HTTP lane admitted work for %llds (best lane %u at occupancy "
                        "%zu, needs %zu); placing there anyway so the hardware wait reports why",
                        static_cast<long long>(stalled_for.count()),
                        static_cast<unsigned>(*out.stream), out.occ, needed);
        }
        lane_stall_since_ = std::chrono::steady_clock::time_point {};
    }
    return out.stream;
}

// Fails the flows already on a lane that went fatal. Their completions never come, and the admission
// path that reports a fatal lane is not taken for it again (placement skips fatal lanes). Only the
// channels are failed: the slots stay with their callbacks, which own the counters.
void Scheduler::fail_flows_on_fatal_lanes(const HTTPReadConfig::HTTPLanes &lanes,
                                          std::unique_lock<std::mutex> &lock) {
    // Collect under the lock, report outside it: throw_lane_fatal() reads CSRs and fail() runs the
    // consumer's readiness callback.
    std::vector<std::pair<uint8_t, std::shared_ptr<SplinterResultChannel>>> victims;
    uint32_t   reporting = 0;
    const auto span      = std::min<size_t>(lanes.count, streams_.size());
    for (uint8_t s = 0; s < span; ++s) {
        const uint32_t bit = 1u << s;
        if (!lanes.at(s).fatal) {
            lane_fatal_reported_ &= ~bit;
            continue;
        }
        if (lane_fatal_reported_ & bit) {
            continue; // reported once, not every iteration
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
    } catch (...) { // a consumer callback or the log must never take this thread down
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
        std::optional<HTTPReadConfig::HTTPLanes> lanes;
        {
            // Destroy the reaped slots with no scheduler lock held (see above). Do it before any
            // re-lock so the dispatcher never holds dispatch_mutex_ across a join.
            // The same unlocked window samples the lanes. The sample stays valid after the relock:
            // only a beat this thread writes clears an admission bit.
            lock.unlock();
            finished.clear();
            lanes = sample_lanes();
            lock.lock();
        }

        if (lanes) {
            fail_flows_on_fatal_lanes(*lanes, lock);
        }

        std::optional<libstf::stream_t> stream;
        // Whether an empty pick means the hardware has no room (poll) or the host has no slot
        // (sleep until a completion signals).
        bool lane_bound_wait = false;
        if (!queue_.empty()) {
            stream = (lanes && lane_aware_)
                         ? pick_lane_stream(*lanes, pending_lane_entries(queue_.front()),
                                            lane_bound_wait)
                         : pick_stream();
        }

        // Park until there is a queued flow *and* a stream with a free slot, or until shutdown.
        if (!stream) {
            libstf::Profiler::close_regions({profiler_prefix + "dispatch_loop"});
            if (stop_ && queue_.empty()) {
                return;
            }
            if (!queue_.empty() && !any_stream_in_service()) {
                // Nothing will ever take the queued flows: fail them rather than park forever.
                Pending pending = std::move(queue_.front());
                queue_.pop_front();
                lock.unlock();
                pending.completion->channel->fail(std::make_exception_ptr(std::runtime_error(
                    "every stream is out of service after failed dispatches; reprogram the board")));
                lock.lock();
                continue;
            }
            if (lane_bound_wait) {
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
        // apply() throws on a hardware fault (a credit timeout, a fatal lane, an exhausted pool). The
        // dispatcher has no handler above it: route the error to the consumer and keep running.
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
            // The handle's thread has no handler above it, and the bookkeeping below must run anyway.
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
                note_progress();
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

    // The exception continues to dispatch_loop, which fails the consumer's channel.
    try {
        for (auto &op : slot->flow) {
            if (dynamic_cast<LocalSinkOperator *>(op.get()) == nullptr) {
                op->apply(stream, ctx_);
            }
        }
    } catch (...) {
        // The sinks' output handles, and perhaps the decoder config and the lane's chunk entries, are
        // already queued on this stream, and a later flow placed here would be decoded against them.
        // So the stream goes out of service, and the slot stays: its sink callbacks capture it.
        ss.out_of_service.store(true);
        libstf::log(libstf::LogLevel::ERROR,
                    "Scheduler: stream %u is out of service after a failed dispatch; reprogram the "
                    "board to use it again",
                    static_cast<unsigned>(stream));
        libstf::Profiler::close_regions({profiler_prefix + "dispatch_to"});
        throw;
    }

    note_progress();
    if (libstf::should_log(libstf::LogLevel::DEBUG)) {
        libstf::log(libstf::LogLevel::DEBUG, "Enqueued flow to stream %u",
                    static_cast<unsigned>(stream));
    }
    libstf::Profiler::close_regions({profiler_prefix + "dispatch_to"});
}

} // namespace oasis
