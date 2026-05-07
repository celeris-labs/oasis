#pragma once

#include <oasis/configuration.hpp>
#include <parcore/configuration.hpp>
#include <parcore/hardware_reader.hpp>

namespace oasis {
namespace parcore {

class RDMAReader : public ::parcore::HardwareReader {
  public:
    RDMAReader(std::shared_ptr<::parcore::ColumnChunkDecoder> column_chunk_decoder,
               std::shared_ptr<libstf::MemoryPool>            memory_pool,
               std::shared_ptr<RDMAReadConfig> rdma_config, uintptr_t offset,
               const ::parcore::metadata::Metadata &meta);

  private:
    std::shared_ptr<RDMAReadConfig> rdma_config_;
    uintptr_t                       offset_;

    std::shared_ptr<libstf::Buffer> get_page_data(const ::parcore::metadata::Page &page,
                                                  ::parcore::PageType page_type) override;
};

} // namespace parcore
} // namespace oasis
