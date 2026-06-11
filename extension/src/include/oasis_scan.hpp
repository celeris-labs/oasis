#pragma once

#include "duckdb.hpp"
#include "libstf_buffer_vector_buffer.hpp"
#include "oasis/configuration.hpp"
#include "oasis_context_cache_entry.hpp"
#include "parcore/column_chunk_decoder.hpp"
#include "parcore/file_reader.hpp"
#include "parcore/metadata/metadata.hpp"

#include <parcore/reader.hpp>

namespace duckdb {

class LogicalGet;

struct OasisFilter {
	bool configured = false;
	oasis::FilterComparison comparison = oasis::FilterComparison::ALWAYS_TRUE;
	std::array<uint64_t, oasis::FilterConfig::NUM_RHS> rhs = {};
	std::array<uint64_t, oasis::FilterConfig::NUM_ADDITIONAL_RHS> additional_rhs = {};
	uint8_t additional_rhs_mask = 0;
};

struct OasisLayerPredicate {
	idx_t column_id;
	OasisFilter filter;
};

struct OasisScanBindData : public TableFunctionData {
	string filename;
	parcore::metadata::Metadata metadata;
	vector<vector<OasisLayerPredicate>> filter_layers;
};

struct OasisScanGlobalState : public GlobalTableFunctionState {
	std::shared_ptr<arrow::io::ReadableFile> file;
	std::vector<std::shared_ptr<parcore::ColumnChunkDecoder>> decoders;
	std::vector<std::unique_ptr<parcore::FileReader>> readers;

	// ParCore column indices for the projected columns, in output order.
	vector<size_t> column_ids;
	// Hardware stream assigned to each projected column, in output order.
	vector<libstf::stream_t> stream_ids;

	// Scan cursor: which row group we'll enqueue next, and where we are
	// inside the buffers returned for the currently-in-flight chunk.
	size_t next_group = 0;
	size_t total_groups = 0;
	std::vector<std::vector<std::shared_ptr<libstf::Buffer>>> current_buffers;
	// the index of the buffers
	size_t current_buf_idx = 0;
	// the idx within the buffers
	size_t current_buf_offset = 0;
};

struct OasisScanLocalState : public LocalTableFunctionState {};

unique_ptr<FunctionData> OasisScanBind(ClientContext &context, TableFunctionBindInput &input,
                                       vector<LogicalType> &return_types, vector<string> &names);

void OasisPushdownComplexFilter(ClientContext &context, LogicalGet &get, FunctionData *bind_data,
                                vector<unique_ptr<Expression>> &filters);

unique_ptr<GlobalTableFunctionState> OasisScanInitGlobal(ClientContext &context, TableFunctionInitInput &input);

unique_ptr<LocalTableFunctionState> OasisScanInitLocal(ExecutionContext &context, TableFunctionInitInput &input,
                                                       GlobalTableFunctionState *global_state_p);

void OasisScanFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output);

} // namespace duckdb
