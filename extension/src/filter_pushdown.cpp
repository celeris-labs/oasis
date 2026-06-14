#include "filter_pushdown.hpp"

#include "column_reader.hpp"
#include "duckdb/logging/log_manager.hpp"
#include "duckdb/planner/filter/conjunction_filter.hpp"
#include "duckdb/planner/filter/constant_filter.hpp"
#include "duckdb/planner/table_filter.hpp"
#include "duckdb/storage/statistics/string_stats.hpp"
#include "duckdb/storage/table/column_segment.hpp"
#include "parquet_reader.hpp"
#include "reader/struct_column_reader.hpp"

namespace duckdb {

// DuckDB's StringStats (and therefore BaseStatistics::CheckStatistics) only retains the first 8
// bytes of a column chunk's min/max, treating those truncated bounds as exact. For a string
// equality / comparison filter that is unsafe: a value whose first 8 bytes fall outside the
// truncated [min, max] can be (wrongly) ruled out even though the untruncated bound would have
// included it -- silently dropping whole row groups. DuckDB's ParquetReader guards against this
// with a string-specific check against the *full-length* Parquet thrift statistics; we mirror it
// here. Without this, string-equality predicates (e.g. p_brand='Brand#23' AND p_container='MED
// BOX' in TPC-H q17) over-prune row groups and lose matching rows.
static FilterPropagateResult CheckParquetStringFilter(BaseStatistics &stats, const Statistics &pq_col_stats,
                                                      const TableFilter &filter) {
	switch (filter.filter_type) {
	case TableFilterType::CONJUNCTION_AND: {
		auto &conjunction_filter = filter.Cast<ConjunctionAndFilter>();
		auto and_result = FilterPropagateResult::FILTER_ALWAYS_TRUE;
		for (auto &child_filter : conjunction_filter.child_filters) {
			auto child_prune_result = CheckParquetStringFilter(stats, pq_col_stats, *child_filter);
			if (child_prune_result == FilterPropagateResult::FILTER_ALWAYS_FALSE) {
				return FilterPropagateResult::FILTER_ALWAYS_FALSE;
			}
			if (child_prune_result != and_result) {
				and_result = FilterPropagateResult::NO_PRUNING_POSSIBLE;
			}
		}
		return and_result;
	}
	case TableFilterType::CONSTANT_COMPARISON: {
		auto &constant_filter = filter.Cast<ConstantFilter>();
		auto &min_value = pq_col_stats.min_value;
		auto &max_value = pq_col_stats.max_value;
		return StringStats::CheckZonemap(const_data_ptr_cast(min_value.c_str()), min_value.size(),
		                                 const_data_ptr_cast(max_value.c_str()), max_value.size(),
		                                 constant_filter.comparison_type, StringValue::Get(constant_filter.constant));
	}
	default:
		return filter.CheckStatistics(stats);
	}
}

bool RowGroupMatchesFilters(ClientContext &context, const OasisScanGlobalState &gstate, OasisScanLocalState &lstate,
                            size_t group) {
	if (!gstate.filters || gstate.filters->filters.empty()) {
		return true;
	}

    // Get the metadata that was already loaded with the Parquet footer during bind
	auto &root_reader = lstate.root_reader->Cast<StructColumnReader>();
	const auto &pq_columns = lstate.parquet_reader->GetFileMetadata()->row_groups[group].columns;

	// Filter keys are output/projection indices, aligned with gstate.projected_columns.
	for (auto &filter_entry : gstate.filters->filters) {
		size_t const out_idx = filter_entry.first;
		if (out_idx >= gstate.projected_columns.size()) {
			continue;
		}
		size_t const col_id = gstate.projected_columns[out_idx].column_id;
		auto &child_reader = root_reader.GetChildReader(col_id);
		auto stats = child_reader.Stats(group, pq_columns);
		if (!stats) {
			continue; // No statistics for this column chunk -- cannot prune on it.
		}

		// String columns need the full-length stats check (see CheckParquetStringFilter); the generic
		// CheckStatistics path truncates min/max to 8 bytes and would over-prune. Only applicable when
		// the Parquet chunk actually carries min_value/max_value.
		FilterPropagateResult prune_result;
		const auto &pq_meta_stats = pq_columns[child_reader.ColumnIndex()].meta_data.statistics;
		bool const has_min_max = pq_meta_stats.__isset.min_value && pq_meta_stats.__isset.max_value;
		if (child_reader.Type().id() == LogicalTypeId::VARCHAR && has_min_max) {
			prune_result = CheckParquetStringFilter(*stats, pq_meta_stats, *filter_entry.second);
		} else {
			prune_result = filter_entry.second->CheckStatistics(*stats);
		}

		if (prune_result == FilterPropagateResult::FILTER_ALWAYS_FALSE) {
			DUCKDB_LOG_DEBUG(context,
			                 "Skipping row group %llu: filter on column %llu ('%s') ruled out by zone map (%s)",
			                 (unsigned long long)group, (unsigned long long)col_id,
			                 child_reader.Schema().name.c_str(),
			                 filter_entry.second->ToString(child_reader.Schema().name).c_str());
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
		vec.ToUnifiedFormat(scan_count, vdata);

		ColumnSegment::FilterSelection(lstate.filter_sel, vec, vdata, scan_filter.filter,
		                               *scan_filter.filter_state, scan_count, approved_tuple_count);
	}

	if (approved_tuple_count != scan_count) {
		output.Slice(lstate.filter_sel, approved_tuple_count);
		output.SetCardinality(approved_tuple_count);
	}
	return approved_tuple_count;
}

} // namespace duckdb
