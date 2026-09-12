#pragma once

#include "oasis/configuration.hpp"
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
#include <vector>

namespace oasis {

class OasisContext;
class HTTPReadConfig;

/**
 * Bridges unbounded query concurrency to the fixed stream count. Callers submit QuerySplinters and
 * get a future in return. The scheduler owns the streams.
 *
 * Two knobs are tunable at runtime: the number of *active* streams (the span the dispatcher load-
 * balances across) and the per-stream pipeline depth.
 *
 * On a bitstream that reports per-lane HTTP registers (CSR revision >= 2) with more than one lane,
 * the dispatcher additionally places work by LANE CREDIT rather than by host load alone: each
 * iteration samples the hardware's per-lane admission windows and picks the least-loaded lane that
 * can still owe another response. Stream index and lane index are the SAME index -- the lane owns
 * the TCP session, the framer, the chunk queue and the decoder its body bytes come out on -- so
 * picking the lane is picking the stream. Everything below is unchanged on any other bitstream.
 */
class Scheduler {
  public:
    explicit Scheduler(OasisContext &ctx);
    ~Scheduler();

    Scheduler(const Scheduler &)            = delete;
    Scheduler &operator=(const Scheduler &) = delete;

    // Expands the splinter into its flows and pushes each onto an unbounded queue, returning 
    // instantly with a future. The splinter completes (its single result channel closes) only once 
    // every flow has drained.
    SplinterResultHandle submit(QuerySplinter splinter);

    [[nodiscard]] libstf::stream_t num_streams() const { return num_streams_; }

    void                           set_active_streams(libstf::stream_t active);
    [[nodiscard]] libstf::stream_t active_streams() const { return active_streams_.load(); }

    void                 set_pipeline_depth(size_t depth);
    [[nodiscard]] size_t pipeline_depth() const { return queue_depth_.load(); }

    /// Everything the lane placement decision reads. Gathered by the dispatcher; the decision itself
    /// (PlaceOnLane) touches no scheduler state, so it can be exercised against synthetic lane
    /// windows with no board attached -- the same reason HTTPReadConfig::DecodeLanes is a static.
    struct LaneInputs {
        /// The hardware's per-lane admission windows, as sampled once for this iteration.
        HTTPReadConfig::HTTPLanes lanes {};
        /// Flows already placed on each stream and not yet retired (StreamState::enqueued).
        std::array<size_t, HTTP_LANE_SLOTS> host_load {};
        /// Flows one stream may hold at once: decoder configs and output buffers, not lane credit.
        size_t host_depth = 1;
        /// Chunk entries the host will let one lane owe (lane_depth_limit()).
        size_t lane_depth = 1;
        /// Entries the queue head will reserve before it can be armed; 0 for a flow that
        /// touches no lane, which then only needs a free host slot.
        size_t needed = 1;
        /// Streams the dispatcher may use; clamped to the lane count inside.
        libstf::stream_t active = 0;
        /// Rotation cursor, so equally loaded lanes are not always tried in index order.
        libstf::stream_t rr = 0;
        /// The stall grace has run out (or the scheduler is shutting down): place the flow even
        /// without credit, so the hardware wait reports why rather than the host polling forever.
        bool credit_expired = false;
    };

    /// What the decision came to. `stream` unset means park -- on a timeout if lane_bound_wait
    /// (hardware frees lane credit silently), otherwise indefinitely (a completion will signal).
    struct LanePlacement {
        std::optional<libstf::stream_t> stream;
        libstf::stream_t                next_rr = 0;
        /// Nothing was placed because no LANE had credit, as opposed to no stream having a slot.
        bool lane_bound_wait = false;
        /// Placed on a lane with no credit, because the grace expired. The wait moves to the
        /// hardware, which reports which lane stopped draining.
        bool forced = false;
        /// Placed on a FATAL lane because every candidate was fatal, to surface the failure now.
        bool fatal = false;
        /// The chosen (or best rejected) lane's occupancy and the streams considered, for logging.
        size_t           occ  = 0;
        libstf::stream_t span = 0;
    };

    /// The lane-aware placement rule, as a pure function of `in`.
    ///
    /// THE INVARIANT IT EXISTS FOR: a lane that is full, fatal, or mid-connect must never hold up a
    /// lane that has credit. The pre-WP5 loop asked one folded question -- "is the board ready?" --
    /// whose answer a single busy lane could dictate for all of them.
    [[nodiscard]] static LanePlacement PlaceOnLane(const LaneInputs &in);

  private:
    struct SplinterCompletion {
        std::shared_ptr<SplinterResultChannel> channel;
        std::atomic<size_t>                    outstanding_sinks;
    };

    // One in-flight flow on a stream. It owns the flow's operators and OutputHandle(s) (one per
    // sink) until reaped, plus a shared pointer to the splinter's completion record.
    struct InFlight {
        OperatorFlow                                       flow;
        std::vector<std::shared_ptr<libstf::OutputHandle>> handles;
        std::shared_ptr<SplinterCompletion>                completion;
        std::atomic<size_t>                                flow_outstanding{0};
        bool                                               done = false;
    };

    // A queued flow waiting for the dispatcher to place it on a stream. Carries the shared
    // completion record of the splinter it belongs to.
    struct Pending {
        OperatorFlow                        flow;
        std::shared_ptr<SplinterCompletion> completion;
    };

    // Per-stream pipeline: The list of in-flight flows and the count of flows currently enqueued on
    // this stream. `enqueued` is the load-balancing metric. It is atomic and held under no lock: the
    // dispatcher bumps it when it places a flow and the flow's last completion callback decrements
    // it when the flow finishes. Keeping it lock-free is what breaks the lock cycle --
    // the callback must never take dispatch_mutex_ while the dispatcher holds dispatch_mutex_ and is
    // waiting for the stream mutex (see dispatch_loop / the completion callback). As a load metric it
    // tolerates being read slightly stale in pick_stream. `in_flight`/`done` are guarded by the
    // stream mutex.
    struct StreamState {
        std::mutex          mutex;
        std::list<InFlight> in_flight;
        std::atomic<size_t> enqueued{0};
    };

    /// One dispatch iteration's view of the hardware's per-lane admission windows. Sampled ONCE per
    /// iteration and with NO scheduler lock held: it costs two CSR reads, and holding
    /// dispatch_mutex_ across a hardware read would block every submitter and every completion
    /// callback for the duration. Defined in scheduler.cpp so this header stays clear of the CSR
    /// layer; `valid` is false whenever the pick must fall back to the host-load-only path.
    struct LaneSnapshot;

    OasisContext                 &ctx_;
    const libstf::stream_t        num_streams_;
    std::atomic<libstf::stream_t> active_streams_;
    std::atomic<size_t>           queue_depth_;

    std::vector<std::unique_ptr<StreamState>> streams_;

    // ---------------------------------------------------------------------------------------------
    // Lane-aware dispatch. Every field here is resolved ONCE, in the constructor, from registers the
    // bitstream cannot change while it is programmed -- so the dispatch loop never re-asks whether
    // the lane registers exist, and a revision-0 board pays nothing at all for this section.
    // ---------------------------------------------------------------------------------------------

    /// The HTTP read config, or null when this bitstream has none. Held so the dispatcher does not
    /// walk the config map on every iteration.
    std::shared_ptr<HTTPReadConfig> http_;

    /// Whether to place work by lane credit. Requires the per-lane CSRs (revision >= 2) AND more
    /// than one lane: with a single lane the field the beats carry is the DECODER index, not a lane,
    /// so there is no per-lane window to meter a decode stream against.
    bool lane_aware_ = false;

    /// Lanes the bitstream has, and the chunk entries the host will let ONE of them owe
    /// (lane_depth_limit(), i.e. OASIS_HTTP_LANE_DEPTH). Both fixed by the bitstream / environment.
    uint8_t lane_count_ = 0;
    size_t  lane_depth_ = 1;

    /// max_batch_chunks(): the hardware's per-batch ceiling, used to cap how much credit a queued
    /// flow is judged to need (its first sub-batch can be no larger than this).
    size_t max_batch_chunks_ = 1;

    /// Rotation cursor for breaking ties between equally loaded lanes, so a run of same-occupancy
    /// picks spreads instead of always landing on the lowest index. Guarded by dispatch_mutex_.
    libstf::stream_t lane_rr_ = 0;

    /// When the dispatcher first found queued work, a free host slot, and NO lane with credit. Reset
    /// on every successful placement. Dispatcher thread only. Its purpose is a deadline: lane credit
    /// comes back in hardware with no host notification, so "no lane admissible" is normally a
    /// microsecond-scale wait -- but if it persists, the pipeline has stopped and the host must find
    /// out rather than poll forever. See kLaneStallGrace in scheduler.cpp.
    std::chrono::steady_clock::time_point lane_stall_since_ {};

    /// So the "more active streams than lanes" warning is printed once, not once per iteration.
    bool lane_span_warned_ = false;

    /// Lanes already reported fatal, one bit per lane. A fatal lane is reported ONCE, not once every
    /// kLaneRetry: the bit is what makes the report an edge rather than a 100 us log storm.
    /// Dispatcher thread only.
    uint32_t lane_fatal_reported_ = 0;

    std::mutex              dispatch_mutex_;
    std::condition_variable dispatch_cv_;
    std::deque<Pending>     queue_;
    bool                    stop_ = false;
    std::thread             dispatcher_;

    // The dispatcher loop: Pops the queue head, picks the least-loaded active stream with a free
    // pipeline slot -- and, where the hardware reports them, a lane with credit -- and dispatches
    // there. Parks on dispatch_cv_ when the queue is empty or every active stream is full; polls it
    // on a short timeout when the only thing missing is lane credit. Reaps finished slots before
    // measuring load.
    void dispatch_loop();

    // Returns the least-loaded active stream that has a free pipeline slot, or nullopt if all are
    // full. Must be called holding dispatch_mutex_. The host-load-only pick: used on every bitstream
    // without per-lane registers, and as the fallback when a lane sample could not be taken.
    std::optional<libstf::stream_t> pick_stream() const;

    // Two CSR reads into a LaneSnapshot, or an invalid snapshot when this bitstream has no per-lane
    // registers (and then it reads nothing at all). MUST be called with no scheduler lock held.
    LaneSnapshot sample_lanes();

    // The lane-aware pick: the least-loaded lane that can still owe `needed` more responses, skipping
    // lanes that are full, fatal, or mid-connect. `needed` is the credit the QUEUE HEAD will ask for.
    //
    // Sets `lane_bound_wait` when it returns nullopt because no lane has CREDIT (as opposed to no
    // stream having a free host slot). The two park differently: a host slot is freed by a completion
    // callback, which signals dispatch_cv_, while lane credit is returned by hardware retiring a
    // response, which signals nothing -- so the caller must poll rather than sleep.
    //
    // Must be called holding dispatch_mutex_; it reads stop_ and advances the rotation cursor.
    std::optional<libstf::stream_t> pick_lane_stream(const LaneSnapshot &view, size_t needed,
                                                     bool &lane_bound_wait);

    // Chunk entries the queued flow will reserve on a lane before it can be armed: the column chunks
    // its HTTP source carries, capped at max_batch_chunks_ because that is the largest sub-batch it
    // can submit at once. 0 for a flow with no HTTP source, which reserves nothing on any lane.
    [[nodiscard]] size_t pending_lane_entries(const Pending &pending) const;

    // Applies a flow on `stream` and registers a completion callback per sink, parking it in the
    // stream's in-flight list. Called only by the dispatcher, with a slot already reserved
    // (enqueued atomically bumped).
    void dispatch_to(libstf::stream_t stream, Pending &pending);

    // Fails every in-flight flow on a lane the hardware has just declared FATAL, because those flows
    // can never complete and nothing else will ever notice: throw_lane_fatal() sits on the ADMISSION
    // path, and PlaceOnLane deliberately routes work away from a fatal lane, so on a board with any
    // healthy lane left that path is never taken again.
    //
    // Called with `lock` (dispatch_mutex_) HELD. It releases and re-acquires it around the CSR reads
    // and the channel callbacks, exactly as the sampling window in dispatch_loop does -- neither
    // belongs under dispatch_mutex_.
    void fail_flows_on_fatal_lanes(const LaneSnapshot &view, std::unique_lock<std::mutex> &lock);

    // Splices in-flight slots whose callback has run into `finished` (without destroying them, so
    // the caller can destroy them outside the locks -- ~OutputHandle join()s the callback thread).
    // Must be called holding ss.mutex.
    void reap(StreamState &ss, std::list<InFlight> &finished);
};

} // namespace oasis
