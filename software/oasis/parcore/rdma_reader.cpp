#include <libstf/profiling.hpp>
#include <oasis/parcore/rdma_reader.hpp>

using libstf::profiler;

namespace oasis {
namespace parcore {

RDMAReader::RDMAReader(std::shared_ptr<coyote::cThread> cthread,
                       std::shared_ptr<libstf::MemoryPool> pool,
                       std::shared_ptr<libstf::TLBManager> tlb,
                       RDMAReadConfig rdma_config,
                       PageDecoderConfig decoder_config, const Metadata &meta,
                       size_t memory_offset, libstf::stream_t stream)
    : Reader(cthread, pool, tlb, decoder_config, meta, nullptr, stream),
      config(rdma_config), offset(memory_offset), stream(stream) {}

const std::string rdma_reader_prefix = "oasis::parcore::RDMAReader::";

void RDMAReader::send_page(const ColumnChunk &column_chunk, const Page &page,
                           PageType page_type) {
  profiler::open_regions({rdma_reader_prefix + "send_page"});
  config.read(stream, offset + page.offset, page.size);
  profiler::close_regions({rdma_reader_prefix + "send_page"});
}

} // namespace parcore
} // namespace oasis
