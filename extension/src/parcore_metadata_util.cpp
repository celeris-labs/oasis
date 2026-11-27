#include "parcore_metadata_util.hpp"

#include "duckdb/common/exception.hpp"
#include "parquet_types.h"

namespace duckdb {

static parcore::metadata::Type parquet_type_to_parcore(duckdb_parquet::Type::type t) {
	switch (t) {
	case duckdb_parquet::Type::BOOLEAN:
		return parcore::metadata::Type::BYTE_T;
	case duckdb_parquet::Type::INT32:
		return parcore::metadata::Type::INT32_T;
	case duckdb_parquet::Type::FLOAT:
		return parcore::metadata::Type::FLOAT_T;
	case duckdb_parquet::Type::INT64:
		return parcore::metadata::Type::INT64_T;
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

static uint8_t LogicalWidth(const duckdb_parquet::SchemaElement &element) {
	if (element.__isset.logicalType && element.logicalType.__isset.INTEGER) {
		return static_cast<uint8_t>(element.logicalType.INTEGER.bitWidth);
	}
	if (!element.__isset.converted_type) {
		return 0;
	}
	switch (element.converted_type) {
	case duckdb_parquet::ConvertedType::INT_8:
	case duckdb_parquet::ConvertedType::UINT_8:
		return 8;
	case duckdb_parquet::ConvertedType::INT_16:
	case duckdb_parquet::ConvertedType::UINT_16:
		return 16;
	case duckdb_parquet::ConvertedType::INT_32:
	case duckdb_parquet::ConvertedType::UINT_32:
		return 32;
	case duckdb_parquet::ConvertedType::INT_64:
	case duckdb_parquet::ConvertedType::UINT_64:
		return 64;
	default:
		return 0;
	}
}

struct LeafInfo {
	idx_t max_define;
	uint8_t logical_width;
};

static idx_t CollectLeaves(const vector<duckdb_parquet::SchemaElement> &schema, idx_t idx, idx_t parent_max_define,
                           vector<LeafInfo> &leaves) {
	if (idx >= schema.size()) {
		throw InvalidInputException("Malformed Parquet schema: child index %llu out of bounds", (unsigned long long)idx);
	}
	auto &element = schema[idx];
	auto max_define = parent_max_define;
	if (element.__isset.repetition_type && element.repetition_type != duckdb_parquet::FieldRepetitionType::REQUIRED) {
		max_define++;
	}

	idx = idx + 1;
	if (!element.__isset.num_children || element.num_children == 0) {
		leaves.push_back({max_define, LogicalWidth(element)});
		return idx;
	}
	for (int32_t i = 0; i < element.num_children; i++) {
		idx = CollectLeaves(schema, idx, max_define, leaves);
	}
	return idx;
}

parcore::metadata::Metadata BuildParcoreMetadata(ParquetReader &parquet_reader) {
	auto *file_meta = parquet_reader.GetFileMetadata();

	parcore::metadata::Metadata meta;

	// schema[0] is the root; its own repetition (if any) does not contribute definition levels.
	vector<LeafInfo> leaves;
	if (!file_meta->schema.empty()) {
		auto &root = file_meta->schema[0];
		for (idx_t idx = 1, child = 0; child < static_cast<idx_t>(root.num_children); child++) {
			idx = CollectLeaves(file_meta->schema, idx, 0, leaves);
		}
	}

	for (auto &col : parquet_reader.columns) {
		meta.column_names.push_back(col.name.GetIdentifierName());
	}

	for (auto &rg : file_meta->row_groups) {
		parcore::metadata::RowGroup parcore_rg;

		if (rg.columns.size() != leaves.size()) {
			throw InvalidInputException("Parquet row group has %llu column chunks but the schema has %llu leaf columns",
			                            (unsigned long long)rg.columns.size(), (unsigned long long)leaves.size());
		}

		for (idx_t col_idx = 0; col_idx < rg.columns.size(); col_idx++) {
			auto &cmd = rg.columns[col_idx].meta_data;

			parcore::metadata::ColumnChunk parcore_cc;
			parcore_cc.type = parquet_type_to_parcore(cmd.type);
			parcore_cc.num_values = static_cast<uint64_t>(cmd.num_values);
			parcore_cc.compression = parquet_codec_to_parcore(cmd.codec);
			parcore_cc.offset = static_cast<uint64_t>(cmd.__isset.dictionary_page_offset ? cmd.dictionary_page_offset
			                                                                             : cmd.data_page_offset);
			parcore_cc.total_compressed_size = static_cast<uint64_t>(cmd.total_compressed_size);
			// The max definition level covers the whole path, so a REQUIRED leaf below an OPTIONAL group has
			// definition levels and is not is_required.
			parcore_cc.is_required = leaves[col_idx].max_define == 0;
			parcore_cc.logical_width = leaves[col_idx].logical_width;

			parcore_rg.chunks.push_back(std::move(parcore_cc));
		}

		meta.groups.push_back(std::move(parcore_rg));
	}

	return meta;
}

bool HasOnlyDictionaryPages(const duckdb_parquet::ColumnMetaData &cmd) {
	using duckdb_parquet::Encoding;
	using duckdb_parquet::PageType;
	if (!cmd.__isset.dictionary_page_offset) {
		return false;
	}
	auto is_dictionary = [](Encoding::type encoding) {
		return encoding == Encoding::PLAIN_DICTIONARY || encoding == Encoding::RLE_DICTIONARY;
	};
	if (cmd.__isset.encoding_stats) {
		for (const auto &stats : cmd.encoding_stats) {
			bool const data_page = stats.page_type == PageType::DATA_PAGE || stats.page_type == PageType::DATA_PAGE_V2;
			if (data_page && stats.count > 0 && !is_dictionary(stats.encoding)) {
				return false;
			}
		}
		return true;
	}
	for (auto encoding : cmd.encodings) {
		// RLE and BIT_PACKED encode the levels
		if (!is_dictionary(encoding) && encoding != Encoding::RLE && encoding != Encoding::BIT_PACKED) {
			return false;
		}
	}
	return true;
}

} // namespace duckdb
