#include <libstf/profiling.hpp>
#include <oasis/parcore/rdma_reader.hpp>

using libstf::Profiler;

const std::string prefix = "oasis::parcore::RDMAReader::";

namespace oasis {
namespace parcore {

RDMAReader::RDMAReader(std::shared_ptr<::parcore::ColumnChunkDecoder> column_chunk_decoder,
                       std::shared_ptr<libstf::MemoryPool>            memory_pool,
                       std::shared_ptr<RDMAReadConfig> rdma_config, uintptr_t offset,
                       const ::parcore::metadata::Metadata &meta)
    : HardwareReader(std::move(column_chunk_decoder), std::move(memory_pool), meta),
      rdma_config_(std::move(rdma_config)), offset_(offset) {}

std::shared_ptr<libstf::Buffer> RDMAReader::get_chunk_data(const ::parcore::metadata::ColumnChunk &column_chunk) {
    Profiler::open_regions({prefix + "send_chunk"});
    rdma_config_->read(decoder_, offset_ + column_chunk.offset,
                       column_chunk.total_compressed_size);
    Profiler::close_regions({prefix + "send_chunk"});
    return nullptr;
}

} // namespace parcore
} // namespace oasis
