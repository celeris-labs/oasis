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

    // 1. Build the text for every chunk. The ranges live only here now -- there is no descriptor
    //    for the FPGA to rebuild them from.
    HTTPReadConfig::RequestBatch batch;
    for (const auto &c : chunks_) {
        // Ranges are inclusive on both ends and the chunk extent is [offset, offset + size). A
        // zero-length chunk would underflow into a range ending at 2^64-1, i.e. a request for the
        // rest of the object.
        if (c.size == 0) {
            throw std::runtime_error("HTTPBatchSourceOperator: zero-length column chunk at offset " +
                                     std::to_string(c.offset) + " in '" + path_ + "'");
        }
        config->read_streamed(server_ip_, server_port_, path_, c.offset, c.offset + c.size - 1,
                              batch);
    }
    if (batch.body_last.empty()) {
        return;
    }

    // 2. Into a Coyote-visible buffer. LOCAL_READ needs a 64 B-aligned source or it emits databeats
    //    with a broken keep signal, which the memory pool guarantees.
    libstf::Status status;
    text_buffer_ = libstf::make_buffer(ctx.memory_pool(), batch.text.size(), status);
    if (!text_buffer_) {
        throw std::runtime_error("HTTPBatchSourceOperator: could not allocate " +
                                 std::to_string(batch.text.size()) + " bytes for request text");
    }
    std::memcpy(text_buffer_->ptr, batch.text.data(), batch.text.size());
    text_buffer_->size = batch.text.size();
    ctx.tlb_manager()->ensure_tlb_mapping(text_buffer_->ptr, text_buffer_->capacity);

    // 3. Tell the hardware what is coming: one bit per expected response, then the arm. This must
    //    precede the DMA -- the arm is what opens the connection, and the queue entries have to be
    //    in place before any response can arrive.
    config->submit_batch(server_ip_, server_port_, batch);

    // 4. The text itself.
    auto  *byte_ptr = static_cast<std::byte *>(text_buffer_->ptr);
    for (size_t off = 0; off < text_buffer_->size; off += coyote::MAX_TRANSFER_SIZE) {
        coyote::localSg sg;
        sg.addr   = reinterpret_cast<void *>(byte_ptr + off);
        sg.len    = std::min(text_buffer_->size - off, coyote::MAX_TRANSFER_SIZE);
        sg.stream = coyote::STRM_HOST;
        sg.dest   = stream;
        const bool last = off + coyote::MAX_TRANSFER_SIZE >= text_buffer_->size;
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
