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

#include <chrono>
#include <cstdio>
#include <cstdlib>

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

static void StartNewStagedBatch(RegexFpgaScanLocalState &lstate, celeris::CelerisContext &ctx);

// Phase timing for the host scan path. Per chunk, not per row -- see RegexBatchPhases.
using StageClock = std::chrono::steady_clock;
static inline uint64_t StageNanos(const StageClock::time_point &t) {
	return uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(StageClock::now() - t).count());
}
static bool CollectOldestTransfer(RegexFpgaScanLocalState &lstate);

static void BuildScanColumns(const RegexFpgaScanBindData &bind_data, const TableFunctionInitInput &input,
                             vector<ColumnIndex> &scan_column_indexes, vector<StorageIndex> &scan_storage_ids,
                             vector<LogicalType> &scan_types, idx_t &scanned_regex_column_idx) {
	scan_column_indexes.clear();
	scan_storage_ids.clear();
	scan_types.clear();
	scanned_regex_column_idx = DConstants::INVALID_INDEX;

	if (input.column_indexes.empty()) {
		// Projection pushdown is enabled on this function, so an empty request means the
		// caller wants no columns back -- a count(*), or a semi-join that only needs the
		// row count. Read only the column the pattern is matched against.
		//
		// This used to scan and emit every column instead, which made count(*) the most
		// expensive projection rather than the cheapest: every retained chunk had its
		// whole string column copied into its own heap by MaterializeRetainedColumns for
		// output nobody reads. Measured at 597 ms of a 2.59 s scan, the same as
		// count(s), which genuinely needs the column.
		scan_column_indexes.emplace_back(bind_data.regex_column_idx);
		scan_storage_ids.push_back(bind_data.table.GetStorageIndex(scan_column_indexes[0]));
		scan_types.push_back(GetScanColumnType(bind_data.table, scan_column_indexes[0]));
		scanned_regex_column_idx = 0;
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
		// Nothing requested, so nothing emitted -- and with an empty map
		// MaterializeRetainedColumns has no work at all, which is the point. The regex
		// column BuildScanColumns read is consumed through ToUnifiedFormat during
		// staging and never outlives the chunk, so it needs no copy.
		return output_map;
	}
	if (input.projection_ids.empty()) {
		// projection_ids lists the columns that actually reach the output, and this
		// function sets filter_prune, so DuckDB always populates it when it wants any.
		// Empty therefore means none -- the shape of count(*), which still names the
		// regex column in column_indexes because the scan has to read it to match, but
		// projects nothing out of it.
		//
		// This used to emit every entry of column_indexes here, which made count(*) pay
		// MaterializeRetainedColumns over the whole string column for output nobody
		// reads: 602 ms of a 2.60 s single-threaded scan, identical to count(s), which
		// genuinely needs it. Verified against DuckDB's actual pushdown -- count(*) gives
		// projection_ids=0 while both count(s) and a bare `SELECT s` give 1.
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
	return *lstate.retained_chunks[lstate.current_retained_chunk_idx].chunk;
}

// Position of a chunk id in retained_chunks. Ids are handed out sequentially and the
// deque only ever grows at the back and shrinks at the front, so the ids it holds stay
// contiguous and the position is arithmetic rather than a search.
static idx_t RetainedChunkIndex(const RegexFpgaScanLocalState &lstate, uint32_t chunk_id) {
	D_ASSERT(!lstate.retained_chunks.empty());
	D_ASSERT(chunk_id >= lstate.retained_chunks.front().id);
	const idx_t index = idx_t(chunk_id - lstate.retained_chunks.front().id);
	D_ASSERT(index < lstate.retained_chunks.size());
	return index;
}

// Drops the staging ref if it is still held. Idempotent, which it has to be: the
// release runs on every submit, and a scanned chunk that fills more than one batch is
// walked past by several of them.
static void ReleaseStagingRef(RetainedChunk &entry) {
	if (!entry.staging_ref) {
		return;
	}
	entry.staging_ref = false;
	D_ASSERT(entry.pending_refs > 0);
	entry.pending_refs--;
}

// Drops chunks at the front that nothing references any more, and slides the staging
// cursor to match. Only the front is examined: chunks are referenced in scan order, so
// a live one at the front means everything behind it is live too.
static void ReleaseRetiredChunks(RegexFpgaScanLocalState &lstate) {
	while (!lstate.retained_chunks.empty() && lstate.retained_chunks.front().pending_refs == 0) {
		lstate.retained_chunks.pop_front();
		if (lstate.current_retained_chunk_idx != DConstants::INVALID_INDEX) {
			// The cursor is an index into a deque that just lost its front. It can never
			// be the popped element itself: that one still holds its staging ref.
			D_ASSERT(lstate.current_retained_chunk_idx > 0);
			lstate.current_retained_chunk_idx--;
		}
	}
	if (lstate.retained_chunks.empty()) {
		lstate.current_retained_chunk_idx = DConstants::INVALID_INDEX;
	}
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

	// The device saturates well below DuckDB's default scan parallelism, so let a query cap the
	// scan's threads and leave the rest of the pool to the operators downstream of it.
	Value max_threads_value;
	if (context.TryGetCurrentSetting("oasis_regex_max_threads", max_threads_value) &&
	    !max_threads_value.IsNull()) {
		const auto cap = UBigIntValue::Get(max_threads_value);
		if (cap > 0 && cap < gstate->max_threads) {
			gstate->max_threads = cap;
		}
	}

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
	if (std::getenv("OASIS_REGEX_DIAG")) {
		std::fprintf(stderr,
		             "[regexdiag] projection: column_indexes=%zu projection_ids=%zu scan_cols=%zu output_map=%zu\n",
		             (size_t)input.column_indexes.size(), (size_t)input.projection_ids.size(),
		             (size_t)scan_column_indexes.size(), (size_t)lstate->output_column_map.size());
	}

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
			// kRegexMaxStringsPerEngine - 1, not kRegexMaxStringsPerEngine: one result
			// slot per engine is spoken for by the terminated filler run finalize()
			// appends (see kRegexFillerByte). At the un-reduced cap finalize() would
			// throw rather than overrun, but throwing on a legal setting is not a
			// useful failure.
			const uint64_t cap =
			    uint64_t(celeris::kRegexMaxStringsPerEngine - 1) * celeris::kRegexEngineCount;
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
	if (context.client.TryGetCurrentSetting("oasis_regex_max_in_flight", setting_value) && !setting_value.IsNull()) {
		const auto depth = setting_value.GetValue<uint64_t>();
		if (depth > 0) {
			lstate->max_in_flight = idx_t(depth);
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

	// One wire buffer up front; the rest of the window's buffers are allocated on first
	// use in StartNewStagedBatch. A scan that never fills a batch therefore costs one
	// buffer, not max_in_flight of them.
	StartNewStagedBatch(*lstate, gstate.ctx);

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
	if (lstate.scan_exhausted) {
		// Re-entered to drain the in-flight window. The storage scan is finished and
		// must not be touched again -- and current_retained_chunk_idx has already been
		// cleared, so the cursor check below would restart it.
		return false;
	}
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
		const auto t_scan = StageClock::now();
		storage.Scan(transaction, *retained, lstate.scan_state);
		AddRegexScanNs(StageNanos(t_scan));
		CALI_MARK_END("table_scan");
		// A scanned chunk is only borrowed, but we retain chunks across several scans while an
		// FPGA batch fills up, so make the columns we will emit self-contained before holding on.
		CALI_MARK_BEGIN("materialize_chunk");
		const auto t_mat = StageClock::now();
		MaterializeRetainedColumns(*retained, lstate.output_column_map);
		AddRegexMaterializeNs(StageNanos(t_mat));
		CALI_MARK_END("materialize_chunk");
		lstate.chunk_offset = 0;
		if (retained->size() > 0) {
			// One staging ref, covering both the cursor reading this chunk and any rows
			// it contributes to the batch that is still being packed. It is dropped at
			// the submit that carries those rows away, by which point the transfer holds
			// its own ref -- see SubmitStagedBatch.
			RetainedChunk entry;
			entry.id = lstate.next_chunk_id++;
			entry.chunk = std::move(retained);
			entry.pending_refs = 1;
			entry.staging_ref = true;
			lstate.retained_chunks.push_back(std::move(entry));
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

// Hands the packer a fresh wire buffer and clears the per-batch staging state. The
// buffer that was being packed is not reused: it is pinned by the DMA until its
// transfer is collected, at which point it returns to free_wire_buffers.
static void StartNewStagedBatch(RegexFpgaScanLocalState &lstate, celeris::CelerisContext &ctx) {
	lstate.accum_count = 0;
	lstate.staged_rows = 0;
	// Take a recycled ref vector if one is free -- clear() keeps its capacity, whereas a
	// fresh vector would regrow and fault pages in on every batch.
	if (!lstate.free_row_refs.empty()) {
		lstate.batch_row_refs = std::move(lstate.free_row_refs.back());
		lstate.free_row_refs.pop_back();
		lstate.batch_row_refs.clear();
	} else {
		lstate.batch_row_refs.clear();
		lstate.batch_row_refs.reserve(lstate.max_accum_count);
	}
	// The slots those dictionary entries pointed at went with the batch.
	lstate.dict_stamp++;

	if (lstate.free_wire_buffers.empty()) {
		libstf::Status status;
		auto buffer = libstf::make_buffer(ctx.get_memory_pool(), lstate.wire_buffer_bytes, status);
		if (!status.ok()) {
			throw InternalException("Failed to allocate FPGA regex wire buffer for table scan");
		}
		lstate.free_wire_buffers.push_back(std::move(buffer));
	}
	lstate.wire_buffer = std::move(lstate.free_wire_buffers.back());
	lstate.free_wire_buffers.pop_back();
	lstate.packer.reset(static_cast<uint8_t *>(lstate.wire_buffer->ptr), lstate.wire_buffer_bytes);
}

static void AppendMatchedRows(RegexFpgaScanLocalState &lstate, const InFlightTransfer &transfer,
                              const RegexMatchBitmap &matches) {
	auto &matches_by_chunk = lstate.match_indices_scratch;
	matches_by_chunk.resize(lstate.retained_chunks.size());
	for (auto &row_indices : matches_by_chunk) {
		row_indices.clear();
	}
	// One entry per row the transfer decides, which is more than the strings sent to the FPGA
	// whenever rows shared a dictionary entry: several rows then read the same slot's match bit.
	for (const auto &row_ref : transfer.row_refs) {
		// A ref carries either a card slot or a verdict already computed on the CPU, so
		// the two kinds interleave in scan order and neither needs a merge pass.
		const bool matched =
		    row_ref.slot_idx == kCpuResolvedSlot ? row_ref.cpu_match : matches.test(row_ref.slot_idx);
		if (!matched) {
			continue;
		}
		matches_by_chunk[RetainedChunkIndex(lstate, row_ref.chunk_id)].push_back(row_ref.row_idx);
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
		projected.ReferenceColumns(*lstate.retained_chunks[chunk_idx].chunk, lstate.output_column_map);
		lstate.output_cache.Append(projected, lstate.match_sel_scratch, row_indices.size());
		// Append copies string_t values, which are pointers into the source chunk's string buffer.
		// The retained chunks are released as soon as this transfer is collected, so hold a reference
		// to their heaps or the cached strings dangle until the caller drains output_cache.
		for (idx_t out_idx = 0; out_idx < projected.ColumnCount(); out_idx++) {
			if (projected.data[out_idx].GetType().InternalType() == PhysicalType::VARCHAR) {
				StringVector::AddHeapReference(lstate.output_cache.data[out_idx], projected.data[out_idx]);
			}
		}
	}
}

// Squares off the staged batch, hands it to the card and pushes it onto the in-flight
// window. Does NOT wait for results -- that is CollectOldestTransfer.
static void SubmitStagedBatch(const RegexFpgaScanBindData &bind_data, RegexFpgaScanGlobalState &global_state,
                              RegexFpgaScanLocalState &lstate) {
	CALI_CXX_MARK_FUNCTION;
	// staged_rows, not accum_count: a batch whose rows were all outliers has rows to
	// deliver and no strings to send. It still becomes a transfer -- one with an
	// unarmed submission -- so those rows reach the output cache in scan order along
	// with everything else.
	if (lstate.staged_rows == 0) {
		return;
	}

	// Take this submission's arm credit before anything else, and never block on it
	// while holding transfers we could collect instead.
	//
	// The credits are process-wide but the window is per-thread, so a thread can run
	// out of credits long before its own window is full -- and if every thread is in
	// that state, every credit is held by a thread waiting for one more and no thread
	// ever reaches the collect that would release one. Observed directly: 3 threads at
	// window 8 issued 16 submissions and zero collects, then all blocked. Collecting
	// our own oldest transfer always frees a credit, so this loop cannot spin forever.
	const bool arms_device = !global_state.dry_run && lstate.accum_count > 0;
	if (arms_device) {
		while (!TryAcquireRegexArmCredit()) {
			if (lstate.in_flight.empty()) {
				// Nothing of ours to collect, so someone else holds them all and will
				// release; waiting is safe and is the only option.
				AcquireRegexArmCredit();
				break;
			}
			CollectOldestTransfer(lstate);
		}
	}

	CALI_MARK_BEGIN("fpga_regex_submit");
	// Squares off the rectangle: pads the short engines and fills the tails. Has to
	// happen before the enqueue and after the last append, so it lives here rather
	// than in the staging loop.
	const celeris::RegexStreamPacker::Plan plan = lstate.packer.finalize();

	InFlightTransfer transfer;
	transfer.count = lstate.accum_count;
	transfer.row_refs = std::move(lstate.batch_row_refs);
	transfer.wire_buffer = lstate.wire_buffer;
	transfer.dry_run = global_state.dry_run;

	// Take a ref on every chunk this transfer's rows come from, so the chunks outlive
	// the device round trip however far the scan runs ahead. Refs are per distinct
	// chunk, not per row: the row refs are in scan order, so consecutive rows from the
	// same chunk collapse without a set.
	uint32_t last_id = 0;
	bool have_last = false;
	for (const auto &row_ref : transfer.row_refs) {
		if (have_last && row_ref.chunk_id == last_id) {
			continue;
		}
		lstate.retained_chunks[RetainedChunkIndex(lstate, row_ref.chunk_id)].pending_refs++;
		transfer.chunk_ids.push_back(row_ref.chunk_id);
		last_id = row_ref.chunk_id;
		have_last = true;
	}

	// The batch is fully packed by this point either way, so a dry run leaves exactly the host-side
	// scan-and-pack cost and drops the enqueue, the device wait and the result read-back.
	if (!transfer.dry_run && lstate.accum_count > 0) {
		transfer.submission = SubmitRegexBatch(global_state.ctx, lstate.wire_buffer->ptr, plan,
		                                       lstate.accum_count, bind_data.regex_blob);
		D_ASSERT(transfer.submission.valid());
	}
	lstate.in_flight.push_back(std::move(transfer));
	CALI_MARK_END("fpga_regex_submit");

	// Every chunk the cursor has already moved past is now owned by the transfers that
	// reference it, so drop the staging ref. The chunk the cursor is still inside keeps
	// its ref -- rows from it may yet be staged into the next batch.
	const idx_t keep_from =
	    lstate.current_retained_chunk_idx == DConstants::INVALID_INDEX ? 0 : lstate.current_retained_chunk_idx;
	for (idx_t i = 0; i < keep_from; i++) {
		ReleaseStagingRef(lstate.retained_chunks[i]);
	}
	ReleaseRetiredChunks(lstate);

	StartNewStagedBatch(lstate, global_state.ctx);
}

// Waits for the oldest outstanding transfer, turns its bitmap into output rows and
// releases everything it was holding. Returns false if the window was empty.
//
// Blocking on the *oldest* of several is what makes the window pay: the ones behind it
// are already on the card, so the wait overlaps their matching rather than serialising
// against it.
static bool CollectOldestTransfer(RegexFpgaScanLocalState &lstate) {
	CALI_CXX_MARK_FUNCTION;
	if (lstate.in_flight.empty()) {
		return false;
	}

	InFlightTransfer transfer = std::move(lstate.in_flight.front());
	lstate.in_flight.pop_front();

	CALI_MARK_BEGIN("fpga_regex_collect");
	RegexMatchBitmap matches;
	if (transfer.dry_run || !transfer.submission.valid()) {
		// Nothing was armed: a dry run, or a batch made up entirely of CPU-resolved
		// outliers. Either way no slot ref can exist, so an all-zero bitmap is never read.
		matches.assign_zero(transfer.count);
	} else {
		matches = CollectRegexBatch(transfer.submission);
	}
	CALI_MARK_END("fpga_regex_collect");

	CALI_MARK_BEGIN("append_output_cache");
	const auto t_emit = StageClock::now();
	AppendMatchedRows(lstate, transfer, matches);
	AddRegexEmitNs(StageNanos(t_emit));
	CALI_MARK_END("append_output_cache");

	// Order matters: the rows have been copied out of the chunks above, so the refs can
	// go now and the chunks with them.
	for (const uint32_t chunk_id : transfer.chunk_ids) {
		auto &entry = lstate.retained_chunks[RetainedChunkIndex(lstate, chunk_id)];
		D_ASSERT(entry.pending_refs > 0);
		entry.pending_refs--;
	}
	ReleaseRetiredChunks(lstate);

	// The DMA is done with the wire buffer, so it can be packed into again.
	if (transfer.wire_buffer) {
		lstate.free_wire_buffers.push_back(std::move(transfer.wire_buffer));
	}
	// Keep the ref vector's allocation for the next batch; its contents are consumed.
	transfer.row_refs.clear();
	lstate.free_row_refs.push_back(std::move(transfer.row_refs));
	return true;
}

RegexFpgaScanLocalState::~RegexFpgaScanLocalState() {
	// A LIMIT or a cancelled query destroys this while transfers are still on the card.
	// Their handles sit in OutputBufferManager's process-wide positional queue, so
	// abandoning one does not merely leak it -- the *next* transfer's results, belonging
	// to some other thread, are delivered into it instead. Drain and discard.
	//
	// Nothing here may throw: this runs during unwinding of whatever ended the scan.
	while (!in_flight.empty()) {
		InFlightTransfer transfer = std::move(in_flight.front());
		in_flight.pop_front();
		if (transfer.dry_run) {
			continue;
		}
		try {
			(void)CollectRegexBatch(transfer.submission);
		} catch (...) {
			// Swallowed deliberately. The handle is consumed either way, which is the
			// part that matters for every other thread; there is nobody left to report to.
		}
	}
}

// Decides one outlier on the CPU.
//
// RE2 rather than std::regex, deliberately: libstdc++'s std::regex is recursive, and
// this path exists precisely for the multi-KB values that blow its stack -- the celeris
// testbench documents the same limit for its own reference matcher and caps subjects at
// 8 KB to stay under it. RE2 is already linked (DuckDB bundles it) and is what DuckDB's
// own regexp functions use, so this agrees with what a CPU-side query would have said.
//
// RegexMatch is a full match, which is the card's semantics and SIMILAR TO's.
static bool MatchOutlierOnHost(const RegexFpgaScanBindData &bind_data, RegexFpgaScanLocalState &lstate,
                               const string_t &value) {
	CALI_CXX_MARK_FUNCTION;
	if (!lstate.cpu_regex) {
		try {
			lstate.cpu_regex = make_uniq<duckdb_re2::Regex>(bind_data.pattern);
		} catch (const std::exception &e) {
			// The NFA accepted this pattern for the card but RE2 will not take it, and a
			// value too long to send has just turned up. Say both halves: the pattern is
			// fine for the scan right up until an outlier appears, so the length is as
			// much a part of the diagnosis as the pattern is.
			throw InvalidInputException(
			    "regex_fpga_scan: a value in column %s is at or above the %llu byte threshold and must be "
			    "matched on the host, but the pattern '%s' does not compile for the host matcher: %s. "
			    "Raise oasis_regex_outlier_bytes to send it to the card instead, or rewrite the pattern.",
			    bind_data.regex_column.c_str(), (unsigned long long)lstate.outlier_bytes,
			    bind_data.pattern.c_str(), e.what());
		}
	}
	const char *data = value.GetData();
	// Pointer range, not a std::string: these are the values big enough that copying
	// them to ask one question would be the most expensive thing on this path. The
	// overload that takes a range needs a Match to fill; the groups are discarded.
	duckdb_re2::Match groups;
	return duckdb_re2::RegexMatch(data, data + value.GetSize(), groups, *lstate.cpu_regex);
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
	//
	// fits(), not wire_size_after(): this runs once per scanned row, and the rectangle
	// form recomputed a divide, a modulo and a round-up every time to answer a question
	// whose answer only changes when the longest engine stream crosses a chunk boundary.
	// The two are exactly equivalent and packer_test cross-checks them on every string.
	return !lstate.packer.fits(next_length);
}

static void AccumulateRows(const RegexFpgaScanBindData &bind_data, RegexFpgaScanGlobalState &global_state,
                           RegexFpgaScanLocalState &lstate, ClientContext &context) {
	CALI_CXX_MARK_FUNCTION;
	while (lstate.output_cache.size() == 0 && !lstate.finished) {
		if (!TryRefillScanChunk(context, bind_data, global_state, lstate)) {
			// Scan exhausted. Submit whatever is staged, then drain the window: every
			// outstanding transfer still owes rows, and there is nothing left to overlap
			// them with. Collecting stops early once the cache has rows -- the rest stay
			// on the card and are collected on the next call, which is exactly the
			// overlap the window exists for.
			SubmitStagedBatch(bind_data, global_state, lstate);
			// The cursor's chunk has no more rows to give, so its staging ref goes too.
			// Without this the last chunk of the scan is never released. Guarded by
			// scan_exhausted because this branch is re-entered once per GetData call
			// while the window drains, and the ref must only be dropped once.
			if (!lstate.scan_exhausted) {
				lstate.scan_exhausted = true;
				if (lstate.current_retained_chunk_idx != DConstants::INVALID_INDEX) {
					ReleaseStagingRef(lstate.retained_chunks[lstate.current_retained_chunk_idx]);
					// Clearing the cursor keeps ReleaseRetiredChunks from trying to slide
					// an index that no longer tracks anything.
					lstate.current_retained_chunk_idx = DConstants::INVALID_INDEX;
					ReleaseRetiredChunks(lstate);
				}
			}
			while (lstate.output_cache.size() == 0 && CollectOldestTransfer(lstate)) {
			}
			if (lstate.in_flight.empty()) {
				lstate.finished = true;
			}
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
		auto t_stage = StageClock::now();
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

			// Outliers are matched here and never reach the card. The card's hazard is
			// length skew -- the collector pops all 64 engines together, so one engine
			// walking a multi-KB string holds the rest until their result FIFOs fill and
			// the array wedges (see kRegexOutlierBytes). Keeping them off the wire
			// removes the skew rather than working around it, and it removes the solo
			// batch this used to need: one device round trip to decide one row, with
			// 63*L of filler paid to carry it.
			//
			// The verdict rides in the row ref, so scan order is preserved with no merge.
			if (needs_slot && next_length >= lstate.outlier_bytes) {
				lstate.batch_row_refs.push_back(
				    {lstate.retained_chunks[lstate.current_retained_chunk_idx].id, kCpuResolvedSlot,
				     static_cast<uint16_t>(row_idx), MatchOutlierOnHost(bind_data, lstate, regex_value)});
				lstate.staged_rows++;
				lstate.chunk_offset++;
				continue;
			}

			// A single value only has to fit one engine's stream, and the rectangle
			// is 64 of those, so the bound is the buffer over the engine count. Only
			// reachable below the outlier threshold now, so it fires solely when the
			// wire buffer has been configured smaller than 64x that threshold.
			if (needs_slot && (next_length + 1) * celeris::kRegexEngineCount > lstate.wire_buffer_bytes) {
				throw InvalidInputException(
				    "regex_fpga_scan: a %llu byte value in column %s does not fit the %llu byte FPGA wire buffer",
				    (unsigned long long)regex_value.GetSize(), bind_data.regex_column.c_str(),
				    (unsigned long long)lstate.wire_buffer_bytes);
			}

			// The batch closes when the row or byte caps bind. chunk_offset is left
			// pointing at the row, so it is staged exactly once against the next batch.
			if (lstate.staged_rows > 0 && WouldExceedFpgaBatch(lstate, next_length, needs_slot)) {
				AddRegexStageNs(StageNanos(t_stage));
				CALI_MARK_END("stage_rows_for_fpga_batch");
				SubmitStagedBatch(bind_data, global_state, lstate);
				// The window is full, so wait for the oldest transfer. Blocking here
				// rather than at submit is the point: the other max_in_flight - 1
				// transfers are still on the card while this one is read back.
				//
				// Collecting before the submit instead was tried, to see whether it cut
				// peak credit demand. It does not: in steady state a thread with a window
				// of W has W transfers on the card either way, so it holds W credits
				// either way. Measured identical, so the simpler order stands.
				if (lstate.in_flight.size() >= lstate.max_in_flight) {
					CollectOldestTransfer(lstate);
				}
				if (lstate.output_cache.size() > 0) {
					return;
				}
				CALI_MARK_BEGIN("stage_rows_for_fpga_batch");
		auto t_stage = StageClock::now();
				continue;
			}

			if (needs_slot) {
				// Straight into the wire layout, no descriptor and no second pass.
				// The slot is the append order, which is what result_bit_index maps
				// back from once the card returns its engine-major bitmap.
				slot = lstate.packer.append(regex_value.GetData(), next_length);
				D_ASSERT(slot == lstate.accum_count);
				lstate.accum_count++;
				if (dedup) {
					if (regex_idx >= lstate.dict_slot_stamp.size()) {
						lstate.dict_slot_of.resize(regex_idx + 1, 0);
						lstate.dict_slot_stamp.resize(regex_idx + 1, 0);
					}
					lstate.dict_slot_of[regex_idx] = slot;
					lstate.dict_slot_stamp[regex_idx] = lstate.dict_stamp;
				}
			}

			lstate.batch_row_refs.push_back({lstate.retained_chunks[lstate.current_retained_chunk_idx].id,
			                                 static_cast<uint32_t>(slot), static_cast<uint16_t>(row_idx), false});
			lstate.staged_rows++;
			lstate.chunk_offset++;
		}
		AddRegexStageNs(StageNanos(t_stage));
		CALI_MARK_END("stage_rows_for_fpga_batch");
	}

	// Left the staging loop with nothing to emit: either the current chunk ran out or
	// the batch filled. Submit what is staged and collect the oldest transfer, which is
	// where a scan that is keeping the card fed actually spends its device time.
	if (lstate.output_cache.size() == 0 && !lstate.finished) {
		SubmitStagedBatch(bind_data, global_state, lstate);
		if (!lstate.in_flight.empty()) {
			CollectOldestTransfer(lstate);
		}
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
