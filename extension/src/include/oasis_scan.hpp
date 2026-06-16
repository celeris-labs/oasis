#pragma once

#include "column_reader.hpp"
#include "duckdb.hpp"
#include "libstf_buffer_vector_buffer.hpp"
#include "oasis/oasis_context.hpp"
#include "oasis/splinter_result.hpp"
#include "oasis_context_cache_entry.hpp"
#include "parcore/metadata/metadata.hpp"
#include "parquet_reader.hpp"

#include "duckdb/planner/table_filter_state.hpp"

#include <atomic>
#include <deque>
#include <functional>
#include <mutex>
#include <vector>

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
	shared_ptr<ParquetFileMetadataCache> parquet_metadata;
};

struct ProjectedColumn {
	size_t column_id;
	size_t elem_size; // 0 for CPU (string) columns
	bool is_cpu;      // variable-length column decoded on the CPU path, not the FPGA
};

// Defined below; the global state owns one for schedule-time / cross-pipeline prefetch.
struct OasisScanLocalState;

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

	size_t groups_in_flight_per_worker = 1;

	// --- Executor-driven cross-pipeline prefetch ---
	//
	// The executor owns the real pipeline dependency graph. When a predecessor pipeline submits its
	// last splinter it calls Executor::PrefetchNextPipelines, which fires the table-function `prefetch`
	// hook (OasisScanPrefetch) on the source of the genuinely-next pipeline. That hook submits this
	// scan's prefetch window. The first scan of a query has no predecessor, so it is never warmed and
	// cold-starts.

	// This scan's source operator, the key the executor matches in PrefetchNextPipelines. Set from
	// input.op in OasisScanInitGlobal; nullptr (and prefetch disabled) for cardinality-only scans.
	const PhysicalOperator *source_op = nullptr;

	// The scan's bind data, stashed so the prefetch hook (which only receives ClientContext + gstate)
	// is self-contained. Set in OasisScanInitGlobal.
	const OasisScanBindData *bind_data = nullptr;

	// How many row groups to warm when this scan's prefetch fires (oasis_scan_prefetch_groups,
	// capped at total_groups). 0 disables prefetch for this scan.
	size_t prefetch_groups = 0;

	// Set by the executor's prefetch hook the instant before it submits this scan's window: a true
	// value means a predecessor is warming us, so a worker that arrives first should yield (BLOCKED)
	// rather than cold-start. A first scan never gets the flag and so never yields.
	std::atomic<bool> prefetch_expected {false};

	// A global-state-owned worker context (own file handle + readers) used to build and submit the
	// prefetch window from outside any pipeline's local-state lifetime. Its `inflight` deque holds the
	// warm PendingGroups until live workers adopt them. Guarded by prefetch_mutex.
	std::mutex prefetch_mutex;
	unique_ptr<OasisScanLocalState> prefetch_worker;
	// Set once the prefetch window has been submitted (OasisScanPrefetch ran). Read by live workers'
	// cold-start check.
	std::atomic<bool> prefetch_submitted {false};

	// One-shot guard so the prefetch hook submits the window exactly once even if the executor fires
	// it more than once.
	std::atomic_flag prefetch_hook_fired = ATOMIC_FLAG_INIT;

	// Waiter list fired by SubmitPrefetchWindow once the window is submitted: a worker that reached
	// this scan before its window existed (and parked itself BLOCKED via ColdStartYield) registers a
	// wake here so it is rescheduled promptly. Guarded by prefetch_mutex.
	using WakeFn = std::function<void()>;
	std::vector<WakeFn> prefetch_waiters;

	// Guards the one-time "this scan submitted its last splinter" event. The shared cursor makes
	// last-splinter a single well-defined event (whichever worker claims the final group); this flag
	// ensures exactly one worker notifies the executor.
	std::atomic_flag last_splinter_fired = ATOMIC_FLAG_INIT;

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

	// Async (BLOCKED) state for the row group this worker has submitted but not yet collected.
	struct PendingGroup {
		size_t group = 0;
		size_t num_rows = 0;
		// The whole row group is one QuerySplinter with one result handle. Batches arrive tagged 
        // with their projection index and are placed into hw_buffers by tag.
		oasis::SplinterResultHandle result;
		size_t hw_columns_remaining = 0;
		std::vector<std::vector<unique_ptr<Vector>>> cpu_slices;
		std::vector<std::shared_ptr<libstf::Buffer>> hw_buffers;

		// True for a prefetched group whose hardware splinter was submitted from global state but
		// whose CPU/string columns have NOT been decoded yet (no local reader was available at
		// prefetch time). The worker that adopts it decodes them lazily before first use.
		bool cpu_decode_deferred = false;

		// One-shot wake guard for the current BLOCKED return: Only the first ready signal fires
        // InterruptState::Callback(), so a single BLOCKED return yields exactly one Reschedule().
		std::shared_ptr<std::atomic_flag> wake_guard = std::make_shared<std::atomic_flag>();
	};

	std::deque<unique_ptr<PendingGroup>> inflight;

	bool groups_exhausted = false;

	// Cold-start yield bookkeeping (Phase 5). A worker yields (BLOCKED) on its very first entry only
	// when nothing has been prefetched for this scan yet and it could not fill any group; once it has
	// kept at least one group in flight it never takes the cold-yield path again.
	bool warmed_up = false;
	bool adopted_prefetch = false; // this worker has already drained gstate's prefetch window

	std::vector<std::shared_ptr<libstf::Buffer>> current_buffers;

	// Fully-decoded CPU/string columns for the current row group, indexed [projection_index][slice].
	std::vector<std::vector<unique_ptr<Vector>>> current_cpu_slices;

	size_t current_buf_offset = 0;
	size_t current_group_num_rows = 0;
	idx_t current_group = 0;

	// Empty-projection path only (COUNT(*) etc.): Rows left to emit from the row group we last
    // claimed. We never decode anything in this path -- the count comes straight from the Parquet
    // metadata.
	size_t empty_proj_remaining = 0;
};

void RegisterOasisScanFunction(ExtensionLoader &loader);

} // namespace duckdb
