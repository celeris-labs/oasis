#pragma once

#include <libstf/buffer.hpp>
#include <libstf/common.hpp>
#include <parcore/metadata/metadata.hpp>

#include <memory>
#include <ostream>

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
    RDMASourceOperator(uint64_t offset, size_t size) : offset_(offset), size_(size) {}

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
 * Sink that writes the stream's output to a host buffer pre-allocated by the caller at the exact 
 * decoded size. apply() enqueues that buffer directly to the FPGA's output writer for `stream`.
 */
class LocalSinkOperator final : public Operator {
  public:
    // `buffer` is the right-sized output buffer the hardware will write into (its capacity must be 
    // a multiple of BYTES_PER_FPGA_TRANSFER). `tag` identifies this flow's output to the
    // consumer since a QuerySplinter's flows can return in any order.
    explicit LocalSinkOperator(std::shared_ptr<libstf::Buffer> buffer, size_t tag = 0)
        : tag_(tag), buffer_(std::move(buffer)) {}

    void apply(libstf::stream_t stream, OasisContext &ctx) override;
    void print(std::ostream &os) const override;

    [[nodiscard]] const std::shared_ptr<libstf::Buffer> &buffer() const { return buffer_; }
    [[nodiscard]] size_t                                 tag()    const { return tag_; }

  private:
    size_t                          tag_;
    std::shared_ptr<libstf::Buffer> buffer_;
};

} // namespace oasis
