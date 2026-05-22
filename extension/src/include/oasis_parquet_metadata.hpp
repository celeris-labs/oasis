#pragma once

#include "duckdb.hpp"
#include "parcore/metadata/metadata.hpp"

namespace duckdb {

class ParquetReader;

parcore::metadata::Metadata BuildParcoreMetadata(ClientContext &context, ParquetReader &parquet_reader);

parcore::metadata::Metadata BuildParcoreMetadataFromParquet(ClientContext &context, const string &filename);

} // namespace duckdb