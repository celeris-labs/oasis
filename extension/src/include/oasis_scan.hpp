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
#include <deque>

namespace duckdb {

// Per-worker state for one pushed-down TableFilter. TableFilterState is not safe to share across
// threads, so each worker owns its own (mirrors ParquetReader's per-scan-state scan_filters).
struct OasisScanFilter {
	OasisScanFilter(ClientContext &context, idx_t filter_idx, const TableFilter &filter)
	    : filter_idx(filter_idx), filter(filter), filter_state(TableFilterState::Initialize(context, filter)) {
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

	struct PendingGroup {
		size_t group = 0;
		size_t num_rows = 0;

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
