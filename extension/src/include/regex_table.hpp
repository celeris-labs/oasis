#pragma once

#include "celeris/celeris_context.hpp"
#include "duckdb.hpp"
#include "duckdb/catalog/catalog_entry/duck_table_entry.hpp"
#include "duckdb/function/table_function.hpp"
#include "duckdb/main/client_context.hpp"
#include "duckdb/storage/data_table.hpp"
#include "duckdb/storage/storage_index.hpp"
#include "duckdb/storage/table/scan_state.hpp"
#include "libstf/buffer.hpp"

#include <memory>
#include <vector>

namespace duckdb {

struct RegexFpgaScanBindData : public TableFunctionData {
	DuckTableEntry &table;
	string regex_column;
	string pattern;
	vector<uint8_t> regex_blob;
	vector<LogicalType> column_types;
	vector<StorageIndex> column_ids;
	idx_t regex_column_idx = DConstants::INVALID_INDEX;
	StorageIndex regex_column_id;

	RegexFpgaScanBindData(DuckTableEntry &table, string regex_column, string pattern, vector<uint8_t> regex_blob)
	    : table(table), regex_column(std::move(regex_column)), pattern(std::move(pattern)),
	      regex_blob(std::move(regex_blob)) {
	}
};

struct RegexFpgaScanGlobalState : public GlobalTableFunctionState {
	idx_t MaxThreads() const override;
	celeris::CelerisContext &ctx;
	ParallelTableScanState parallel_scan;
	idx_t max_threads = 1;

	explicit RegexFpgaScanGlobalState(celeris::CelerisContext &ctx) : ctx(ctx) {
	}
};

struct StagedRowRef {
	idx_t chunk_idx;
	idx_t row_idx;
};

struct RegexFpgaScanLocalState : public LocalTableFunctionState {
	TableScanState scan_state;
	DataChunk output_cache;

	vector<LogicalType> scanned_types;
	idx_t scanned_regex_column_idx = DConstants::INVALID_INDEX;
	vector<idx_t> output_column_map;

	vector<unique_ptr<DataChunk>> retained_chunks;
	vector<StagedRowRef> batch_row_refs;

	idx_t current_retained_chunk_idx = DConstants::INVALID_INDEX;
	idx_t chunk_offset = 0;
	idx_t output_cache_read_idx = 0;
	idx_t rows_in_current_row_group = 0;

	idx_t accum_count = 0;
	uint64_t raw_used = 0;
	bool finished = false;

	std::shared_ptr<libstf::Buffer> struct_buffer;
	std::shared_ptr<libstf::Buffer> raw_buffer;
};

unique_ptr<FunctionData> RegexFpgaScanBind(ClientContext &context, TableFunctionBindInput &input,
                                           vector<LogicalType> &return_types, vector<string> &names);

unique_ptr<GlobalTableFunctionState> RegexFpgaScanInitGlobal(ClientContext &context,
                                                             TableFunctionInitInput &input);

unique_ptr<LocalTableFunctionState> RegexFpgaScanInitLocal(ExecutionContext &context,
                                                           TableFunctionInitInput &input,
                                                           GlobalTableFunctionState *global_state);

void RegexFpgaScanFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output);

void RegisterRegexFpgaScanFunction(ExtensionLoader &loader);

} // namespace duckdb
