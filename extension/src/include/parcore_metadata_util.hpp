#pragma once

#include "duckdb.hpp"
#include "parcore/metadata/metadata.hpp"
#include "parquet_reader.hpp"

namespace duckdb {

// Builds the ParCore metadata (column names, row groups, per-column-chunk type/compression/offset)
// from an already-opened DuckDB ParquetReader's footer. Throws InvalidInputException for Parquet
// physical types or compression codecs that ParCore does not support.
parcore::metadata::Metadata BuildParcoreMetadata(ParquetReader &parquet_reader);

// Whether the decoders can emit the column chunk's dictionary and indices instead of its values: The
// chunk has a dictionary page and every data page is dictionary-encoded. The page encodings come
// from encoding_stats, or else from the encodings list when it holds no PLAIN encoding, since some
// writers list PLAIN for the dictionary page itself.
// WARNING: The check only sees the footer metadata. Writers that run out of dictionary space switch
// to PLAIN pages mid-chunk. If a writer does not record such a switch in encoding_stats or
// encodings, the check passes and the decoders hang or emit corrupt output on the PLAIN pages.
bool HasOnlyDictionaryPages(const duckdb_parquet::ColumnMetaData &cmd);

} // namespace duckdb
