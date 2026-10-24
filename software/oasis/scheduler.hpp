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
 * On an HTTP bitstream with more than one lane the dispatcher places work by lane credit: stream S
 * is fetched on lane S, so it picks the least-loaded lane that can still owe another response.
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

    // Everything the lane placement reads, so that PlaceOnLane is a pure function the board-free
    // checks can call.
    struct LaneInputs {
        HTTPReadConfig::HTTPLanes           lanes {};     // sampled once per iteration
        std::array<size_t, HTTP_MAX_LANES> host_load {}; // flows placed per stream, not yet retired
        size_t           host_depth     = 1;     // flows one stream may hold (configs and buffers)
        size_t           lane_depth     = 1;     // lane_depth_limit()
        size_t           needed         = 1;     // entries the queue head reserves; 0 = no HTTP source
        libstf::stream_t active         = 0;     // streams the dispatcher may use
        libstf::stream_t rr             = 0;     // rotation cursor for equally loaded lanes
        bool             credit_expired = false; // place even without credit (grace over, shutdown)
    };

    // `stream` unset means park: on a timeout if lane_bound_wait (the hardware frees lane credit
    // silently), otherwise until a completion signals.
    struct LanePlacement {
        std::optional<libstf::stream_t> stream;
        libstf::stream_t                next_rr         = 0;
        bool                            lane_bound_wait = false; // no lane had credit
        bool                            forced          = false; // placed without credit
        size_t                          occ             = 0;     // the lane's occupancy, for logging
    };

    // The lane-aware placement rule: a lane that is full, fatal or reconnecting never holds up a lane
    // that has credit.
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
        // Set when a dispatch failed part way: the stream's queues may hold the failed flow's decoder
        // config and output handle, so no flow is placed here again.
        std::atomic<bool>   out_of_service{false};
    };

    OasisContext                 &ctx_;
    const libstf::stream_t        num_streams_;
    std::atomic<libstf::stream_t> active_streams_;
    std::atomic<size_t>           queue_depth_;

    std::vector<std::unique_ptr<StreamState>> streams_;

    // Lane-aware dispatch; the first four are read once, in the constructor.
    std::shared_ptr<HTTPReadConfig> http_;                 // null without HTTP
    bool                            lane_aware_ = false;   // more than one lane
    size_t                          lane_depth_ = 1;       // lane_depth_limit()
    size_t                          max_batch_chunks_ = 1; // caps the credit a queued flow needs
    libstf::stream_t                lane_rr_ = 0;          // rotation cursor; dispatch_mutex_
    // Since when no lane had credit for the queue head (kLaneStallGrace); dispatcher thread only.
    std::chrono::steady_clock::time_point lane_stall_since_ {};
    // Lanes already reported fatal, one bit each, so a lane is reported once; dispatcher thread only.
    uint32_t lane_fatal_reported_ = 0;

    std::mutex              dispatch_mutex_;
    std::condition_variable dispatch_cv_;
    std::deque<Pending>     queue_;
    bool                    stop_ = false;
    std::thread             dispatcher_;

    // No-progress watchdog (see watchdog_loop). On every HTTP bitstream; its state dump needs
    // OASIS_STALL_DUMP_S.
    bool                    watchdog_on_ = false;
    double                  stall_dump_s_ = 0.0; // 0 = kick only, never dump
    std::thread             watchdog_;
    std::mutex              watchdog_mutex_;
    std::condition_variable watchdog_cv_;
    bool                    watchdog_stop_ = false;
    std::atomic<int64_t>    last_progress_ns_ {0}; // steady_clock time of the last retire or dispatch
    // Channels of the submitted splinters, for the watchdog's kicks. Guarded by dispatch_mutex_.
    std::vector<std::weak_ptr<SplinterResultChannel>> live_channels_;

    void watchdog_loop();
    void note_progress();
    // The queue, each stream's in-flight flows, the HTTP CSR dump and the decoder profiles. Takes
    // dispatch_mutex_ and the stream mutexes itself.
    std::string describe_stall(double stalled_s);

    // The dispatcher loop: Pops the queue head, picks the least-loaded active stream with a free
    // pipeline slot (and a lane with credit, when placing by lane) and dispatches there. Parks on
    // dispatch_cv_ when the queue is empty or every active stream is full, with a short timeout when
    // only lane credit is missing. Reaps finished slots before measuring load.
    void dispatch_loop();

    // Returns the least-loaded active stream that has a free pipeline slot, or nullopt if all are
    // full. Must be called holding dispatch_mutex_. Used when not placing by lane.
    std::optional<libstf::stream_t> pick_stream() const;

    // Whether any active stream can still take work (is not out of service).
    [[nodiscard]] bool any_stream_in_service() const;

    // One dispatch iteration's view of the lanes: two CSR reads, or nothing without HTTP or when the
    // read failed. Called with no scheduler lock held.
    std::optional<HTTPReadConfig::HTTPLanes> sample_lanes();

    // PlaceOnLane for the queue head, which reserves `needed` entries. Sets `lane_bound_wait` when no
    // lane has credit, so the caller polls instead of sleeping. Must be called holding
    // dispatch_mutex_.
    std::optional<libstf::stream_t> pick_lane_stream(const HTTPReadConfig::HTTPLanes &lanes,
                                                     size_t needed, bool &lane_bound_wait);

    // Chunk entries the queued flow reserves on a lane, capped at max_batch_chunks_; 0 without an
    // HTTP source.
    [[nodiscard]] size_t pending_lane_entries(const Pending &pending) const;

    // Applies a flow on `stream` and registers a completion callback per sink, parking it in the
    // stream's in-flight list. Called only by the dispatcher, with a slot already reserved
    // (enqueued atomically bumped).
    void dispatch_to(libstf::stream_t stream, Pending &pending);

    // Fails the in-flight flows of a lane that went fatal. Called with `lock` (dispatch_mutex_) held;
    // releases it around the CSR reads and the channel callbacks.
    void fail_flows_on_fatal_lanes(const HTTPReadConfig::HTTPLanes &lanes,
                                   std::unique_lock<std::mutex> &lock);

    // Splices in-flight slots whose callback has run into `finished` (without destroying them, so
    // the caller can destroy them outside the locks -- ~OutputHandle join()s the callback thread).
    // Must be called holding ss.mutex.
    void reap(StreamState &ss, std::list<InFlight> &finished);
};

} // namespace oasis
