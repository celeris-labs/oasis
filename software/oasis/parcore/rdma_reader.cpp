#include <libstf/profiling.hpp>
#include <oasis/parcore/rdma_reader.hpp>

using libstf::Profiler;

const std::string prefix = "oasis::parcore::RDMAReader::";

namespace oasis {
namespace parcore {

RDMAReader::RDMAReader(
    std::shared_ptr<coyote::cThread> cthread,
    std::shared_ptr<libstf::MemoryPool> memory_pool,
    std::shared_ptr<libstf::TLBManager> tlb_manager,
    std::shared_ptr<libstf::OutputBufferManager> output_buffer_manager,
    std::shared_ptr<::parcore::ColumnChunkDecoderConfig> column_chunk_config,
    std::shared_ptr<::parcore::PageDecoderConfig> page_config,
    std::shared_ptr<RDMAReadConfig> rdma_config,
    const ::parcore::metadata::Metadata &meta, uintptr_t memory_offset,
    libstf::stream_t stream)
    : HardwareReader(cthread, memory_pool, tlb_manager, output_buffer_manager,
                     column_chunk_config, page_config, meta, stream),
      config_(rdma_config), offset_(memory_offset) {}

void RDMAReader::send_page(const ::parcore::metadata::Page &page,
                           ::parcore::PageType page_type) {
  Profiler::open_regions({prefix + "send_page"});
  config_->read(decoder_, offset_ + page.offset, page.size);
  Profiler::close_regions({prefix + "send_page"});
}

} // namespace parcore
} // namespace oasis
