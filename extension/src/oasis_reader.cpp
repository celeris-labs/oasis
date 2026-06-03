#include "oasis_reader.hpp"

#include "duckdb/common/exception.hpp"
#include "rdma_file_system.hpp"

namespace duckdb {

OasisReader::OasisReader(std::shared_ptr<parcore::ColumnChunkDecoder> column_chunk_decoder,
                         std::shared_ptr<libstf::MemoryPool> memory_pool, const parcore::metadata::Metadata &meta,
                         unique_ptr<FileHandle> file_handle)
    : HardwareReader(std::move(column_chunk_decoder), std::move(memory_pool), meta),
      file_handle_(std::move(file_handle)) {
}

std::shared_ptr<libstf::Buffer> OasisReader::get_chunk_data(const parcore::metadata::ColumnChunk &column_chunk) {
	if (auto *rdma = dynamic_cast<RDMAFileHandle *>(file_handle_.get())) {
		// RDMA-backed file: the FPGA reads the remote bytes straight into the decoder
		// stream, so there is no host staging buffer to allocate or keep alive.
		rdma->ReadIntoStream(decoder(), column_chunk.offset, column_chunk.total_compressed_size);
		return nullptr;
	}

	// Host-copy path (e.g., local disk): Read straight into the libstf buffer.
	auto buffer = allocate_buffer(column_chunk.total_compressed_size);
	file_handle_->Read(buffer->ptr, column_chunk.total_compressed_size, column_chunk.offset);

	input_buffers_.push_back(buffer);
	return buffer;
}

std::vector<std::shared_ptr<libstf::Buffer>> OasisReader::next_column_chunk() {
	auto result = HardwareReader::next_column_chunk();
	// Pop the input buffer which removes the last pointer reference and frees it.
	// The RDMA path pushes no input buffer, so only pop when one is present.
	if (!input_buffers_.empty()) {
		input_buffers_.pop_front();
	}
	return result;
}

} // namespace duckdb
