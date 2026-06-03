#pragma once

#include "duckdb.hpp"
#include "duckdb/common/file_system.hpp"

#include <parcore/hardware_reader.hpp>

#include <deque>

namespace duckdb {

/**
 * ParCore reader that loads column chunk bytes through DuckDB's FileSystem (a FileHandle) and hands 
 * them to the hardware column chunk decoder. For RDMA, it directly sends the data to the 
 * corresponding hardware column chunk decoder. In all other cases, the data is first read into an 
 * input buffer.
 */
class OasisReader : public parcore::HardwareReader {
public:
	OasisReader(std::shared_ptr<parcore::ColumnChunkDecoder> column_chunk_decoder,
	            std::shared_ptr<libstf::MemoryPool> memory_pool, const parcore::metadata::Metadata &meta,
	            unique_ptr<FileHandle> file_handle);

	[[nodiscard]] std::vector<std::shared_ptr<libstf::Buffer>> next_column_chunk() override;
protected:
	std::shared_ptr<libstf::Buffer> get_chunk_data(const parcore::metadata::ColumnChunk &column_chunk) override;

private:
	unique_ptr<FileHandle> file_handle_;

    // Dequeue keeping the input buffers alive until they were consumed.
	std::deque<std::shared_ptr<libstf::Buffer>> input_buffers_;
};

} // namespace duckdb
