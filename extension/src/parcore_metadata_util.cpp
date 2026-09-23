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

// Records, per leaf column, whether its data pages carry a definition-level section and/or a
// repetition-level section. The two are independent: max_define == 0 means no definition-level
// section, max_repeat == 0 means no repetition-level section, and a REQUIRED, non-repeated column
// (both zero) has neither -- its page bodies hold values only and the hardware must not strip a
// length prefix for either. `column_index` is the leaf's position in the file, which is also its
// index into RowGroup::columns. Both vectors are pre-sized to the leaf count and pre-filled with
// true, so leaves the walk does not reach keep the safe default.
static void CollectLevelFlags(const ParquetColumnSchema &schema, vector<bool> &has_def_levels,
                              vector<bool> &has_rep_levels) {
	if (schema.children.empty()) {
		if (schema.schema_type != ParquetColumnSchemaType::COLUMN) {
			return; // Synthetic column (file_row_number and friends); no column chunk backs it.
		}
		if (schema.column_index < has_def_levels.size()) {
			has_def_levels[schema.column_index] = schema.max_define > 0;
			has_rep_levels[schema.column_index] = schema.max_repeat > 0;
		}
		return;
	}
	for (auto &child : schema.children) {
		CollectLevelFlags(child, has_def_levels, has_rep_levels);
	}
}

parcore::metadata::Metadata BuildParcoreMetadata(ParquetReader &parquet_reader) {
	auto *file_meta = parquet_reader.GetFileMetadata();

	parcore::metadata::Metadata meta;

	for (auto &col : parquet_reader.columns) {
		meta.column_names.push_back(col.name.GetIdentifierName());
	}

	// Level presence is schema information, not page information: DataPageHeaderV1 always populates
	// definition_level_encoding/repetition_level_encoding regardless of whether any levels were
	// written, so the decoder cannot infer this from the page headers and has to be told. Every row
	// group has the same columns, so the first one gives the leaf count.
	idx_t const num_leaf_columns = file_meta->row_groups.empty() ? 0 : file_meta->row_groups[0].columns.size();
	vector<bool> has_def_levels(num_leaf_columns, true);
	vector<bool> has_rep_levels(num_leaf_columns, true);
	if (parquet_reader.root_schema) {
		CollectLevelFlags(*parquet_reader.root_schema, has_def_levels, has_rep_levels);
	}

	for (auto &rg : file_meta->row_groups) {
		parcore::metadata::RowGroup parcore_rg;

		for (idx_t col_idx = 0; col_idx < rg.columns.size(); col_idx++) {
			auto &cmd = rg.columns[col_idx].meta_data;

			parcore::metadata::ColumnChunk parcore_cc;
			parcore_cc.type = parquet_type_to_parcore(cmd.type);
			parcore_cc.num_values = static_cast<uint64_t>(cmd.num_values);
			parcore_cc.compression = parquet_codec_to_parcore(cmd.codec);
			parcore_cc.offset = static_cast<uint64_t>(cmd.__isset.dictionary_page_offset ? cmd.dictionary_page_offset
			                                                                             : cmd.data_page_offset);
			parcore_cc.total_compressed_size = static_cast<uint64_t>(cmd.total_compressed_size);
			// Conservatively assume a section is present if the schema walk did not cover this leaf:
			// stripping a prefix that is there is correct, inventing one is not.
			parcore_cc.has_def_levels = col_idx < has_def_levels.size() ? has_def_levels[col_idx] : true;
			parcore_cc.has_rep_levels = col_idx < has_rep_levels.size() ? has_rep_levels[col_idx] : true;

			parcore_rg.chunks.push_back(std::move(parcore_cc));
		}

		meta.groups.push_back(std::move(parcore_rg));
	}

	return meta;
}

} // namespace duckdb
