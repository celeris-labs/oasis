#include <libstf/profiling.hpp>
#include <oasis/parcore/rdma_reader.hpp>

using libstf::Profiler;

namespace oasis {
namespace parcore {

RDMAReader::RDMAReader(
    std::shared_ptr<coyote::cThread> cthread,
    std::shared_ptr<libstf::MemoryPool> memory_pool,
    std::shared_ptr<libstf::TLBManager> tlb_manager,
    std::shared_ptr<libstf::OutputBufferManager> output_buffer_manager,
    RDMAReadConfig rdma_config, ColumnChunkDecoderConfig column_chunk_config,
    PageDecoderConfig page_config, const Metadata &meta,
    uintptr_t memory_offset, libstf::stream_t stream)
    : Reader(cthread, memory_pool, tlb_manager, output_buffer_manager,
             column_chunk_config, page_config, meta, stream),
      config(rdma_config), offset(memory_offset), stream(stream) {}

const std::string rdma_reader_prefix = "oasis::parcore::RDMAReader::";

void RDMAReader::send_page(const Page &page, PageType page_type) {
  Profiler::open_regions({rdma_reader_prefix + "send_page"});
  config.read(stream, offset + page.offset, page.size);
  Profiler::close_regions({rdma_reader_prefix + "send_page"});
}

} // namespace parcore
} // namespace oasis
