#include "oasis_scan.hpp"

#include "duckdb/common/exception.hpp"
#include "duckdb/common/multi_file/multi_file_options.hpp"
#include "oasis/oasis_context.hpp"
#include "parcore/configuration.hpp"
#include "parquet_reader.hpp"
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

static parcore::metadata::Metadata build_parcore_metadata(ClientContext &context, ParquetReader &parquet_reader) {
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

	auto meta = build_parcore_metadata(context, parquet_reader);
	if (meta.groups.empty()) {
		throw InvalidInputException("Parquet file contains no row groups");
	}
	bind_data->metadata = std::move(meta);
	bind_data->filename = parquet_file;

	return std::move(bind_data);
}

unique_ptr<GlobalTableFunctionState> OasisScanInitGlobal(ClientContext &context, TableFunctionInitInput &input) {
	auto &bind_data = input.bind_data->Cast<OasisScanBindData>();

	// Ensure OasisContext is initialized for this database instance.
	ObjectCache::GetObjectCache(context).GetOrCreate<OasisContextCacheEntry>("oasis_context");
	auto &ctx = oasis::OasisContext::ctx();

	auto gstate = make_uniq<OasisScanGlobalState>();

	auto column_chunk_config = ctx.config<parcore::ColumnChunkDecoderConfig>();

	gstate->decoder = std::make_shared<parcore::ColumnChunkDecoder>(
	    ctx.cthread(), ctx.tlb_manager(), ctx.output_buffer_manager(),
	    column_chunk_config, 0);

	auto maybe_file = arrow::io::ReadableFile::Open(bind_data.filename);
	if (!maybe_file.ok()) {
		throw IOException(maybe_file.status().ToString());
	}
	gstate->file = *maybe_file;

	gstate->reader =
	    std::make_unique<parcore::FileReader>(gstate->decoder, ctx.memory_pool(), bind_data.metadata, gstate->file);

	gstate->total_groups = bind_data.metadata.groups.size();

	for (auto col_id : input.column_ids) {
		if (col_id == COLUMN_IDENTIFIER_ROW_ID) {
			continue;
		}
		auto t = bind_data.metadata.groups[0].chunks[col_id].type;
		if (!parcore::metadata::is_libstf_type(t)) {
			throw InvalidInputException("Column '%s' has type BYTE_ARRAY which is not supported by ParCore",
			                            bind_data.metadata.column_names[col_id].c_str());
		}
		gstate->column_ids.push_back(col_id);
	}

	gstate->current_buffers.assign(gstate->column_ids.size(), {});
	gstate->current_buf_idx = 0;
	gstate->current_buf_offset = 0;

	return std::move(gstate);
}

unique_ptr<LocalTableFunctionState> OasisScanInitLocal(ExecutionContext &context, TableFunctionInitInput &input,
                                                       GlobalTableFunctionState *global_state_p) {
	return make_uniq<OasisScanLocalState>();
}

// Zero-copy multi-column scan. For each row group we enqueue every column,
// then dequeue them in order (ParCore's output queue is a FIFO) and slice each
// column's buffers in lockstep into STANDARD_VECTOR_SIZE-sized vectors. This
// assumes ParCore returns the same buffer layout (same buffer count, same
// elements per buffer at each index) across all columns of a row group; we
// assert this below.
void OasisScanFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &gstate = data_p.global_state->Cast<OasisScanGlobalState>();
	auto &bind = data_p.bind_data->Cast<OasisScanBindData>();

	// Pull in next row group cursor reached end, needs to be synchronised across columns
	// assuming row groups have same element count across columns
	if (gstate.current_buf_idx >= gstate.current_buffers[0].size()) {
		if (gstate.next_group >= gstate.total_groups) {
			output.SetCardinality(0);
			return;
		}

		for (size_t col_id : gstate.column_ids) {
			gstate.reader->enqueue_column_chunk(gstate.next_group, col_id);
		}
		for (size_t i = 0; i < gstate.column_ids.size(); i++) {
			gstate.current_buffers[i] = gstate.reader->next_column_chunk(); // blocks on FPGA
		}

		gstate.current_buf_idx = 0;
		gstate.current_buf_offset = 0;
		gstate.next_group++;
	}

	auto elem_size = [&](size_t col_file_idx) -> size_t {
		// next_group has already been incremented, so the in-flight group is next_group - 1.
		auto t = bind.metadata.groups[gstate.next_group - 1].chunks[col_file_idx].type;
		if (!parcore::metadata::is_libstf_type(t)) {
			throw InternalException("Unsupported ParCore type %d in elem_size", (int)t);
		}
		return libstf::size_of(parcore::metadata::to_libstf_type(t));
	};

	size_t const col0_file_idx = gstate.column_ids[0];
	size_t const total_elements =
	    gstate.current_buffers[0][gstate.current_buf_idx]->size / elem_size(col0_file_idx);
	size_t const remaining_elements = total_elements - gstate.current_buf_offset;
	size_t const emit = std::min<size_t>(remaining_elements, STANDARD_VECTOR_SIZE);
	for (size_t i = 0; i < gstate.column_ids.size(); i++) {
		const size_t kElemSize = elem_size(gstate.column_ids[i]);

		auto &buf = gstate.current_buffers[i][gstate.current_buf_idx];
		if (buf->size / kElemSize != total_elements) {
			throw InternalException(
			    "ParCore buffer layout mismatch across columns: column %llu has %llu elements, expected %llu",
			    (unsigned long long)i, (unsigned long long)(buf->size / kElemSize), (unsigned long long)total_elements);
		}

		// The actual zero-copy handoff. Two things happen here:
		//
		//  1. FlatVector::SetData points the vector's raw data pointer directly
		//     into the FPGA-written libstf buffer (+ byte offset for the
		//     STANDARD_VECTOR_SIZE slice we're emitting this call). No memcpy,
		//     no arrow intermediary.
		//
		//  2. SetAuxiliary hands the buffer's shared_ptr to DuckDB's Vector
		//     lifetime slot (wrapped in LibstfBufferVectorBuffer, because
		//     DuckDB's slot is typed to shared_ptr<VectorBuffer>, not our
		//     shared_ptr<libstf::Buffer>). DuckDB copies this shared_ptr whenever
		//     it copies the vector, so the underlying memory stays alive as long
		//     as any downstream consumer references it.
		//
		// Two refcount holders protect the memory while it's in flight:
		//   - gstate.current_buffers keeps it alive across scan calls while we
		//     slice one FPGA chunk into multiple STANDARD_VECTOR_SIZE emissions
		//     (auxiliary gets cleared on each output.Reset()).
		//   - vector auxiliary (set here) keeps it alive for any downstream
		//     consumer that holds onto the vector past our next scan call.
		auto &vec = output.data[i];
		vec.SetVectorType(VectorType::FLAT_VECTOR);
		FlatVector::SetData(vec, reinterpret_cast<data_ptr_t>(buf->ptr) + gstate.current_buf_offset * kElemSize);
		vec.SetAuxiliary(make_buffer<LibstfBufferVectorBuffer>(buf));
	}

	// Advance the cursor. If we hit the end of this buffer, step to the next
	// one so the next scan call's `if` branch either keeps emitting or pulls
	// a fresh chunk.
	gstate.current_buf_offset += emit;
	if (gstate.current_buf_offset >= total_elements) {
		gstate.current_buf_idx++;
		gstate.current_buf_offset = 0;
	}

	output.SetCardinality(emit);
}

} // namespace duckdb
