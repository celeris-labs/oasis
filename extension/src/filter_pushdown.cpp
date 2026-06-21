#include "filter_pushdown.hpp"

#include "column_reader.hpp"
#include "duckdb/logging/log_manager.hpp"
#include "duckdb/planner/filter/expression_filter.hpp"
#include "duckdb/planner/table_filter.hpp"
#include "duckdb/storage/table/column_segment.hpp"
#include "parquet_reader.hpp"

namespace duckdb {

bool RowGroupMatchesFilters(ClientContext &context, const OasisScanGlobalState &gstate, OasisScanLocalState &lstate,
                            size_t group) {
	if (!gstate.filters || gstate.filters->FilterCount() == 0) {
		return true;
	}

	// Get the metadata that was already loaded with the Parquet footer during bind.
	const auto &pq_columns = lstate.parquet_reader->GetFileMetadata()->row_groups[group].columns;

	// Filter keys are output/projection indices, aligned with gstate.projected_columns.
	for (auto &entry : *gstate.filters) {
		size_t const out_idx = entry.GetIndex();
		if (out_idx >= gstate.projected_columns.size()) {
			continue;
		}
		size_t const col_id = gstate.projected_columns[out_idx].column_id;
		auto &child_reader = lstate.scan_state->GetColumnReader(col_id);
		auto stats = child_reader.Stats(group, pq_columns);
		if (!stats) {
			continue; // No statistics for this column chunk -- cannot prune on it.
		}

		auto &expr_filter = ExpressionFilter::GetExpressionFilter(entry.Filter(), "RowGroupMatchesFilters");
		auto prune_result = expr_filter.CheckStatistics(context, *stats);

		if (prune_result == FilterPropagateResult::FILTER_ALWAYS_FALSE) {
			DUCKDB_LOG_DEBUG(context,
			                 "Skipping row group %llu: filter on column %llu ('%s') ruled out by zone map (%s)",
			                 (unsigned long long)group, (unsigned long long)col_id,
			                 child_reader.Schema().name.c_str(),
			                 expr_filter.ToString(child_reader.Schema().name).c_str());
			return false;
		}
	}
	return true;
}

idx_t ApplyFilters(OasisScanGlobalState &gstate, OasisScanLocalState &lstate, DataChunk &output) {
	if (lstate.scan_filters.empty()) {
		return output.size();
	}

	const idx_t scan_count = output.size();
	idx_t approved_tuple_count = scan_count;

	lstate.filter_sel.Initialize(nullptr);

	for (auto &scan_filter : lstate.scan_filters) {
		if (approved_tuple_count == 0) {
			break; // No rows left -- remaining filters cannot pass any.
		}
		// Filter keys are output/projection indices, aligned with output.data (the scan loop writes
		// output.data[i] for projected_columns[i], and filter keys index into projected_columns).
		auto &vec = output.data[scan_filter.filter_idx];

		UnifiedVectorFormat vdata;
		vec.ToUnifiedFormat(vdata);

		ColumnSegment::FilterSelection(lstate.filter_sel, vec, vdata, scan_filter.filter,
		                               *scan_filter.filter_state, scan_count, approved_tuple_count);
	}

	if (approved_tuple_count != scan_count) {
		output.Slice(lstate.filter_sel, approved_tuple_count);
		output.CheckCardinality(approved_tuple_count);
	}
	return approved_tuple_count;
}

} // namespace duckdb
