#pragma once

#include <libstf/buffer.hpp>
#include <libstf/common.hpp>
#include <libstf/output_handle.hpp>
#include <parcore/metadata/metadata.hpp>

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
 * Fires a ranged HTTP GET from the FPGA's own HTTP client. The handler opens the TCP connection,
 * issues the request, strips the response headers and streams the body straight into the stream's
 * ColumnChunkDecoder -- the bytes never touch host memory, mirroring RDMASourceOperator.
 *
 * `offset`/`size` are the column chunk's byte extent in the remote object; they become an inclusive
 * `Range: bytes=offset-(offset+size-1)` header.
 *
 * Single-session constraint: HttpConfig is one set of parameter CSRs behind one START pulse, so at
 * most one of these may be in flight at a time. Scheduler pins its pipeline depth to 1 on HTTP
 * bitstreams to enforce that (see default_pipeline_depth in scheduler.cpp); do not relax it without
 * giving the hardware per-session request state.
 */
class HTTPSourceOperator final : public SourceOperator {
  public:
    HTTPSourceOperator(std::string path, uint32_t server_ip, uint16_t server_port, uint64_t offset,
                       size_t size)
        : path_(std::move(path))
        , server_ip_(server_ip)
        , server_port_(server_port)
        , offset_(offset)
        , size_(size) {}

    void apply(libstf::stream_t stream, OasisContext &ctx) override;
    void print(std::ostream &os) const override;

  private:
    std::string path_;
    uint32_t    server_ip_;
    uint16_t    server_port_;
    uint64_t    offset_;
    size_t      size_;
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
 * Sink that writes the stream's output to host buffers. apply() acquires the OutputHandle from the
 * OutputBufferManager; the scheduler reads the decoded buffers off handle() once the hardware has written.
 */
class LocalSinkOperator final : public Operator {
  public:
    // `tag` identifies this QuerySplinter's output to the consumer. The scheduler forwards it 
    // verbatim with each batch it pushes onto the result channel.
    explicit LocalSinkOperator(size_t tag = 0) : tag_(tag) {}

    void apply(libstf::stream_t stream, OasisContext &ctx) override;
    void print(std::ostream &os) const override;

    [[nodiscard]] const std::shared_ptr<libstf::OutputHandle> &handle() const { return handle_; }
    [[nodiscard]] size_t                                       tag() const { return tag_; }

  private:
    size_t                                tag_;
    std::shared_ptr<libstf::OutputHandle> handle_;
};

} // namespace oasis
