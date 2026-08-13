#include "oasis/operator.hpp"

#include "oasis/configuration.hpp"
#include "oasis/oasis_context.hpp"
#include "parcore/configuration.hpp"

#include <coyote/cDefs.hpp>
#include <coyote/cOps.hpp>

#include <cassert>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#include <string>
#include <thread>

namespace oasis {

void RDMASourceOperator::apply(libstf::stream_t stream, OasisContext &ctx) {
    ctx.config<RDMAReadConfig>()->enqueue_read(stream, offset_, size_);
}

void RDMASourceOperator::print(std::ostream &os) const {
    os << "RDMASource(offset=" << offset_ << ", size=" << size_ << ")";
}

void HTTPSourceOperator::apply(libstf::stream_t stream, OasisContext &ctx) {
    // HTTP ranges are inclusive on both ends, the column chunk extent is [offset, offset + size).
    // A zero-length chunk would underflow that conversion into a range ending at 2^64-1, which the
    // hardware would happily turn into a request for the rest of the object.
    if (size_ == 0) {
        throw std::runtime_error("HTTPSourceOperator: zero-length column chunk at offset " +
                                 std::to_string(offset_) + " in '" + path_ + "'");
    }
    ctx.config<HTTPReadConfig>()->read(stream, server_ip_, server_port_, path_, offset_,
                                       offset_ + size_ - 1, /*session_id*/ 0);

    // Debug-gated stage tracing. The HTTP handler going back to IDLE only proves the transfer
    // finished at the network edge; it says nothing about whether the body reached the decoder or
    // whether the decoder emitted anything. Sampling the decoder's in/out handshake counters
    // alongside the handler state localises a stall to one stage:
    //   in=0            -> body never arrived (strip_http / normalizer dropped it)
    //   in>0, out=0     -> decoder consumed but produced nothing (config or decode failure)
    //   in>0, out>0     -> decoder produced output, loss is in OutputWriter / OBM delivery
    // Detached and best-effort: it only reads CSRs, and OasisContext owns both configs for the
    // whole session so they outlive the samples.
    if (http_debug_enabled()) {
        std::thread([&ctx, stream] {
            auto http = ctx.config<HTTPReadConfig>();
            auto dec  = ctx.config<parcore::ColumnChunkDecoderConfig>();
            for (const int ms : {200, 1000, 5000}) {
                std::this_thread::sleep_for(std::chrono::milliseconds(ms));
                const auto prof = dec->read_profile(stream);
                std::fprintf(stderr,
                             "[oasis-http]   t=%-5dms %s\n"
                             "[oasis-http]              decoder in: hs=%llu starved=%llu stalled=%llu | "
                             "out: hs=%llu starved=%llu stalled=%llu\n",
                             ms, HTTPReadConfig::describe_status(http->debug_status()).c_str(),
                             static_cast<unsigned long long>(prof.in.handshakes_cycles),
                             static_cast<unsigned long long>(prof.in.starved_cycles),
                             static_cast<unsigned long long>(prof.in.stalled_cycles),
                             static_cast<unsigned long long>(prof.out.handshakes_cycles),
                             static_cast<unsigned long long>(prof.out.starved_cycles),
                             static_cast<unsigned long long>(prof.out.stalled_cycles));
            }
            // Coyote's shell counters close the last gap: "Sent local writes" says whether the
            // OutputWriter ever issued a host DMA, and "Notifications received" whether the
            // completion interrupt made it back. Decoder counters cannot see either.
            std::fflush(stderr);
            ctx.cthread()->printDebug();
        }).detach();
    }
}

void HTTPSourceOperator::print(std::ostream &os) const {
    os << "HTTPSource(path=" << path_ << ", range=[" << offset_ << "," << (offset_ + size_ - 1)
       << "])";
}

void HTTPBatchSourceOperator::apply(libstf::stream_t stream, OasisContext &ctx) {
    auto config = ctx.config<HTTPReadConfig>();

    // Split so no batch is larger than the hardware queue. The queue holds one entry per expected
    // response and every entry is pushed BEFORE the transfer is armed, so an oversized batch does
    // not back-pressure, it deadlocks: the host waits on a free entry, and entries are only freed
    // by responses, which cannot arrive until the arm that comes after them.
    //
    // A wide scale-30 row group at a 768 KiB chunk is thousands of GETs, so this is the normal path
    // rather than a guard against an exotic case. Successive sub-batches self-pace: the next one
    // blocks on entries the previous one is already draining.
    const size_t max_per_batch = config->max_batch_requests();
    size_t       chunk_lo      = 0;
    while (chunk_lo < chunks_.size()) {
        HTTPReadConfig::RequestBatch batch;
        size_t                       chunk_hi = chunk_lo;
        while (chunk_hi < chunks_.size()) {
            HTTPReadConfig::RequestBatch probe;
            build_chunk(*config, chunks_[chunk_hi], probe);
            if (!batch.body_last.empty() &&
                batch.body_last.size() + probe.body_last.size() > max_per_batch) {
                break;
            }
            batch.text += probe.text;
            batch.body_last.insert(batch.body_last.end(), probe.body_last.begin(),
                                   probe.body_last.end());
            chunk_hi++;
        }
        // A single column chunk that alone exceeds the queue would loop forever otherwise.
        if (batch.body_last.size() > max_per_batch) {
            throw std::runtime_error(
                "HTTPBatchSourceOperator: column chunk at offset " +
                std::to_string(chunks_[chunk_lo].offset) + " needs " +
                std::to_string(batch.body_last.size()) +
                " GETs, more than the hardware queue holds (" + std::to_string(max_per_batch) +
                "). Raise OASIS_HTTP_CHUNK_BYTES or the queue depth.");
        }
        emit_batch(stream, ctx, batch);
        chunk_lo = chunk_hi;
    }
}

void HTTPBatchSourceOperator::build_chunk(HTTPReadConfig &config, const Chunk &c,
                                          HTTPReadConfig::RequestBatch &batch) {
    // Ranges are inclusive on both ends and the chunk extent is [offset, offset + size). A
    // zero-length chunk would underflow into a range ending at 2^64-1, i.e. a request for the
    // rest of the object.
    if (c.size == 0) {
        throw std::runtime_error("HTTPBatchSourceOperator: zero-length column chunk at offset " +
                                 std::to_string(c.offset) + " in '" + path_ + "'");
    }
    config.read_streamed(server_ip_, server_port_, path_, c.offset, c.offset + c.size - 1, batch);
}

void HTTPBatchSourceOperator::emit_batch(libstf::stream_t stream, OasisContext &ctx,
                                         const HTTPReadConfig::RequestBatch &batch) {
    if (batch.body_last.empty()) {
        return;
    }
    auto config = ctx.config<HTTPReadConfig>();

    // Into a Coyote-visible buffer. LOCAL_READ needs a 64 B-aligned source or it emits databeats
    // with a broken keep signal, which the memory pool guarantees.
    //
    // Kept in a vector, not a single member: the DMA is asynchronous, so a sub-batch's buffer must
    // stay alive until its transfer completes. Overwriting one member per sub-batch would free the
    // bytes the hardware is still reading.
    libstf::Status status;
    auto           buf = libstf::make_buffer(ctx.memory_pool(), batch.text.size(), status);
    if (!buf) {
        throw std::runtime_error("HTTPBatchSourceOperator: could not allocate " +
                                 std::to_string(batch.text.size()) + " bytes for request text");
    }
    std::memcpy(buf->ptr, batch.text.data(), batch.text.size());
    buf->size = batch.text.size();
    ctx.tlb_manager()->ensure_tlb_mapping(buf->ptr, buf->capacity);
    text_buffers_.push_back(buf);

    // Tell the hardware what is coming: one bit per expected response, then the arm. This must
    // precede the DMA -- the arm is what opens the connection, and the queue entries have to be in
    // place before any response can arrive.
    config->submit_batch(server_ip_, server_port_, batch);

    // Then the text itself.
    auto *byte_ptr = static_cast<std::byte *>(buf->ptr);
    for (size_t off = 0; off < buf->size; off += coyote::MAX_TRANSFER_SIZE) {
        coyote::localSg sg;
        sg.addr   = reinterpret_cast<void *>(byte_ptr + off);
        sg.len    = std::min(buf->size - off, coyote::MAX_TRANSFER_SIZE);
        sg.stream = coyote::STRM_HOST;
        sg.dest   = stream;
        const bool last = off + coyote::MAX_TRANSFER_SIZE >= buf->size;
        ctx.cthread()->invoke(coyote::CoyoteOper::LOCAL_READ, sg, last);
    }
}

void HTTPBatchSourceOperator::print(std::ostream &os) const {
    os << "HTTPBatchSource(path=" << path_ << ", chunks=" << chunks_.size() << ")";
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
