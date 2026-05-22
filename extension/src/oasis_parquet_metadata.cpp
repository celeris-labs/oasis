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
	auto *file_meta = parquet_reader.GetFileMetadata();
	auto &file_handle = parquet_reader.GetHandle();

	// TODO: Remove this page metadata fetch after adding a page header parser to the hardware.
	auto proto = duckdb_base_std::make_shared<ThriftFileTransport>(file_handle, false);
	auto thrift_proto =
	    make_uniq<duckdb_apache::thrift::protocol::TCompactProtocolT<ThriftFileTransport>>(proto);

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

			int64_t start_offset =
			    cmd.__isset.dictionary_page_offset ? cmd.dictionary_page_offset : cmd.data_page_offset;
			int64_t end_offset = start_offset + cmd.total_compressed_size;

			proto->SetLocation(static_cast<idx_t>(start_offset));

			uint64_t hybrid_num_values = 0;

			while (proto->GetLocation() < static_cast<idx_t>(end_offset)) {
				duckdb_parquet::PageHeader page_hdr;
				page_hdr.read(thrift_proto.get());

				idx_t page_data_offset = proto->GetLocation();
				uint64_t page_size = static_cast<uint64_t>(page_hdr.compressed_page_size);

				parcore::metadata::Page parcore_page;
				parcore_page.offset = page_data_offset;
				parcore_page.size = page_size;

				if (page_hdr.type == duckdb_parquet::PageType::DICTIONARY_PAGE) {
					parcore_page.encoding = parcore::metadata::Encoding::PLAIN;
					parcore_page.num_values =
					    static_cast<uint64_t>(page_hdr.dictionary_page_header.num_values);
					parcore_cc.dictionary = parcore_page;
				} else if (page_hdr.type == duckdb_parquet::PageType::DATA_PAGE) {
					auto enc = page_hdr.data_page_header.encoding;
					if (enc == duckdb_parquet::Encoding::RLE_DICTIONARY ||
					    enc == duckdb_parquet::Encoding::PLAIN_DICTIONARY) {
						parcore_page.encoding = parcore::metadata::Encoding::HYBRID;
						parcore_page.num_values =
						    static_cast<uint64_t>(page_hdr.data_page_header.num_values);
						hybrid_num_values += parcore_page.num_values;
					} else {
						parcore_page.encoding = parcore::metadata::Encoding::PLAIN;
						parcore_page.num_values =
						    static_cast<uint64_t>(page_hdr.data_page_header.num_values);
					}
					parcore_cc.data.push_back(parcore_page);
				} else if (page_hdr.type == duckdb_parquet::PageType::DATA_PAGE_V2) {
					auto enc = page_hdr.data_page_header_v2.encoding;
					if (enc == duckdb_parquet::Encoding::RLE_DICTIONARY ||
					    enc == duckdb_parquet::Encoding::PLAIN_DICTIONARY) {
						parcore_page.encoding = parcore::metadata::Encoding::HYBRID;
						parcore_page.num_values =
						    static_cast<uint64_t>(page_hdr.data_page_header_v2.num_values);
						hybrid_num_values += parcore_page.num_values;
					} else {
						parcore_page.encoding = parcore::metadata::Encoding::PLAIN;
						parcore_page.num_values =
						    static_cast<uint64_t>(page_hdr.data_page_header_v2.num_values);
					}
					parcore_cc.data.push_back(parcore_page);
				}

				proto->SetLocation(page_data_offset + page_size);
			}

			parcore_cc.hybrid_num_values = hybrid_num_values;
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