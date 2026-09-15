#include "regex_table.hpp"
#include "regex_fpga_batch.hpp"

#include "duckdb/catalog/catalog_entry/duck_table_entry.hpp"
#include "duckdb/catalog/catalog_entry/table_catalog_entry.hpp"
#include "duckdb/common/identifier.hpp"
#include "duckdb/common/types/data_chunk.hpp"
#include "duckdb/common/types/vector.hpp"
#include "duckdb/common/fsst.hpp"
#include "duckdb/common/vector/fsst_vector.hpp"
#include "duckdb/common/vector_size.hpp"
#include "duckdb/execution/partition_info.hpp"
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
#include "fsst.h" // duckdb_fsst_decoder_t, for the zeroTerminated check
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

static void StartNewStagedBatch(RegexFpgaScanLocalState &lstate, celeris::CelerisContext &ctx);

// Phase timing for the host scan path. Per chunk, not per row -- see RegexBatchPhases.
using StageClock = std::chrono::steady_clock;
static inline uint64_t StageNanos(const StageClock::time_point &t) {
	return uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(StageClock::now() - t).count());
}
static bool CollectOldestTransfer(RegexFpgaScanLocalState &lstate);



// How close to the row cap a batch has to be before it is allowed to close early on a
// chunk boundary. One chunk of a 64 B string is 4 strings per engine, i.e. 256 rows; at
// 512 the rule can fire for anything up to 128 B strings and still give up at most half
// a percent of the batch.
static constexpr idx_t kBoundaryCloseSlack = 512;

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
// Returns a scanned chunk to the per-thread pool. Bounded, so a burst of retained chunks does
// not pin their memory for the rest of the scan.
static void RecycleChunk(RegexFpgaScanLocalState &lstate, unique_ptr<DataChunk> chunk) {
	static constexpr idx_t kChunkPoolMax = 64;
	if (!lstate.chunk_recycle || !chunk || lstate.chunk_pool.size() >= kChunkPoolMax) {
		return;
	}
	chunk->Reset();
	lstate.chunk_pool.push_back(std::move(chunk));
}

static void ReleaseRetiredChunks(RegexFpgaScanLocalState &lstate) {
	while (!lstate.retained_chunks.empty() && lstate.retained_chunks.front().pending_refs == 0) {
		RecycleChunk(lstate, std::move(lstate.retained_chunks.front().chunk));
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
	NoteRegexQueryStart();
	storage.InitializeParallelScan(context, gstate->parallel_scan, input.column_indexes);
	gstate->max_threads = storage.MaxThreads(context);

	// Scan threads are capped by the arm-credit pool, not by the machine.
	//
	// Every transfer on the card holds one arm credit, and there are exactly
	// kRegexMaxSubmissionsInFlight (64) of them because that is the depth of the RTL's
	// strings_in_batch queue, which does not back-pressure. A thread that cannot get a
	// credit stops packing and collects instead, so T threads each keeping W transfers
	// outstanding need T*W <= 64 or they spend the scan taking credits off each other.
	//
	// The default window is now 4, so the cap is 16 threads -- the best point measured on the
	// 128-engine card (see REGEX_FPGA_DEFAULT_IN_FLIGHT). The history below is from the
	// 64-engine card with 32 credits, when W=2 and a 16-thread cap won.
	//
	// That fixes the shape of the operating point rather than leaving it to the machine's
	// core count. W = 1 makes a thread wait out its own device round trip before it packs
	// again -- the only overlap it gets is other threads' -- so the useful window is 2,
	// and that puts the thread cap at 16. Measured at 32 threads over 283 MB, paired over
	// 16 rounds of benchmark_runner:
	//
	//   32 threads, W=1  26.78 ms   (the previous default)
	//   32 threads, W=2  27.2  ms   demand 64 > 32 credits, threads block on credits
	//   16 threads, W=1  26.5  ms   half the packing power, still one round trip deep
	//   16 threads, W=2  25.98 ms   won 16 of 16 rounds
	//
	// It is a cap, not a target: a smaller machine keeps its own thread count. The host
	// can afford it -- with the device switched out (oasis_regex_dry_run) the scan-and-pack
	// path runs at 17.7 GB/s on 16 threads against 15.8 on 32, because 32 workers on 16
	// physical cores is already past the knee for this memory-bound work.
	Value max_in_flight_value;
	idx_t window = REGEX_FPGA_DEFAULT_IN_FLIGHT;
	if (context.TryGetCurrentSetting("oasis_regex_max_in_flight", max_in_flight_value) &&
	    !max_in_flight_value.IsNull()) {
		const auto depth = UBigIntValue::Get(max_in_flight_value);
		if (depth > 0) {
			window = idx_t(depth);
		}
	}
	const idx_t credit_cap = MaxValue<idx_t>(kRegexMaxSubmissionsInFlight / MaxValue<idx_t>(window, 1), 1);
	if (credit_cap < gstate->max_threads) {
		gstate->max_threads = credit_cap;
	}

	// An explicit setting still wins, in either direction.
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
	const auto t_init = StageClock::now();
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
	if (context.client.TryGetCurrentSetting("oasis_regex_fsst_passthrough", setting_value) &&
	    !setting_value.IsNull()) {
		lstate->fsst_passthrough = BooleanValue::Get(setting_value);
	}
	// No error when enable_fsst_vectors is off, although the passthrough is on by default. That
	// setting is GLOBAL_ONLY and defaults to false, so erroring would break every default query.
	// Without it every vector arrives flattened and every row rides the identity table: correct,
	// just uncompressed, and compressed_pct in regex_fpga_batch_phases() reads 0.
	//
	// Projecting the regex column is fine: RetainOutputColumns keeps its FSST vector compressed,
	// staging reads the compressed bytes, and AppendMatchedRows decompresses only matched rows.
	if (const char *late_env = std::getenv("OASIS_REGEX_LATE_MAT")) {
		lstate->late_materialize = late_env[0] != '0';
	}
	// A constant empty string, appended in place of a compressed column whose matched rows are
	// decompressed into the output cache afterwards. See AppendMatchedRows.
	lstate->empty_string_placeholder.SetVectorType(VectorType::CONSTANT_VECTOR);
	ConstantVector::SetNull(lstate->empty_string_placeholder, false);
	ConstantVector::GetData<string_t>(lstate->empty_string_placeholder)[0] = string_t(nullptr, 0);
	if (context.client.TryGetCurrentSetting("oasis_regex_max_in_flight", setting_value) && !setting_value.IsNull()) {
		const auto depth = setting_value.GetValue<uint64_t>();
		if (depth > 0) {
			lstate->max_in_flight = idx_t(depth);
		}
	}

	// Opening ramp: how many of this thread's first batches are shrunk. Defaults to
	// REGEX_FPGA_FILL_RAMP_STEPS; OASIS_REGEX_FILL_RAMP overrides it (0 disables the
	// ramp) so the two can be A/B'd in one build.
	lstate->fill_ramp_steps = REGEX_FPGA_FILL_RAMP_STEPS;
	if (const char *ramp_env = std::getenv("OASIS_REGEX_FILL_RAMP")) {
		lstate->fill_ramp_steps = idx_t(std::strtoul(ramp_env, nullptr, 10));
	}
	// Wire-byte target per batch. OASIS_REGEX_TARGET_WIRE_BYTES overrides
	// REGEX_FPGA_TARGET_WIRE_BYTES so the size can be swept without a rebuild; the row cap
	// (oasis_regex_batch_rows) is a backstop and cannot raise it.
	// Straddle side batch, on by default; OASIS_REGEX_SIDE_BATCH=0 restores one open batch.
	if (const char *side_env = std::getenv("OASIS_REGEX_SIDE_BATCH")) {
		lstate->side_batching = side_env[0] != '0';
	}
	// The side batch submits straddle rows after segment rows scanned later, so projected rows
	// would come out of scan order -- wrong under preserve_insertion_order, and a batch index that
	// goes backwards. Only a count, whose rows carry nothing, may keep it.
	//
	if (!lstate->output_column_map.empty()) {
		lstate->side_batching = false;
	}
	if (const char *fast_env = std::getenv("OASIS_REGEX_FAST_STAGE")) {
		lstate->fast_staging = fast_env[0] != '0';
	}
	if (const char *recycle_env = std::getenv("OASIS_REGEX_CHUNK_RECYCLE")) {
		lstate->chunk_recycle = recycle_env[0] != '0';
	}
	lstate->target_wire_bytes = REGEX_FPGA_TARGET_WIRE_BYTES;
	if (const char *target_env = std::getenv("OASIS_REGEX_TARGET_WIRE_BYTES")) {
		const auto bytes = std::strtoull(target_env, nullptr, 10);
		if (bytes > 0) {
			lstate->target_wire_bytes = bytes;
		}
	}
	// Row cap for batches on a real FSST table. Never below max_accum_count, and bounded by the
	// same result-FIFO limit oasis_regex_batch_rows is clamped to above.
	{
		uint64_t segment_rows = REGEX_FPGA_SEGMENT_ACCUM_COUNT;
		if (const char *segment_env = std::getenv("OASIS_REGEX_SEGMENT_ROWS")) {
			segment_rows = std::strtoull(segment_env, nullptr, 10);
		}
		const uint64_t fifo_cap = uint64_t(celeris::kRegexMaxStringsPerEngine - 1) * celeris::kRegexEngineCount;
		segment_rows = MinValue<uint64_t>(segment_rows, fifo_cap);
		lstate->segment_accum_count = MaxValue<idx_t>(lstate->max_accum_count, idx_t(segment_rows));
	}
	auto &storage = bind_data.table.GetStorage();
	// No table filters: filter_pushdown is off (see RegisterRegexFpgaScanFunction), so DuckDB
	// applies them above the scan and never hands any to this one.
	D_ASSERT(!input.filters || !input.filters->HasFilters());
	lstate->scan_state.Initialize(scan_storage_ids, context.client, nullptr);
	// segment_accum_count, not max_accum_count: a batch on a real FSST table may stage that many.
	lstate->output_cache.Initialize(context.client, lstate->output_types, lstate->segment_accum_count);
	lstate->batch_row_refs.reserve(lstate->segment_accum_count);
	lstate->match_sel_scratch.Initialize(STANDARD_VECTOR_SIZE);

	lstate->rows_in_current_row_group = storage.NextParallelScan(context.client, gstate.parallel_scan, lstate->scan_state);

	// One wire buffer up front; the rest of the window's buffers are allocated on first
	// use in StartNewStagedBatch. A scan that never fills a batch therefore costs one
	// buffer, not max_in_flight of them.
	StartNewStagedBatch(*lstate, gstate.ctx);

	AddRegexInitLocalNs(StageNanos(t_init));
	return std::move(lstate);
}

// The storage scan state that produced the chunk just scanned: the committed table, or the
// transaction-local rows once the committed ones are exhausted. Mirrors DataTable::Scan.
static CollectionScanState &ActiveCollectionScan(RegexFpgaScanLocalState &lstate) {
	auto &scan = lstate.scan_state;
	return scan.table_state.row_group ? scan.table_state : scan.local_state;
}

// Same rule as DuckDB's TableScanGetPartitionData.
static idx_t ScanBatchIndex(const RegexFpgaScanLocalState &lstate) {
	const auto &scan = lstate.scan_state;
	if (scan.table_state.row_group) {
		return scan.table_state.batch_index;
	}
	if (scan.local_state.row_group) {
		return scan.table_state.batch_index + scan.local_state.batch_index;
	}
	return 0;
}

// Records, per retained output string column, which segment the storage scan is positioned in,
// so RetainOutputColumns can tell which blocks the next chunk's strings can point into.
static void NoteSegmentsBeforeScan(RegexFpgaScanLocalState &lstate) {
	if (!lstate.late_materialize || lstate.output_column_map.empty()) {
		return;
	}
	auto &active = ActiveCollectionScan(lstate);
	lstate.scan_state_before_scan = &active;
	lstate.row_group_before_scan = active.row_group;
	lstate.segment_before_scan.assign(lstate.scanned_types.size(), nullptr);
	for (const auto col_idx : lstate.output_column_map) {
		if (col_idx < active.column_scans.size()) {
			lstate.segment_before_scan[col_idx] = active.column_scans[col_idx].current;
		}
	}
}

// Makes the output columns of a scanned chunk safe to hold across later scans, until every transfer
// reading its rows has been collected.
//
// Dictionary and constant vectors are flattened: their selection buffer is shared with the scan and
// overwritten by the next one. String payloads point into storage blocks the scan pins only until it
// moves on, and there are two ways to keep them:
//
//   pin      hold the blocks of the segment the scan started in and the one it ended in. Covers
//            every row of the chunk when those are the same segment or adjacent ones. An FSST vector
//            stays compressed, so only matched rows are ever decompressed -- in AppendMatchedRows.
//   copy     decompress and copy every string into the vector's own heap. The fallback when the scan
//            crossed more than one segment boundary, or with OASIS_REGEX_LATE_MAT=0.
//
// Strings DuckDB already placed in the vector's heap (FSST straddle reads, overflow strings) are
// safe under either.
static void RetainOutputColumns(ClientContext &context, RegexFpgaScanLocalState &lstate, DataChunk &chunk,
                                vector<BufferHandle> &pins) {
	if (lstate.output_column_map.empty()) {
		return;
	}
	optional_ptr<CollectionScanState> active;
	if (lstate.late_materialize && !lstate.segment_before_scan.empty()) {
		auto &current = ActiveCollectionScan(lstate);
		if (&current == lstate.scan_state_before_scan.get() &&
		    current.row_group.get() == lstate.row_group_before_scan.get()) {
			active = &current;
		}
	}
	for (const auto col_idx : lstate.output_column_map) {
		auto &vec = chunk.data[col_idx];
		if (vec.GetType().InternalType() != PhysicalType::VARCHAR) {
			vec.Flatten(chunk.size());
			continue;
		}
		if (active && col_idx < active->column_scans.size()) {
			const auto before = lstate.segment_before_scan[col_idx];
			const auto after = active->column_scans[col_idx].current;
			if (before && after && (before == after || before->GetIndex() + 1 == after->GetIndex())) {
				auto &buffer_manager = BufferManager::GetBufferManager(context);
				if (before != after) {
					pins.push_back(buffer_manager.Pin(before->GetNode().GetBlockHandle()));
				}
				pins.push_back(buffer_manager.Pin(after->GetNode().GetBlockHandle()));
				if (vec.GetVectorType() != VectorType::FSST_VECTOR) {
					vec.Flatten(chunk.size());
				}
				continue;
			}
		}
		vec.Flatten(chunk.size());
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

// Lays one FSST symbol table into the wire buffer in the card's format: two 64-bit words
// per code, word 2x the symbol little-endian and word 2x+1 its length minus one. See the
// layout note in common.sv -- the wasteful two-words-per-code shape is deliberate, so the
// RTL unpacks with a counter instead of a byte extractor.
//
// duckdb_fsst_decoder_t holds 255 codes; the 256th exists only to make the index a whole
// byte. Codes the table never uses carry len 0, which would underflow the stored len-1,
// so they are clamped -- the card never looks them up, but a garbage length there would
// be a live-lock waiting for a symbol that never ends.
// Sentinel "decoder" for the identity table. Batches are grouped by decoder pointer, so this
// only has to be a unique address that can never collide with a real duckdb_fsst_decoder_t.
static const uint8_t kIdentityDecoderTag = 0;
static const void *const kRegexIdentityDecoder = &kIdentityDecoderTag;

// A symbol table where code c decodes to the single byte c.
//
// This is what lets a segment-straddle row -- one DuckDB handed back decompressed, which
// therefore cannot join a batch carrying that segment's real table -- go to the CARD instead of
// to host RE2. Its plaintext bytes ARE valid codes under this table, so staging costs a memcpy
// and no encoding at all.
//
// The point is what it avoids. Routing those rows to RE2 costs ~27% of host time on an easy
// pattern and 90x on a hard one (.*[30-member class].{26}: 0.12 GB/s against 10.94 plaintext),
// because the accelerator inherits software's worst case on 10% of rows. The obvious
// alternative -- send them in a *plaintext* batch -- makes fsst_mode vary within a query, and
// that wedges the array: the mode is read from the arm-queue head at input time but popped at
// retire time, and it is a single global wire that all 64 engines read live, so queued beats
// get decoded under a newer transfer's mode. Confirmed in xsim (`--fsst-mismatch` and
// `--fsst-fixed` both hang; `--fsst-serial`, which drains between mode changes, passes).
//
// An identity batch is a *compressed* batch, so the mode never changes -- only the table does,
// and per-transfer table changes are already safe (double-buffered banks, and xsim passes 12
// pipelined transfers with a distinct table each). It needs no RTL change.
//
// Now that the card has no plaintext path, this carries every row that is not shipped compressed,
// not only straddles. Safe without escaping because code 0 is the terminator and 255 is FSST_ESC
// under zeroTerminated=1, and neither byte occurs: VARCHAR is valid UTF-8, where 0xFF never
// appears, and an interior 0x00 already split the string when the card took plaintext.
static void WriteIdentitySymbolTableHeader(uint8_t *header) {
	D_ASSERT(header != nullptr);
	auto *words = reinterpret_cast<uint64_t *>(header);
	for (uint32_t code = 0; code < celeris::kRegexSymbolCount; code++) {
		// Codes 0 and 255 are reserved and never emitted. Give them the same self-consistent
		// filler byte the unused-code path below uses -- decoding them to 0x00 would make the
		// compressed filler a delimiter and wedge the array, as documented there.
		const bool reserved = (code == 0) || (code >= 255);
		words[code * 2]     = reserved ? uint64_t(celeris::kRegexCompressedFillerByte) : uint64_t(code);
		words[code * 2 + 1] = 0;  // stored length is len-1, so 0 means one byte
	}
}

static void WriteSymbolTableHeader(uint8_t *header, const void *decoder) {
	D_ASSERT(header != nullptr && decoder != nullptr);
	const auto *dec = reinterpret_cast<const duckdb_fsst_decoder_t *>(decoder);
	auto *words = reinterpret_cast<uint64_t *>(header);
	for (uint32_t code = 0; code < celeris::kRegexSymbolCount; code++) {
		const bool real = code < 255;
		const uint8_t len = real ? dec->len[code] : 0;
		if (len > 0) {
			words[code * 2] = dec->symbol[code];
			words[code * 2 + 1] = uint64_t(len - 1) & 0x7;
			continue;
		}
		// An unused code must not decode to 0x00. The stored length is len-1, so a clamped
		// zero means "one byte of symbol 0" -- and symbol 0 is the empty symbol, so the card
		// emits a NUL and reads it as end-of-string.
		//
		// That is not hypothetical padding trivia: the compressed filler is code 0x01
		// (kRegexCompressedFillerByte), and any segment whose FSST table holds fewer than
		// two symbols leaves code 1 unused. Every filler byte would then terminate a string
		// instead of the run terminating once, the engine would report far more results than
		// Plan::strings_per_engine, and the array would wedge with no diagnosis. Reproduced
		// in RTL simulation on a batch of empty strings, whose table is empty outright.
		//
		// Decoding to the filler byte itself keeps it self-consistent: filler code 0x01
		// yields byte 0x01, which is neither a delimiter nor FSST_ESC.
		words[code * 2] = celeris::kRegexCompressedFillerByte;
		words[code * 2 + 1] = 0;
	}
}

// The code to pad a compressed batch with: the table's shortest symbol.
//
// finalize() squares every engine's stream off to whole 256 B chunks, and the engines walk the
// padding *decoded*. Code 1 is usually the segment's most valuable symbol, so often 8 B, which
// made up to 255 filler bytes per engine cost up to 2040 cycles per transfer. On the 128-engine
// bench that was ~6 us of every ~40 us transfer (72 B x 16384: 25.8 -> 29.8 GB/s with this).
//
// An unused code 1 already decodes to the single byte 0x01 (see WriteSymbolTableHeader), which
// is as short as it gets.
static uint8_t ShortestSymbolCode(const void *decoder) {
	const auto *dec = reinterpret_cast<const duckdb_fsst_decoder_t *>(decoder);
	uint8_t best = celeris::kRegexCompressedFillerByte;
	if (dec->len[best] == 0) {
		return best;
	}
	uint8_t best_len = dec->len[best];
	for (uint32_t code = 1; code < 255 && best_len > 1; code++) {
		if (dec->len[code] > 0 && dec->len[code] < best_len) {
			best = uint8_t(code);
			best_len = dec->len[code];
		}
	}
	return best;
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

	// The cursor's chunk is fully staged. With nothing projected, its data is never read again --
	// the wire holds the bytes and collect needs only row counts -- so its memory goes straight
	// back to the pool for the scan below. The entry stays in retained_chunks, empty, because
	// its id still anchors the refs and the release order.
	if (lstate.chunk_recycle && lstate.output_column_map.empty() &&
	    lstate.current_retained_chunk_idx != DConstants::INVALID_INDEX) {
		RecycleChunk(lstate, std::move(lstate.retained_chunks[lstate.current_retained_chunk_idx].chunk));
	}

	auto &storage = bind_data.table.GetStorage();
	auto &transaction = DuckTransaction::Get(context, bind_data.table.catalog);
	while (true) {
		unique_ptr<DataChunk> retained;
		if (!lstate.chunk_pool.empty()) {
			retained = std::move(lstate.chunk_pool.back());
			lstate.chunk_pool.pop_back();
		} else {
			retained = make_uniq<DataChunk>();
			retained->Initialize(context, lstate.scanned_types);
		}
		CALI_MARK_BEGIN("table_scan");
		NoteSegmentsBeforeScan(lstate);
		const auto t_scan = StageClock::now();
		storage.Scan(transaction, *retained, lstate.scan_state);
		AddRegexScanNs(StageNanos(t_scan));
		CALI_MARK_END("table_scan");
		lstate.chunk_offset = 0;
		if (retained->size() > 0) {
			// A scanned chunk is only borrowed, but we retain chunks across several scans while an
			// FPGA batch fills up, so make the columns we will emit safe to hold before holding on.
			RetainedChunk entry;
			CALI_MARK_BEGIN("materialize_chunk");
			const auto t_mat = StageClock::now();
			RetainOutputColumns(context, lstate, *retained, entry.pins);
			AddRegexMaterializeNs(StageNanos(t_mat));
			CALI_MARK_END("materialize_chunk");
			// One staging ref, covering both the cursor reading this chunk and any rows
			// it contributes to the batch that is still being packed. It is dropped at
			// the submit that carries those rows away, by which point the transfer holds
			// its own ref -- see SubmitStagedBatch.
			entry.id = lstate.next_chunk_id++;
			entry.batch_index = ScanBatchIndex(lstate);
			entry.chunk = std::move(retained);
			entry.pending_refs = 1;
			entry.staging_ref = true;
			lstate.retained_chunks.push_back(std::move(entry));
			lstate.current_retained_chunk_idx = lstate.retained_chunks.size() - 1;
			return true;
		}
		RecycleChunk(lstate, std::move(retained));

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
	lstate.accum_cap = lstate.max_accum_count;
	lstate.batch_payload_bytes = 0;
	lstate.batch_fsst_decoder = nullptr;
	lstate.batch_decoder_owner.reset();
	// Opening ramp: the first few batches are deliberately small so the card has
	// something to read while the rest of the first full batch is still being packed.
	// See REGEX_FPGA_FILL_RAMP_STEPS.
	lstate.batch_target_bytes = lstate.target_wire_bytes;
	if (lstate.batches_started < lstate.fill_ramp_steps) {
		lstate.batch_target_bytes >>= (lstate.fill_ramp_steps - lstate.batches_started);
	}
	lstate.batches_started++;
	// Take a recycled ref vector if one is free -- clear() keeps its capacity, whereas a
	// fresh vector would regrow and fault pages in on every batch.
	if (!lstate.free_row_refs.empty()) {
		lstate.batch_row_refs = std::move(lstate.free_row_refs.back());
		lstate.free_row_refs.pop_back();
		lstate.batch_row_refs.clear();
	} else {
		lstate.batch_row_refs.clear();
		lstate.batch_row_refs.reserve(lstate.segment_accum_count);
	}
	// The slots those dictionary entries pointed at went with the batch.
	lstate.dict_stamp++;

	if (lstate.free_wire_buffers.empty()) {
		const auto t_alloc = StageClock::now();
		libstf::Status status;
		auto buffer = libstf::make_buffer(ctx.get_memory_pool(), lstate.wire_buffer_bytes, status);
		if (!status.ok()) {
			throw InternalException("Failed to allocate FPGA regex wire buffer for table scan");
		}
		lstate.free_wire_buffers.push_back(std::move(buffer));
		AddRegexWireAllocNs(StageNanos(t_alloc));
	}
	lstate.wire_buffer = std::move(lstate.free_wire_buffers.back());
	lstate.free_wire_buffers.pop_back();
	lstate.packer.reset(static_cast<uint8_t *>(lstate.wire_buffer->ptr), lstate.wire_buffer_bytes);
	// After reset(), never before: reset() installs this batch's buffer and recomputes the
	// capacity, so a reservation taken earlier would be applied to the previous batch's
	// buffer and then thrown away -- leaving batch_symbol_header dangling.
	//
	// Taken on the batch's first row, not here: that row decides which table the batch rides
	// (real or identity), and the reservation must still precede every append because it moves
	// the packing origin. Every batch that ships has a first row, so every transfer carries a
	// header -- the card requires one. A batch of nothing but outliers ships no transfer.
	//
	// (An earlier note here blamed this line for hanging the default path. That measurement was
	// taken on a card already poisoned by an earlier wedge, so it was void; the default path
	// was fine.)
	lstate.batch_symbol_header = nullptr;
}

// Exchanges the active batch with the parked one. See RegexFpgaScanLocalState::parked.
static void SwapStagedBatch(RegexFpgaScanLocalState &lstate, celeris::CelerisContext &ctx) {
	auto &parked = lstate.parked;
	std::swap(lstate.packer, parked.packer);
	std::swap(lstate.wire_buffer, parked.wire_buffer);
	std::swap(lstate.batch_row_refs, parked.batch_row_refs);
	std::swap(lstate.accum_count, parked.accum_count);
	std::swap(lstate.staged_rows, parked.staged_rows);
	std::swap(lstate.accum_cap, parked.accum_cap);
	std::swap(lstate.batch_payload_bytes, parked.batch_payload_bytes);
	std::swap(lstate.batch_target_bytes, parked.batch_target_bytes);
	std::swap(lstate.batch_fsst_decoder, parked.batch_fsst_decoder);
	std::swap(lstate.batch_symbol_header, parked.batch_symbol_header);
	std::swap(lstate.batch_decoder_owner, parked.batch_decoder_owner);
	lstate.active_is_side = !lstate.active_is_side;
	// Dictionary slots name slots of the batch that was active, not of this one.
	lstate.dict_stamp++;
	if (!lstate.wire_buffer) {
		StartNewStagedBatch(lstate, ctx);
	}
}

// Records that `count` rows of `chunk_id` starting at `row` are decided by `count` slots starting
// at `slot`, extending the previous run when both ranges continue it. Merging is exact whenever
// rows and slots are both contiguous, however they came to be -- a dictionary row reusing the
// slot right after the run decides the row right after it just as a fresh append would.
static inline void PushSlotRun(RegexFpgaScanLocalState &lstate, uint32_t chunk_id, uint32_t slot, idx_t row,
                               idx_t count) {
	auto &refs = lstate.batch_row_refs;
	if (!refs.empty()) {
		auto &last = refs.back();
		const idx_t n = last.Count();
		if (last.chunk_id == chunk_id && last.slot_idx != kCpuResolvedSlot && last.slot_idx + n == slot &&
		    idx_t(last.row_idx) + n == row && n + count <= kRunCountMask) {
			last.run = uint16_t(n + count);
			return;
		}
	}
	refs.push_back({chunk_id, slot, static_cast<uint16_t>(row), static_cast<uint16_t>(count)});
}

// Notes that output_cache rows appended from here on belong to `batch_index`.
static void MarkOutputBatch(RegexFpgaScanLocalState &lstate, idx_t batch_index) {
	auto &marks = lstate.output_batch_marks;
	const idx_t row = lstate.output_cache.size();
	if (!marks.empty() && marks.back().first == row) {
		marks.back().second = batch_index;
		return;
	}
	if (marks.empty() || marks.back().second != batch_index) {
		marks.emplace_back(row, batch_index);
	}
}

static void AppendMatchedRows(RegexFpgaScanLocalState &lstate, const InFlightTransfer &transfer,
                              const RegexMatchBitmap &matches) {
	// Nothing projected: the output is a row count, so count the set bits and never touch a
	// chunk -- which is also what lets TryRefillScanChunk recycle chunks before collect.
	// Counted per batch index, because a transfer can span row groups and each output chunk
	// must carry exactly one.
	if (lstate.output_column_map.empty()) {
		idx_t matched = 0;
		idx_t run_batch = 0;
		const auto flush = [&]() {
			if (matched == 0) {
				return;
			}
			MarkOutputBatch(lstate, run_batch);
			DataChunk no_columns;
			no_columns.InitializeEmpty(lstate.output_types);
			lstate.output_cache.Append(no_columns, *FlatVector::IncrementalSelectionVector(), matched);
			matched = 0;
		};
		for (const auto &row_ref : transfer.row_refs) {
			const idx_t batch = MaxValue<idx_t>(
			    lstate.retained_chunks[RetainedChunkIndex(lstate, row_ref.chunk_id)].batch_index,
			    lstate.count_batch_high);
			lstate.count_batch_high = batch;
			if (batch != run_batch) {
				flush();
				run_batch = batch;
			}
			if (row_ref.slot_idx == kCpuResolvedSlot) {
				matched += row_ref.CpuMatch() ? 1 : 0;
				continue;
			}
			idx_t bit = row_ref.slot_idx;
			const idx_t end = bit + row_ref.Count();
			for (; bit < end && (bit & 7) != 0; bit++) {
				matched += matches.test(bit);
			}
			for (; bit + 8 <= end; bit += 8) {
				matched += idx_t(__builtin_popcount(matches.bits[bit >> 3]));
			}
			for (; bit < end; bit++) {
				matched += matches.test(bit);
			}
		}
		flush();
		return;
	}

	auto &matches_by_chunk = lstate.match_indices_scratch;
	matches_by_chunk.resize(lstate.retained_chunks.size());
	for (auto &row_indices : matches_by_chunk) {
		row_indices.clear();
	}
	// One run per stretch of rows the transfer decides. Rows sharing a dictionary entry read the
	// same slot's match bit, which is why a run can be as short as one row.
	for (const auto &row_ref : transfer.row_refs) {
		auto &row_indices = matches_by_chunk[RetainedChunkIndex(lstate, row_ref.chunk_id)];
		// A ref carries either card slots or a verdict already computed on the CPU, so the two
		// kinds interleave in scan order and neither needs a merge pass.
		if (row_ref.slot_idx == kCpuResolvedSlot) {
			if (row_ref.CpuMatch()) {
				row_indices.push_back(row_ref.row_idx);
			}
			continue;
		}
		const idx_t count = row_ref.Count();
		for (idx_t i = 0; i < count; i++) {
			if (matches.test(row_ref.slot_idx + i)) {
				row_indices.push_back(row_ref.row_idx + i);
			}
		}
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
		auto &source_chunk = *lstate.retained_chunks[chunk_idx].chunk;
		projected.ReferenceColumns(source_chunk, lstate.output_column_map);
		// A column still compressed here is decompressed straight into the cache's string heap
		// below, so Append carries an empty placeholder for it. Letting Append flatten the FSST
		// vector instead costs a second copy of every matched string: it decompresses into a
		// throwaway arena and then AddBlob()s that into the same heap.
		bool any_fsst = false;
		for (idx_t out_idx = 0; out_idx < projected.ColumnCount(); out_idx++) {
			if (projected.data[out_idx].GetVectorType() == VectorType::FSST_VECTOR) {
				projected.data[out_idx].Reference(lstate.empty_string_placeholder);
				any_fsst = true;
			}
		}
		const idx_t cache_offset = lstate.output_cache.size();
		MarkOutputBatch(lstate, lstate.retained_chunks[chunk_idx].batch_index);
		lstate.output_cache.Append(projected, lstate.match_sel_scratch, row_indices.size());
		if (any_fsst) {
			for (idx_t out_idx = 0; out_idx < projected.ColumnCount(); out_idx++) {
				auto &source = source_chunk.data[lstate.output_column_map[out_idx]];
				if (source.GetVectorType() != VectorType::FSST_VECTOR) {
					continue;
				}
				auto *compressed = FSSTVector::GetCompressedData(source);
				auto *decoder = FSSTVector::GetDecoder(source);
				auto &source_validity = FSSTVector::Validity(source);
				auto &target = lstate.output_cache.data[out_idx];
				auto target_data = FlatVector::GetDataMutable<string_t>(target);
				auto &target_validity = FlatVector::ValidityMutable(target);
				auto &allocator = StringVector::GetStringAllocator(target);
				for (idx_t i = 0; i < row_indices.size(); i++) {
					const idx_t source_row = row_indices[i];
					if (!source_validity.RowIsValid(source_row)) {
						target_validity.SetInvalid(cache_offset + i);
						continue;
					}
					const auto &value = compressed[source_row];
					target_data[cache_offset + i] =
					    value.GetSize() == 0
					        ? string_t(nullptr, 0)
					        : FSSTPrimitives::DecompressValue(decoder, allocator, value.GetData(), value.GetSize());
				}
			}
		}
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
	if (!lstate.submitted_any) {
		lstate.submitted_any = true;
		NoteRegexFirstSubmit();
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

	// Optional (OASIS_REGEX_TABLE_SLOTS=1; off by default now that the card double-buffers its
	// symbol RAM): a transfer whose table differs from the one already in flight waits for
	// that one to drain, so its header cannot rewrite a bank still being decoded. Same
	// collect-on-failure shape as the credit loop above, and for the same reason: blocking
	// here while holding uncollected transfers can be waiting on a slot only we could free.
	// With the passthrough off every decoder is nullptr, so this never serialises anything.
	if (arms_device) {
		while (!TryAcquireRegexTableSlot(lstate.batch_fsst_decoder)) {
			if (lstate.in_flight.empty()) {
				AcquireRegexTableSlot(lstate.batch_fsst_decoder);
				break;
			}
			CollectOldestTransfer(lstate);
		}
	}

	CALI_MARK_BEGIN("fpga_regex_submit");
	// Squares off the rectangle: pads the short engines and fills the tails. Has to
	// happen before the enqueue and after the last append, so it lives here rather
	// than in the staging loop.
	// Diagnostic geometry floors, both off by default. See finalize() in regex_stream.hpp:
	// the hardware wedge correlates with minimum-geometry batches, and these separate the
	// result-count floor from the rectangle floor so one can be raised without the other.
	static const uint32_t min_spe = [] {
		const char *e = std::getenv("OASIS_REGEX_MIN_SPE");
		return e ? static_cast<uint32_t>(std::strtoul(e, nullptr, 10)) : 0u;
	}();
	static const uint64_t min_rect = [] {
		const char *e = std::getenv("OASIS_REGEX_MIN_RECT_BYTES");
		return e ? std::strtoull(e, nullptr, 10) : 0ull;
	}();
	const celeris::RegexStreamPacker::Plan plan = lstate.packer.finalize(min_spe, min_rect);

	// Host-side audit of the count invariant the card enforces in rem_engines.sv:535.
	// Off unless OASIS_REGEX_VERIFY_WIRE is set: it walks the whole rectangle a byte at a
	// time, which is far too slow to leave on. Silence is the result -- it prints only
	// when a batch's delimiters disagree with the count it is about to arm with, which is
	// the condition that makes the arm never retire and the collect never return.
	//
	// The submit-side half. The same audit runs again in CollectOldestTransfer, against
	// the same buffer, and a disagreement there means the bytes the DMA read were not the
	// bytes that were packed -- the one failure this side cannot see on its own.
	static const bool verify_wire = std::getenv("OASIS_REGEX_VERIFY_WIRE") != nullptr;
	uint64_t audit_header_bytes = 0;
	uint64_t audit_delims = 0;
	uint64_t audit_hash = 0;
	bool audit_taken = false;
	if (verify_wire && lstate.accum_count > 0) {
		const auto audit = celeris::RegexStreamPacker::audit_wire(
		    static_cast<const uint8_t *>(lstate.wire_buffer->ptr), plan,
		    lstate.packer.header_bytes(), lstate.batch_fsst_decoder != nullptr);
		if (!audit.ok) {
			std::fprintf(stderr,
			             "[regexdiag] WIRE MISMATCH rows=%llu armed=%u per_engine=%u found=%llu "
			             "short=%u long=%u first_bad_engine=%u its_count=%llu compressed=%d\n",
			             (unsigned long long)lstate.accum_count, plan.strings_in_batch,
			             audit.expected_per_engine, (unsigned long long)audit.total,
			             audit.short_engines, audit.long_engines, audit.first_bad_engine,
			             (unsigned long long)audit.first_bad_count,
			             lstate.batch_fsst_decoder != nullptr ? 1 : 0);
		}
		audit_header_bytes = lstate.packer.header_bytes();
		audit_delims = audit.total;
		audit_hash = celeris::RegexStreamPacker::wire_hash(
		    static_cast<const uint8_t *>(lstate.wire_buffer->ptr), plan);
		audit_taken = true;
	}

	InFlightTransfer transfer;
	transfer.count = lstate.accum_count;
	transfer.row_refs = std::move(lstate.batch_row_refs);
	transfer.wire_buffer = lstate.wire_buffer;
	transfer.dry_run = global_state.dry_run;
	transfer.table_slot = arms_device;
	transfer.table_decoder = lstate.batch_fsst_decoder;
	transfer.decoder_owner = std::move(lstate.batch_decoder_owner);
	if (audit_taken) {
		transfer.audit_plan = plan;
		transfer.audit_header_bytes = audit_header_bytes;
		transfer.audit_delims = audit_delims;
		transfer.audit_hash = audit_hash;
		transfer.audit_compressed = lstate.batch_fsst_decoder != nullptr;
		transfer.audit_taken = true;
	}

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
		transfer.submission =
		    SubmitRegexBatch(global_state.ctx, lstate.wire_buffer->ptr, plan, lstate.accum_count,
		                     bind_data.regex_blob);
		D_ASSERT(transfer.submission.valid());
	}
	lstate.in_flight.push_back(std::move(transfer));
	CALI_MARK_END("fpga_regex_submit");

	// Every chunk the cursor has already moved past is now owned by the transfers that
	// reference it, so drop the staging ref. The chunk the cursor is still inside keeps
	// its ref -- rows from it may yet be staged into the next batch. So does every chunk the
	// parked batch has rows in: it has not submitted, so nothing else holds them yet. Its
	// refs are in scan order, so the first one bounds them all.
	idx_t keep_from =
	    lstate.current_retained_chunk_idx == DConstants::INVALID_INDEX ? 0 : lstate.current_retained_chunk_idx;
	if (!lstate.parked.batch_row_refs.empty()) {
		keep_from = MinValue<idx_t>(keep_from,
		                            RetainedChunkIndex(lstate, lstate.parked.batch_row_refs.front().chunk_id));
	}
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
	if (transfer.table_slot) {
		// The card has finished this transfer, so its table is no longer in use.
		ReleaseRegexTableSlot(transfer.table_decoder);
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

	// The collect-side half of the wire audit. The DMA has finished with this buffer, so
	// re-hashing it now and comparing against submit answers whether the bytes the card
	// read were the bytes that were packed. Only a difference prints: a changed hash means
	// the buffer was written after it was armed -- reuse under an in-flight transfer --
	// and the re-count says whether that changed the delimiter framing, which is what
	// turns it into a wedge rather than a wrong answer.
	if (transfer.audit_taken && transfer.wire_buffer) {
		const auto *wire = static_cast<const uint8_t *>(transfer.wire_buffer->ptr);
		const uint64_t now_hash = celeris::RegexStreamPacker::wire_hash(wire, transfer.audit_plan);
		if (now_hash != transfer.audit_hash) {
			const auto again = celeris::RegexStreamPacker::audit_wire(
			    wire, transfer.audit_plan, transfer.audit_header_bytes, transfer.audit_compressed);
			std::fprintf(stderr,
			             "[regexdiag] WIRE MUTATED seq=%llu rows=%llu armed=%u "
			             "delims_at_submit=%llu delims_now=%llu hash %016llx -> %016llx\n",
			             (unsigned long long)transfer.submission.seq,
			             (unsigned long long)transfer.count,
			             transfer.audit_plan.strings_in_batch,
			             (unsigned long long)transfer.audit_delims,
			             (unsigned long long)again.total,
			             (unsigned long long)transfer.audit_hash,
			             (unsigned long long)now_hash);
		}
	}

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
			// fallthrough to the slot release below
			// Swallowed deliberately. The handle is consumed either way, which is the
			// part that matters for every other thread; there is nobody left to report to.
		}
		if (transfer.table_slot) {
			// Must happen even on the throwing path: a stranded slot blocks every other
			// thread's differing table for the life of the process.
			ReleaseRegexTableSlot(transfer.table_decoder);
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
	// them to ask one question would be the most expensive thing on this path.
	//
	// NoGroups, not the Match overload: this path only needs yes/no, and asking RE2 for
	// submatches it then discards cost 2.36 us/row on `.*(warthogs|instruction[a-z]).*`
	// versus ~65 ns/row on the same data with a group-free pattern -- the capture group
	// pushes RE2 off its DFA, and the wrapper heap-allocates per call besides. Under the
	// passthrough ~10% of rows land here (the segment straddle), so it set the whole
	// query's throughput: 3.31 GB/s against 12.31 for the group-free twin.
	return duckdb_re2::RegexMatchNoGroups(data, data + value.GetSize(), *lstate.cpu_regex);
}

// Whether staging one more *distinct* string would overrun the batch. `next_length` is the string's
// length; it is ignored for a row that reuses an already-staged dictionary entry, which costs
// nothing on the wire.
static bool WouldExceedFpgaBatch(const RegexFpgaScanLocalState &lstate, uint64_t next_length, bool needs_slot) {
	// Rows are capped independently of strings: when a dictionary column resolves millions of rows
	// to a handful of distinct values the string budget would never fill, and the retained chunks
	// backing those rows would grow without bound.
	if (lstate.staged_rows >= lstate.accum_cap) {
		return true;
	}
	if (!needs_slot) {
		return false;
	}
	// Also the per-engine result-FIFO bound, since the count is dealt round-robin:
	// REGEX_FPGA_MAX_ACCUM_COUNT / 64 = 1024 results per engine.
	if (lstate.accum_count >= lstate.accum_cap) {
		return true;
	}
	// Close on the chunk boundary rather than one string past it, once the batch has
	// either reached its byte target or come within a chunk of its row cap.
	//
	// The wire is a whole number of 256 B chunks per engine, so wherever a batch happens
	// to end, the last chunk of all 64 engines is part filler -- and the card reads and
	// the engines walk every byte of it. On the 72 B benchmark column a 16384-row batch
	// landed one byte into a fresh chunk, so 74 chunks travelled to carry 73 chunks of
	// strings: 1.4% of the wire, pure loss. Closing at the boundary instead took the
	// scan's wire from 291.0 MB to 288.4 MB for 283.1 MB of text and was worth 1.7-2.0%
	// end to end, paired over 18-20 rounds.
	if ((lstate.batch_payload_bytes >= lstate.batch_target_bytes ||
	     lstate.staged_rows + kBoundaryCloseSlack >= lstate.accum_cap) &&
	    lstate.packer.rectangle_grows(next_length)) {
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

// Push the per-thread row-path tallies into the global counters. One atomic per path per
// call instead of one per row; the counts are only read by regex_fpga_batch_phases(), so
// they need to be correct by the end of the scan, not row by row.
static void FlushRegexRowPaths(RegexFpgaScanLocalState &lstate) {
	if (lstate.path_compressed) {
		NoteRegexRowPath(RegexRowPath::COMPRESSED, lstate.path_compressed);
		lstate.path_compressed = 0;
	}
	if (lstate.path_not_fsst) {
		NoteRegexRowPath(RegexRowPath::NOT_FSST, lstate.path_not_fsst);
		lstate.path_not_fsst = 0;
	}
	if (lstate.path_mode0) {
		NoteRegexRowPath(RegexRowPath::MODE0, lstate.path_mode0);
		lstate.path_mode0 = 0;
	}
	if (lstate.path_outlier) {
		NoteRegexRowPath(RegexRowPath::OUTLIER, lstate.path_outlier);
		lstate.path_outlier = 0;
	}
}

static void AccumulateRows(const RegexFpgaScanBindData &bind_data, RegexFpgaScanGlobalState &global_state,
                           RegexFpgaScanLocalState &lstate, ClientContext &context) {
	CALI_CXX_MARK_FUNCTION;
	// Scoped, not a call at the end: this function returns early from inside the staging
	// loop, and a missed flush would silently under-report compressed_pct.
	struct RowPathFlush {
		RegexFpgaScanLocalState &state;
		~RowPathFlush() {
			FlushRegexRowPaths(state);
		}
	} row_path_flush {lstate};
	while (lstate.output_cache.size() == 0 && !lstate.finished) {
		if (!TryRefillScanChunk(context, bind_data, global_state, lstate)) {
			// Scan exhausted. Submit whatever is staged, then drain the window: every
			// outstanding transfer still owes rows, and there is nothing left to overlap
			// them with. Collecting stops early once the cache has rows -- the rest stay
			// on the card and are collected on the next call, which is exactly the
			// overlap the window exists for.
			SubmitStagedBatch(bind_data, global_state, lstate);
			// And the parked side batch, if it holds anything. Re-entry finds it empty: the
			// swap leaves the batch just submitted, restarted with no rows, in its place.
			if (lstate.parked.staged_rows > 0) {
				SwapStagedBatch(lstate, global_state.ctx);
				SubmitStagedBatch(bind_data, global_state, lstate);
			}
			// Nothing is staged any more, so every staging ref goes -- the cursor's chunk, and
			// any the parked batch was holding before it submitted. Without this those chunks
			// are never released. Guarded by scan_exhausted because this branch is re-entered
			// once per GetData call while the window drains, and the refs must only be dropped
			// once (ReleaseStagingRef is idempotent regardless).
			if (!lstate.scan_exhausted) {
				lstate.scan_exhausted = true;
				for (auto &entry : lstate.retained_chunks) {
					ReleaseStagingRef(entry);
				}
				// Clearing the cursor keeps ReleaseRetiredChunks from trying to slide an index
				// that no longer tracks anything.
				lstate.current_retained_chunk_idx = DConstants::INVALID_INDEX;
				ReleaseRetiredChunks(lstate);
			}
			while (lstate.output_cache.size() == 0 && CollectOldestTransfer(lstate)) {
			}
			if (lstate.in_flight.empty()) {
				lstate.finished = true;
				NoteRegexThreadDone();
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

		// Classify for the FSST compressed passthrough BEFORE ToUnifiedFormat below, which
		// flattens -- and so decompresses -- anything that is not FLAT/CONSTANT/DICTIONARY
		// (Vector::ToUnifiedFormat, duckdb/common/types/vector.cpp). After that call the
		// compressed bytes are gone and the vector type no longer says what it was.
		//
		// Two conditions, both required. The vector must actually be FSST -- DuckDB only
		// emits one when enable_fsst_vectors is on AND the read did not straddle a
		// ColumnSegment boundary (ColumnData::GetVectorScanType). And the segment's symbol
		// table must be zeroTerminated: the wire format frames strings on NUL, so under
		// upstream's zeroTerminated=0 encoding code 0 can be an ordinary multi-byte symbol
		// and the card would frame on the wrong bytes -- returning valid-looking wrong
		// matches with no error. Any database written by a build without the FSST fork in
		// extension/duckdb/src/storage/compression/fsst.cpp is mode 0, so this is the
		// common case, not an edge case.
		bool fsst_passthrough = false;
		if (lstate.fsst_passthrough && regex_vector_type == VectorType::FSST_VECTOR) {
			auto *decoder = reinterpret_cast<duckdb_fsst_decoder_t *>(FSSTVector::GetDecoder(regex_vector));
			fsst_passthrough = decoder != nullptr && decoder->zeroTerminated != 0;
		}

		// Two ways to reach the strings. The plaintext path goes through ToUnifiedFormat, which
		// flattens -- and so decompresses -- an FSST vector. The passthrough must not call it:
		// it reads the compressed string_t array out of the vector's buffer directly and leaves
		// the vector compressed. An FSST vector is always flat-indexed and carries its validity
		// on the buffer rather than in a UnifiedVectorFormat, hence the separate accessors.
		UnifiedVectorFormat regex_format;
		const string_t *regex_data = nullptr;
		const SelectionVector *regex_sel = nullptr;
		const ValidityMask *regex_validity = nullptr;
		void *fsst_decoder = nullptr;
		if (fsst_passthrough) {
			regex_data = FSSTVector::GetCompressedData(regex_vector);
			regex_sel = FlatVector::IncrementalSelectionVector();
			regex_validity = &FSSTVector::Validity(regex_vector);
			fsst_decoder = FSSTVector::GetDecoder(regex_vector);
		} else {
			regex_vector.ToUnifiedFormat(regex_format);
			regex_data = UnifiedVectorFormat::GetData<string_t>(regex_format);
			regex_sel = regex_format.sel;
			regex_validity = &regex_format.validity;
		}

		// Which symbol table this chunk's rows ride. Every row rides one: the card has no
		// plaintext path, so a decompressed chunk -- a segment straddle, a zeroTerminated=0
		// table, or any chunk at all with the passthrough off -- rides the identity table, and
		// everything else rides its segment's real table.
		const void *row_decoder =
		    fsst_passthrough ? static_cast<const void *>(fsst_decoder) : kRegexIdentityDecoder;

		// Straddle rows ride their own batch rather than closing the segment's; swap to the batch
		// of this chunk's table kind. Per chunk is enough, since every row of a chunk rides the
		// same table. See RegexFpgaScanLocalState::parked.
		if (lstate.fsst_passthrough && lstate.side_batching &&
		    (row_decoder == kRegexIdentityDecoder) != lstate.active_is_side) {
			SwapStagedBatch(lstate, global_state.ctx);
		}

		if (dedup) {
			// Dictionary indices only mean anything within the chunk that produced them.
			lstate.dict_stamp++;
		}

		CALI_MARK_BEGIN("stage_rows_for_fpga_batch");
		auto t_stage = StageClock::now();
		// Hoisted, and the output_cache test dropped, because DataChunk::size() is not the
		// register read it looks like in this fork:
		//
		//     inline idx_t size() const {
		//         if (count.IsValid()) { return count.GetIndex(); }
		//         for (const auto &v : data) { if (v.GetBufferRef()) { return v.size(); } }
		//
		// It was called TWICE per row -- 31 M calls for a 15.7 M-row table -- and showed up
		// at 6.8% of host time in perf, more than duckdb_fsst_decompress.
		//
		// chunk_size is constant for the chunk. The output_cache test is dead: the cache is
		// empty on entry (the caller's loop guarantees it) and the only thing inside this
		// loop that can grow it is the CollectOldestTransfer below, which is immediately
		// followed by `return` when it does.
		const idx_t chunk_size = current_chunk.size();

		// Chunk-level fast path. The general loop below decides each row separately: selection
		// vector, validity, dictionary slot, outlier, wire-buffer bound, table change, the batch
		// caps, the header, then one ref per row. On a plain FSST chunk -- no dictionary, identity
		// selection, no NULLs -- nearly all of that is settled once per chunk, and at 16 threads
		// the loop was 52% of CPU (30 ns/row against 16 for DuckDB's own scan).
		//
		// The tight loop keeps only what can change row to row: the length bounds and whether
		// the batch might close. It stops at the first row that fails any of them and hands that
		// row to the general loop, which decides exactly as before. So batch boundaries are
		// unchanged -- the fast condition implies WouldExceedFpgaBatch() is false -- and the
		// staged run becomes a single ref.
		const bool fast_chunk =
		    lstate.fast_staging && !dedup && !regex_sel->IsSet() &&
		    (regex_validity->CannotHaveNull() || regex_validity->CheckAllValid(chunk_size));
		// Below outlier_bytes, and small enough that one engine's stream fits the wire buffer.
		const uint64_t fast_len_limit =
		    MinValue<uint64_t>(lstate.outlier_bytes, lstate.wire_buffer_bytes / celeris::kRegexEngineCount);
		const RegexRowPath fast_path = fsst_passthrough                                ? RegexRowPath::COMPRESSED
		                               : regex_vector_type == VectorType::FSST_VECTOR ? RegexRowPath::MODE0
		                                                                               : RegexRowPath::NOT_FSST;

		while (lstate.chunk_offset < chunk_size) {
			// The batch must already carry this chunk's table: its first row reserves the header,
			// and that stays in the general loop. Outside the passthrough both are nullptr.
			if (fast_chunk && lstate.batch_fsst_decoder == row_decoder) {
				const idx_t run_start = lstate.chunk_offset;
				const uint32_t first_slot = static_cast<uint32_t>(lstate.accum_count);
				// staged + kBoundaryCloseSlack < accum_cap, without the add in the loop.
				const idx_t staged_limit =
				    lstate.accum_cap > kBoundaryCloseSlack ? lstate.accum_cap - kBoundaryCloseSlack : 0;
				const uint64_t target_bytes = lstate.batch_target_bytes;
				idx_t staged = lstate.staged_rows;
				uint64_t payload = lstate.batch_payload_bytes;
				idx_t offset = run_start;
				while (offset < chunk_size) {
					const string_t &value = regex_data[offset];
					const uint64_t length = value.GetSize();
					// accum_count <= staged_rows, so the staged bound covers both row caps; with the
					// payload under target neither rectangle-closing clause can fire; and fits() is
					// the capacity test itself.
					if (length >= fast_len_limit || staged >= staged_limit || payload >= target_bytes ||
					    !lstate.packer.fits(length)) {
						break;
					}
					lstate.packer.append(value.GetData(), length);
					staged++;
					payload += length + 1;
					offset++;
				}
				const idx_t staged_now = offset - run_start;
				if (staged_now > 0) {
					lstate.accum_count += staged_now;
					lstate.staged_rows = staged;
					lstate.batch_payload_bytes = payload;
					lstate.chunk_offset = offset;
					PushSlotRun(lstate, lstate.retained_chunks[lstate.current_retained_chunk_idx].id, first_slot,
					            run_start, staged_now);
					switch (fast_path) {
					case RegexRowPath::COMPRESSED:
						lstate.path_compressed += staged_now;
						break;
					case RegexRowPath::MODE0:
						lstate.path_mode0 += staged_now;
						break;
					default:
						lstate.path_not_fsst += staged_now;
						break;
					}
					if (offset >= chunk_size) {
						break;
					}
				}
			}

			const idx_t row_idx = lstate.chunk_offset;
			const idx_t regex_idx = regex_sel->get_index(row_idx);
			if (!regex_validity->RowIsValid(regex_idx)) {
				lstate.chunk_offset++;
				continue;
			}

			// A chunk DuckDB handed back decompressed (a vector straddling two ColumnSegments)
			// used to be matched here on the host with RE2, because it cannot join a batch
			// carrying that segment's real symbol table. It now goes to the card under the
			// IDENTITY table instead -- its plaintext bytes are already valid codes there --
			// so it costs a memcpy rather than a software regex. See
			// WriteIdentitySymbolTableHeader for why identity rather than a plaintext batch.
			//
			// Nothing else in this loop changes: row_decoder below routes the row to a batch
			// grouped by the identity sentinel, and the existing table-change check closes the
			// batch on the boundary.

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
			//
			// The row is staged *below* the batch-close check, not here. An outlier takes a
			// row but no slot and no wire bytes, so the row cap is the only thing that can
			// close a batch on it -- and staging here with a `continue` skipped that check
			// entirely. One outlier in ordinary data is harmless, because the next normal row
			// closes the batch; a table whose strings are *all* at or above the threshold
			// (the length suite's par_2048, where outlier_bytes is exactly the string length)
			// never reaches the check at all, so staged_rows grew to the whole row group.
			// AppendMatchedRows then overran output_cache, which is sized to max_accum_count:
			// "INTERNAL Error: Can't append to vector without resizing". It surfaced only when
			// a column was projected -- count(*) appends a chunk with no vectors, so it has no
			// capacity to overrun and merely retained the row group.
			const bool is_outlier = needs_slot && next_length >= lstate.outlier_bytes;

			// A single value only has to fit one engine's stream, and the rectangle
			// is 64 of those, so the bound is the buffer over the engine count. Outliers
			// are exempt: they never go on the wire, so a wire buffer smaller than 64x the
			// outlier threshold must not reject them.
			if (needs_slot && !is_outlier &&
			    (next_length + 1) * celeris::kRegexEngineCount > lstate.wire_buffer_bytes) {
				throw InvalidInputException(
				    "regex_fpga_scan: a %llu byte value in column %s does not fit the %llu byte FPGA wire buffer",
				    (unsigned long long)regex_value.GetSize(), bind_data.regex_column.c_str(),
				    (unsigned long long)lstate.wire_buffer_bytes);
			}

			// The batch closes when the row or byte caps bind. chunk_offset is left
			// pointing at the row, so it is staged exactly once against the next batch.
			// A batch ships one symbol table, so crossing into a segment with a different
			// decoder closes the batch even when neither the row nor the byte cap binds.
			// row_decoder, not fsst_decoder: a straddling chunk rides the identity table, so
			// moving between real and identity tables closes the batch just like moving
			// between two real ones. The MODE never changes -- both are compressed batches --
			// which is the whole point.
			//
			// An outlier crosses neither: it carries no symbol table (it never touches the
			// packer) and claims no slot, so it is passed as needs_slot = false and only the
			// row cap can bind on it.
			const bool crosses_symbol_table = !is_outlier && lstate.batch_fsst_decoder != nullptr &&
			                                  lstate.batch_fsst_decoder != row_decoder;
			if (lstate.staged_rows > 0 &&
			    (crosses_symbol_table ||
			     WouldExceedFpgaBatch(lstate, next_length, needs_slot && !is_outlier))) {
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
				// Restart the timer, do not shadow it: `auto t_stage = ...` here declared a
				// second variable that died at the `continue`, so the accumulator at the
				// bottom of the loop measured from the top of the *chunk* and swallowed
				// every submit and drain that happened in between. stage_ms then read as
				// stage + drain and the decomposition did not add up.
				t_stage = StageClock::now();
				continue;
			}

			// Now that the batch has room, decide the outlier on the host and stage it as a
			// CPU-resolved run. It reserves no symbol header and never sets batch_fsst_decoder,
			// because it contributes nothing to the wire -- a batch of nothing but outliers
			// ships no transfer at all (see the staged_rows check in SubmitStagedBatch).
			if (is_outlier) {
				lstate.path_outlier++;
				// Under the passthrough regex_value is compressed, and RE2 must not see those
				// bytes -- it would match the symbol codes and quietly return a verdict for a
				// string that does not exist. Decompress this one value; outliers are rare by
				// construction, so the copy costs nothing at the scale that matters.
				bool outlier_match;
				if (fsst_passthrough) {
					const string plain = FSSTPrimitives::DecompressValue(
					    fsst_decoder, regex_value.GetData(), next_length,
					    FSSTVector::GetDecompressBuffer(regex_vector));
					outlier_match = MatchOutlierOnHost(bind_data, lstate, string_t(plain));
				} else {
					outlier_match = MatchOutlierOnHost(bind_data, lstate, regex_value);
				}
				lstate.batch_row_refs.push_back(
				    {lstate.retained_chunks[lstate.current_retained_chunk_idx].id, kCpuResolvedSlot,
				     static_cast<uint16_t>(row_idx), static_cast<uint16_t>(1 | (outlier_match ? kRunCpuMatchBit : 0))});
				lstate.staged_rows++;
				lstate.chunk_offset++;
				continue;
			}

			{
				D_ASSERT(lstate.batch_fsst_decoder == nullptr || lstate.batch_fsst_decoder == row_decoder);
				if (lstate.batch_fsst_decoder == nullptr) {
					// First row of this batch, so take the reservation now.
					// accum_count must still be 0: reserve_symbol_header() moves the packing
					// origin and cannot run after an append.
					D_ASSERT(lstate.accum_count == 0);
					lstate.batch_symbol_header = lstate.packer.reserve_symbol_header();
					// The padding finalize() adds must be codes too, not 0xFF -- that is
					// FSST_ESC and would eat the filler's own terminator. reset() restores the
					// 0xFF filler, so this must run for every batch that ships.
					if (row_decoder == kRegexIdentityDecoder) {
						lstate.packer.set_compressed_filler(true);   // every identity code is 1 B
						WriteIdentitySymbolTableHeader(lstate.batch_symbol_header);
					} else {
						lstate.packer.set_compressed_filler(true, ShortestSymbolCode(fsst_decoder));
						WriteSymbolTableHeader(lstate.batch_symbol_header, fsst_decoder);
						// Pin the decoder for as long as its address identifies this batch's table.
						lstate.batch_decoder_owner = regex_vector.GetBufferRef();
						// The segment's end closes this batch, so let it rather than the row cap
						// decide: see REGEX_FPGA_SEGMENT_ACCUM_COUNT.
						lstate.accum_cap = lstate.segment_accum_count;
					}
				}
				lstate.batch_fsst_decoder = row_decoder;
			}

			if (needs_slot) {
				// Straight into the wire layout, no descriptor and no second pass.
				// The slot is the append order, which is what result_bit_index maps
				// back from once the card returns its engine-major bitmap.
				slot = lstate.packer.append(regex_value.GetData(), next_length);
				D_ASSERT(slot == lstate.accum_count);
				lstate.accum_count++;
				lstate.batch_payload_bytes += next_length + 1;
				if (dedup) {
					if (regex_idx >= lstate.dict_slot_stamp.size()) {
						lstate.dict_slot_of.resize(regex_idx + 1, 0);
						lstate.dict_slot_stamp.resize(regex_idx + 1, 0);
					}
					lstate.dict_slot_of[regex_idx] = slot;
					lstate.dict_slot_stamp[regex_idx] = lstate.dict_stamp;
				}
			}

			if (fsst_passthrough) {
				lstate.path_compressed++;
			} else if (regex_vector_type == VectorType::FSST_VECTOR) {
				lstate.path_mode0++;
			} else {
				lstate.path_not_fsst++;
			}
			PushSlotRun(lstate, lstate.retained_chunks[lstate.current_retained_chunk_idx].id,
			            static_cast<uint32_t>(slot), row_idx, 1);
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
	const idx_t start = lstate.output_cache_read_idx;
	idx_t end = MinValue<idx_t>(lstate.output_cache.size(), start + STANDARD_VECTOR_SIZE);
	// Stop at the next batch boundary, so the chunk carries a single batch index. A thread's row
	// groups need not have consecutive indices -- another thread can hold the one in between -- so
	// labelling a mixed chunk with either index would misorder rows under preserve_insertion_order.
	auto &marks = lstate.output_batch_marks;
	auto &cursor = lstate.output_batch_mark_cursor;
	while (cursor + 1 < marks.size() && marks[cursor + 1].first <= start) {
		cursor++;
	}
	if (cursor < marks.size()) {
		lstate.emitted_batch_index = marks[cursor].second;
		if (cursor + 1 < marks.size()) {
			end = MinValue<idx_t>(end, marks[cursor + 1].first);
		}
	}
	// output_cache is already materialized in output-projection layout, so emit it directly.
	//
	// `output` is a *slice over* output_cache's vectors, not a copy. Vector::Slice hands the
	// new buffer the string_t values, but StandardVectorBuffer::FlattenSliceInternal copies
	// only the data and the validity mask -- never the auxiliary data that owns the string
	// heap. Resetting output_cache here therefore freed the heap the caller was still
	// reading from, and a fraction of emitted strings arrived as a run of NUL bytes with the
	// length field intact and the payload gone. It was rare, non-deterministic and scaled
	// with row-group count, and it never touched the match verdicts -- only the payload --
	// so count(*) was always right and only projections of a VARCHAR column were affected.
	// The reset is deferred to the next call instead: see ResetDrainedOutputCache.
	output.Slice(lstate.output_cache, lstate.output_cache_read_idx, end);
	lstate.output_cache_read_idx = end;
}

// True once every row of output_cache has been emitted. The cache is reset only on the call
// *after* that, so the slice handed to the caller keeps the heap its strings point into.
static bool DrainedOutputCache(const RegexFpgaScanLocalState &lstate) {
	return lstate.output_cache.size() > 0 && lstate.output_cache_read_idx >= lstate.output_cache.size();
}

static void ResetDrainedOutputCache(RegexFpgaScanLocalState &lstate) {
	if (DrainedOutputCache(lstate)) {
		lstate.output_cache.Reset();
		lstate.output_cache_read_idx = 0;
		lstate.output_batch_marks.clear();
		lstate.output_batch_mark_cursor = 0;
	}
}

void RegexFpgaScanFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	CALI_CXX_MARK_FUNCTION;
	auto &bind_data = data_p.bind_data->Cast<RegexFpgaScanBindData>();
	auto &global_state = data_p.global_state->Cast<RegexFpgaScanGlobalState>();
	auto &lstate = data_p.local_state->Cast<RegexFpgaScanLocalState>();

	// The chunk handed back by the previous call has been consumed by the pipeline by now, so
	// the cache it was sliced from can finally be recycled. This has to run before anything
	// below can refill the cache: the refill paths test output_cache.size() == 0 to decide
	// whether there is more work to do.
	ResetDrainedOutputCache(lstate);

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

// Without this DuckDB cannot preserve insertion order across threads, and any plan that needs it --
// every SELECT returning rows to a client -- ran the whole scan on one thread: 2.2 s against 0.22 s
// for the same projection at 0% selectivity.
static OperatorPartitionData RegexFpgaScanGetPartitionData(ClientContext &context,
                                                           TableFunctionGetPartitionInput &input) {
	if (input.partition_info.RequiresPartitionColumns()) {
		throw InternalException("regex_fpga_scan: partition columns are not supported");
	}
	return OperatorPartitionData(input.local_state->Cast<RegexFpgaScanLocalState>().emitted_batch_index);
}

void RegisterRegexFpgaScanFunction(ExtensionLoader &loader) {
	TableFunction table_function("regex_fpga_scan", {LogicalType::VARCHAR}, RegexFpgaScanFunction, RegexFpgaScanBind,
	                             RegexFpgaScanInitGlobal, RegexFpgaScanInitLocal);
	table_function.get_partition_data = RegexFpgaScanGetPartitionData;
	table_function.named_parameters["regex_column"] = LogicalType::VARCHAR;
	table_function.named_parameters["pattern"] = LogicalType::VARCHAR;
	table_function.projection_pushdown = true;
	// Off: DuckDB keeps the filter as an operator above this scan. A pushed filter makes the
	// storage scan fetch the other columns through ColumnData::Select -> FSSTStorage::Select,
	// which always decompresses, so every filtered query lost the FSST passthrough -- and the
	// card has no plaintext path any more. The cost is that filtered-out rows are matched too.
	table_function.filter_pushdown = false;
	// Independent of pushdown (RemoveUnusedColumns): it is what populates projection_ids,
	// which BuildOutputColumnMap relies on to tell count(*) from a projected column.
	table_function.filter_prune = true;
	loader.RegisterFunction(table_function);
}

} // namespace duckdb
