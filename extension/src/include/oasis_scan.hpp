#pragma once

#include "column_reader.hpp"
#include "duckdb.hpp"
#include "libstf_buffer_vector_buffer.hpp"
#include "oasis/oasis_context.hpp"
#include "oasis_context_cache_entry.hpp"
#include "parcore/metadata/metadata.hpp"
#include "parquet_reader.hpp"

#include "duckdb/planner/table_filter_state.hpp"

#include <atomic>

namespace duckdb {

// Per-worker state for one pushed-down TableFilter. TableFilterState is not safe to share across 
// threads, so each worker owns its own (mirrors ParquetReader's per-scan-state scan_filters).
struct OasisScanFilter {
	OasisScanFilter(ClientContext &context, idx_t filter_idx, const TableFilter &filter)
	    : filter_idx(filter_idx), filter(filter),
	      filter_state(TableFilterState::Initialize(context, filter)) {
	}

	idx_t filter_idx;
	const TableFilter &filter;
	unique_ptr<TableFilterState> filter_state;
};

struct OasisScanBindData : public TableFunctionData {
	string filename;
	parcore::metadata::Metadata metadata;
};

struct ProjectedColumn {
	size_t column_id;
	size_t elem_size; // 0 for CPU (string) columns
	bool is_cpu;      // variable-length column decoded on the CPU path, not the FPGA
};

// Global scan state shared across all DuckDB worker threads of one read_oasis scan. Following
// DuckDB's own Parquet reader, the only shared mutable state is the row-group cursor (an atomic
// each worker claims a group from). Everything per-row-group lives in the local state so workers
// never race on it.
struct OasisScanGlobalState : public GlobalTableFunctionState {
	string filename;
	oasis::OasisContext *ctx = nullptr;

	vector<ProjectedColumn> projected_columns;
	bool has_cpu_columns = false;

	// True when the query consumes no column values (e.g. COUNT(*), EXISTS).
	bool emit_cardinality_only = false;

	optional_ptr<TableFilterSet> filters;

	// Row-group cursor: the next group to hand out. Claimed atomically by workers.
	std::atomic<size_t> next_group {0};
	size_t total_groups = 0;

	idx_t MaxThreads() const override {
		return total_groups == 0 ? 1 : total_groups;
	}
};

// Per-worker scan state. Owns this worker's file handle (DuckDB FileHandles are not safe to share
// across threads) and, for the row group it is currently scanning, the decoded buffer per column it 
// is slicing into vectors.
//
// One buffer per column chunk: a row group is decoded in full in hardware, each column yielding
// exactly one buffer, and we then slice all columns' buffers in lockstep. The next group is loaded
// only once the current buffers are fully emitted.
struct OasisScanLocalState : public LocalTableFunctionState {
	unique_ptr<FileHandle> file_handle;

	unique_ptr<ParquetReader> parquet_reader;
	unique_ptr<ParquetReaderScanState> scan_state;
	unique_ptr<ColumnReader> root_reader;

	// Per-worker pushed-down filter states, built once at scan init from gstate.filters.
	std::vector<OasisScanFilter> scan_filters;

	// Reused selection vector for row-level filtering, so we don't reallocate per scan call.
	SelectionVector filter_sel;

	std::vector<std::shared_ptr<libstf::Buffer>> current_buffers;
	size_t current_buf_offset = 0;
	size_t current_group_num_rows = 0;

	// Empty-projection path only (COUNT(*) etc.): Rows left to emit from the row group we last 
    // claimed. We never decode anything in this path -- the count comes straight from the Parquet 
    // metadata.
	size_t empty_proj_remaining = 0;
};

unique_ptr<FunctionData> OasisScanBind(ClientContext &context, TableFunctionBindInput &input,
                                       vector<LogicalType> &return_types, vector<string> &names);

unique_ptr<GlobalTableFunctionState> OasisScanInitGlobal(ClientContext &context, TableFunctionInitInput &input);

unique_ptr<LocalTableFunctionState> OasisScanInitLocal(ExecutionContext &context, TableFunctionInitInput &input,
                                                       GlobalTableFunctionState *global_state_p);

void OasisScanFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output);

virtual_column_map_t OasisScanGetVirtualColumns(ClientContext &context, optional_ptr<FunctionData> bind_data);

} // namespace duckdb
