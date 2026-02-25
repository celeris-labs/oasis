#pragma once

#include "libstf/common.hpp"
#include <cstdint>
#include <oasis/configuration.hpp>
#include <oasis/parcore/parcore.hpp>
#include <parcore/reader.hpp>

namespace oasis {
namespace parcore {

class RDMAReader : public ::parcore::Reader {
private:
  RDMAReadConfig config;
  uintptr_t offset;
  libstf::stream_t stream;

public:
  RDMAReader(std::shared_ptr<coyote::cThread> cthread,
             std::shared_ptr<libstf::MemoryPool> memory_pool,
             std::shared_ptr<libstf::TLBManager> tlb_manager,
             std::shared_ptr<libstf::OutputBufferManager> output_buffer_manager,
             RDMAReadConfig rdma_config,
             ColumnChunkDecoderConfig column_chunk_config,
             PageDecoderConfig page_config, const Metadata &meta,
             uintptr_t offset, libstf::stream_t stream = 0);

private:
  void send_page(const ColumnChunk &column_chunk, const Page &page,
                 PageType page_type);
};

} // namespace parcore
} // namespace oasis
