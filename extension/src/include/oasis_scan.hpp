#pragma once

#include "duckdb.hpp"
#include "libstf_buffer_vector_buffer.hpp"
#include "oasis_context_cache_entry.hpp"
#include "parcore/column_chunk_decoder.hpp"
#include "parcore/file_reader.hpp"
#include "parcore/metadata/metadata.hpp"

#include <parcore/reader.hpp>

namespace duckdb {

struct OasisBloomMockState;

struct OasisScanBindData : public TableFunctionData {
	string filename;
	parcore::metadata::Metadata metadata;

	bool runtime_bloom_enabled = false;
	string runtime_bloom_build_filename;
	string runtime_bloom_build_key;
	string runtime_bloom_probe_key;
};

struct OasisScanGlobalState : public GlobalTableFunctionState {
	std::shared_ptr<parcore::ColumnChunkDecoder> decoder;
	std::shared_ptr<arrow::io::ReadableFile> file;
	std::unique_ptr<parcore::FileReader> reader;

	// Points to bind_data.metadata. The bind data lives for the lifetime of the scan.
	const parcore::metadata::Metadata *metadata = nullptr;

	vector<size_t> column_ids;
	vector<size_t> scan_column_ids;
	vector<size_t> output_to_scan_idx;

	bool runtime_bloom_enabled = false;
	size_t runtime_bloom_probe_col_id = DConstants::INVALID_INDEX;
	size_t runtime_bloom_probe_scan_idx = DConstants::INVALID_INDEX;

	std::shared_ptr<OasisBloomMockState> bloom_mock;

	size_t next_group = 0;
	size_t total_groups = 0;
	std::vector<std::vector<std::shared_ptr<libstf::Buffer>>> current_buffers;

	size_t current_buf_idx = 0;
	size_t current_buf_offset = 0;
};

struct OasisScanLocalState : public LocalTableFunctionState {
};

unique_ptr<FunctionData> OasisScanBind(ClientContext &context, TableFunctionBindInput &input,
                                       vector<LogicalType> &return_types, vector<string> &names);

unique_ptr<GlobalTableFunctionState> OasisScanInitGlobal(ClientContext &context, TableFunctionInitInput &input);

unique_ptr<LocalTableFunctionState> OasisScanInitLocal(ExecutionContext &context, TableFunctionInitInput &input,
                                                       GlobalTableFunctionState *global_state_p);

void OasisScanFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output);

bool OasisLoadNextRowGroupIfNeeded(OasisScanGlobalState &gstate);

} // namespace duckdb