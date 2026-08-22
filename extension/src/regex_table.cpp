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
#include "duckdb/planner/expression/bound_conjunction_expression.hpp"
#include "duckdb/planner/expression/bound_function_expression.hpp"
#include "duckdb/planner/expression/bound_reference_expression.hpp"
#include "duckdb/planner/filter/expression_filter.hpp"
#include "duckdb/planner/filter/table_filter_functions.hpp"
#include "duckdb/planner/table_filter_set.hpp"
#include "duckdb/storage/data_table.hpp"
#include "duckdb/transaction/duck_transaction.hpp"
#include "libstf/buffer.hpp"
#include "nfa.hpp"
#include "oasis_profiling.hpp"

namespace duckdb {

// Must track REGEX_MAX_STATES / REGEX_MAX_TOKENS in the celeris submodule
// (software/celeris/operators/regex/CMakeLists.txt), which in turn must equal
// rem_top_ff's STATE_COUNT / CHAR_COUNT in the flashed bitstream.
//
// CHAR_COUNT was widened 12 -> 32 in celeris a39225a (bitstream
// build_hw_more_chars). Measured against that bitstream, the extra slots do
// work -- a 26-slot alternation matches correctly -- but a *single unbroken
// literal run* longer than 16 characters silently returns wrong results
// instead of being rejected. Runs are what chain through rem_decoder's
// config_conds; alternation branches and class/quantifier-separated literals
// each start a fresh chain, so only the per-run length is capped.
// REGEX_HW_MAX_RUN below is a host-side guard for that, since neither the NFA
// compiler nor the hardware reports it.
//
// Taken from the compile definitions rather than restated: OASIS_REGEX_MAX_STATES
// / OASIS_REGEX_MAX_TOKENS in CMakeLists.txt is the single source, and it already
// feeds the fregex ExternalProject that instantiates the blob layout. Restating
// them here is what let regex.cpp sit at 12 against a 24-state build.
#if !defined(REGEX_MAX_STATES) || !defined(REGEX_MAX_TOKENS)
#error "REGEX_MAX_STATES / REGEX_MAX_TOKENS must be set from CMake (see OASIS_REGEX_MAX_*)"
#endif
static constexpr idx_t REGEX_HW_MAX_STATES = REGEX_MAX_STATES;
static constexpr idx_t REGEX_HW_MAX_CHARS = REGEX_MAX_TOKENS;
// A literal run occupies one char slot per character, so the cap is CHAR_COUNT
// (RegexConfig::kMaxLiteralRun in regex_config.hpp), not an independent number.
static constexpr idx_t REGEX_HW_MAX_RUN = REGEX_MAX_TOKENS;

idx_t RegexFpgaScanGlobalState::MaxThreads() const {
	return max_threads;
}

// Rejects patterns whose longest unbroken literal run exceeds what rem_decoder's
// chained comparators handle. Deliberately a conservative textual scan rather
// than an NFA walk: anything that is not a plain literal character (a class, an
// escape, a group or alternation delimiter, a quantifier) ends the current run,
// which is exactly how the hardware chain breaks. Over-counting a run would
// reject a working pattern, so escapes end the run rather than extending it.
static void CheckRegexLiteralRunLength(const string &pattern) {
	idx_t run = 0;
	idx_t longest = 0;
	for (idx_t i = 0; i < pattern.size(); i++) {
		const char c = pattern[i];
		const bool is_meta = c == '\\' || c == '[' || c == ']' || c == '(' || c == ')' || c == '|' || c == '*' ||
		                     c == '+' || c == '?' || c == '{' || c == '}' || c == '.' || c == '^' || c == '$';
		if (is_meta) {
			if (c == '\\' && i + 1 < pattern.size()) {
				i++; // consume the escaped character with the escape
			}
			run = 0;
			continue;
		}
		run++;
		longest = MaxValue(longest, run);
	}
	if (longest > REGEX_HW_MAX_RUN) {
		throw BinderException(
		    "regex_fpga_scan: pattern contains a literal run of %llu characters; the bitstream matches at most %llu "
		    "consecutive literal characters correctly. Break the run with a class, quantifier or alternation.",
		    static_cast<uint64_t>(longest), static_cast<uint64_t>(REGEX_HW_MAX_RUN));
	}
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

static unique_ptr<TableFilterSet> BuildScanFilterSet(const TableFunctionInitInput &input,
                                                     const vector<LogicalType> &scan_types);

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
	if (input.column_indexes.empty()) {
		// No projection pushdown: BuildScanColumns scanned every table column, so emit them all.
		output_map.reserve(scan_column_indexes.size());
		for (idx_t col_idx = 0; col_idx < scan_column_indexes.size(); col_idx++) {
			output_map.push_back(col_idx);
		}
		return output_map;
	}
	if (input.projection_ids.empty()) {
		// Projection pushdown without reordering: emit exactly the requested columns. This excludes
		// the regex column that BuildScanColumns may have appended purely for matching, which would
		// otherwise leave output_cache one column wider than the output chunk (e.g. count(*)).
		output_map.reserve(input.column_indexes.size());
		for (idx_t col_idx = 0; col_idx < input.column_indexes.size(); col_idx++) {
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

	CheckRegexLiteralRunLength(pattern);

	// dump_binary() returns only as many bytes as the compiled pattern occupies, but
	// write_regex_blob_if_changed drives a fixed number of MMIO words: the card latches
	// RegexConfig::kBlobBytes every time. Handing it a short vector leaves the tail words
	// unwritten, so the engines match against whatever the previous pattern left behind --
	// which shows up as every row matching or none, deterministically and regardless of
	// the pattern. Pad to full width, exactly as examples/06_regex does.
	std::vector<uint8_t> regex_blob = NFA(pattern, REGEX_HW_MAX_STATES, REGEX_HW_MAX_CHARS).dump_binary();
	regex_blob.resize(REGEX_CONFIG_BLOB_BYTES, 0);

	auto bind_data = make_uniq<RegexFpgaScanBindData>(table_entry, table_column, pattern, std::move(regex_blob));

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

	Value dry_run_value;
	if (context.TryGetCurrentSetting("oasis_regex_dry_run", dry_run_value) && !dry_run_value.IsNull()) {
		gstate->dry_run = BooleanValue::Get(dry_run_value);
	}
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

	// Batch geometry: 0 means "use the default". Rows are clamped to what the result FIFOs can
	// hold (kRegexMaxStringsPerEngine per engine), which finalize() would otherwise reject.
	Value setting_value;
	if (context.client.TryGetCurrentSetting("oasis_regex_batch_rows", setting_value) && !setting_value.IsNull()) {
		const auto rows = setting_value.GetValue<uint64_t>();
		if (rows > 0) {
			const uint64_t cap = uint64_t(celeris::kRegexMaxStringsPerEngine) * celeris::kRegexEngineCount;
			lstate->max_accum_count = idx_t(MinValue<uint64_t>(rows, cap));
		}
	}
	if (context.client.TryGetCurrentSetting("oasis_regex_wire_buffer_bytes", setting_value) &&
	    !setting_value.IsNull()) {
		const auto bytes = setting_value.GetValue<uint64_t>();
		if (bytes > 0) {
			lstate->wire_buffer_bytes = bytes;
		}
	}
	if (context.client.TryGetCurrentSetting("oasis_regex_outlier_bytes", setting_value) && !setting_value.IsNull()) {
		const auto bytes = setting_value.GetValue<uint64_t>();
		if (bytes > 0) {
			lstate->outlier_bytes = bytes;
		}
	}

	auto &storage = bind_data.table.GetStorage();
	// Push scan filters (e.g. c_nationkey = 7) into the storage scan so the FPGA only sees surviving rows.
	lstate->scan_filter_set = BuildScanFilterSet(input, lstate->scanned_types);
	lstate->scan_state.Initialize(scan_storage_ids, context.client,
	                              lstate->scan_filter_set ? lstate->scan_filter_set.get() : input.filters.get());
	lstate->output_cache.Initialize(context.client, lstate->output_types, lstate->max_accum_count);
	lstate->batch_row_refs.reserve(lstate->max_accum_count);
	lstate->match_sel_scratch.Initialize(STANDARD_VECTOR_SIZE);

	lstate->rows_in_current_row_group = storage.NextParallelScan(context.client, gstate.parallel_scan, lstate->scan_state);

	auto &ctx = gstate.ctx;
	libstf::Status status;
	lstate->wire_buffer = libstf::make_buffer(ctx.get_memory_pool(), lstate->wire_buffer_bytes, status);
	if (!status.ok()) {
		throw InternalException("Failed to allocate FPGA regex wire buffer for table scan");
	}
	lstate->packer.reset(static_cast<uint8_t *>(lstate->wire_buffer->ptr), lstate->wire_buffer_bytes);

	return std::move(lstate);
}

// Makes the columns listed in @p column_ids self-contained so the chunk can outlive the scan that
// produced it: flattens dictionary/constant vectors (which otherwise share a selection buffer that
// later scans overwrite) and copies non-inlined strings into the vector's own string buffer
// (VARCHAR payloads otherwise point into storage blocks pinned only until the next Scan()).
// Only these columns need it — the regex column is read through ToUnifiedFormat and consumed
// immediately, so it stays untouched unless it is also emitted.
static void MaterializeRetainedColumns(DataChunk &chunk, const vector<idx_t> &column_ids) {
	for (const auto col_idx : column_ids) {
		auto &vec = chunk.data[col_idx];
		vec.Flatten(chunk.size());
		if (vec.GetType().InternalType() != PhysicalType::VARCHAR) {
			continue;
		}
		auto strings = FlatVector::GetDataMutable<string_t>(vec);
		auto &validity = FlatVector::Validity(vec);
		for (idx_t row = 0; row < chunk.size(); row++) {
			if (!validity.RowIsValid(row) || strings[row].IsInlined()) {
				continue;
			}
			strings[row] = StringVector::AddStringOrBlob(vec, strings[row]);
		}
	}
}

// Returns the real predicate hidden inside an "optional" filter wrapper, or nullptr if @p expr is
// not such a wrapper. DuckDB pushes OR/IN/LIKE predicates down wrapped in an internal marker
// function whose own evaluation is hard-coded to return all-true, parking the actual predicate in
// the wrapper's bind data. A scan that just evaluates the pushed filter therefore filters nothing;
// to benefit we have to reach in and take the child expression.
static optional_ptr<const Expression> UnwrapOptionalFilter(const Expression &expr) {
	if (expr.GetExpressionClass() != ExpressionClass::BOUND_FUNCTION) {
		return nullptr;
	}
	auto &func = expr.Cast<BoundFunctionExpression>();
	if (!func.BindInfo()) {
		return nullptr;
	}
	if (func.Function().GetName() == OptionalFilterScalarFun::NAME) {
		return func.BindInfo()->Cast<OptionalFilterFunctionData>().child_filter_expr.get();
	}
	if (func.Function().GetName() == SelectivityOptionalFilterScalarFun::NAME) {
		return func.BindInfo()->Cast<SelectivityOptionalFilterFunctionData>().child_filter_expr.get();
	}
	return nullptr;
}

// Rewrites the pushed-down filter set, replacing every optional wrapper with the real predicate it
// hides, and returns the result for the storage scan to enforce. The scan applies these while it
// reads each column, so filtered rows cost no FPGA work and no output materialization -- strictly
// better than re-filtering the chunk afterwards. Returns nullptr when there is nothing to rewrite,
// in which case the caller keeps using the filters DuckDB supplied.
static unique_ptr<TableFilterSet> BuildScanFilterSet(const TableFunctionInitInput &input,
                                                     const vector<LogicalType> &scan_types) {
	if (!input.filters || !input.filters->HasFilters()) {
		return nullptr;
	}
	auto rewritten = make_uniq<TableFilterSet>();
	bool unwrapped_any = false;
	for (auto &entry : *input.filters) {
		const auto filter_idx = entry.GetIndex();
		auto &filter = entry.Filter();
		if (filter.filter_type != TableFilterType::EXPRESSION_FILTER || filter_idx >= scan_types.size()) {
			return nullptr; // unfamiliar filter shape - leave the original set untouched
		}
		auto &expr_filter = ExpressionFilter::GetExpressionFilter(filter, "regex_fpga_scan");
		auto child = UnwrapOptionalFilter(*expr_filter.expr);
		if (child) {
			// Keep the child's own BOUND_REF placeholder: the scan evaluates a table filter against
			// a single-column chunk holding just the filtered column.
			rewritten->PushFilter(filter_idx, make_uniq<ExpressionFilter>(child->Copy()));
			unwrapped_any = true;
		} else {
			rewritten->PushFilter(filter_idx, expr_filter.Copy());
		}
	}
	return unwrapped_any ? std::move(rewritten) : nullptr;
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
		// A scanned chunk is only borrowed, but we retain chunks across several scans while an
		// FPGA batch fills up, so make the columns we will emit self-contained before holding on.
		CALI_MARK_BEGIN("materialize_chunk");
		MaterializeRetainedColumns(*retained, lstate.output_column_map);
		CALI_MARK_END("materialize_chunk");
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
	lstate.staged_rows = 0;
	lstate.batch_has_outlier = false;
	lstate.packer.reset(static_cast<uint8_t *>(lstate.wire_buffer->ptr), lstate.wire_buffer_bytes);
	lstate.batch_row_refs.clear();
	// The slots those dictionary entries pointed at are gone with the batch.
	lstate.dict_stamp++;

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

static void AppendMatchedRows(RegexFpgaScanLocalState &lstate, const RegexMatchBitmap &matches) {
	auto &matches_by_chunk = lstate.match_indices_scratch;
	matches_by_chunk.resize(lstate.retained_chunks.size());
	for (auto &row_indices : matches_by_chunk) {
		row_indices.clear();
	}
	// One entry per row the batch decides, which is more than the strings sent to the FPGA whenever
	// rows shared a dictionary entry: several rows then read the same slot's match bit.
	for (const auto &row_ref : lstate.batch_row_refs) {
		if (!matches.test(row_ref.slot_idx)) {
			continue;
		}
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
		// Append copies string_t values, which are pointers into the source chunk's string buffer.
		// The retained chunks are released as soon as this batch is flushed, so hold a reference to
		// their heaps or the cached strings dangle until the caller drains output_cache.
		for (idx_t out_idx = 0; out_idx < projected.ColumnCount(); out_idx++) {
			if (projected.data[out_idx].GetType().InternalType() == PhysicalType::VARCHAR) {
				StringVector::AddHeapReference(lstate.output_cache.data[out_idx], projected.data[out_idx]);
			}
		}
	}
}

static void FlushFpgaBatch(const RegexFpgaScanBindData &bind_data, RegexFpgaScanGlobalState &global_state,
                           RegexFpgaScanLocalState &lstate, bool keep_current_retained_chunk = false) {
	CALI_CXX_MARK_FUNCTION;
	if (lstate.accum_count == 0) {
		return;
	}

	CALI_MARK_BEGIN("fpga_regex_batch");
	// Squares off the rectangle: pads the short engines and fills the tails. Has to
	// happen before the enqueue and after the last append, so it lives here rather
	// than in the staging loop.
	const celeris::RegexStreamPacker::Plan plan = lstate.packer.finalize();
	// The batch is fully packed by this point either way, so a dry run leaves exactly the host-side
	// scan-and-pack cost and drops the enqueue, the device wait and the result read-back.
	RegexMatchBitmap matches;
	if (global_state.dry_run) {
		matches.assign_zero(lstate.accum_count);
	} else {
		matches = RunFpgaRegexPackedBatch(global_state.ctx, lstate.wire_buffer->ptr, plan, lstate.accum_count,
		                                  bind_data.regex_blob);
	}
	CALI_MARK_END("fpga_regex_batch");

	CALI_MARK_BEGIN("append_output_cache");
	AppendMatchedRows(lstate, matches);
	CALI_MARK_END("append_output_cache");

	ResetFpgaAccumulation(lstate, keep_current_retained_chunk);
}

// Whether staging one more *distinct* string would overrun the batch. `next_length` is the string's
// length; it is ignored for a row that reuses an already-staged dictionary entry, which costs
// nothing on the wire.
static bool WouldExceedFpgaBatch(const RegexFpgaScanLocalState &lstate, uint64_t next_length, bool needs_slot) {
	// Rows are capped independently of strings: when a dictionary column resolves millions of rows
	// to a handful of distinct values the string budget would never fill, and the retained chunks
	// backing those rows would grow without bound.
	if (lstate.staged_rows >= lstate.max_accum_count) {
		return true;
	}
	if (!needs_slot) {
		return false;
	}
	// Also the per-engine result-FIFO bound, since the count is dealt round-robin:
	// REGEX_FPGA_MAX_ACCUM_COUNT / 64 = 1024 results per engine.
	if (lstate.accum_count >= lstate.max_accum_count) {
		return true;
	}
	// The wire size is set by the longest engine stream once the rectangle is
	// squared off, not by the sum of the strings, so ask the packer rather than
	// tracking a running total.
	return lstate.packer.wire_size_after(next_length) > lstate.wire_buffer_bytes;
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
		// A dictionary- or constant-encoded vector resolves many rows onto few distinct strings.
		// Read before ToUnifiedFormat, which may attach a flattened child to the vector.
		const auto regex_vector_type = regex_vector.GetVectorType();
		const bool dedup = regex_vector_type == VectorType::DICTIONARY_VECTOR ||
		                   regex_vector_type == VectorType::CONSTANT_VECTOR;

		UnifiedVectorFormat regex_format;
		regex_vector.ToUnifiedFormat(regex_format);
		const string_t *regex_data = UnifiedVectorFormat::GetData<string_t>(regex_format);

		if (dedup) {
			// Dictionary indices only mean anything within the chunk that produced them.
			lstate.dict_stamp++;
		}

		CALI_MARK_BEGIN("stage_rows_for_fpga_batch");
		while (lstate.chunk_offset < current_chunk.size() && lstate.output_cache.size() == 0) {
			const idx_t row_idx = lstate.chunk_offset;
			const idx_t regex_idx = regex_format.sel->get_index(row_idx);
			if (!regex_format.validity.RowIsValid(regex_idx)) {
				lstate.chunk_offset++;
				continue;
			}

			// Reuse the slot if this dictionary entry has already been sent in this batch.
			idx_t slot = DConstants::INVALID_INDEX;
			if (dedup && regex_idx < lstate.dict_slot_stamp.size() &&
			    lstate.dict_slot_stamp[regex_idx] == lstate.dict_stamp) {
				slot = lstate.dict_slot_of[regex_idx];
			}
			const bool needs_slot = slot == DConstants::INVALID_INDEX;

			const string_t &regex_value = regex_data[regex_idx];
			const uint64_t next_length = regex_value.GetSize();
			// A single value only has to fit one engine's stream, and the rectangle
			// is 64 of those, so the bound is the buffer over the engine count.
			if (needs_slot && (next_length + 1) * celeris::kRegexEngineCount > lstate.wire_buffer_bytes) {
				throw InvalidInputException(
				    "regex_fpga_scan: a %llu byte value in column %s does not fit the %llu byte FPGA wire buffer",
				    (unsigned long long)regex_value.GetSize(), bind_data.regex_column.c_str(),
				    (unsigned long long)lstate.wire_buffer_bytes);
			}

			// Outliers go in a batch of their own. The collector pops all 64 engines
			// together, so one engine walking a multi-KB string holds the rest until
			// their result FIFOs fill, which backs pressure all the way to the
			// splitter and can wedge the array -- see kRegexOutlierBytes. Alone, every
			// engine owes exactly one result and nobody can run ahead.
			//
			// Flush what is staged, then let the outlier be staged into the empty
			// batch; the byte/row caps below close it again on the next row.
			if (needs_slot && next_length >= lstate.outlier_bytes && lstate.staged_rows > 0) {
				CALI_MARK_END("stage_rows_for_fpga_batch");
				FlushFpgaBatch(bind_data, global_state, lstate, true);
				if (lstate.output_cache.size() > 0) {
					return;
				}
				CALI_MARK_BEGIN("stage_rows_for_fpga_batch");
				continue;
			}
			// ...and close the batch again immediately after one, so it stays solo.
			if (lstate.batch_has_outlier && lstate.staged_rows > 0) {
				CALI_MARK_END("stage_rows_for_fpga_batch");
				FlushFpgaBatch(bind_data, global_state, lstate, true);
				if (lstate.output_cache.size() > 0) {
					return;
				}
				CALI_MARK_BEGIN("stage_rows_for_fpga_batch");
				continue;
			}

			if (lstate.staged_rows > 0 && WouldExceedFpgaBatch(lstate, next_length, needs_slot)) {
				// Send what we have and retry this row against a fresh batch. chunk_offset is left
				// pointing at the row, so it is staged exactly once. Keeping the current chunk is
				// required even at offset 0: it still holds the rows we are about to stage.
				CALI_MARK_END("stage_rows_for_fpga_batch");
				FlushFpgaBatch(bind_data, global_state, lstate, true);
				if (lstate.output_cache.size() > 0) {
					return;
				}
				CALI_MARK_BEGIN("stage_rows_for_fpga_batch");
				continue;
			}

			if (needs_slot) {
				// Straight into the wire layout, no descriptor and no second pass.
				// The slot is the append order, which is what result_bit_index maps
				// back from once the card returns its engine-major bitmap.
				slot = lstate.packer.append(regex_value.GetData(), next_length);
				D_ASSERT(slot == lstate.accum_count);
				lstate.accum_count++;
				if (next_length >= lstate.outlier_bytes) {
					lstate.batch_has_outlier = true;
				}
				if (dedup) {
					if (regex_idx >= lstate.dict_slot_stamp.size()) {
						lstate.dict_slot_of.resize(regex_idx + 1, 0);
						lstate.dict_slot_stamp.resize(regex_idx + 1, 0);
					}
					lstate.dict_slot_of[regex_idx] = slot;
					lstate.dict_slot_stamp[regex_idx] = lstate.dict_stamp;
				}
			}

			lstate.batch_row_refs.push_back({lstate.current_retained_chunk_idx, row_idx, slot});
			lstate.staged_rows++;
			lstate.chunk_offset++;
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
	table_function.filter_pushdown = true;
	table_function.filter_prune = true;
	loader.RegisterFunction(table_function);
}

} // namespace duckdb
