#include "oasis_scan.hpp"

#include "duckdb/common/exception.hpp"
#include "duckdb/common/multi_file/multi_file_options.hpp"
#include "oasis/oasis_context.hpp"
#include "parcore/configuration.hpp"
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

static void validate_int64_column(const OasisScanBindData &bind_data, size_t col_id) {
	if (col_id >= bind_data.metadata.groups[0].chunks.size()) {
		throw InternalException("Oasis hardware column index is out of range");
	}
	if (bind_data.metadata.groups[0].chunks[col_id].type != parcore::metadata::Type::INT64_T) {
		throw InvalidInputException("Oasis hardware filtering currently supports only INT64 columns");
	}
}

static void plan_output_columns(const TableFunctionInitInput &input, OasisScanGlobalState &gstate) {
	if (std::find(input.column_ids.begin(), input.column_ids.end(), COLUMN_IDENTIFIER_ROW_ID) !=
	    input.column_ids.end()) {
		throw InvalidInputException("Oasis hardware filtering does not support row ID projection");
	}

	vector<size_t> scan_columns(input.column_ids.begin(), input.column_ids.end());
	if (input.projection_ids.empty()) {
		gstate.output_column_ids = scan_columns;
	} else {
		for (const auto scan_index : input.projection_ids) {
			if (scan_index >= scan_columns.size()) {
				throw InternalException("Oasis projection index is out of range");
			}
			gstate.output_column_ids.push_back(scan_columns[scan_index]);
		}
	}
}

static vector<size_t> collect_filter_columns(const vector<OasisFilterLayer> &layers) {
	vector<size_t> columns;
	for (const auto &layer : layers) {
		for (const auto &predicate : layer) {
			if (std::find(columns.begin(), columns.end(), predicate.first) == columns.end()) {
				columns.push_back(predicate.first);
			}
		}
	}
	return columns;
}

static void plan_materialized_scan(const OasisScanBindData &bind_data, OasisScanGlobalState &gstate) {
	gstate.hardware_column_ids = gstate.output_column_ids;

	for (const auto filter_column : gstate.filter_column_ids) {
		if (std::find(gstate.hardware_column_ids.begin(), gstate.hardware_column_ids.end(), filter_column) ==
		    gstate.hardware_column_ids.end()) {
			gstate.hardware_column_ids.push_back(filter_column);
		}
	}

	if (gstate.hardware_column_ids.empty() ||
	    gstate.hardware_column_ids.size() > oasis::FilterConfig::MAX_STREAMS) {
		throw InvalidInputException(
		    "Oasis hardware filtering supports at most four unique projected and filter columns");
	}
	for (const auto col_id : gstate.hardware_column_ids) {
		validate_int64_column(bind_data, col_id);
	}
	for (const auto output_column : gstate.output_column_ids) {
		auto position =
		    std::find(gstate.hardware_column_ids.begin(), gstate.hardware_column_ids.end(), output_column);
		gstate.output_hardware_indices.push_back(position - gstate.hardware_column_ids.begin());
	}
}

static void plan_bitmask_scan(const OasisScanBindData &bind_data, OasisScanGlobalState &gstate) {
	if (gstate.filter_column_ids.empty()) {
		throw InternalException("Oasis bitmask mode requires at least one filter column");
	}
	if (gstate.filter_column_ids.size() > oasis::FilterConfig::MAX_STREAMS) {
		throw InvalidInputException("Oasis bitmask filtering supports at most four distinct filter columns");
	}
	if (gstate.output_column_ids.empty()) {
		throw InvalidInputException("Oasis bitmask mode requires at least one projected column");
	}
	for (const auto col_id : gstate.filter_column_ids) {
		validate_int64_column(bind_data, col_id);
	}
	for (const auto col_id : gstate.output_column_ids) {
		validate_int64_column(bind_data, col_id);
	}
	gstate.bitmask_mode = true;
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

	gstate->filter_layers = NormalizeOasisFilters(input, bind_data);
	gstate->filter_column_ids = collect_filter_columns(gstate->filter_layers);
	plan_output_columns(input, *gstate);
	const bool filter_enabled = !gstate->filter_layers.empty();
	gstate->pipeline_config = ctx.config<oasis::PipelineConfig>();
	gstate->filter_config = ctx.config<oasis::FilterConfig>();
	gstate->pipeline_config->set_filter_enabled(false);

	size_t decoder_count;
	if (filter_enabled && OASIS_FILTER_MODE == oasis::FilterMode::BITMASK) {
		plan_bitmask_scan(bind_data, *gstate);
		gstate->stream_ids = AssignOasisFilterStreams(gstate->filter_column_ids, gstate->filter_layers);
		decoder_count = oasis::FilterConfig::MAX_STREAMS;
	} else {
		plan_materialized_scan(bind_data, *gstate);
		gstate->stream_ids =
		    AssignOasisFilterStreams(gstate->hardware_column_ids, gstate->filter_layers);
		if (filter_enabled) {
			ConfigureOasisFilters(*gstate->filter_config, gstate->hardware_column_ids,
			                      gstate->stream_ids, gstate->filter_layers, OASIS_FILTER_MODE);
		}
		gstate->pipeline_config->set_filter_enabled(filter_enabled);
		decoder_count = gstate->hardware_column_ids.size();
	}

	for (size_t stream = 0; stream < decoder_count; stream++) {
		auto decoder = std::make_shared<parcore::ColumnChunkDecoder>(
		    ctx.cthread(), ctx.tlb_manager(), ctx.output_buffer_manager(),
		    column_chunk_config, page_config, stream);
		gstate->decoders.push_back(decoder);
		gstate->readers.push_back(std::make_unique<parcore::FileReader>(
		    decoder, ctx.memory_pool(), bind_data.metadata, gstate->file));
	}

	gstate->current_buffers.assign(
	    gstate->bitmask_mode ? gstate->output_column_ids.size() : gstate->hardware_column_ids.size(), {});

	return std::move(gstate);
}

unique_ptr<LocalTableFunctionState> OasisScanInitLocal(ExecutionContext &, TableFunctionInitInput &,
                                                       GlobalTableFunctionState *) {
	return make_uniq<OasisScanLocalState>();
}

static size_t buffer_bytes(const std::vector<std::shared_ptr<libstf::Buffer>> &buffers) {
	size_t total = 0;
	for (const auto &buffer : buffers) {
		total += buffer->size;
	}
	return total;
}

static uint8_t buffer_byte_at(const std::vector<std::shared_ptr<libstf::Buffer>> &buffers, size_t offset) {
	for (const auto &buffer : buffers) {
		if (offset < buffer->size) {
			return reinterpret_cast<const uint8_t *>(buffer->ptr)[offset];
		}
		offset -= buffer->size;
	}
	throw InternalException("Oasis bitmask offset is outside the returned FPGA buffers");
}

static int64_t buffer_int64_at(const std::vector<std::shared_ptr<libstf::Buffer>> &buffers, size_t index) {
	size_t byte_offset = index * sizeof(int64_t);
	for (const auto &buffer : buffers) {
		if (byte_offset < buffer->size) {
			if (byte_offset + sizeof(int64_t) > buffer->size) {
				throw InternalException("Oasis INT64 value crosses an FPGA output buffer boundary");
			}
			return reinterpret_cast<const int64_t *>(buffer->ptr)[byte_offset / sizeof(int64_t)];
		}
		byte_offset -= buffer->size;
	}
	throw InternalException("Oasis row offset is outside the returned FPGA buffers");
}

static void load_next_materialized_row_group(OasisScanGlobalState &gstate) {
	for (size_t i = 0; i < gstate.hardware_column_ids.size(); i++) {
		gstate.readers[gstate.stream_ids[i]]->enqueue_column_chunk(
		    gstate.next_group, gstate.hardware_column_ids[i]);
	}
	for (size_t i = 0; i < gstate.hardware_column_ids.size(); i++) {
		gstate.current_buffers[i] =
		    gstate.readers[gstate.stream_ids[i]]->next_column_chunk(); // blocks on FPGA
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

static void load_next_bitmask_row_group(OasisScanGlobalState &gstate) {
	gstate.pipeline_config->set_filter_enabled(false);
	ConfigureOasisFilters(*gstate.filter_config, gstate.filter_column_ids, gstate.stream_ids,
	                      gstate.filter_layers, oasis::FilterMode::BITMASK);
	gstate.pipeline_config->set_filter_enabled(true);

	for (size_t i = 0; i < gstate.filter_column_ids.size(); i++) {
		gstate.readers[gstate.stream_ids[i]]->enqueue_column_chunk(gstate.next_group,
		                                                          gstate.filter_column_ids[i]);
	}
	for (size_t i = 0; i < gstate.filter_column_ids.size(); i++) {
		auto mask = gstate.readers[gstate.stream_ids[i]]->next_column_chunk();
		if (i == 0) {
			gstate.bitmask_buffers = std::move(mask);
		}
	}

	gstate.pipeline_config->set_filter_enabled(false);
	for (size_t batch_start = 0; batch_start < gstate.output_column_ids.size();
	     batch_start += oasis::FilterConfig::MAX_STREAMS) {
		const auto batch_size =
		    std::min<size_t>(oasis::FilterConfig::MAX_STREAMS,
		                     gstate.output_column_ids.size() - batch_start);
		for (size_t stream = 0; stream < batch_size; stream++) {
			gstate.readers[stream]->enqueue_column_chunk(
			    gstate.next_group, gstate.output_column_ids[batch_start + stream]);
		}
		for (size_t stream = 0; stream < batch_size; stream++) {
			gstate.current_buffers[batch_start + stream] =
			    gstate.readers[stream]->next_column_chunk();
		}
	}

	gstate.bitmask_total_rows = buffer_bytes(gstate.current_buffers[0]) / sizeof(int64_t);
	for (const auto &buffers : gstate.current_buffers) {
		const auto output_bytes = buffer_bytes(buffers);
		if (output_bytes % sizeof(int64_t) != 0 ||
		    output_bytes / sizeof(int64_t) != gstate.bitmask_total_rows) {
			throw InternalException("Oasis bitmask projected columns are not row-aligned");
		}
	}
	if (buffer_bytes(gstate.bitmask_buffers) < (gstate.bitmask_total_rows + 7) / 8) {
		throw InternalException("Oasis hardware returned an incomplete selection bitmask");
	}

	gstate.bitmask_row_offset = 0;
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

static idx_t emit_bitmask_slice(OasisScanGlobalState &gstate, DataChunk &output) {
	vector<int64_t *> output_data;
	for (idx_t output_index = 0; output_index < output.ColumnCount(); output_index++) {
		auto &vector = output.data[output_index];
		vector.SetVectorType(VectorType::FLAT_VECTOR);
		output_data.push_back(FlatVector::GetData<int64_t>(vector));
	}

	idx_t emit = 0;
	while (gstate.bitmask_row_offset < gstate.bitmask_total_rows && emit < STANDARD_VECTOR_SIZE) {
		const auto row = gstate.bitmask_row_offset++;
		const auto mask_byte = buffer_byte_at(gstate.bitmask_buffers, row / 8);
		if ((mask_byte & (uint8_t {1} << (row % 8))) == 0) {
			continue;
		}

		for (idx_t output_index = 0; output_index < output.ColumnCount(); output_index++) {
			output_data[output_index][emit] =
			    buffer_int64_at(gstate.current_buffers[output_index], row);
		}
		emit++;
	}

	output.SetCardinality(emit);
	return emit;
}

void OasisScanFunction(ClientContext &, TableFunctionInput &data_p, DataChunk &output) {
	auto &gstate = data_p.global_state->Cast<OasisScanGlobalState>();

	if (gstate.bitmask_mode) {
		while (true) {
			if (gstate.bitmask_row_offset >= gstate.bitmask_total_rows) {
				if (gstate.next_group >= gstate.total_groups) {
					output.SetCardinality(0);
					return;
				}
				load_next_bitmask_row_group(gstate);
			}
			if (emit_bitmask_slice(gstate, output) > 0) {
				return;
			}
		}
	}

	while (gstate.current_buf_idx >= gstate.current_buffers[0].size()) {
		if (gstate.next_group >= gstate.total_groups) {
			output.SetCardinality(0);
			return;
		}
		load_next_materialized_row_group(gstate);
	}

	emit_output_slice(gstate, output);
}

} // namespace duckdb
