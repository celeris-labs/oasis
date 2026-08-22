#pragma once

#include "celeris/celeris_context.hpp"
#include "celeris/operators/regex/regex_stream.hpp"
#include "regex_fpga_batch.hpp" // batch-geometry defaults
#include "syslog_undef.hpp" // must follow the celeris include, precede the duckdb ones

#include "duckdb.hpp"
#include "duckdb/catalog/catalog_entry/duck_table_entry.hpp"
#include "duckdb/common/types/selection_vector.hpp"
#include "duckdb/execution/expression_executor.hpp"
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
	// oasis_regex_dry_run: skip the device and report no matches, leaving only the host-side
	// scan-and-pack cost. Benchmarking only -- see the option's description.
	bool dry_run = false;

	explicit RegexFpgaScanGlobalState(celeris::CelerisContext &ctx) : ctx(ctx) {
	}
};

struct StagedRowRef {
	idx_t chunk_idx;
	idx_t row_idx;
	// Batch slot whose match bit decides this row. Usually one slot per row, but rows sharing a
	// dictionary entry share a slot -- see the dictionary fast path in AccumulateRows.
	idx_t slot_idx;
};

struct RegexFpgaScanLocalState : public LocalTableFunctionState {
	TableScanState scan_state;
	DataChunk output_cache;

	vector<LogicalType> scanned_types;
	vector<LogicalType> output_types;
	idx_t scanned_regex_column_idx = DConstants::INVALID_INDEX;
	vector<idx_t> output_column_map;

	vector<unique_ptr<DataChunk>> retained_chunks;
	vector<StagedRowRef> batch_row_refs;

	// Reusable scratch for compacting matched rows, sized once to avoid per-flush allocation.
	vector<vector<idx_t>> match_indices_scratch;
	SelectionVector match_sel_scratch;

	// Filters DuckDB pushed down as "optional": it does not enforce them (their evaluation is a
	// no-op marker) and keeps a FILTER above us instead. We unwrap them into a real filter set and
	// hand that to the storage scan, so rows are dropped during column reading and never reach the
	// FPGA. Must outlive scan_state, which only borrows it.
	unique_ptr<TableFilterSet> scan_filter_set;

	idx_t current_retained_chunk_idx = DConstants::INVALID_INDEX;
	idx_t chunk_offset = 0;
	idx_t output_cache_read_idx = 0;
	idx_t rows_in_current_row_group = 0;

	idx_t accum_count = 0; // distinct strings staged for the FPGA in this batch
	idx_t staged_rows = 0; // rows this batch decides; >= accum_count once rows share a slot
	// A multi-KB value is staged alone: the collector pops all 64 engines together,
	// so one engine on a long string can wedge the array (see kRegexOutlierBytes).
	bool batch_has_outlier = false;
	bool finished = false;

	// Dictionary fast path. When the regex column arrives dictionary-encoded, every row with the
	// same dictionary entry has the same string and therefore the same answer, so the string is
	// sent to the FPGA once and the rest of the rows read the result out of the same slot.
	// dict_slot_of maps a dictionary index to that slot; dict_slot_stamp records which
	// (chunk, batch) the mapping belongs to, so invalidating the whole map is a counter bump
	// rather than a clear -- it is invalidated on every flush and on every new chunk.
	vector<idx_t> dict_slot_of;
	vector<uint64_t> dict_slot_stamp;
	uint64_t dict_stamp = 0;

	// Rows are packed straight into the wire layout as they are scanned, so there
	// is no separate descriptor buffer and no second pass. The packer holds the
	// per-engine write cursors; the batch geometry only becomes known at flush.
	std::shared_ptr<libstf::Buffer> wire_buffer;
	celeris::RegexStreamPacker packer;

	// Batch geometry, resolved once per scan from oasis_regex_batch_rows /
	// oasis_regex_wire_buffer_bytes so a sweep does not need a rebuild. A batch ends
	// when either cap is hit: rows bind for short strings, bytes for long ones.
	idx_t max_accum_count = REGEX_FPGA_MAX_ACCUM_COUNT;
	uint64_t wire_buffer_bytes = REGEX_FPGA_WIRE_BUFFER_BYTES;
	// Solo-batch threshold, from oasis_regex_outlier_bytes. Defaults to the celeris
	// constant; raising it is only safe when lengths are uniform, since the deadlock it
	// guards against needs a long laggard beside short neighbours.
	uint64_t outlier_bytes = celeris::kRegexOutlierBytes;
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
