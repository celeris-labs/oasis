#include "oasis_scan.hpp"

#include "duckdb/common/exception.hpp"
#include "duckdb/common/multi_file/multi_file_options.hpp"
#include "oasis/oasis_context.hpp"
#include "parcore/configuration.hpp"
#include "parquet_reader.hpp"
#include "parquet_types.h"
#include "thrift_tools.hpp"

#include <numeric>

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

static parcore::metadata::Metadata build_parcore_metadata(ParquetReader &parquet_reader) {
	auto *file_meta = parquet_reader.GetFileMetadata();
	auto &file_handle = parquet_reader.GetHandle();

    // TODO: Remove the fetching of page meta data after adding a page header parser to the hardware
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

			// Walk page headers to collect individual pages
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
				auto add_data_page = [&](const auto &header) {
					const auto encoding = header.encoding;
					const bool hybrid = encoding == duckdb_parquet::Encoding::RLE_DICTIONARY ||
					                    encoding == duckdb_parquet::Encoding::PLAIN_DICTIONARY;
					parcore_page.encoding =
					    hybrid ? parcore::metadata::Encoding::HYBRID : parcore::metadata::Encoding::PLAIN;
					parcore_page.num_values = static_cast<uint64_t>(header.num_values);
					hybrid_num_values += hybrid ? parcore_page.num_values : 0;
					parcore_cc.data.push_back(parcore_page);
				};

				if (page_hdr.type == duckdb_parquet::PageType::DICTIONARY_PAGE) {
					parcore_page.encoding = parcore::metadata::Encoding::PLAIN;
					parcore_page.num_values =
					    static_cast<uint64_t>(page_hdr.dictionary_page_header.num_values);
					parcore_cc.dictionary = parcore_page;
				} else if (page_hdr.type == duckdb_parquet::PageType::DATA_PAGE) {
					add_data_page(page_hdr.data_page_header);
				} else if (page_hdr.type == duckdb_parquet::PageType::DATA_PAGE_V2) {
					add_data_page(page_hdr.data_page_header_v2);
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

unique_ptr<FunctionData> OasisScanBind(ClientContext &context, TableFunctionBindInput &input,
                                       vector<LogicalType> &return_types, vector<string> &names) {
	auto parquet_file = StringValue::Get(input.inputs[0]);

	ParquetOptions parquet_opts(context);
	ParquetReader parquet_reader(context, OpenFileInfo {parquet_file}, parquet_opts);

	auto bind_data = make_uniq<OasisScanBindData>();

	for (auto &col : parquet_reader.columns) {
		names.push_back(col.name);
		return_types.push_back(col.type);
	}

	bind_data->metadata = build_parcore_metadata(parquet_reader);
	if (bind_data->metadata.groups.empty()) {
		throw InvalidInputException("Parquet file contains no row groups");
	}
	bind_data->filename = parquet_file;

	return std::move(bind_data);
}

static void plan_hardware_columns(const TableFunctionInitInput &input, const OasisScanBindData &bind_data,
                                  const vector<OasisFilterLayer> &layers, OasisScanGlobalState &gstate) {
	if (std::find(input.column_ids.begin(), input.column_ids.end(), COLUMN_IDENTIFIER_ROW_ID) !=
	    input.column_ids.end()) {
		throw InvalidInputException("Oasis hardware filtering does not support row ID projection");
	}

	gstate.hardware_column_ids.assign(input.column_ids.begin(), input.column_ids.end());
	const auto scan_column_count = gstate.hardware_column_ids.size();
	if (input.projection_ids.empty()) {
		gstate.output_hardware_indices.resize(scan_column_count);
		std::iota(gstate.output_hardware_indices.begin(), gstate.output_hardware_indices.end(), 0);
	} else {
		gstate.output_hardware_indices = input.projection_ids;
	}
	for (const auto scan_index : gstate.output_hardware_indices) {
		if (scan_index >= scan_column_count) {
			throw InternalException("Oasis projection index is out of range");
		}
	}

	for (const auto &layer : layers) {
		for (const auto &predicate : layer) {
			if (std::find(gstate.hardware_column_ids.begin(), gstate.hardware_column_ids.end(),
			              predicate.first) == gstate.hardware_column_ids.end()) {
				gstate.hardware_column_ids.push_back(predicate.first);
			}
		}
	}

	if (gstate.hardware_column_ids.empty() ||
	    gstate.hardware_column_ids.size() > oasis::FilterConfig::MAX_STREAMS) {
		throw InvalidInputException(
		    "Oasis hardware filtering supports at most four unique projected and filter columns");
	}
	for (const auto col_id : gstate.hardware_column_ids) {
		if (col_id >= bind_data.metadata.groups[0].chunks.size()) {
			throw InternalException("Oasis hardware column index is out of range");
		}
		if (bind_data.metadata.groups[0].chunks[col_id].type != parcore::metadata::Type::INT64_T) {
			throw InvalidInputException("Oasis hardware filtering currently supports only INT64 columns");
		}
	}
}

unique_ptr<GlobalTableFunctionState> OasisScanInitGlobal(ClientContext &context, TableFunctionInitInput &input) {
	auto &bind_data = input.bind_data->Cast<OasisScanBindData>();

	ObjectCache::GetObjectCache(context).GetOrCreate<OasisContextCacheEntry>("oasis_context");
	auto &ctx = oasis::OasisContext::ctx();

	auto gstate = make_uniq<OasisScanGlobalState>();

	auto column_chunk_config = ctx.config<parcore::ColumnChunkDecoderConfig>();
	auto page_config = ctx.config<parcore::PageDecoderConfig>();

	auto maybe_file = arrow::io::ReadableFile::Open(bind_data.filename);
	if (!maybe_file.ok()) {
		throw IOException(maybe_file.status().ToString());
	}
	gstate->file = *maybe_file;

	gstate->total_groups = bind_data.metadata.groups.size();

	auto layers = NormalizeOasisFilters(input, bind_data);
	plan_hardware_columns(input, bind_data, layers, *gstate);
	const bool filter_enabled = !layers.empty();
	ctx.config<oasis::PipelineConfig>()->set_filter_enabled(filter_enabled);

	gstate->stream_ids = AssignOasisFilterStreams(gstate->hardware_column_ids, layers);

	if (filter_enabled) {
		auto filter_config = ctx.config<oasis::FilterConfig>();
		ConfigureOasisFilters(*filter_config, gstate->hardware_column_ids, gstate->stream_ids, layers);
	}

	for (size_t column_index = 0; column_index < gstate->hardware_column_ids.size(); column_index++) {
		auto decoder = std::make_shared<parcore::ColumnChunkDecoder>(
		    ctx.cthread(), ctx.tlb_manager(), ctx.output_buffer_manager(),
		    column_chunk_config, page_config, gstate->stream_ids[column_index]);
		gstate->decoders.push_back(decoder);
		gstate->readers.push_back(std::make_unique<parcore::FileReader>(
		    decoder, ctx.memory_pool(), bind_data.metadata, gstate->file));
	}

	gstate->current_buffers.assign(gstate->hardware_column_ids.size(), {});

	return std::move(gstate);
}

unique_ptr<LocalTableFunctionState> OasisScanInitLocal(ExecutionContext &, TableFunctionInitInput &,
                                                       GlobalTableFunctionState *) {
	return make_uniq<OasisScanLocalState>();
}

static void load_next_row_group(OasisScanGlobalState &gstate) {
	for (size_t i = 0; i < gstate.hardware_column_ids.size(); i++) {
		gstate.readers[i]->enqueue_column_chunk(gstate.next_group, gstate.hardware_column_ids[i]);
	}
	for (size_t i = 0; i < gstate.hardware_column_ids.size(); i++) {
		gstate.current_buffers[i] = gstate.readers[i]->next_column_chunk(); // blocks on FPGA
	}

	const auto expected_buffer_count = gstate.current_buffers[0].size();
	for (size_t i = 1; i < gstate.current_buffers.size(); i++) {
		if (gstate.current_buffers[i].size() != expected_buffer_count) {
			throw InternalException(
			    "ParCore buffer count mismatch across columns: hardware column %llu has %llu buffers, expected %llu",
			    (unsigned long long)i,
			    (unsigned long long)gstate.current_buffers[i].size(),
			    (unsigned long long)expected_buffer_count);
		}
	}

	gstate.current_buf_idx = 0;
	gstate.current_buf_offset = 0;
	gstate.next_group++;
}

static void emit_output_slice(OasisScanGlobalState &gstate, DataChunk &output) {
	constexpr size_t ELEM_SIZE = sizeof(int64_t);
	size_t const total_elements = gstate.current_buffers[0][gstate.current_buf_idx]->size / ELEM_SIZE;
	size_t const remaining_elements = total_elements - gstate.current_buf_offset;
	size_t const emit = std::min<size_t>(remaining_elements, STANDARD_VECTOR_SIZE);

	for (size_t hardware_index = 0; hardware_index < gstate.hardware_column_ids.size(); hardware_index++) {
		auto &buf = gstate.current_buffers[hardware_index][gstate.current_buf_idx];
		if (buf->size / ELEM_SIZE != total_elements) {
			throw InternalException(
			    "ParCore buffer layout mismatch across columns: hardware column %llu has %llu elements, expected %llu",
			    (unsigned long long)hardware_index, (unsigned long long)(buf->size / ELEM_SIZE),
			    (unsigned long long)total_elements);
		}
	}

	for (size_t output_index = 0; output_index < gstate.output_hardware_indices.size(); output_index++) {
		const auto hardware_index = gstate.output_hardware_indices[output_index];
		auto &buf = gstate.current_buffers[hardware_index][gstate.current_buf_idx];

		auto &vec = output.data[output_index];
		vec.SetVectorType(VectorType::FLAT_VECTOR);
		FlatVector::SetData(vec, reinterpret_cast<data_ptr_t>(buf->ptr) + gstate.current_buf_offset * ELEM_SIZE);
		// Keep the FPGA-written buffer alive while DuckDB references its data.
		vec.SetAuxiliary(make_buffer<LibstfBufferVectorBuffer>(buf));
	}

	gstate.current_buf_offset += emit;
	if (gstate.current_buf_offset >= total_elements) {
		gstate.current_buf_idx++;
		gstate.current_buf_offset = 0;
	}

	output.SetCardinality(emit);
}

void OasisScanFunction(ClientContext &, TableFunctionInput &data_p, DataChunk &output) {
	auto &gstate = data_p.global_state->Cast<OasisScanGlobalState>();

	while (gstate.current_buf_idx >= gstate.current_buffers[0].size()) {
		if (gstate.next_group >= gstate.total_groups) {
			output.SetCardinality(0);
			return;
		}
		load_next_row_group(gstate);
	}

	emit_output_slice(gstate, output);
}

} // namespace duckdb
