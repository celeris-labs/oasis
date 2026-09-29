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
	for (size_t k = 0; k < lstate.scan_filters.size(); k++) {
		needs_row_filter[k] = lstate.scan_filters[k].row_level;
	}
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
                           idx_t emit, optional_ptr<const SelectionVector> candidate_sel, idx_t candidate_count) {
	/*
	Function internals and terminology:

	The function decodes CPU columns and applies filter to both CPU and HW columns.
	It combines the results of all filters, so it can return a (consistent) subset of the rows for all columns.

	This works by progressively pruning the rows as more filters are evaluated. This leads to different mappings of the original rows:
	- Page space - all rows as stored in the parquet file.
	- Candidate space - the rows that are selected by candidate_sel (if present, otherwise it's the same as page space).
	- Survivor space - the rows that survive all filters so far.

	HW columns are inherently in candidate space, as they are arrive (or are pruned) from the FPGA.
	They are sliced to survivor space at the end of the function.

	CPU columns are decoded from page space directly into survivor space. Every time the survivor space is pruned, ALL the CPU columns are adjusted.
	*/
	
	auto *define_ptr = reinterpret_cast<uint8_t *>(lstate.scan_state->define_buf.ptr);
	auto *repeat_ptr = reinterpret_cast<uint8_t *>(lstate.scan_state->repeat_buf.ptr);

	// Whether filter k still needs row-level evaluation on this group (not proven always-true).
	auto filter_active = [&](size_t k) {
		return k >= lstate.current_needs_row_filter.size() || lstate.current_needs_row_filter[k];
	};

	const idx_t scan_count = candidate_sel ? candidate_count : emit;
	idx_t approved_tuple_count = scan_count;
	auto &sel = lstate.filter_sel;
	sel.Initialize(nullptr);

	lstate.cpu_column_read.assign(gstate.projected_columns.size(), false);

	// Step 1: hardware-column filters, evaluated directly on in-memory FPGA buffers.
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
			ColumnReader::ApplyFilter(vec, scan_filter.filter, *scan_filter.filter_state, scan_count, sel,
			                          approved_tuple_count);
		}
	}

	auto candidate_to_page_space = [&](const SelectionVector &current_sel, idx_t count) -> SelectionVector {
		if (!candidate_sel) {
			return current_sel;
		}
		return SelectionVector(candidate_sel->Slice(current_sel, count));
	};

	// read_cpu_column parses the CPU column and returns it in survivor space.
	auto read_cpu_column = [&](size_t col_idx) {
		auto &reader = lstate.scan_state->GetColumnReader(gstate.projected_columns[col_idx].column_id);
		auto &vec = scan_chunk.data[col_idx];
		lstate.scan_state->define_buf.zero();
		lstate.scan_state->repeat_buf.zero();

		auto reader_sel = candidate_to_page_space(sel, approved_tuple_count);

		ColumnReaderInput input(emit, define_ptr, repeat_ptr);
		reader.Select(input, vec, reader_sel, approved_tuple_count);
		vec.Slice(reader_sel, approved_tuple_count);
	};

	// Step 2: CPU filter columns, decoded only for rows surviving hardware filters.
	if (gstate.has_cpu_columns && approved_tuple_count > 0) {
		ScopedTimer timer(lstate.string_decode_time_ns);
		for (size_t k = 0; k < lstate.scan_filters.size(); k++) {
			if (approved_tuple_count == 0) {
				break;
			}

			auto &scan_filter = lstate.scan_filters[k];
			const auto &col = gstate.projected_columns[scan_filter.filter_idx];
			if (!col.is_cpu || !filter_active(k)) {
				continue;
			}

			auto &vec = scan_chunk.data[scan_filter.filter_idx];
			if (!lstate.cpu_column_read[scan_filter.filter_idx]) {
				lstate.cpu_column_read[scan_filter.filter_idx] = true;
				read_cpu_column(scan_filter.filter_idx);
			}

			SelectionVector filter_sel;
			filter_sel.Initialize(nullptr);
			idx_t prev_count = approved_tuple_count;
			ColumnReader::ApplyFilter(vec, scan_filter.filter, *scan_filter.filter_state, prev_count,
			                          filter_sel, approved_tuple_count);
			if (approved_tuple_count < prev_count) {
				// update survivor space
				sel.Initialize(sel.Slice(filter_sel, approved_tuple_count));

				// update all CPU columns
				for (size_t j = 0; j < gstate.projected_columns.size(); j++) {
					if (gstate.projected_columns[j].is_cpu && lstate.cpu_column_read[j]) {
						scan_chunk.data[j].Slice(filter_sel, approved_tuple_count);
					}
				}
			}
		}
	}

	// Step 3: remaining emitted CPU columns, decoded only for the final surviving rows.
	if (gstate.has_cpu_columns) {
		ScopedTimer timer(lstate.string_decode_time_ns);
		for (size_t i = 0; i < gstate.projected_columns.size(); i++) {
			const auto &col = gstate.projected_columns[i];
			if (!col.is_cpu || lstate.cpu_column_read[i]) {
				continue;
			}

			auto &reader = lstate.scan_state->GetColumnReader(col.column_id);
			if (approved_tuple_count == 0 || !gstate.column_emitted[i]) {
				reader.Skip(emit);
				continue;
			}

			read_cpu_column(i);
		}
	}

	if (approved_tuple_count == 0) {
		scan_chunk.SetChildCardinality(0);
		return 0;
	}

	// Slice hardware columns down to the surviving rows.
	// CPU columns are actively sliced during filter evaluation, so they are already in the correct survivor space.
	if (approved_tuple_count != scan_count) {
		for (size_t i = 0; i < gstate.projected_columns.size(); i++) {
			if (!gstate.projected_columns[i].is_cpu) {
				scan_chunk.data[i].Slice(sel, approved_tuple_count);
			}
		}
	}
	
	scan_chunk.SetChildCardinality(approved_tuple_count);
	return approved_tuple_count;
}

} // namespace duckdb
