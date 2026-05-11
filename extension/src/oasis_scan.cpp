#include "oasis_scan.hpp"

#include "duckdb/common/exception.hpp"
#include "oasis/oasis_context.hpp"
#include "parcore/configuration.hpp"

namespace duckdb {

static LogicalType ParcoreTypeToLogical(parcore::metadata::Type type) {
	switch (type) {
	case parcore::metadata::Type::INT32_T:
		return LogicalType::INTEGER;
	case parcore::metadata::Type::INT64_T:
		return LogicalType::BIGINT;
	case parcore::metadata::Type::FLOAT_T:
		return LogicalType::FLOAT;
	case parcore::metadata::Type::DOUBLE_T:
		return LogicalType::DOUBLE;
	case parcore::metadata::Type::BYTE_T:
		return LogicalType::TINYINT;
	case parcore::metadata::Type::BYTE_ARRAY:
		return LogicalType::VARCHAR;
	default:
		throw InternalException("Unsupported ParCore type: %d", static_cast<int>(type));
	}
}

unique_ptr<FunctionData> OasisScanBind(ClientContext &context, TableFunctionBindInput &input,
                                       vector<LogicalType> &return_types, vector<string> &names) {
	auto parquet_file = StringValue::Get(input.inputs[0]);
	auto meta = parcore::metadata::from_file(parquet_file + ".meta");

	if (meta.groups.empty()) {
		throw InvalidInputException("Parquet metadata contains no row groups");
	}

	auto bind_data = make_uniq<OasisScanBindData>();

	for (size_t i = 0; i < meta.groups[0].chunks.size(); i++) {
		auto &chunk = meta.groups[0].chunks[i];
		names.push_back(meta.column_names[i]);
		return_types.push_back(ParcoreTypeToLogical(chunk.type));
		bind_data->parcore_types.push_back(chunk.type);
	}
	bind_data->metadata = meta;
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
	auto page_config = ctx.config<parcore::PageDecoderConfig>();

	gstate->decoder = std::make_shared<parcore::ColumnChunkDecoder>(
	    ctx.cthread(), ctx.tlb_manager(), ctx.output_buffer_manager(),
	    column_chunk_config, page_config, 0);

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
// then dequeue them in order (ParCore's output queue is FIFO) and slice each
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

	size_t const col0_file_idx = gstate.column_ids[0];
	size_t const total_elements =
	    gstate.current_buffers[0][gstate.current_buf_idx]->size /
	    libstf::size_of(parcore::metadata::to_libstf_type(bind.parcore_types[col0_file_idx]));
	size_t const remaining_elements = total_elements - gstate.current_buf_offset;
	size_t const emit = std::min<size_t>(remaining_elements, STANDARD_VECTOR_SIZE);
	for (size_t i = 0; i < gstate.column_ids.size(); i++) {
		const size_t kElemSize =
		    libstf::size_of(parcore::metadata::to_libstf_type(bind.parcore_types[gstate.column_ids[i]]));

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
