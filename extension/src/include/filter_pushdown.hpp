#pragma once

#include "oasis_scan.hpp"

namespace duckdb {

// Returns false if the pushed-down filters prove `group` cannot contain any matching row. Mirrors 
// the statistics-pruning logic of DuckDB's ParquetReader::PrepareRowGroupBuffer: for each projected 
// column with a filter, read the column chunk's Parquet statistics and ask the filter whether they 
// rule the group out entirely.
bool RowGroupMatchesFilters(ClientContext &context, const OasisScanGlobalState &gstate, OasisScanLocalState &lstate,
                            size_t group);

// Applies the pushed-down filters to the materialized `output` chunk in place, removing rows
// that do not satisfy every filter. Returns the number of rows that passed.
idx_t ApplyFilters(OasisScanGlobalState &gstate, OasisScanLocalState &lstate, DataChunk &output);

} // namespace duckdb
