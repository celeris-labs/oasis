#pragma once

#include "oasis_scan.hpp"

namespace duckdb {

// Builds this worker's scan filters from the pushed-down filter set. A column's ExpressionFilter
// whose expression is a top-level AND (how TableFilterSet::PushFilter combines multiple pushed
// filters, e.g. a dynamic join min/max range plus a bloom filter) is split into one scan filter
// per conjunct, so RowGroupMatchesFilters can classify each conjunct independently: A conjunct
// the group's statistics prove always-true is skipped without disabling its selective siblings.
void BuildScanFilters(ClientContext &context, const TableFilterSet &filters,
                      std::vector<OasisScanFilter> &scan_filters);

// Returns false if the pushed-down filters prove `group` cannot contain any matching row. Mirrors
// the statistics-pruning logic of DuckDB's ParquetReader::PrepareRowGroupBuffer: For each projected
// column with a filter, read the column chunk's Parquet statistics and ask the filter whether they
// rule the group out entirely.
//
// When the group survives, `needs_row_filter` holds one entry per lstate.scan_filters: false for
// filters the statistics prove always-true on this group (no row-level evaluation needed, the
// common case for dynamic join min/max filters on uniformly spread keys), true otherwise.
bool RowGroupMatchesFilters(ClientContext &context, const OasisScanGlobalState &gstate, OasisScanLocalState &lstate,
                            size_t group, std::vector<bool> &needs_row_filter);

// Decodes the current slice's CPU columns and applies the pushed-down filters, mirroring the
// parquet reader's late-materialization order: CPU filter columns are decoded through
// ColumnReader::Filter (dictionary pages evaluate the predicate once per dictionary entry),
// hardware-column filters run on the already-decoded flat vectors, and the remaining CPU columns
// are then decoded only for the surviving rows (Select) or skipped entirely when all rows are
// rejected or the column is filter-only and not emitted. Filters whose
// lstate.current_needs_row_filter entry is false are skipped (proven always-true on this group).
// The hardware columns must already be in scan_chunk. Slices scan_chunk to the surviving rows and
// returns their count (0 = fully filtered, scan_chunk contents undefined).
idx_t DecodeAndFilterSlice(OasisScanGlobalState &gstate, OasisScanLocalState &lstate, DataChunk &scan_chunk,
                           idx_t emit);

} // namespace duckdb
