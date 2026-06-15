#pragma once

#include "duckdb.hpp"
#include "libstf_buffer_vector_buffer.hpp"
#include "oasis_context_cache_entry.hpp"
#include "oasis_filter.hpp"
#include "parcore/column_chunk_decoder.hpp"
#include "parcore/file_reader.hpp"
#include "parcore/metadata/metadata.hpp"

#include <parcore/reader.hpp>

namespace duckdb {

struct OasisScanBindData : public TableFunctionData {
	string filename;
	parcore::metadata::Metadata metadata;
	vector<OasisFilterLayer> filter_layers;
};

struct OasisScanGlobalState : public GlobalTableFunctionState {
	std::shared_ptr<arrow::io::ReadableFile> file;
	std::vector<std::shared_ptr<parcore::ColumnChunkDecoder>> decoders;
	std::vector<std::unique_ptr<parcore::FileReader>> readers;

	vector<size_t> hardware_column_ids;
	vector<libstf::stream_t> stream_ids;
	vector<size_t> output_hardware_indices;

	size_t next_group = 0;
	size_t total_groups = 0;
	std::vector<std::vector<std::shared_ptr<libstf::Buffer>>> current_buffers;
	size_t current_buf_idx = 0;
	size_t current_buf_offset = 0;
};

struct OasisScanLocalState : public LocalTableFunctionState {};

unique_ptr<FunctionData> OasisScanBind(ClientContext &context, TableFunctionBindInput &input,
                                       vector<LogicalType> &return_types, vector<string> &names);

unique_ptr<GlobalTableFunctionState> OasisScanInitGlobal(ClientContext &context, TableFunctionInitInput &input);

unique_ptr<LocalTableFunctionState> OasisScanInitLocal(ExecutionContext &context, TableFunctionInitInput &input,
                                                       GlobalTableFunctionState *global_state_p);

void OasisScanFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output);

} // namespace duckdb
