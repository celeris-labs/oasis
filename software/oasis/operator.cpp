#include "oasis/operator.hpp"

#include "oasis/configuration.hpp"
#include "oasis/oasis_context.hpp"
#include "parcore/configuration.hpp"

#include <coyote/cDefs.hpp>
#include <coyote/cOps.hpp>

#include <algorithm>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace oasis {

void RDMASourceOperator::apply(libstf::stream_t stream, OasisContext &ctx) {
    ctx.config<RDMAReadConfig>()->enqueue_read(stream, offset_, size_);
}

void RDMASourceOperator::print(std::ostream &os) const {
    os << "RDMASource(offset=" << offset_ << ", size=" << size_ << ")";
}

void HTTPBatchSourceOperator::apply(libstf::stream_t stream, OasisContext &ctx) {
    auto config = ctx.config<HTTPReadConfig>();

    // Split so no batch is larger than the hardware queue. The queue holds one entry per column
    // chunk and every entry is pushed BEFORE the transfer is armed, so an oversized batch does not
    // back-pressure, it deadlocks: the host waits on a free entry, and entries are only freed by
    // responses, which cannot arrive until the arm that comes after them. Successive batches
    // self-pace: the next one blocks on entries the previous one is already draining.
    const size_t per_batch = config->max_batch_chunks();
    for (size_t lo = 0; lo < chunks_.size(); lo += per_batch) {
        HTTPReadConfig::RequestBatch batch;
        for (size_t i = lo; i < std::min(chunks_.size(), lo + per_batch); i++) {
            config->append_chunk(server_ip_, server_port_, path_, chunks_[i].offset, chunks_[i].size,
                                 batch);
        }
        emit_batch(stream, ctx, *config, batch);

        // The decoder's handshake counters alongside every batch line. Without them a trace shows
        // the queue filling but not WHY nothing retires, because a chunk only retires when it
        // reaches tlast, and that needs the decoder to be accepting.
        //
        //   in stalled climbing   -> the decoder refuses input; nothing can retire
        //   in starved climbing   -> the decoder is idle waiting; the stall is upstream
        //   out handshakes flat   -> the decoder is not producing, so it is waiting, not busy
        if (http_debug_enabled()) {
            const auto prof = ctx.config<parcore::ColumnChunkDecoderConfig>()->read_profile(stream);
            // idle is the counter that was missing, and it is the one that matters. handshake /
            // starved / stalled only describe cycles WHILE a column chunk is streaming; the
            // profiler sits in IDLE between chunks and counts none of them. So a decoder that
            // looks 80% stalled in-chunk can still be idle most of the wall clock, waiting for the
            // host to configure the next chunk -- with the receive buffer already full of data it
            // has not been told about yet. Without this field the two cannot be told apart.
            std::fprintf(stderr,
                         "[oasis-http]   decoder in: hs=%llu starved=%llu stalled=%llu idle=%llu | "
                         "out: hs=%llu starved=%llu stalled=%llu idle=%llu\n",
                         static_cast<unsigned long long>(prof.in.handshakes_cycles),
                         static_cast<unsigned long long>(prof.in.starved_cycles),
                         static_cast<unsigned long long>(prof.in.stalled_cycles),
                         static_cast<unsigned long long>(prof.in.idle_cycles),
                         static_cast<unsigned long long>(prof.out.handshakes_cycles),
                         static_cast<unsigned long long>(prof.out.starved_cycles),
                         static_cast<unsigned long long>(prof.out.stalled_cycles),
                         static_cast<unsigned long long>(prof.out.idle_cycles));
        }
    }
}

// Per-lane host-side traffic counters for the exit/stall dump: GETs armed and body bytes requested,
// per lane, since the process started.
namespace {
std::atomic<uint64_t> g_lane_gets[HTTP_LANE_SLOTS];
std::atomic<uint64_t> g_lane_bytes[HTTP_LANE_SLOTS];
} // namespace

std::string HttpLaneTrafficSummary() {
    std::ostringstream o;
    o << "host traffic per lane (since process start):";
    for (int l = 0; l < HTTP_LANE_SLOTS; l++) {
        const auto g = g_lane_gets[l].load();
        if (g != 0) {
            o << " [lane " << l << ": " << g << " GETs, " << g_lane_bytes[l].load() << " body bytes]";
        }
    }
    return o.str();
}

namespace {

// A batch carries ONE lane for all its chunks, so every chunk in it must belong to the stream
// this operator runs on. That holds when each flow submits its own chunk (OASIS_HTTP_BATCH=0):
// the decode config and the request are applied on the same stream by construction.
//
// It does NOT hold for a row-group batch, whose chunks come from sibling flows the scheduler
// may have placed on other streams. With one decoder that was harmless -- every stream was 0.
// With more than one it would route a column's bytes to a decoder configured for a different
// column, which corrupts silently. Refuse rather than corrupt.
void RefuseCrossStreamBatch(OasisContext &ctx, const HTTPReadConfig::RequestBatch &batch) {
    if (batch.chunk_bytes.size() > 1) {
        const auto decoders = ctx.config<parcore::ColumnChunkDecoderConfig>()->num_decoders();
        if (decoders > 1) {
            throw std::runtime_error(
                "HTTPBatchSourceOperator: a multi-chunk batch cannot target " +
                std::to_string(decoders) +
                " decoders -- its chunks may belong to different streams. Run with "
                "OASIS_HTTP_BATCH=0 (one request per column chunk), or give the batch a per-chunk "
                "lane before enabling multi-decoder batching. Each lane owns its own TCP connection "
                "and its own request-text stream, so a batch spanning lanes has no single "
                "destination to be DMA'd to.");
        }
    }
}

constexpr size_t BEAT = 64;

size_t RoundUpToBeat(size_t bytes) { return (bytes + BEAT - 1) / BEAT * BEAT; }

// The handler's state with every revision-2 batch: a hang blocks the board for other processes, so
// the last line before it is the only reading of the state going into the batch that hung.
void PrintLaneState(HTTPReadConfig &config, uint8_t lane, size_t chunks, size_t text_bytes) {
    const auto f  = config.inflight();
    const auto st = config.stall();
    std::fprintf(stderr,
                 "[oasis-http] batch: lane %u, %zu column chunks, %zu bytes of request text | %s | "
                 "%s\n",
                 unsigned(lane), chunks, text_bytes, f.describe().c_str(),
                 st.any() ? st.describe().c_str() : "no stalls");
    std::fprintf(stderr, "[oasis-http]   %s\n", config.lanes().describe().c_str());
    if (st.status_bad) {
        std::fprintf(stderr, "[oasis-http]   %s\n", config.response().describe().c_str());
    }
}

} // namespace

// Tells the hardware what is coming -- one chunk-length entry per column chunk, then an arm per
// transfer -- and DMAs the request text into the lane's request stream.
//
// Revision 2 sends the whole batch as ONE transfer. Revision 6 sends ONE TRANSFER PER GET: its GET
// credit counts arms (+1 per arm, -1 per framed response), so an arm announcing several GETs would
// be charged once and retired several times. There the (GET_CREDIT+1)-th GET of a lane is armed only
// after that lane's oldest response has been framed, on this (dispatcher) thread. That cannot
// deadlock: the response's decoder config and output buffer were placed before its GET.
void HTTPBatchSourceOperator::emit_batch(libstf::stream_t stream, OasisContext &ctx,
                                         HTTPReadConfig &config,
                                         const HTTPReadConfig::RequestBatch &batch) {
    if (batch.chunk_bytes.empty()) {
        return;
    }
    RefuseCrossStreamBatch(ctx, batch);
    const uint8_t lane = config.lane_for_stream(stream);
    const bool    toe  = config.toe_ring();

    // Each transfer is padded to whole beats (PadRequestTextToBeat) and starts at a 64-byte aligned
    // offset of one buffer: LOCAL_READ needs an aligned source, and http_req_stream drains every
    // transfer to its TLAST. The tail of the buffer is zeroed, so a stray tail is visibly NUL.
    std::vector<std::string> texts = toe ? HTTPReadConfig::SplitRequests(batch)
                                         : std::vector<std::string> {batch.text};
    std::vector<size_t>      offsets;
    size_t                   total = 0;
    for (auto &text : texts) {
        PadRequestTextToBeat(text);
        offsets.push_back(total);
        total += RoundUpToBeat(text.size());
    }
    libstf::Status status;
    auto           buf = libstf::make_buffer(ctx.memory_pool(), total, status);
    if (!buf) {
        throw std::runtime_error("HTTPBatchSourceOperator: could not allocate " +
                                 std::to_string(total) + " bytes for request text");
    }
    auto *bytes = static_cast<std::byte *>(buf->ptr);
    std::memset(bytes, 0, total);
    for (size_t i = 0; i < texts.size(); i++) {
        std::memcpy(bytes + offsets[i], texts[i].data(), texts[i].size());
    }
    buf->size = total;
    ctx.tlb_manager()->ensure_tlb_mapping(buf->ptr, buf->capacity);
    // Lives as long as this operator, i.e. until the flow retires, which needs every response.
    text_buffers_.push_back(buf);

    lane_.store(lane);
    gets_total_.fetch_add(batch.request_bytes.size());
    g_lane_gets[lane].fetch_add(batch.request_bytes.size());
    for (const auto b : batch.chunk_bytes) {
        g_lane_bytes[lane].fetch_add(b);
    }

    config.push_entries(batch, lane);
    for (size_t i = 0; i < texts.size(); i++) {
        config.arm_transfer(server_ip_, server_port_, static_cast<uint32_t>(texts[i].size()), lane);
        if (toe) {
            // Proof the arm was taken before anything else is written -- the next GET's arm, or the
            // next flow's entries, would otherwise rewrite the registers it is sampled from.
            config.await_arm_taken(lane);
        } else if (http_debug_enabled()) {
            PrintLaneState(config, lane, batch.chunk_bytes.size(), texts[i].size());
        }
        // The request text goes to the lane's own axis_host_recv stream (sg.dest); the lane rides in
        // the chunk-length register, set above, and never in the DMA descriptor.
        const size_t len = RoundUpToBeat(texts[i].size());
        for (size_t off = 0; off < len; off += coyote::MAX_TRANSFER_SIZE) {
            coyote::localSg sg;
            sg.addr   = reinterpret_cast<void *>(bytes + offsets[i] + off);
            sg.len    = std::min(len - off, coyote::MAX_TRANSFER_SIZE);
            sg.stream = coyote::STRM_HOST;
            sg.dest   = lane;
            ctx.cthread()->invoke(coyote::CoyoteOper::LOCAL_READ, sg,
                                  off + coyote::MAX_TRANSFER_SIZE >= len);
        }
        gets_sent_.fetch_add(toe ? 1 : batch.request_bytes.size());
    }

    if (!toe) {
        // Revision 2: wait for the text to have gone out (ARM_READY is !stream_busy there). If the
        // query ended first, the buffer would be freed under the DMA, http_req_stream would wait in
        // ST_SEND_DATA for bytes that never come, and every later arm on the lane would be refused.
        // On revision 6 ARM_READY also carries the GET credit, so the same wait would hold this
        // thread until a response is framed; the arm-taken proof above is enough there.
        config.await_cfg_ready("request text to finish sending", lane, HTTPReadConfig::LaneAdmit::Arm);
    } else if (http_debug_enabled()) {
        std::fprintf(stderr,
                     "[oasis-http] toe batch: lane %u, %zu column chunk(s), %zu GET(s), %zu bytes of "
                     "request text | %s\n",
                     unsigned(lane), batch.chunk_bytes.size(), texts.size(), total,
                     config.lanes().describe().c_str());
    }
}

void HTTPBatchSourceOperator::print(std::ostream &os) const {
    os << "HTTPBatchSource(path=" << path_ << ", chunks=" << chunks_.size();
    for (const auto &c : chunks_) {
        os << " [" << c.offset << "+" << c.size << "]";
    }
    os << ", lane=" << lane_.load() << ", GETs sent " << gets_sent_.load() << " / "
       << gets_total_.load() << ")";
}

void LocalSourceOperator::apply(libstf::stream_t stream, OasisContext &ctx) {
    // LOCAL_READ into `stream`, chunked at MAX_TRANSFER_SIZE. The TLB mapping must exist first.
    const auto &buffer   = input_buffer_;
    auto       *byte_ptr = static_cast<const std::byte *>(buffer->ptr);
    ctx.tlb_manager()->ensure_tlb_mapping(buffer->ptr, buffer->capacity);

    auto cthread = ctx.cthread();
    for (size_t off = 0; off < buffer->size; off += coyote::MAX_TRANSFER_SIZE) {
        auto  *curr_ptr   = reinterpret_cast<void *>(const_cast<std::byte *>(byte_ptr) + off);
        size_t input_size = std::min(buffer->size - off, coyote::MAX_TRANSFER_SIZE);

        coyote::localSg sg;
        // Coyote needs a 64B-aligned source address or it emits databeats with a broken keep
        // signal.
        assert((reinterpret_cast<uintptr_t>(curr_ptr) % 64) == 0);
        sg.addr   = curr_ptr;
        sg.len    = input_size;
        sg.stream = coyote::STRM_HOST;
        sg.dest   = stream;

        bool last_transfer = off + coyote::MAX_TRANSFER_SIZE >= buffer->size;
        cthread->invoke(coyote::CoyoteOper::LOCAL_READ, sg, last_transfer);
    }
}

void LocalSourceOperator::print(std::ostream &os) const {
    os << "LocalSource(ptr=" << input_buffer_->ptr << ", size=" << input_buffer_->size << ")";
}

void DecodeColumnChunkOperator::apply(libstf::stream_t stream, OasisContext &ctx) {
    auto config = ctx.config<parcore::ColumnChunkDecoderConfig>();
    config->enqueue_column_chunk(stream, compression_, num_values_, type_);
}

void DecodeColumnChunkOperator::print(std::ostream &os) const {
    os << "DecodeColumnChunk(compression=" << compression_ << ", num_values=" << num_values_
       << ", type=" << type_ << ")";
}

void LocalSinkOperator::apply(libstf::stream_t stream, OasisContext &ctx) {
    libstf::stream_mask_t mask;
    mask.set(stream);
    handle_ = ctx.output_buffer_manager()->acquire_output_handle(mask);
}

void LocalSinkOperator::print(std::ostream &os) const {
    os << "HostBufferSink(tag=" << tag_ << ")";
}

} // namespace oasis
