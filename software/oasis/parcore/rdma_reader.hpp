#pragma once

#include "libstf/common.hpp"
#include <oasis/configuration.hpp>
#include <oasis/parcore/parcore.hpp>
#include <parcore/reader.hpp>

namespace oasis {
namespace parcore {

class RDMAReader : public ::parcore::Reader {
private:
  RDMAReadConfig config;
  size_t offset;
  libstf::stream_t stream;

public:
  RDMAReader(std::shared_ptr<coyote::cThread> cthread,
             std::shared_ptr<libstf::MemoryPool> pool,
             std::shared_ptr<libstf::TLBManager> tlb,
             RDMAReadConfig rdma_config, PageDecoderConfig decoder_config,
             const Metadata &meta, size_t memory_offset,
             libstf::stream_t stream = 0);

private:
  void send_page(const ColumnChunk &column_chunk, const Page &page,
                 PageType page_type);
};

} // namespace parcore
} // namespace oasis
