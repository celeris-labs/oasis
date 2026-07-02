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
	return 1;
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
	return make_uniq<RegexFpgaScanGlobalState>(GetCelerisContext());
}

unique_ptr<LocalTableFunctionState> RegexFpgaScanInitLocal(ExecutionContext &context, TableFunctionInitInput &input,
                                                         GlobalTableFunctionState *global_state) {
	auto &bind_data = input.bind_data->Cast<RegexFpgaScanBindData>();
	auto lstate = make_uniq<RegexFpgaScanLocalState>();

	auto &transaction = DuckTransaction::Get(context.client, bind_data.table.catalog);
	bind_data.table.GetStorage().InitializeScan(context.client, transaction, lstate->scan_state, bind_data.column_ids,
	                                            nullptr);

	lstate->scan_chunk.Initialize(context.client, bind_data.column_types);
	lstate->accum_rows.Initialize(context.client, bind_data.column_types, REGEX_FPGA_MAX_ACCUM_COUNT);
	lstate->output_cache.Initialize(context.client, bind_data.column_types, REGEX_FPGA_MAX_ACCUM_COUNT);

	auto &ctx = global_state->Cast<RegexFpgaScanGlobalState>().ctx;
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

//ensures scan_chunk has unconsumed rows
//returns true if new rows arrived, false if table is exhausted


static bool TryRefillScanChunk(ClientContext &context, const RegexFpgaScanBindData &bind_data,
                               RegexFpgaScanLocalState &lstate) {
	CALI_CXX_MARK_FUNCTION;
	if (lstate.chunk_offset < lstate.scan_chunk.size()) {
		return true;
	}

	lstate.scan_chunk.Reset();
	CALI_MARK_BEGIN("table_scan");
	auto &transaction = DuckTransaction::Get(context, bind_data.table.catalog);
	bind_data.table.GetStorage().Scan(transaction, lstate.scan_chunk, lstate.scan_state);
	CALI_MARK_END("table_scan");
	lstate.chunk_offset = 0;
	return lstate.scan_chunk.size() > 0;
}

static void ResetFpgaAccumulation(RegexFpgaScanLocalState &lstate) {
	lstate.accum_count = 0;
	lstate.raw_used = 0;
	lstate.accum_rows.SetChildCardinality(0);
}

static void FlushFpgaBatch(const RegexFpgaScanBindData &bind_data, RegexFpgaScanGlobalState &global_state,
                           RegexFpgaScanLocalState &lstate) {
	CALI_CXX_MARK_FUNCTION;
	if (lstate.accum_count == 0) {
		return;
	}

	CALI_MARK_BEGIN("fpga_regex_batch");
	auto matches = RunFpgaRegexPackedBatch(global_state.ctx, lstate.struct_buffer->ptr, lstate.accum_count,
	                                     lstate.raw_buffer ? lstate.raw_buffer->ptr : nullptr, lstate.raw_used,
	                                     bind_data.regex_blob);
	CALI_MARK_END("fpga_regex_batch");

	CALI_MARK_BEGIN("collect_matches");
	SelectionVector sel(lstate.accum_count);
	idx_t match_count = 0;
	for (idx_t i = 0; i < lstate.accum_count; i++) {
		if (matches[i]) {
			sel.set_index(match_count++, i);
		}
	}
	CALI_MARK_END("collect_matches");

	if (match_count > 0) {
		CALI_MARK_BEGIN("append_output_cache");
		lstate.output_cache.Append(lstate.accum_rows, sel, match_count);
		CALI_MARK_END("append_output_cache");
	}

	ResetFpgaAccumulation(lstate);
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
		if (!TryRefillScanChunk(context, bind_data, lstate)) {
		    //table exhausted
			FlushFpgaBatch(bind_data, global_state, lstate);
			lstate.finished = true;
			return;
		}

		auto &regex_vector = lstate.scan_chunk.data[bind_data.regex_column_idx];
		UnifiedVectorFormat regex_format;
		regex_vector.ToUnifiedFormat(regex_format);
		const string_t *regex_data = UnifiedVectorFormat::GetData<string_t>(regex_format);

		CALI_MARK_BEGIN("stage_rows_for_fpga_batch");
		while (lstate.chunk_offset < lstate.scan_chunk.size() && lstate.output_cache.size() == 0) {
			const idx_t row_idx = lstate.chunk_offset++;
			const idx_t regex_idx = regex_format.sel->get_index(row_idx);
			if (!regex_format.validity.RowIsValid(regex_idx)) {
				continue;
			}

			const string_t &regex_value = regex_data[regex_idx];
			const uint64_t raw_cost = RegexFpgaNonInlinedRawCost(regex_value);
			if (WouldExceedFpgaBatch(lstate, raw_cost)) {
				CALI_MARK_END("stage_rows_for_fpga_batch");
				FlushFpgaBatch(bind_data, global_state, lstate);
				if (lstate.output_cache.size() > 0) {
					// Re-process this row on the next accumulation batch.
					lstate.chunk_offset--;
					return;
				}
				CALI_MARK_BEGIN("stage_rows_for_fpga_batch");
			}

			auto *descriptors = reinterpret_cast<string_t *>(lstate.struct_buffer->ptr);
			RegexFpgaPackString(&descriptors[lstate.accum_count],
			                    static_cast<char *>(lstate.raw_buffer ? lstate.raw_buffer->ptr : nullptr),
			                    lstate.raw_used, regex_value);

			SelectionVector sel(1);
			sel.set_index(0, row_idx);
			lstate.accum_rows.Append(lstate.scan_chunk, sel, 1);

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

} // namespace duckdb
