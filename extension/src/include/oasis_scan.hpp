#pragma once

#include "coalesced_fetcher.hpp"
#include "column_reader.hpp"
#include "duckdb.hpp"
#include "libstf_buffer_vector_buffer.hpp"
#include "oasis/oasis_context.hpp"
#include "oasis/splinter_result.hpp"
#include "oasis_context_cache_entry.hpp"
#include "parcore/metadata/metadata.hpp"
#include "parquet_reader.hpp"

#include "duckdb/parallel/async_result.hpp"
#include "duckdb/planner/table_filter_state.hpp"

#include <atomic>
#include <chrono>
#include <deque>
#include <mutex>

namespace duckdb {

class PhysicalTableScan;

// Adds the lifetime of the scope to `target_ns`.
class ScopedTimer {
public:
	explicit ScopedTimer(uint64_t &target_ns) : target_ns(target_ns), start(std::chrono::steady_clock::now()) {
	}
	~ScopedTimer() {
		auto elapsed = std::chrono::steady_clock::now() - start;
		target_ns += static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(elapsed).count());
	}

private:
	uint64_t &target_ns;
	std::chrono::steady_clock::time_point start;
};

// Per-worker state for one pushed-down TableFilter. TableFilterState is not safe to share across
// threads, so each worker owns its own (mirrors ParquetReader's per-scan-state scan_filters).
struct OasisScanFilter {
	OasisScanFilter(ClientContext &context, idx_t filter_idx, const TableFilter &filter)
	    : filter_idx(filter_idx), filter(filter), filter_state(TableFilterState::Initialize(context, filter)) {
	}

	// Owning variant: Used for filters synthesized by splitting a pushed-down AND into its
	// conjuncts, so each conjunct is classified and evaluated independently.
	OasisScanFilter(ClientContext &context, idx_t filter_idx, unique_ptr<TableFilter> owned_filter_p)
	    : filter_idx(filter_idx), owned_filter(std::move(owned_filter_p)), filter(*owned_filter),
	      filter_state(TableFilterState::Initialize(context, *owned_filter)) {
	}

	idx_t filter_idx;
	unique_ptr<TableFilter> owned_filter; // null when `filter` references a gstate-owned filter
	const TableFilter &filter;
	unique_ptr<TableFilterState> filter_state;
};

struct OasisScanBindData : public TableFunctionData {
	string filename;
	parcore::metadata::Metadata metadata;
	shared_ptr<ParquetFileMetadataCache> parquet_metadata;
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

	// filter_prune support. When the plan consumes fewer columns than the scan reads (some are
	// filter-only), can_prune is set, projection_ids holds the indices (into projected_columns)
	// of the consumed columns in output order, and column_emitted marks which projected columns
	// are consumed at all. Without pruning, column_emitted is all-true and output == scan layout.
	vector<column_t> projection_ids;
	bool can_prune = false;
	std::vector<bool> column_emitted;

	// True when the query consumes no column values (e.g. COUNT(*), EXISTS).
	bool emit_cardinality_only = false;

	optional_ptr<TableFilterSet> filters;

	// Dynamic join filters (min/max pushed by hash joins into the probe-side scan). Our global
	// state is created at schedule time (INITIALIZE_ON_SCHEDULE), before the build side has run,
	// so PhysicalTableScan's own dynamic-filter merge sees an empty set and drops them. Instead we
	// keep a pointer to the physical scan and merge its dynamic filters into `filters` once, when
	// the first worker initializes -- the probe pipeline only executes after the build completed.
	optional_ptr<const PhysicalTableScan> physical_scan;
	std::once_flag dynamic_filter_merge;
	unique_ptr<TableFilterSet> merged_filters;

	// Row-group cursor: the next group to hand out. Claimed atomically by workers.
	std::atomic<size_t> next_group {0};
	size_t total_groups = 0;

	size_t groups_in_flight_per_worker = 1;

	// Scan-wide profiling totals, folded in from each worker's local counters when its scan
	// finishes (OasisScanGetMetrics) and reported on the query profiling tree.
	std::atomic<uint64_t> filter_time_ns {0};
	std::atomic<uint64_t> string_decode_time_ns {0};

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

	// Per-worker pushed-down filter states, built once at scan init from gstate.filters.
	std::vector<OasisScanFilter> scan_filters;

	// Reused selection vector for row-level filtering, so we don't reallocate per scan call.
	SelectionVector filter_sel;

	// When can_prune, slices are scanned and filtered in this full-width chunk and only the
	// projection_ids columns are referenced into the output chunk.
	DataChunk all_columns;

	// Per-slice scratch: which CPU columns have consumed the current slice from their reader.
	std::vector<bool> cpu_column_read;

	struct PendingGroup {
		size_t group = 0;
		size_t num_rows = 0;

		// Per-scan_filters entry: whether the filter still needs row-level evaluation on this
		// group (false when the group's statistics prove it always-true).
		std::vector<bool> needs_row_filter;

		std::unique_ptr<CoalescedFetcher> fetcher;

		// Hardware columns of this group:
		// hw_slot[k] is the projection index, hw_chunks[k] the chunk, host_handles[k] the fetcher
		// handle resolving hw_chunks[k]'s bytes (host path only).
		std::vector<size_t> hw_slot;
		std::vector<const parcore::metadata::ColumnChunk *> hw_chunks;
		std::vector<CoalescedFetcher::RangeHandle> host_handles;

		// CPU (string) columns of this group: Fetched over RDMA as raw bypass flows: cpu_slot[k]
        // is the projection index, cpu_chunks[k] the chunk.
		std::vector<size_t> cpu_slot;
		std::vector<const parcore::metadata::ColumnChunk *> cpu_chunks;

		oasis::SplinterResultHandle result;
		bool submitted = false;
		size_t batches_remaining = 0;

		std::vector<std::shared_ptr<libstf::Buffer>> hw_buffers;
		std::vector<std::vector<std::shared_ptr<libstf::Buffer>>> cpu_buffers;
	};

	std::deque<unique_ptr<PendingGroup>> inflight;

	bool groups_exhausted = false;

	std::vector<std::shared_ptr<libstf::Buffer>> current_buffers;

	// The current group's needs_row_filter mask (see PendingGroup), consumed by DecodeAndFilterSlice.
	std::vector<bool> current_needs_row_filter;

	size_t current_buf_offset = 0;
	size_t current_group_num_rows = 0;
	idx_t current_group = 0;

	// Empty-projection path only (COUNT(*) etc.): Rows left to emit from the row group we last
	// claimed. We never decode anything in this path -- the count comes straight from the Parquet
	// metadata.
	size_t empty_proj_remaining = 0;

	// This worker's profiling counters (steady_clock nanoseconds), folded into the global totals
	// when the worker's scan finishes.
	uint64_t filter_time_ns = 0;
	uint64_t string_decode_time_ns = 0;
};

void RegisterOasisScanFunction(ExtensionLoader &loader);

} // namespace duckdb
