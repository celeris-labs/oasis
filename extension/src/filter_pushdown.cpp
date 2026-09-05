#include "filter_pushdown.hpp"

#include "column_reader.hpp"
#include "duckdb/logging/log_manager.hpp"
#include "duckdb/planner/filter/expression_filter.hpp"
#include "duckdb/planner/table_filter.hpp"
#include "duckdb/storage/table/column_segment.hpp"
#include "parquet_reader.hpp"

namespace duckdb {

// Appends the leaf conjuncts of a (possibly nested) top-level AND to `conjuncts`. A non-AND
// expression is its own single conjunct.
static void CollectConjuncts(const Expression &expr, vector<reference<const Expression>> &conjuncts) {
	if (expr.GetExpressionClass() == ExpressionClass::BOUND_CONJUNCTION &&
	    expr.GetExpressionType() == ExpressionType::CONJUNCTION_AND) {
		for (auto &child : expr.Cast<BoundConjunctionExpression>().GetChildren()) {
			CollectConjuncts(*child, conjuncts);
		}
		return;
	}
	conjuncts.push_back(expr);
}

void BuildScanFilters(ClientContext &context, const TableFilterSet &filters,
                      std::vector<OasisScanFilter> &scan_filters) {
	for (auto &entry : filters) {
		auto &filter = entry.Filter();
		if (filter.filter_type != TableFilterType::EXPRESSION_FILTER) {
			scan_filters.emplace_back(context, entry.GetIndex(), filter);
			continue;
		}
		auto &expr = *filter.Cast<ExpressionFilter>().expr;
		vector<reference<const Expression>> conjuncts;
		CollectConjuncts(expr, conjuncts);
		if (conjuncts.size() <= 1) {
			scan_filters.emplace_back(context, entry.GetIndex(), filter);
			continue;
		}
		// Splitting an AND into sequentially applied filters is equivalent: Both intersect the
		// passing rows, and a NULL conjunct fails the row either way.
		for (auto &conjunct : conjuncts) {
			scan_filters.emplace_back(context, entry.GetIndex(),
			                          make_uniq<ExpressionFilter>(conjunct.get().Copy()));
		}
	}
}

bool RowGroupMatchesFilters(ClientContext &context, const OasisScanGlobalState &gstate, OasisScanLocalState &lstate,
                            size_t group, std::vector<bool> &needs_row_filter) {
	needs_row_filter.assign(lstate.scan_filters.size(), true);
	if (lstate.scan_filters.empty()) {
		return true;
	}

	// Get the metadata that was already loaded with the Parquet footer during bind.
	const auto &pq_columns = lstate.parquet_reader->GetFileMetadata()->row_groups[group].columns;

	// Filter keys are output/projection indices, aligned with gstate.projected_columns.
	for (size_t k = 0; k < lstate.scan_filters.size(); k++) {
		size_t const out_idx = lstate.scan_filters[k].filter_idx;
		if (out_idx >= gstate.projected_columns.size()) {
			continue;
		}
		size_t const col_id = gstate.projected_columns[out_idx].column_id;
		auto &child_reader = lstate.scan_state->GetColumnReader(col_id);
		auto stats = child_reader.Stats(group, pq_columns);
		if (!stats) {
			continue; // No statistics for this column chunk -- cannot prune on it.
		}

		auto &expr_filter = ExpressionFilter::GetExpressionFilter(lstate.scan_filters[k].filter, "RowGroupMatchesFilters");
		auto prune_result = expr_filter.CheckStatistics(context, *stats);

		if (prune_result == FilterPropagateResult::FILTER_ALWAYS_FALSE) {
			DUCKDB_LOG_DEBUG(context,
			                 "Skipping row group %llu: filter on column %llu ('%s') ruled out by zone map (%s)",
			                 (unsigned long long)group, (unsigned long long)col_id,
			                 child_reader.Schema().name.c_str(),
			                 expr_filter.ToString(child_reader.Schema().name).c_str());
			return false;
		}
		if (prune_result == FilterPropagateResult::FILTER_ALWAYS_TRUE) {
			// Every row in this group passes the filter (stats cover the filter range and rule out
			// NULLs), so skip its row-level evaluation for this group.
			needs_row_filter[k] = false;
		}
	}
	return true;
}

idx_t DecodeAndFilterSlice(OasisScanGlobalState &gstate, OasisScanLocalState &lstate, DataChunk &scan_chunk,
                           idx_t emit) {
	const idx_t scan_count = emit;
	idx_t approved_tuple_count = scan_count;
	auto &sel = lstate.filter_sel;
	sel.Initialize(nullptr);
	bool any_filter_ran = false;

	auto *define_ptr = reinterpret_cast<uint8_t *>(lstate.scan_state->define_buf.ptr);
	auto *repeat_ptr = reinterpret_cast<uint8_t *>(lstate.scan_state->repeat_buf.ptr);

	// Whether filter k still needs row-level evaluation on this group (not proven always-true).
	auto filter_active = [&](size_t k) {
		return k >= lstate.current_needs_row_filter.size() || lstate.current_needs_row_filter[k];
	};

	lstate.cpu_column_read.assign(gstate.projected_columns.size(), false);

	// Phase 1: CPU filter columns. The first active conjunct of a column consumes the slice from
	// its reader via Filter() (dictionary pages evaluate the predicate once per dictionary entry);
	// further active conjuncts filter the decoded vector in place. Every reader must consume each
	// slice exactly once, so a column whose rows are already all rejected skips instead.
	if (gstate.has_cpu_columns) {
		ScopedTimer timer(lstate.string_decode_time_ns);
		for (size_t k = 0; k < lstate.scan_filters.size(); k++) {
			auto &scan_filter = lstate.scan_filters[k];
			// Filter keys are output/projection indices, aligned with projected_columns and
			// scan_chunk.data.
			const auto &col = gstate.projected_columns[scan_filter.filter_idx];
			if (!col.is_cpu || !filter_active(k)) {
				continue;
			}
			auto &reader = lstate.scan_state->GetColumnReader(col.column_id);
			auto &vec = scan_chunk.data[scan_filter.filter_idx];
			if (!lstate.cpu_column_read[scan_filter.filter_idx]) {
				lstate.cpu_column_read[scan_filter.filter_idx] = true;
				if (approved_tuple_count == 0) {
					reader.Skip(scan_count);
					continue;
				}
				// The reader writes into define/repeat scratch as a side effect; zero per slice so
				// a short final slice can't inherit a previous slice's levels.
				lstate.scan_state->define_buf.zero();
				lstate.scan_state->repeat_buf.zero();
				ColumnReaderInput input(scan_count, define_ptr, repeat_ptr);
				reader.Filter(input, vec, scan_filter.filter, *scan_filter.filter_state, sel, approved_tuple_count,
				              !any_filter_ran);
				any_filter_ran = true;
			} else if (approved_tuple_count > 0) {
				ColumnReader::ApplyFilter(vec, scan_filter.filter, *scan_filter.filter_state, scan_count, sel,
				                          approved_tuple_count);
				any_filter_ran = true;
			}
		}
	}

	// Phase 2: hardware-column filters, on the already-decoded flat vectors.
	{
		ScopedTimer timer(lstate.filter_time_ns);
		for (size_t k = 0; k < lstate.scan_filters.size(); k++) {
			if (approved_tuple_count == 0) {
				break;
			}
			auto &scan_filter = lstate.scan_filters[k];
			const auto &col = gstate.projected_columns[scan_filter.filter_idx];
			if (col.is_cpu || !filter_active(k)) {
				continue;
			}
			auto &vec = scan_chunk.data[scan_filter.filter_idx];
			UnifiedVectorFormat vdata;
			vec.ToUnifiedFormat(vdata);
			ColumnSegment::FilterSelection(sel, vec, vdata, scan_filter.filter, *scan_filter.filter_state, scan_count,
			                               approved_tuple_count);
		}
	}

	// Phase 3: remaining CPU columns, decoded only for the surviving rows. A column that is not
	// needed -- all rows rejected, or filter-only and not emitted -- is skipped. Skips are
	// deferred and flushed by this column's next read; leftovers at the end of a group are
	// discarded with the readers (InitGroupCPUColumns recreates them per group).
	if (gstate.has_cpu_columns) {
		ScopedTimer timer(lstate.string_decode_time_ns);
		for (size_t i = 0; i < gstate.projected_columns.size(); i++) {
			const auto &col = gstate.projected_columns[i];
			if (!col.is_cpu || lstate.cpu_column_read[i]) {
				continue;
			}
			auto &reader = lstate.scan_state->GetColumnReader(col.column_id);
			if (approved_tuple_count == 0 || !gstate.column_emitted[i]) {
				reader.Skip(scan_count);
				continue;
			}
			lstate.scan_state->define_buf.zero();
			lstate.scan_state->repeat_buf.zero();
			ColumnReaderInput input(scan_count, define_ptr, repeat_ptr);
			auto &vec = scan_chunk.data[i];
			reader.Select(input, vec, sel, approved_tuple_count);
			if (vec.GetVectorType() == VectorType::FLAT_VECTOR) {
				FlatVector::SetSize(vec, count_t(scan_count));
			}
		}
	}

	if (approved_tuple_count == 0) {
		return 0;
	}
	// Unwritten vectors (skipped filter-only columns) have stale sizes, so set instead of check.
	scan_chunk.SetChildCardinality(scan_count);
	if (approved_tuple_count != scan_count) {
		scan_chunk.Slice(sel, approved_tuple_count);
		scan_chunk.CheckCardinality(approved_tuple_count);
	}
	return approved_tuple_count;
}

} // namespace duckdb
