#pragma once

#include <libstf/buffer.hpp>
#include <libstf/common.hpp>
#include <parcore/metadata/metadata.hpp>

#include <cstdint>
#include <limits>
#include <memory>
#include <ostream>
#include <stdexcept>
#include <vector>

namespace oasis {

class OasisContext;

/**
 * Operator as part of a QuerySplinter, bound to a stream at schedule time. apply() has to run
 * under a lock on the respective stream and configures the hardware components. Single-use.
 */
class Operator {
  public:
    virtual ~Operator() = default;

    virtual void apply(libstf::stream_t stream, OasisContext &ctx) = 0;

    virtual void print(std::ostream &os) const = 0;
};

inline std::ostream &operator<<(std::ostream &os, const Operator &op) {
    op.print(os);
    return os;
}

/**
 * Operator that fetches data into a stream. Hides the transport (e.g., RDMA or local DMA).
 */
class SourceOperator : public Operator {};

/**
 * Triggers a remote RDMA read. The hardware pulls bytes straight into the stream, so no host
 * buffer. Offsets are relative to the remote RDMA region base (see ReadReqConfig::enqueue_read).
 */
class RDMASourceOperator final : public SourceOperator {
  public:
    RDMASourceOperator(uint64_t offset, size_t size) : offset_(offset), size_(size) {
        if (size > std::numeric_limits<uint32_t>::max()) {
            throw std::runtime_error("RDMA read size exceeds 32-bit limit");
        }
    }

    void apply(libstf::stream_t stream, OasisContext &ctx) override;
    void print(std::ostream &os) const override;

  private:
    uint64_t offset_;
    size_t   size_;
};

/**
 * Triggers a local read of of the input host buffer into the stream. Owns the input buffer for the
 * splinter's lifetime so it stays mapped until the hardware has consumed it. Throws if RDMA is 
 * enabled, since only one of the data paths is synthesized into the hardware at a time
 */
class LocalSourceOperator final : public SourceOperator {
  public:
    explicit LocalSourceOperator(std::shared_ptr<libstf::Buffer> input_buffer)
        : input_buffer_(std::move(input_buffer)) {}

    void apply(libstf::stream_t stream, OasisContext &ctx) override;
    void print(std::ostream &os) const override;

  private:
    std::shared_ptr<libstf::Buffer> input_buffer_;
};

/**
 * Programs the configuration (compression, value count, type) via 
 * ColumnChunkDecoderConfig::enqueue_column_chunk.
 */
class DecodeColumnChunkOperator final : public Operator {
  public:
    DecodeColumnChunkOperator(parcore::metadata::Compression compression, uint64_t num_values,
                              libstf::type_t type)
        : compression_(compression), num_values_(num_values), type_(type) {}

    void apply(libstf::stream_t stream, OasisContext &ctx) override;
    void print(std::ostream &os) const override;

  private:
    parcore::metadata::Compression compression_;
    uint64_t                       num_values_;
    libstf::type_t                 type_;
};

/**
 * Sink that writes the stream's output to host buffers pre-allocated by the caller at the exact
 * transfer size. A flow ends in exactly one sink; a transfer larger than a single output-writer
 * buffer spans multiple buffers, which the hardware fills in enqueue order. apply() enqueues every
 * buffer to the FPGA's output writer for `stream`, in order.
 */
class LocalSinkOperator final : public Operator {
  public:
    // `buffers` are the right-sized output buffers the hardware will write into, in write order
    // (each capacity must be a multiple of BYTES_PER_FPGA_TRANSFER). `tag` identifies this flow's
    // output to the consumer since a QuerySplinter's flows can return in any order.
    explicit LocalSinkOperator(std::vector<std::shared_ptr<libstf::Buffer>> buffers, size_t tag = 0)
        : tag_(tag), buffers_(std::move(buffers)) {
        if (buffers_.empty()) {
            throw std::runtime_error("LocalSinkOperator requires at least one buffer");
        }
    }

    explicit LocalSinkOperator(std::shared_ptr<libstf::Buffer> buffer, size_t tag = 0)
        : LocalSinkOperator(std::vector<std::shared_ptr<libstf::Buffer>>{std::move(buffer)}, tag) {}

    void apply(libstf::stream_t stream, OasisContext &ctx) override;
    void print(std::ostream &os) const override;

    [[nodiscard]] const std::vector<std::shared_ptr<libstf::Buffer>> &buffers() const {
        return buffers_;
    }
    [[nodiscard]] size_t tag() const { return tag_; }

  private:
    size_t                                       tag_;
    std::vector<std::shared_ptr<libstf::Buffer>> buffers_;
};

} // namespace oasis
