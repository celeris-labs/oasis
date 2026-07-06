#include "regex_table.hpp"
#include "regex_fpga_batch.hpp"

#include "duckdb/catalog/catalog_entry/duck_table_entry.hpp"
#include "duckdb/catalog/catalog_entry/table_catalog_entry.hpp"
#include "duckdb/common/identifier.hpp"
#include "duckdb/common/types/data_chunk.hpp"
#include "duckdb/common/types/vector.hpp"
#include "duckdb/common/vector_size.hpp"
#include "duckdb/main/extension/extension_loader.hpp"
#include "duckdb/parser/column_definition.hpp"
#include "duckdb/storage/data_table.hpp"
#include "duckdb/transaction/duck_transaction.hpp"
#include "libstf/buffer.hpp"
#include "nfa.hpp"

#include <caliper/cali.h>
#include <caliper/cali_macros.h>

namespace duckdb {

static constexpr idx_t REGEX_HW_MAX_STATES = 12;
static constexpr idx_t REGEX_HW_MAX_CHARS = 12;

idx_t RegexFpgaScanGlobalState::MaxThreads() const {
	return max_threads;
}

static LogicalType GetScanColumnType(const DuckTableEntry &table, const ColumnIndex &column_index) {
	if (column_index.IsRowIdColumn()) {
		return LogicalType::ROW_TYPE;
	}
	if (column_index.HasType()) {
		return column_index.GetScanType();
	}
	return table.GetColumns().GetColumn(column_index.ToLogical()).Type();
}

static void BuildScanColumns(const RegexFpgaScanBindData &bind_data, const TableFunctionInitInput &input,
                             vector<ColumnIndex> &scan_column_indexes, vector<StorageIndex> &scan_storage_ids,
                             vector<LogicalType> &scan_types, idx_t &scanned_regex_column_idx) {
	scan_column_indexes.clear();
	scan_storage_ids.clear();
	scan_types.clear();
	scanned_regex_column_idx = DConstants::INVALID_INDEX;

	if (input.column_indexes.empty()) {
		for (idx_t col_idx = 0; col_idx < bind_data.column_types.size(); col_idx++) {
			scan_column_indexes.emplace_back(col_idx);
			scan_storage_ids.push_back(bind_data.column_ids[col_idx]);
			scan_types.push_back(bind_data.column_types[col_idx]);
		}
		scanned_regex_column_idx = bind_data.regex_column_idx;
		return;
	}

	scan_column_indexes = input.column_indexes;
	for (idx_t col_idx = 0; col_idx < scan_column_indexes.size(); col_idx++) {
		if (scan_column_indexes[col_idx].GetPrimaryIndex() == bind_data.regex_column_idx) {
			scanned_regex_column_idx = col_idx;
			break;
		}
	}
	if (scanned_regex_column_idx == DConstants::INVALID_INDEX) {
		scanned_regex_column_idx = scan_column_indexes.size();
		scan_column_indexes.emplace_back(bind_data.regex_column_idx);
	}

	for (const auto &column_index : scan_column_indexes) {
		scan_storage_ids.push_back(bind_data.table.GetStorageIndex(column_index));
		scan_types.push_back(GetScanColumnType(bind_data.table, column_index));
	}
}

static vector<idx_t> BuildOutputColumnMap(const TableFunctionInitInput &input,
                                          const vector<ColumnIndex> &scan_column_indexes) {
	vector<idx_t> output_map;
	if (input.column_indexes.empty() || input.projection_ids.empty()) {
		output_map.reserve(scan_column_indexes.size());
		for (idx_t col_idx = 0; col_idx < scan_column_indexes.size(); col_idx++) {
			output_map.push_back(col_idx);
		}
		return output_map;
	}

	output_map.reserve(input.projection_ids.size());
	for (const auto proj_id : input.projection_ids) {
		const auto &column_index = input.column_indexes[proj_id];
		idx_t scan_idx = DConstants::INVALID_INDEX;
		for (idx_t col_idx = 0; col_idx < scan_column_indexes.size(); col_idx++) {
			if (scan_column_indexes[col_idx] == column_index) {
				scan_idx = col_idx;
				break;
			}
		}
		if (scan_idx == DConstants::INVALID_INDEX) {
			throw InternalException("Projected column not found in regex_fpga_scan scan columns");
		}
		output_map.push_back(scan_idx);
	}
	return output_map;
}

static DataChunk &CurrentRetainedChunk(RegexFpgaScanLocalState &lstate) {
	D_ASSERT(lstate.current_retained_chunk_idx != DConstants::INVALID_INDEX);
	return *lstate.retained_chunks[lstate.current_retained_chunk_idx];
}

unique_ptr<FunctionData> RegexFpgaScanBind(ClientContext &context, TableFunctionBindInput &input,
                                           vector<LogicalType> &return_types, vector<string> &names) {
	string table_name = StringValue::Get(input.inputs[0]);
	string table_column = StringValue::Get(input.named_parameters["regex_column"]);
	string pattern = StringValue::Get(input.named_parameters["pattern"]);

	DuckTableEntry &table_entry =
	    Catalog::GetEntry<DuckTableEntry>(context, Identifier::InvalidCatalog(), Identifier::DefaultSchema(),
	                                      Identifier(table_name));
	const ColumnDefinition &column = table_entry.GetColumn(Identifier(table_column));
	if (column.GetType() != LogicalType::VARCHAR) {
		throw InternalException("Column type must be string: " + table_column);
	}

	auto bind_data = make_uniq<RegexFpgaScanBindData>(table_entry, table_column, pattern,
	                                                  NFA(pattern, REGEX_HW_MAX_STATES, REGEX_HW_MAX_CHARS).dump_binary());

	const auto &columns = table_entry.GetColumns();
	for (idx_t col_idx = 0; col_idx < columns.PhysicalColumnCount(); col_idx++) {
		const auto &col = columns.GetColumn(LogicalIndex(col_idx));
		names.push_back(col.Name().GetIdentifierName());
		return_types.push_back(col.Type());
		bind_data->column_types.push_back(col.Type());
		bind_data->column_ids.push_back(table_entry.GetStorageIndex(ColumnIndex(col_idx)));
	}

	Identifier regex_identifier(table_column);
	const auto regex_logical = table_entry.GetColumnIndex(regex_identifier);
	bind_data->regex_column_idx = regex_logical.index;
	bind_data->regex_column_id = table_entry.GetStorageIndex(ColumnIndex(regex_logical.index));

	return std::move(bind_data);
}

unique_ptr<GlobalTableFunctionState> RegexFpgaScanInitGlobal(ClientContext &context,
                                                             TableFunctionInitInput &input) {
	auto &bind_data = input.bind_data->Cast<RegexFpgaScanBindData>();
	auto gstate = make_uniq<RegexFpgaScanGlobalState>(GetCelerisContext());
	auto &storage = bind_data.table.GetStorage();
	storage.InitializeParallelScan(context, gstate->parallel_scan, input.column_indexes);
	gstate->max_threads = storage.MaxThreads(context);
	return std::move(gstate);
}

unique_ptr<LocalTableFunctionState> RegexFpgaScanInitLocal(ExecutionContext &context, TableFunctionInitInput &input,
                                                         GlobalTableFunctionState *global_state) {
	auto &bind_data = input.bind_data->Cast<RegexFpgaScanBindData>();
	auto &gstate = global_state->Cast<RegexFpgaScanGlobalState>();
	auto lstate = make_uniq<RegexFpgaScanLocalState>();

	vector<ColumnIndex> scan_column_indexes;
	vector<StorageIndex> scan_storage_ids;
	BuildScanColumns(bind_data, input, scan_column_indexes, scan_storage_ids, lstate->scanned_types,
	                 lstate->scanned_regex_column_idx);
	lstate->output_column_map = BuildOutputColumnMap(input, scan_column_indexes);

	lstate->output_types.reserve(lstate->output_column_map.size());
	for (const auto scan_idx : lstate->output_column_map) {
		lstate->output_types.push_back(lstate->scanned_types[scan_idx]);
	}

	auto &storage = bind_data.table.GetStorage();
	lstate->scan_state.Initialize(scan_storage_ids, context.client, nullptr);
	lstate->output_cache.Initialize(context.client, lstate->output_types, REGEX_FPGA_MAX_ACCUM_COUNT);
	lstate->batch_row_refs.reserve(REGEX_FPGA_MAX_ACCUM_COUNT);
	lstate->match_sel_scratch.Initialize(STANDARD_VECTOR_SIZE);

	lstate->rows_in_current_row_group = storage.NextParallelScan(context.client, gstate.parallel_scan, lstate->scan_state);

	auto &ctx = gstate.ctx;
	libstf::Status status;
	const uint64_t raw_capacity = align_to_64_multiple(REGEX_FPGA_RAW_BATCH_LIMIT);
	lstate->struct_buffer =
	    libstf::make_buffer(ctx.get_memory_pool(), REGEX_FPGA_MAX_ACCUM_COUNT * sizeof(string_t), status);
	if (!status.ok()) {
		throw InternalException("Failed to allocate FPGA regex descriptor buffer for table scan");
	}
	if (raw_capacity > 0) {
		lstate->raw_buffer = libstf::make_buffer(ctx.get_memory_pool(), raw_capacity, status);
		if (!status.ok()) {
			throw InternalException("Failed to allocate FPGA regex payload buffer for table scan");
		}
	}

	return std::move(lstate);
}

static bool TryRefillScanChunk(ClientContext &context, const RegexFpgaScanBindData &bind_data,
                               RegexFpgaScanGlobalState &global_state, RegexFpgaScanLocalState &lstate) {
	CALI_CXX_MARK_FUNCTION;
	if (lstate.current_retained_chunk_idx != DConstants::INVALID_INDEX &&
	    lstate.chunk_offset < CurrentRetainedChunk(lstate).size()) {
		return true;
	}

	auto &storage = bind_data.table.GetStorage();
	auto &transaction = DuckTransaction::Get(context, bind_data.table.catalog);
	while (true) {
		auto retained = make_uniq<DataChunk>();
		retained->Initialize(context, lstate.scanned_types);
		CALI_MARK_BEGIN("table_scan");
		storage.Scan(transaction, *retained, lstate.scan_state);
		CALI_MARK_END("table_scan");
		lstate.chunk_offset = 0;
		if (retained->size() > 0) {
			lstate.retained_chunks.push_back(std::move(retained));
			lstate.current_retained_chunk_idx = lstate.retained_chunks.size() - 1;
			return true;
		}

		lstate.rows_in_current_row_group =
		    storage.NextParallelScan(context, global_state.parallel_scan, lstate.scan_state);
		if (lstate.rows_in_current_row_group == 0) {
			return false;
		}
	}
}

static void ResetFpgaAccumulation(RegexFpgaScanLocalState &lstate, bool keep_current_retained_chunk = false) {
	lstate.accum_count = 0;
	lstate.raw_used = 0;
	lstate.batch_row_refs.clear();

	if (keep_current_retained_chunk && lstate.current_retained_chunk_idx != DConstants::INVALID_INDEX) {
		unique_ptr<DataChunk> kept = std::move(lstate.retained_chunks[lstate.current_retained_chunk_idx]);
		lstate.retained_chunks.clear();
		lstate.retained_chunks.push_back(std::move(kept));
		lstate.current_retained_chunk_idx = 0;
	} else {
		lstate.retained_chunks.clear();
		lstate.current_retained_chunk_idx = DConstants::INVALID_INDEX;
	}
}

static void AppendMatchedRows(RegexFpgaScanLocalState &lstate, const std::vector<bool> &matches) {
	auto &matches_by_chunk = lstate.match_indices_scratch;
	matches_by_chunk.resize(lstate.retained_chunks.size());
	for (auto &row_indices : matches_by_chunk) {
		row_indices.clear();
	}
	for (idx_t i = 0; i < lstate.accum_count; i++) {
		if (!matches[i]) {
			continue;
		}
		const auto &row_ref = lstate.batch_row_refs[i];
		matches_by_chunk[row_ref.chunk_idx].push_back(row_ref.row_idx);
	}

	// Project each retained chunk down to the output columns (zero-copy view) before copying the matched
	// rows into the cache, so match-only columns (e.g. the regex column) are never physically copied.
	DataChunk projected;
	projected.InitializeEmpty(lstate.output_types);
	for (idx_t chunk_idx = 0; chunk_idx < matches_by_chunk.size(); chunk_idx++) {
		auto &row_indices = matches_by_chunk[chunk_idx];
		if (row_indices.empty()) {
			continue;
		}
		for (idx_t i = 0; i < row_indices.size(); i++) {
			lstate.match_sel_scratch.set_index(i, row_indices[i]);
		}
		projected.ReferenceColumns(*lstate.retained_chunks[chunk_idx], lstate.output_column_map);
		lstate.output_cache.Append(projected, lstate.match_sel_scratch, row_indices.size());
	}
}

static void FlushFpgaBatch(const RegexFpgaScanBindData &bind_data, RegexFpgaScanGlobalState &global_state,
                           RegexFpgaScanLocalState &lstate, bool keep_current_retained_chunk = false) {
	CALI_CXX_MARK_FUNCTION;
	if (lstate.accum_count == 0) {
		return;
	}

	CALI_MARK_BEGIN("fpga_regex_batch");
	auto matches = RunFpgaRegexPackedBatch(global_state.ctx, lstate.struct_buffer->ptr, lstate.accum_count,
	                                     lstate.raw_buffer ? lstate.raw_buffer->ptr : nullptr, lstate.raw_used,
	                                     bind_data.regex_blob);
	CALI_MARK_END("fpga_regex_batch");

	CALI_MARK_BEGIN("append_output_cache");
	AppendMatchedRows(lstate, matches);
	CALI_MARK_END("append_output_cache");

	ResetFpgaAccumulation(lstate, keep_current_retained_chunk);
}

static bool WouldExceedFpgaBatch(const RegexFpgaScanLocalState &lstate, uint64_t next_raw_cost) {
	if (lstate.accum_count >= REGEX_FPGA_MAX_ACCUM_COUNT) {
		return true;
	}
	if (next_raw_cost == 0) {
		return false;
	}
	return lstate.raw_used + next_raw_cost > REGEX_FPGA_RAW_BATCH_LIMIT;
}

static void AccumulateRows(const RegexFpgaScanBindData &bind_data, RegexFpgaScanGlobalState &global_state,
                           RegexFpgaScanLocalState &lstate, ClientContext &context) {
	CALI_CXX_MARK_FUNCTION;
	while (lstate.output_cache.size() == 0 && !lstate.finished) {
		if (!TryRefillScanChunk(context, bind_data, global_state, lstate)) {
			FlushFpgaBatch(bind_data, global_state, lstate);
			lstate.finished = true;
			return;
		}

		auto &current_chunk = CurrentRetainedChunk(lstate);
		auto &regex_vector = current_chunk.data[lstate.scanned_regex_column_idx];
		UnifiedVectorFormat regex_format;
		regex_vector.ToUnifiedFormat(regex_format);
		const string_t *regex_data = UnifiedVectorFormat::GetData<string_t>(regex_format);

		CALI_MARK_BEGIN("stage_rows_for_fpga_batch");
		while (lstate.chunk_offset < current_chunk.size() && lstate.output_cache.size() == 0) {
			const idx_t row_idx = lstate.chunk_offset++;
			const idx_t regex_idx = regex_format.sel->get_index(row_idx);
			if (!regex_format.validity.RowIsValid(regex_idx)) {
				continue;
			}

			const string_t &regex_value = regex_data[regex_idx];
			const uint64_t raw_cost = RegexFpgaNonInlinedRawCost(regex_value);
			if (WouldExceedFpgaBatch(lstate, raw_cost)) {
				CALI_MARK_END("stage_rows_for_fpga_batch");
				const bool keep_current_chunk = lstate.chunk_offset > 0;
				FlushFpgaBatch(bind_data, global_state, lstate, keep_current_chunk);
				lstate.chunk_offset--;
				if (lstate.output_cache.size() > 0) {
					return;
				}
				CALI_MARK_BEGIN("stage_rows_for_fpga_batch");
			}

			auto *descriptors = reinterpret_cast<string_t *>(lstate.struct_buffer->ptr);
			RegexFpgaPackString(&descriptors[lstate.accum_count],
			                    static_cast<char *>(lstate.raw_buffer ? lstate.raw_buffer->ptr : nullptr),
			                    lstate.raw_used, regex_value);

			lstate.batch_row_refs.push_back({lstate.current_retained_chunk_idx, row_idx});

			lstate.raw_used += raw_cost;
			lstate.accum_count++;
		}
		CALI_MARK_END("stage_rows_for_fpga_batch");
	}

	if (lstate.output_cache.size() == 0 && !lstate.finished && lstate.accum_count > 0) {
		FlushFpgaBatch(bind_data, global_state, lstate);
	}
}

static void EmitFromOutputCache(RegexFpgaScanLocalState &lstate, DataChunk &output) {
	CALI_CXX_MARK_FUNCTION;
	const idx_t remaining = lstate.output_cache.size() - lstate.output_cache_read_idx;
	const idx_t emit_count = MinValue<idx_t>(remaining, STANDARD_VECTOR_SIZE);
	const idx_t end = lstate.output_cache_read_idx + emit_count;
	// output_cache is already materialized in output-projection layout, so emit it directly.
	output.Slice(lstate.output_cache, lstate.output_cache_read_idx, end);
	lstate.output_cache_read_idx = end;
	if (lstate.output_cache_read_idx >= lstate.output_cache.size()) {
		lstate.output_cache.Reset();
		lstate.output_cache_read_idx = 0;
	}
}

void RegexFpgaScanFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	CALI_CXX_MARK_FUNCTION;
	auto &bind_data = data_p.bind_data->Cast<RegexFpgaScanBindData>();
	auto &global_state = data_p.global_state->Cast<RegexFpgaScanGlobalState>();
	auto &lstate = data_p.local_state->Cast<RegexFpgaScanLocalState>();

	if (lstate.output_cache_read_idx < lstate.output_cache.size()) {
		CALI_MARK_BEGIN("emit_output_cache");
		EmitFromOutputCache(lstate, output);
		CALI_MARK_END("emit_output_cache");
		return;
	}

	if (lstate.finished) {
		output.SetChildCardinality(0);
		return;
	}

	AccumulateRows(bind_data, global_state, lstate, context);

	if (lstate.output_cache_read_idx < lstate.output_cache.size()) {
		CALI_MARK_BEGIN("emit_output_cache");
		EmitFromOutputCache(lstate, output);
		CALI_MARK_END("emit_output_cache");
		return;
	}

	output.SetChildCardinality(0);
}

void RegisterRegexFpgaScanFunction(ExtensionLoader &loader) {
	TableFunction table_function("regex_fpga_scan", {LogicalType::VARCHAR}, RegexFpgaScanFunction, RegexFpgaScanBind,
	                             RegexFpgaScanInitGlobal, RegexFpgaScanInitLocal);
	table_function.named_parameters["regex_column"] = LogicalType::VARCHAR;
	table_function.named_parameters["pattern"] = LogicalType::VARCHAR;
	table_function.projection_pushdown = true;
	table_function.filter_prune = true;
	loader.RegisterFunction(table_function);
}

} // namespace duckdb
