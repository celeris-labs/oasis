#pragma once

#include "libstf/common.hpp"
#include <cstdint>
#include <oasis/configuration.hpp>
#include <parcore/configuration.hpp>
#include <parcore/fpga/reader.hpp>

namespace oasis {
namespace parcore {

class RDMAReader : public ::parcore::fpga::HardwareReader {
private:
  std::shared_ptr<RDMAReadConfig> config_;
  uintptr_t offset_;

public:
  RDMAReader(
      std::shared_ptr<coyote::cThread> cthread,
      std::shared_ptr<libstf::MemoryPool> memory_pool,
      std::shared_ptr<libstf::TLBManager> tlb_manager,
      std::shared_ptr<libstf::OutputBufferManager> output_buffer_manager,
      std::shared_ptr<::parcore::ColumnChunkDecoderConfig> column_chunk_config,
      std::shared_ptr<::parcore::PageDecoderConfig> page_config,
      std::shared_ptr<RDMAReadConfig> rdma_config,
      const ::parcore::metadata::Metadata &meta, uintptr_t offset,
      libstf::stream_t stream = 0);

private:
  void send_page(const ::parcore::metadata::Page &page,
                 ::parcore::PageType page_type) override;
};

} // namespace parcore
} // namespace oasis
