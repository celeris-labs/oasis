#pragma once

#include <libstf/buffer.hpp>
#include <libstf/common.hpp>
#include <libstf/output_handle.hpp>
#include <parcore/metadata/metadata.hpp>

#include <functional>
#include <cstdint>
#include <memory>
#include <ostream>
#include <string>

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
 * buffer. Offsets are relative to the remote RDMA region base (see RDMAReadConfig::enqueue_read).
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
 * DMA read host bytes into the stream via Coyote LOCAL_READ. Owns the input buffer for the
 * splinter's lifetime so it stays mapped until the FPGA has consumed it.
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
 * Programs the generic StreamConfig for the stream currently chosen by the scheduler.
 *
 * This is used by the normal scan to route stream 0 through the Bloom-bypass path, and by the
 * Bloom path to route BUILD/PROBE through the Bloomfilter path.
 */
class StreamConfigOperator final : public Operator {
  public:
    StreamConfigOperator(libstf::type_t type, uint8_t select)
        : type_(type), select_(select) {}

    void apply(libstf::stream_t stream, OasisContext &ctx) override;
    void print(std::ostream &os) const override;

  private:
    libstf::type_t   type_;
    uint8_t select_;
};

/**
 * Generic single-use operator for small configuration actions that do not deserve a dedicated
 * Operator subclass yet.
 *
 * This is intentionally narrow: it keeps the scheduler abstraction intact while allowing special
 * paths such as the Bloomfilter smoke-test to enqueue BFConfig/TLAST writes in the same ordered
 * operator chain as StreamConfig, Decode and Source.
 */
class CallbackOperator final : public Operator {
  public:
    using Callback = std::function<void(libstf::stream_t, OasisContext &)>;

    CallbackOperator(std::string name, Callback callback)
        : name_(std::move(name)), callback_(std::move(callback)) {}

    void apply(libstf::stream_t stream, OasisContext &ctx) override;
    void print(std::ostream &os) const override;

  private:
    std::string name_;
    Callback    callback_;
};

/**
 * Sink that writes the stream's output to host buffers. apply() acquires the OutputHandle from the
 * OutputBufferManager; the scheduler reads the decoded buffers off handle() once the hardware has written.
 */
class HostBufferSinkOperator final : public Operator {
  public:
    void apply(libstf::stream_t stream, OasisContext &ctx) override;
    void print(std::ostream &os) const override;

    [[nodiscard]] const std::shared_ptr<libstf::OutputHandle> &handle() const { return handle_; }

  private:
    std::shared_ptr<libstf::OutputHandle> handle_;
};

} // namespace oasis