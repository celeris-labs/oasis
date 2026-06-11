#pragma once

#include "duckdb.hpp"
#include "parcore/metadata/metadata.hpp"
#include "parquet_reader.hpp"

namespace duckdb {

// Builds the ParCore metadata (column names, row groups, per-column-chunk type/compression/offset)
// from an already-opened DuckDB ParquetReader's footer. Throws InvalidInputException for Parquet
// physical types or compression codecs that ParCore does not support.
parcore::metadata::Metadata BuildParcoreMetadata(ParquetReader &parquet_reader);

} // namespace duckdb
