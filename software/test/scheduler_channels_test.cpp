// Tests the scheduler's handling of sinks that read another stream's output channel, without hardware:
// the operators' hardware side is stubbed (they record what they were asked to enqueue), and the test
// plays the interrupt thread by calling Scheduler::handle_completion itself.
//
// Build and run (from software/, after a build in software/build):
//   cmake --build build --target scheduler_channels_test && timeout 120 build/scheduler_channels_test

#include "oasis/scheduler.hpp"

#include <libstf/buffer.hpp>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <thread>
#include <utility>
#include <vector>

namespace oasis {

// -- Stubs for what would reach the hardware --------------------------------------------------------
namespace {
std::mutex                                           g_mutex;
std::vector<std::pair<libstf::stream_t, size_t>>     g_enqueued; // (stream, tag) per enqueued buffer
} // namespace

void RDMASourceOperator::apply(libstf::stream_t, OasisContext &) {}
void RDMASourceOperator::print(std::ostream &os) const { os << "RDMASource"; }
void LocalSourceOperator::apply(libstf::stream_t, OasisContext &) {}
void LocalSourceOperator::print(std::ostream &os) const { os << "LocalSource"; }
void DecodeColumnChunkOperator::apply(libstf::stream_t, OasisContext &) {}
void DecodeColumnChunkOperator::print(std::ostream &os) const { os << "Decode"; }
void LocalSinkOperator::apply(libstf::stream_t stream, OasisContext &) {
    std::lock_guard<std::mutex> lock(g_mutex);
    for (size_t i = 0; i < buffers_.size(); ++i) {
        g_enqueued.emplace_back(stream, tag_);
    }
}
void LocalSinkOperator::print(std::ostream &os) const { os << "Sink(" << tag_ << ")"; }

} // namespace oasis

using namespace oasis;

namespace {

int g_failures = 0;

#define CHECK(cond)                                                                                \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond);          \
            ++g_failures;                                                                          \
        }                                                                                          \
    } while (0)

bool wait_for(const std::function<bool()> &predicate, int timeout_ms = 5000) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    while (!predicate()) {
        if (std::chrono::steady_clock::now() > deadline) {
            return false;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return true;
}

// Stream layout: 0 = DECODE, 1..3 = OUTPUT channels
constexpr libstf::stream_t DECODE = 0;
constexpr libstf::stream_t RAW    = 1;
constexpr libstf::stream_t MASK   = 2;
constexpr libstf::stream_t MAT    = 3;

std::vector<StreamDescription> descriptions(size_t channel_buffers = 4, size_t decode_buffers = 8) {
    std::vector<StreamDescription> streams;
    streams.push_back({StreamCapability::DECODE, 8, 16, 16, decode_buffers});
    for (int c = 0; c < 3; c++) {
        streams.push_back({StreamCapability::OUTPUT, 1, 0, 0, channel_buffers});
    }
    return streams;
}

struct SinkSpec {
    std::optional<libstf::stream_t> channel;
    size_t                          tag;
    size_t                          buffers = 1;
};

OperatorFlow make_flow(const std::vector<SinkSpec> &sinks, size_t decodes = 1) {
    OperatorFlow flow;
    for (size_t i = 0; i < decodes; i++) {
        flow.push_back(std::make_unique<RDMASourceOperator>(0, 64));
        flow.push_back(std::make_unique<DecodeColumnChunkOperator>(parcore::metadata::Compression::RAW, 8,
                                                                  libstf::type_t::INT64_T));
    }
    for (const auto &spec : sinks) {
        std::vector<std::shared_ptr<libstf::Buffer>> buffers;
        for (size_t i = 0; i < spec.buffers; i++) {
            buffers.push_back(std::make_shared<libstf::Buffer>(libstf::Buffer {nullptr, 64, 64}));
        }
        flow.push_back(std::make_unique<LocalSinkOperator>(std::move(buffers), spec.tag, spec.channel));
    }
    return flow;
}

QuerySplinter splinter_of(OperatorFlow flow) {
    QuerySplinter splinter;
    splinter.streams.push_back(std::move(flow));
    return splinter;
}

size_t enqueued_count() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_enqueued.size();
}

// The flow of the Bloom probe: the key chunk's mask and kept keys, then one materialized column
void test_flow_completes_over_independent_channels(Scheduler &scheduler) {
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_enqueued.clear();
    }
    auto result = scheduler.submit(splinter_of(make_flow({{MASK, 10}, {RAW, 11}, {MAT, 12}}, 2)));

    CHECK(wait_for([] { return enqueued_count() == 3; }));
    CHECK(wait_for([&] { return scheduler.in_flight_flows() == 1; }));
    {
        // Each buffer went to the channel its sink named, none to the stream the flow runs on
        std::lock_guard<std::mutex> lock(g_mutex);
        CHECK(g_enqueued[0] == std::make_pair(MASK, size_t(10)));
        CHECK(g_enqueued[1] == std::make_pair(RAW, size_t(11)));
        CHECK(g_enqueued[2] == std::make_pair(MAT, size_t(12)));
    }

    // Complete out of order, the flow must not conclude before the last channel is done
    scheduler.handle_completion(MAT, 8, true);
    scheduler.handle_completion(RAW, 16, true);
    CHECK(scheduler.in_flight_flows() == 1);
    {
        auto first = result.try_get_next_batch();
        CHECK(first.ready && first.batch && first.batch->tag == 12 && first.batch->buffer->size == 8);
        auto second = result.try_get_next_batch();
        CHECK(second.ready && second.batch && second.batch->tag == 11 && second.batch->buffer->size == 16);
        auto none = result.try_get_next_batch();
        CHECK(!none.ready); // Still open, the mask is outstanding
    }

    scheduler.handle_completion(MASK, 1, true);
    CHECK(wait_for([&] { return scheduler.in_flight_flows() == 0; }));
    auto mask = result.get_next_batch();
    CHECK(mask && mask->tag == 10 && mask->buffer->size == 1);
    CHECK(!result.get_next_batch()); // Closed
}

void test_channels_keep_enqueue_order_across_flows(Scheduler &scheduler) {
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_enqueued.clear();
    }
    auto a = scheduler.submit(splinter_of(make_flow({{MASK, 1}, {RAW, 2}})));
    auto b = scheduler.submit(splinter_of(make_flow({{MASK, 3}, {RAW, 4}})));
    CHECK(wait_for([] { return enqueued_count() == 4; }));

    // The n-th interrupt of a channel is the n-th buffer enqueued to it: flow a's before flow b's,
    // however the channels interleave.
    scheduler.handle_completion(RAW, 4, true);
    scheduler.handle_completion(RAW, 4, true);
    scheduler.handle_completion(MASK, 1, true);
    scheduler.handle_completion(MASK, 1, true);

    CHECK(wait_for([&] { return scheduler.in_flight_flows() == 0; }));
    auto a_raw = a.get_next_batch(), a_mask = a.get_next_batch();
    CHECK(a_raw && a_raw->tag == 2);
    CHECK(a_mask && a_mask->tag == 1);
    auto b_raw = b.get_next_batch(), b_mask = b.get_next_batch();
    CHECK(b_raw && b_raw->tag == 4);
    CHECK(b_mask && b_mask->tag == 3);
}

void test_channel_capacity_gates_dispatch() {
    // Two buffers fit on the raw channel: the third flow waits for one of them to complete
    Scheduler scheduler(*reinterpret_cast<OasisContext *>(0x1), descriptions(2));
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_enqueued.clear();
    }
    std::vector<SplinterResultHandle> results;
    for (size_t i = 0; i < 3; i++) {
        results.push_back(scheduler.submit(splinter_of(make_flow({{RAW, 20 + i}}))));
    }
    CHECK(wait_for([] { return enqueued_count() == 2; }));
    CHECK(wait_for([&] { return scheduler.queued_flows() == 1; }));
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    CHECK(enqueued_count() == 2);
    CHECK(scheduler.in_flight_flows() == 2);

    scheduler.handle_completion(RAW, 8, true);
    CHECK(wait_for([] { return enqueued_count() == 3; }));
    scheduler.handle_completion(RAW, 8, true);
    scheduler.handle_completion(RAW, 8, true);
    CHECK(wait_for([&] { return scheduler.in_flight_flows() == 0 && scheduler.queued_flows() == 0; }));
    for (auto &result : results) {
        CHECK(result.get_next_batch().has_value());
        CHECK(!result.get_next_batch().has_value());
    }
}

void test_flow_with_only_channel_sinks_and_own_stream_sink() {
    // A flow may mix a sink on its own stream (bypass/ack) with sinks on channels
    Scheduler scheduler(*reinterpret_cast<OasisContext *>(0x1), descriptions());
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_enqueued.clear();
    }
    auto result = scheduler.submit(splinter_of(make_flow({{std::nullopt, 7}, {MAT, 8}})));
    CHECK(wait_for([] { return enqueued_count() == 2; }));
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        CHECK(g_enqueued[0] == std::make_pair(DECODE, size_t(7)));
        CHECK(g_enqueued[1] == std::make_pair(MAT, size_t(8)));
    }
    scheduler.handle_completion(DECODE, 4, true);
    scheduler.handle_completion(MAT, 4, true);
    CHECK(wait_for([&] { return scheduler.in_flight_flows() == 0; }));
    CHECK(result.get_next_batch().has_value());
    CHECK(result.get_next_batch().has_value());
    CHECK(!result.get_next_batch().has_value());
}

void test_multi_buffer_sink_on_a_channel() {
    // Two buffers of one sink: the first one's interrupt does not conclude the flow
    Scheduler scheduler(*reinterpret_cast<OasisContext *>(0x1), descriptions());
    auto result = scheduler.submit(splinter_of(make_flow({{MAT, 5, 2}, {MASK, 6}})));
    CHECK(wait_for([&] { return scheduler.in_flight_flows() == 1; }));
    scheduler.handle_completion(MAT, 8, false);
    scheduler.handle_completion(MASK, 1, true);
    CHECK(scheduler.in_flight_flows() == 1);
    scheduler.handle_completion(MAT, 8, true);
    CHECK(wait_for([&] { return scheduler.in_flight_flows() == 0; }));
    size_t batches = 0;
    while (result.get_next_batch()) {
        batches++;
    }
    CHECK(batches == 3);
}

void test_rejected_flows() {
    Scheduler scheduler(*reinterpret_cast<OasisContext *>(0x1), descriptions());
    auto throws = [&](OperatorFlow flow) {
        try {
            scheduler.submit(splinter_of(std::move(flow)));
        } catch (const std::runtime_error &) {
            return true;
        }
        return false;
    };
    CHECK(throws(make_flow({{DECODE, 1}}))); // A decode stream is no output channel
    CHECK(throws(make_flow({{libstf::stream_t(9), 1}}))); // No such stream
    CHECK(throws(make_flow({{RAW, 1, 5}}))); // More buffers than the channel's FIFO holds
    CHECK(scheduler.queued_flows() == 0);
}

} // namespace

int main() {
    {
        Scheduler scheduler(*reinterpret_cast<OasisContext *>(0x1), descriptions());
        test_flow_completes_over_independent_channels(scheduler);
        test_channels_keep_enqueue_order_across_flows(scheduler);
    }
    test_channel_capacity_gates_dispatch();
    test_flow_with_only_channel_sinks_and_own_stream_sink();
    test_multi_buffer_sink_on_a_channel();
    test_rejected_flows();

    if (g_failures != 0) {
        std::fprintf(stderr, "%d check(s) failed\n", g_failures);
        return 1;
    }
    std::printf("scheduler_channels_test: all checks passed\n");
    return 0;
}
