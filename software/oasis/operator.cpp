#include "oasis/operator.hpp"

#include "oasis/configuration.hpp"
#include "oasis/oasis_context.hpp"
#include "parcore/configuration.hpp"

#include <coyote/cDefs.hpp>
#include <coyote/cOps.hpp>

#include <cassert>
#include <stdexcept>
#include <string>

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
}

void HTTPSourceOperator::print(std::ostream &os) const {
    os << "HTTPSource(path=" << path_ << ", range=[" << offset_ << "," << (offset_ + size_ - 1)
       << "])";
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
