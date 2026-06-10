#include "oasis_scan.hpp"

#include "column_reader.hpp"
#include "duckdb/common/exception.hpp"
#include "duckdb/common/multi_file/multi_file_options.hpp"
#include "duckdb/logging/logger.hpp"
#include "oasis/oasis_context.hpp"
#include "oasis/operator.hpp"
#include "oasis/query_splinter.hpp"
#include "parcore/configuration.hpp"
#include "parquet_reader.hpp"
#include "parquet_types.h"
#include "rdma_file_system.hpp"
#include "reader/struct_column_reader.hpp"

// oasis_scan.hpp transitively pulls in Coyote, which includes <syslog.h>. That
// header defines LOG_INFO / LOG_DEBUG as numeric macros that collide with the
// duckdb::LogLevel enum values, turning e.g. `LogLevel::LOG_DEBUG` into
// `LogLevel::7`. #undef them so the LogLevel:: use sites below compile.
#undef LOG_INFO
#undef LOG_DEBUG

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
			parcore_cc.offset = static_cast<uint64_t>(cmd.__isset.dictionary_page_offset ? cmd.dictionary_page_offset
			                                                                             : cmd.data_page_offset);
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

static oasis::OasisContext &GetOasisContext(ClientContext &context) {
	return ObjectCache::GetObjectCache(context).GetOrCreate<OasisContextCacheEntry>("oasis_context", *context.db)->ctx();
}

// Applies the oasis_scheduler_num_streams / oasis_scheduler_queue_depth SET parameters to the live
// scheduler. A value of 0 (the default) leaves the corresponding knob at its current value, so the
// hardware defaults chosen at context init stay in effect until the user overrides them.
static void ApplySchedulerSettings(ClientContext &context, oasis::Scheduler &scheduler) {
	Value value;
	if (context.TryGetCurrentSetting("oasis_scheduler_num_streams", value) && !value.IsNull()) {
		auto streams = value.GetValue<uint64_t>();
		if (streams > 0) {
			scheduler.set_active_streams(static_cast<libstf::stream_t>(streams));
		}
	}
	if (context.TryGetCurrentSetting("oasis_scheduler_queue_depth", value) && !value.IsNull()) {
		auto depth = value.GetValue<uint64_t>();
		if (depth > 0) {
			scheduler.set_pipeline_depth(static_cast<size_t>(depth));
		}
	}
}

unique_ptr<GlobalTableFunctionState> OasisScanInitGlobal(ClientContext &context, TableFunctionInitInput &input) {
	auto &bind_data = input.bind_data->Cast<OasisScanBindData>();
	auto &ctx = GetOasisContext(context);
	auto gstate = make_uniq<OasisScanGlobalState>();

	ApplySchedulerSettings(context, ctx.scheduler());

	gstate->ctx = &ctx;
	gstate->filename = bind_data.filename;
	gstate->total_groups = bind_data.metadata.groups.size();

	for (auto col_id : input.column_ids) {
		if (col_id == COLUMN_IDENTIFIER_EMPTY) {
			gstate->emit_cardinality_only = true;
			continue;
		}
		auto t = bind_data.metadata.groups[0].chunks[col_id].type;
		gstate->column_ids.push_back(col_id);
		if (parcore::metadata::is_libstf_type(t)) {
			// Hardware path: Fixed-width type the ParCore decoder handles.
			gstate->is_cpu_column.push_back(false);
			gstate->elem_sizes.push_back(libstf::size_of(parcore::metadata::to_libstf_type(t)));
		} else {
			// CPU path: Variable-length type (BYTE_ARRAY/string) decoded by DuckDB's ColumnReader.
			gstate->is_cpu_column.push_back(true);
			gstate->elem_sizes.push_back(0);
			gstate->has_cpu_columns = true;
		}
	}

	return std::move(gstate);
}

unique_ptr<LocalTableFunctionState> OasisScanInitLocal(ExecutionContext &context, TableFunctionInitInput &input,
                                                       GlobalTableFunctionState *global_state_p) {
	auto &gstate = global_state_p->Cast<OasisScanGlobalState>();
	auto lstate = make_uniq<OasisScanLocalState>();

	// Each worker owns its own file handle: DuckDB FileHandles are not safe to share across threads,
	// and the local source path reads from it on this worker thread.
	auto &fs = FileSystem::GetFileSystem(context.client);
	lstate->file_handle = fs.OpenFile(gstate.filename, FileOpenFlags::FILE_FLAGS_READ);

	if (gstate.has_cpu_columns) {
		ParquetOptions parquet_opts(context.client);
		lstate->parquet_reader = make_uniq<ParquetReader>(context.client, OpenFileInfo {gstate.filename}, parquet_opts);
		lstate->scan_state = make_uniq<ParquetReaderScanState>();

		vector<idx_t> groups_to_read;
		groups_to_read.reserve(gstate.total_groups);
		for (idx_t g = 0; g < gstate.total_groups; g++) {
			groups_to_read.push_back(g);
		}
		lstate->parquet_reader->InitializeScan(context.client, *lstate->scan_state, std::move(groups_to_read));
		lstate->root_reader = std::move(lstate->scan_state->root_reader);
	}

	return std::move(lstate);
}

// Builds the source operator for one column chunk. The transport (remote RDMA vs. local host DMA) is
// chosen once, here, and hidden behind the SourceOperator interface; the scheduler never sees it.
static std::unique_ptr<oasis::SourceOperator> MakeSource(oasis::OasisContext &ctx, OasisScanLocalState &lstate,
                                                         const parcore::metadata::ColumnChunk &cc) {
	if (auto *rdma = dynamic_cast<RDMAFileHandle *>(lstate.file_handle.get())) {
		return std::make_unique<oasis::RDMASourceOperator>(rdma->remote_offset + cc.offset, cc.total_compressed_size);
	}

	// Host-copy path: read the compressed bytes into a libstf buffer on this worker thread. The
	// LocalSourceOperator owns the buffer and DMAs it into the stream when the splinter runs.
	void *ptr;
	auto status = ctx.memory_pool()->allocate(cc.total_compressed_size, &ptr);
	if (!status.ok()) {
		throw IOException("Could not allocate input buffer: " + status.message());
	}
	auto buffer = libstf::make_buffer(ctx.memory_pool(), ptr, cc.total_compressed_size, cc.total_compressed_size);
	lstate.file_handle->Read(buffer->ptr, cc.total_compressed_size, cc.offset);
	return std::make_unique<oasis::LocalSourceOperator>(std::move(buffer));
}

// Submits one splinter per projected column of `group` to the shared scheduler and collects each
// column's single decoded buffer into lstate.current_buffers (in projection order). We assume the
// hardware emits exactly one output buffer per column chunk: OasisContextCacheEntry sizes the OBM's
// auto-enqueued buffers to hold a whole DuckDB column chunk, and we reject any chunk whose decoded
// size would overflow that buffer (which is what would otherwise force a multi-buffer split).
static void DecodeGroup(ClientContext &context, oasis::OasisContext &ctx, OasisScanGlobalState &gstate,
                        OasisScanLocalState &lstate, const OasisScanBindData &bind, size_t group) {
	const size_t buffer_capacity = ctx.output_buffer_manager()->buffer_capacity();

	// Submit one query splinter per hardware column. CPU columns are skipped here and decoded inline.
	std::vector<oasis::SplinterResultHandle> results;
	results.reserve(gstate.column_ids.size());
	for (size_t i = 0; i < gstate.column_ids.size(); i++) {
		if (gstate.is_cpu_column[i]) {
			results.emplace_back();
			continue;
		}

		const auto &cc = bind.metadata.groups[group].chunks[gstate.column_ids[i]];
		auto type = parcore::metadata::to_libstf_type(cc.type);

		// Enforce the one-buffer-per-chunk invariant: the decoded output must fit in a single OBM
		// buffer. num_values is the row count; elem_sizes[i] the decoded element width.
		const size_t decoded_size = cc.num_values * gstate.elem_sizes[i];
		if (decoded_size > buffer_capacity) {
			throw NotImplementedException(
			    "Column '%s' row group %llu decodes to %llu bytes, exceeding the %llu byte output "
			    "buffer capacity.",
			    bind.metadata.column_names[gstate.column_ids[i]].c_str(), (unsigned long long)group,
			    (unsigned long long)decoded_size, (unsigned long long)buffer_capacity);
		}

		oasis::QuerySplinter splinter;
		splinter.operators.push_back(MakeSource(ctx, lstate, cc));
		splinter.operators.push_back(
		    std::make_unique<oasis::DecodeColumnChunkOperator>(cc.compression, cc.num_values, type));
		splinter.operators.push_back(std::make_unique<oasis::HostBufferSinkOperator>());
		results.push_back(ctx.scheduler().submit(std::move(splinter)));
        DUCKDB_LOG_DEBUG(context, "Submitted query splinter for row group %llu, column %llu ('%s'): "
		                          "%llu values, %llu compressed bytes",
		                 (unsigned long long)group, (unsigned long long)gstate.column_ids[i],
		                 bind.metadata.column_names[gstate.column_ids[i]].c_str(),
		                 (unsigned long long)cc.num_values, (unsigned long long)cc.total_compressed_size);
	}

	// InitializeRead(...) does the page-header parsing / I/O positioning for the row group.
	if (gstate.has_cpu_columns) {
		lstate.root_reader->InitializeRead(group, lstate.parquet_reader->GetFileMetadata()->row_groups[group].columns,
		                                   *lstate.scan_state->thrift_file_proto);
	}

	// Collect each hardware column's one buffer in submit order (restores per-column order even 
    // though splinters may finish on different streams out of order). Each splinter must yield 
    // exactly one buffer and then close -- that is the invariant the size check above protects.
	lstate.current_buffers.assign(gstate.column_ids.size(), nullptr);
	for (size_t i = 0; i < results.size(); i++) {
		if (gstate.is_cpu_column[i]) {
			continue;
		}
		auto batch = results[i].get_next_batch();
		if (!batch) {
			throw InternalException("Column %llu produced no output for row group %llu", 
                                    (unsigned long long)i, (unsigned long long)group);
		}
		size_t const col_id = gstate.column_ids[i];
		DUCKDB_LOG_DEBUG(context, "Hardware decoder for row group %llu, column %llu ('%s') returned batch",
		                 (unsigned long long)group, (unsigned long long)col_id,
		                 bind.metadata.column_names[col_id].c_str());
		lstate.current_buffers[i] = std::move(*batch);
	}
}

// Claims the next non-empty row group off the shared atomic cursor, returning its index (or
// total_groups once all groups are consumed).
static size_t ClaimNextNonEmptyGroup(OasisScanGlobalState &gstate, const OasisScanBindData &bind) {
	while (true) {
		size_t group = gstate.next_group.fetch_add(1);
		if (group >= gstate.total_groups) {
			return gstate.total_groups;
		}
		// Every column chunk in a row group shares its row count; take it from the first chunk.
		if (bind.metadata.groups[group].chunks[0].num_values != 0) {
			return group;
		}
	}
}

// Loads the next row group's buffers into lstate.current_buffers, claiming groups off the shared
// cursor. Returns false once all groups are consumed. Each worker owns its group's buffers privately.
static bool LoadNextGroup(ClientContext &context, oasis::OasisContext &ctx, OasisScanGlobalState &gstate,
                          OasisScanLocalState &lstate, const OasisScanBindData &bind) {
	size_t group = ClaimNextNonEmptyGroup(gstate, bind);
	if (group >= gstate.total_groups) {
		return false;
	}
	DecodeGroup(context, ctx, gstate, lstate, bind, group);
	lstate.current_buf_offset = 0;
	lstate.current_group_num_rows = bind.metadata.groups[group].chunks[0].num_values;
	return true;
}

// Emits cardinality only, for queries that project no columns (COUNT(*), EXISTS, etc.). DuckDB
// derives the aggregate from the row counts we report, so there is nothing to decode: each worker
// claims row groups off the shared cursor and emits their row counts (from the Parquet metadata)
// in STANDARD_VECTOR_SIZE slices. The hardware is never touched.
static void EmitCardinalityOnly(OasisScanGlobalState &gstate, OasisScanLocalState &lstate,
                                const OasisScanBindData &bind, DataChunk &output) {
	// Claim the next group with rows off the shared cursor (ClaimNextNonEmptyGroup skips empty groups
	// for us) or signal EOF once the groups run out.
	if (lstate.empty_proj_remaining == 0) {
		size_t group = ClaimNextNonEmptyGroup(gstate, bind);
		if (group >= gstate.total_groups) {
			output.SetCardinality(0);
			return;
		}
		// Every column chunk in a row group shares its row count; take it from the first chunk.
		lstate.empty_proj_remaining = bind.metadata.groups[group].chunks[0].num_values;
	}

	size_t const emit = std::min<size_t>(lstate.empty_proj_remaining, STANDARD_VECTOR_SIZE);
	lstate.empty_proj_remaining -= emit;
	output.SetCardinality(emit);
}

// Zero-copy multi-column scan. Each worker atomically claims a row group (LoadNextGroup), decoding
// every projected column into exactly one buffer, then slices those buffers in lockstep into
// STANDARD_VECTOR_SIZE-sized vectors. The one-buffer-per-column-chunk model holds because the OBM
// buffers are sized to a whole DuckDB column chunk and DecodeGroup rejects any chunk that would
// overflow them. All columns of a row group share the same element count, so the slices stay aligned.
void OasisScanFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &gstate = data_p.global_state->Cast<OasisScanGlobalState>();
	auto &lstate = data_p.local_state->Cast<OasisScanLocalState>();
	auto &bind = data_p.bind_data->Cast<OasisScanBindData>();
	auto &ctx = *gstate.ctx;

	if (gstate.emit_cardinality_only) {
		EmitCardinalityOnly(gstate, lstate, bind, output);
		return;
	}

	// When the current group is fully emitted, decode/claim the next one.
	if (lstate.current_group_num_rows == 0) {
		if (!LoadNextGroup(context, ctx, gstate, lstate, bind)) {
			output.SetCardinality(0);
			return;
		}
	}

	size_t const total_elements = lstate.current_group_num_rows;
	size_t const remaining_elements = total_elements - lstate.current_buf_offset;
	size_t const emit = std::min<size_t>(remaining_elements, STANDARD_VECTOR_SIZE);

	// Scratch define/repeat buffers shared by this worker's CPU column readers for this call.
	uint8_t *define_ptr = nullptr;
	uint8_t *repeat_ptr = nullptr;
	if (gstate.has_cpu_columns) {
		lstate.scan_state->define_buf.zero();
		lstate.scan_state->repeat_buf.zero();
		define_ptr = reinterpret_cast<uint8_t *>(lstate.scan_state->define_buf.ptr);
		repeat_ptr = reinterpret_cast<uint8_t *>(lstate.scan_state->repeat_buf.ptr);
	}

	for (size_t i = 0; i < gstate.column_ids.size(); i++) {
		if (gstate.is_cpu_column[i]) {
			auto &vec = output.data[i];
			auto &child_reader = lstate.root_reader->Cast<StructColumnReader>().GetChildReader(gstate.column_ids[i]);
			auto rows_read = child_reader.Read(emit, define_ptr, repeat_ptr, vec);
			if (rows_read != emit) {
				throw InternalException(
				    "ParCore CPU column %llu read %llu values, expected %llu (HW/CPU cursor desync)",
				    (unsigned long long)i, (unsigned long long)rows_read, (unsigned long long)emit);
			}
			continue;
		}

		const size_t kElemSize = gstate.elem_sizes[i];

		auto &buf = lstate.current_buffers[i];
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
		//   - lstate.current_buffers holds the one buffer per column and keeps it
		//     alive across scan calls while we slice it into multiple
		//     STANDARD_VECTOR_SIZE emissions (auxiliary gets cleared on each
		//     output.Reset()).
		//   - vector auxiliary (set here) keeps it alive for any downstream
		//     consumer that holds onto the vector past our next scan call.
		auto &vec = output.data[i];
		vec.SetVectorType(VectorType::FLAT_VECTOR);
		FlatVector::SetData(vec, reinterpret_cast<data_ptr_t>(buf->ptr) + lstate.current_buf_offset * kElemSize);
		vec.SetAuxiliary(make_buffer<LibstfBufferVectorBuffer>(buf));
	}

	// Advance the cursor. If we have emitted this group's last elements, release the buffers so the
	// next scan call's `if` branch loads the next row group. Dropping our refs here lets each buffer
	// free as soon as downstream consumers are done with it.
	lstate.current_buf_offset += emit;
	if (lstate.current_buf_offset >= total_elements) {
		lstate.current_buffers.assign(gstate.column_ids.size(), nullptr);
		lstate.current_buf_offset = 0;
		lstate.current_group_num_rows = 0;
	}

	output.SetCardinality(emit);
}

// Advertises the zero-width COLUMN_IDENTIFIER_EMPTY virtual column. For queries that consume no
// column values (e.g., COUNT(*), EXISTS), DuckDB's optimizer projects this sentinel instead of 
// anchoring the scan on a real column (LogicalGet::GetAnyColumn).
virtual_column_map_t OasisScanGetVirtualColumns(ClientContext &, optional_ptr<FunctionData>) {
	virtual_column_map_t result;
	result.insert(make_pair(COLUMN_IDENTIFIER_EMPTY, TableColumn("", LogicalType::BOOLEAN)));
	return result;
}

} // namespace duckdb
