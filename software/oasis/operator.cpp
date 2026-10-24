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

namespace oasis {

void RDMASourceOperator::apply(libstf::stream_t stream, OasisContext &ctx) {
    ctx.config<RDMAReadConfig>()->enqueue_read(stream, offset_, size_);
}

void RDMASourceOperator::print(std::ostream &os) const {
    os << "RDMASource(offset=" << offset_ << ", size=" << size_ << ")";
}

void HTTPBatchSourceOperator::apply(libstf::stream_t stream, OasisContext &ctx) {
    auto config = ctx.config<HTTPReadConfig>();

    // Batches of at most max_batch_chunks() column chunks: every entry of a batch is pushed before its
    // arm, so a larger batch could never drain. A later batch waits on entries the earlier one is
    // draining.
    const size_t per_batch = config->max_batch_chunks();
    for (size_t lo = 0; lo < chunks_.size(); lo += per_batch) {
        HTTPReadConfig::RequestBatch batch;
        for (size_t i = lo; i < std::min(chunks_.size(), lo + per_batch); i++) {
            config->append_chunk(server_ip_, server_port_, path_, chunks_[i].offset, chunks_[i].size,
                                 batch);
        }
        emit_batch(stream, ctx, *config, batch);

        // The decoder's counters with every batch line: a chunk only retires at tlast, which needs
        // the decoder to accept. in stalled growing: the decoder refuses input; in starved growing:
        // the stall is upstream; idle counts the cycles between chunks. Reading the last profile
        // register stops the profiler, so each line holds the counts since the previous read, and
        // debug mode also disturbs later oasis_stream_profile() readings.
        if (http_debug_enabled()) {
            const auto prof = ctx.config<parcore::ColumnChunkDecoderConfig>()->read_profile(stream);
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

// GETs armed and body bytes requested per lane since the process started, for the stall and exit
// dumps.
namespace {
std::atomic<uint64_t> g_lane_gets[HTTP_MAX_LANES];
std::atomic<uint64_t> g_lane_bytes[HTTP_MAX_LANES];
} // namespace

std::string HttpLaneTrafficSummary() {
    std::ostringstream o;
    o << "host traffic per lane (since process start):";
    for (int l = 0; l < HTTP_MAX_LANES; l++) {
        const auto g = g_lane_gets[l].load();
        if (g != 0) {
            o << " [lane " << l << ": " << g << " GETs, " << g_lane_bytes[l].load() << " body bytes]";
        }
    }
    return o.str();
}

namespace {

constexpr size_t BEAT = 64;

size_t RoundUpToBeat(size_t bytes) { return (bytes + BEAT - 1) / BEAT * BEAT; }

// The handler's state with every batch. A process hung on the board keeps others off it, so the
// last such line is the only reading of the state going into the batch that hung.
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

// Tells the hardware what is coming -- one chunk-length entry per column chunk, then one arm for
// the whole batch -- and DMAs the batch's request text into the lane's request stream as one
// transfer.
void HTTPBatchSourceOperator::emit_batch(libstf::stream_t stream, OasisContext &ctx,
                                         HTTPReadConfig &config,
                                         const HTTPReadConfig::RequestBatch &batch) {
    if (batch.chunk_bytes.empty()) {
        return;
    }
    const uint8_t lane = config.lane_for_stream(stream);

    // The text is padded to whole beats (PadRequestTextToBeat) and copied to the start of a buffer:
    // LOCAL_READ needs an aligned source, and http_req_stream drains the transfer to its TLAST. The
    // tail of the buffer is zeroed, so a stray tail is visibly NUL.
    std::string text = batch.text;
    PadRequestTextToBeat(text);
    const size_t   len = RoundUpToBeat(text.size());
    libstf::Status status;
    auto           buf = libstf::make_buffer(ctx.memory_pool(), len, status);
    if (!buf) {
        throw std::runtime_error("HTTPBatchSourceOperator: could not allocate " +
                                 std::to_string(len) + " bytes for request text");
    }
    auto *bytes = static_cast<std::byte *>(buf->ptr);
    std::memset(bytes, 0, len);
    std::memcpy(bytes, text.data(), text.size());
    buf->size = len;
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
    config.arm_transfer(server_ip_, server_port_, static_cast<uint32_t>(text.size()), lane);
    if (http_debug_enabled()) {
        PrintLaneState(config, lane, batch.chunk_bytes.size(), text.size());
    }
    // The request text goes to the lane's own axis_host_recv stream (sg.dest); the lane rides in
    // the chunk-length register, set above, and never in the DMA descriptor.
    for (size_t off = 0; off < len; off += coyote::MAX_TRANSFER_SIZE) {
        coyote::localSg sg;
        sg.addr   = reinterpret_cast<void *>(bytes + off);
        sg.len    = std::min(len - off, coyote::MAX_TRANSFER_SIZE);
        sg.stream = coyote::STRM_HOST;
        sg.dest   = lane;
        ctx.cthread()->invoke(coyote::CoyoteOper::LOCAL_READ, sg,
                              off + coyote::MAX_TRANSFER_SIZE >= len);
    }
    gets_sent_.fetch_add(batch.request_bytes.size());

    // Wait for the text to have gone out (ARM_READY is !stream_busy). If the query ended first, the
    // buffer would be freed under the DMA, http_req_stream would wait in ST_SEND_DATA for bytes
    // that never come, and every later arm on the lane would be refused.
    config.await_cfg_ready("request text to finish sending", lane, HTTPReadConfig::LaneAdmit::Arm);
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
