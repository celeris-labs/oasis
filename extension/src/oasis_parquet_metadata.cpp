#include "oasis_parquet_metadata.hpp"

#include "duckdb/common/exception.hpp"
#include "duckdb/common/multi_file/multi_file_options.hpp"
#include "parquet_reader.hpp"
#include "parquet_types.h"
#include "thrift_tools.hpp"

namespace duckdb {

static parcore::metadata::Type parquet_type_to_parcore(duckdb_parquet::Type::type t) {
	switch (t) {
	case duckdb_parquet::Type::BOOLEAN:
		return parcore::metadata::Type::BYTE_T;
	case duckdb_parquet::Type::INT32:
		return parcore::metadata::Type::INT32_T;
	case duckdb_parquet::Type::INT64:
		return parcore::metadata::Type::INT64_T;
	case duckdb_parquet::Type::FLOAT:
		return parcore::metadata::Type::FLOAT_T;
	case duckdb_parquet::Type::DOUBLE:
		return parcore::metadata::Type::DOUBLE_T;
	case duckdb_parquet::Type::BYTE_ARRAY:
		return parcore::metadata::Type::BYTE_ARRAY;
	default:
		throw InvalidInputException("Parquet physical type %d not supported by ParCore", (int)t);
	}
}

static parcore::metadata::Compression parquet_codec_to_parcore(duckdb_parquet::CompressionCodec::type c) {
	switch (c) {
	case duckdb_parquet::CompressionCodec::UNCOMPRESSED:
		return parcore::metadata::Compression::RAW;
	case duckdb_parquet::CompressionCodec::SNAPPY:
		return parcore::metadata::Compression::SNAPPY;
	default:
		throw InvalidInputException("Parquet compression codec %d not supported by ParCore", (int)c);
	}
}

parcore::metadata::Metadata BuildParcoreMetadata(ClientContext &context, ParquetReader &parquet_reader) {
        (void)context;

        auto *file_meta = parquet_reader.GetFileMetadata();

        parcore::metadata::Metadata meta;

        for (auto &col : parquet_reader.columns) {
                meta.column_names.push_back(col.name);
        }

        for (auto &rg : file_meta->row_groups) {
                parcore::metadata::RowGroup parcore_rg;

                for (auto &col_chunk : rg.columns) {
                        auto &cmd = col_chunk.meta_data;

                        parcore::metadata::ColumnChunk parcore_cc;
                        parcore_cc.type = parquet_type_to_parcore(cmd.type);
                        parcore_cc.num_values = static_cast<uint64_t>(cmd.num_values);
                        parcore_cc.compression = parquet_codec_to_parcore(cmd.codec);
                        parcore_cc.offset = static_cast<uint64_t>(
                            cmd.__isset.dictionary_page_offset ? cmd.dictionary_page_offset : cmd.data_page_offset);
                        parcore_cc.total_compressed_size = static_cast<uint64_t>(cmd.total_compressed_size);

                        parcore_rg.chunks.push_back(std::move(parcore_cc));
                }

                meta.groups.push_back(std::move(parcore_rg));
        }

        return meta;
}

parcore::metadata::Metadata BuildParcoreMetadataFromParquet(ClientContext &context, const string &filename) {
	ParquetOptions parquet_opts(context);
	ParquetReader parquet_reader(context, OpenFileInfo {filename}, parquet_opts);
	return BuildParcoreMetadata(context, parquet_reader);
}

} // namespace duckdb