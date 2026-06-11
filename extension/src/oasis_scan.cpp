#include "oasis_scan.hpp"

#include "column_reader.hpp"
#include "duckdb/common/exception.hpp"
#include "duckdb/common/multi_file/multi_file_options.hpp"
#include "duckdb/logging/logger.hpp"
#include "duckdb/main/extension/extension_loader.hpp"
#include "oasis/oasis_context.hpp"
#include "oasis/operator.hpp"
#include "oasis/query_splinter.hpp"
#include "parcore/configuration.hpp"
#include "parcore_metadata_util.hpp"
#include "parquet_reader.hpp"
#include "rdma_file_system.hpp"
#include "reader/struct_column_reader.hpp"
#include "filter_pushdown.hpp"

#include <algorithm>
#include <vector>

// oasis_scan.hpp transitively pulls in Coyote, which includes <syslog.h>. That
// header defines LOG_INFO / LOG_DEBUG as numeric macros that collide with the
// duckdb::LogLevel enum values, turning e.g. `LogLevel::LOG_DEBUG` into
// `LogLevel::7`. #undef them so the LogLevel:: use sites below compile.
#undef LOG_INFO
#undef LOG_DEBUG

namespace duckdb {

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

	auto meta = BuildParcoreMetadata(parquet_reader);
	if (meta.groups.empty()) {
		throw InvalidInputException("Parquet file contains no row groups");
	}
	bind_data->metadata = std::move(meta);
	bind_data->filename = parquet_file;

	return std::move(bind_data);
}

unique_ptr<GlobalTableFunctionState> OasisScanInitGlobal(ClientContext &context, TableFunctionInitInput &input) {
	auto &bind_data = input.bind_data->Cast<OasisScanBindData>();
	auto &ctx = GetOrCreateOasisContext(context);
	auto gstate = make_uniq<OasisScanGlobalState>();

	// Scheduler knobs (oasis_scheduler_num_streams / oasis_scheduler_queue_depth) are applied to the
	// live scheduler by their SET callbacks in oasis_settings.cpp, so there is nothing to do here.
	gstate->ctx = &ctx;
	gstate->filename = bind_data.filename;
	gstate->total_groups = bind_data.metadata.groups.size();
	gstate->filters = input.filters;

	for (auto col_id : input.column_ids) {
		if (col_id == COLUMN_IDENTIFIER_EMPTY) {
			gstate->emit_cardinality_only = true;
			continue;
		}
		auto t = bind_data.metadata.groups[0].chunks[col_id].type;
		if (parcore::metadata::is_libstf_type(t)) {
			// Hardware path: Fixed-width type the ParCore decoder handles.
			gstate->projected_columns.push_back({col_id, libstf::size_of(parcore::metadata::to_libstf_type(t)), false});
		} else {
			// CPU path: Variable-length type (BYTE_ARRAY/string) decoded by DuckDB's ColumnReader.
			gstate->projected_columns.push_back({col_id, 0, true});
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

	// Build a per-worker ParquetReader: The root_reader supplies the per-column-chunk statistics 
    // used for row-group skipping (RowGroupMatchesFilters). The CPU decode path additionally drives 
    // this reader's child readers in OasisScanFunction.
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

	// Prepare the pushed-down filters for row-level filtering (one TableFilterState per filter,
	// owned by this worker).
	if (gstate.filters) {
		for (auto &filter_entry : gstate.filters->filters) {
			lstate->scan_filters.emplace_back(context.client, filter_entry.first, *filter_entry.second);
		}
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

// Every column chunk in a row group shares its row count. Take it from the first chunk.
static uint64_t RowGroupNumRows(const OasisScanBindData &bind, size_t group) {
	const auto &chunks = bind.metadata.groups[group].chunks;
	return chunks.empty() ? 0 : chunks[0].num_values;
}

// Submits one query splinter per projected hardware column of `group` to the shared scheduler,
// returning the result handles in projection order (CPU columns get an empty placeholder handle so
// the index stays aligned with projected_columns). We assume the hardware emits exactly one output
// buffer per column chunk: OasisContextCacheEntry sizes the OBM's auto-enqueued buffers to hold a
// whole DuckDB column chunk, and we reject any chunk whose decoded size would overflow that buffer.
static std::vector<oasis::SplinterResultHandle>
SubmitColumnSplinters(ClientContext &context, oasis::OasisContext &ctx, OasisScanGlobalState &gstate,
                      OasisScanLocalState &lstate, const OasisScanBindData &bind, size_t group) {
	const size_t buffer_capacity = ctx.output_buffer_manager()->buffer_capacity();

	// Phase 1: Build every hardware column's splinter.
	std::vector<oasis::QuerySplinter> splinters;
	std::vector<size_t> splinter_slot;
	splinters.reserve(gstate.projected_columns.size());
	splinter_slot.reserve(gstate.projected_columns.size());
	for (size_t i = 0; i < gstate.projected_columns.size(); i++) {
		const auto &col = gstate.projected_columns[i];
		if (col.is_cpu) {
			continue;
		}

		const auto &cc = bind.metadata.groups[group].chunks[col.column_id];
		auto type = parcore::metadata::to_libstf_type(cc.type);

		// Enforce the one-buffer-per-chunk invariant: the decoded output must fit in a single OBM
		// buffer. num_values is the row count, col.elem_size the decoded element width.
		const size_t decoded_size = cc.num_values * col.elem_size;
		if (decoded_size > buffer_capacity) {
			throw NotImplementedException(
			    "Column '%s' row group %llu decodes to %llu bytes, exceeding the %llu byte output "
			    "buffer capacity.",
			    bind.metadata.column_names[col.column_id].c_str(), (unsigned long long)group,
			    (unsigned long long)decoded_size, (unsigned long long)buffer_capacity);
		}

		oasis::QuerySplinter splinter;
		splinter.operators.push_back(MakeSource(ctx, lstate, cc));
		splinter.operators.push_back(
		    std::make_unique<oasis::DecodeColumnChunkOperator>(cc.compression, cc.num_values, type));
		splinter.operators.push_back(std::make_unique<oasis::HostBufferSinkOperator>());
		splinters.push_back(std::move(splinter));
		splinter_slot.push_back(i);
	}

	// Phase 2: Submit the whole row group at once.
	auto handles = ctx.scheduler().submit(std::move(splinters));
    DUCKDB_LOG_DEBUG(context, "Submitted %llu QuerySplinters for row group %llu.",
		             (unsigned long long)splinter_slot.size(), (unsigned long long)group);
	std::vector<oasis::SplinterResultHandle> results(gstate.projected_columns.size());
	for (size_t k = 0; k < handles.size(); k++) {
		results[splinter_slot[k]] = std::move(handles[k]);
	}
	return results;
}

// Blocks until each hardware column's decoded buffer is ready and stores it into
// lstate.current_buffers (in projection order).
static void CollectColumnBuffers(ClientContext &context, OasisScanGlobalState &gstate,
                                 OasisScanLocalState &lstate, const OasisScanBindData &bind, size_t group,
                                 std::vector<oasis::SplinterResultHandle> &results) {
	lstate.current_buffers.assign(gstate.projected_columns.size(), nullptr);
	for (size_t i = 0; i < results.size(); i++) {
		if (gstate.projected_columns[i].is_cpu) {
			continue;
		}
		auto batch = results[i].get_next_batch();
		if (!batch) {
			throw InternalException("Column %llu produced no output for row group %llu", (unsigned long long)i,
			                        (unsigned long long)group);
		}
		size_t const col_id = gstate.projected_columns[i].column_id;
		DUCKDB_LOG_DEBUG(context, "Hardware decoder for row group %llu, column %llu ('%s') returned batch",
		                 (unsigned long long)group, (unsigned long long)col_id,
		                 bind.metadata.column_names[col_id].c_str());
		lstate.current_buffers[i] = std::move(*batch);
	}
}

// Decodes one row group: submit a splinter per hardware column, initialize the CPU/string readers,
// then collect the decoded buffers.
static void DecodeGroup(ClientContext &context, oasis::OasisContext &ctx, OasisScanGlobalState &gstate,
                        OasisScanLocalState &lstate, const OasisScanBindData &bind, size_t group) {
	auto results = SubmitColumnSplinters(context, ctx, gstate, lstate, bind, group);

	// InitializeRead(...) does the page-header parsing / I/O positioning for the CPU/string columns.
	if (gstate.has_cpu_columns) {
		lstate.root_reader->InitializeRead(group, lstate.parquet_reader->GetFileMetadata()->row_groups[group].columns,
		                                   *lstate.scan_state->thrift_file_proto);
	}

	CollectColumnBuffers(context, gstate, lstate, bind, group, results);
}

// Claims the next non-empty row group off the shared atomic cursor, returning its index (or
// total_groups once all groups are consumed).
static size_t ClaimNextNonEmptyGroup(OasisScanGlobalState &gstate, const OasisScanBindData &bind) {
	while (true) {
		size_t group = gstate.next_group.fetch_add(1);
		if (group >= gstate.total_groups) {
			return gstate.total_groups;
		}
		if (RowGroupNumRows(bind, group) != 0) {
			return group;
		}
	}
}

// Claims the next non-empty row group that also survives filter pruning.
static size_t ClaimNextMatchingGroup(ClientContext &context, OasisScanGlobalState &gstate,
                                     OasisScanLocalState &lstate, const OasisScanBindData &bind) {
	while (true) {
		size_t group = ClaimNextNonEmptyGroup(gstate, bind);
		if (group >= gstate.total_groups) {
			return gstate.total_groups;
		}
		if (RowGroupMatchesFilters(context, gstate, lstate, group)) {
			return group;
		}
	}
}

// Loads the next row group's buffers into lstate.current_buffers. Returns false once all groups are consumed.
static bool LoadNextGroup(ClientContext &context, oasis::OasisContext &ctx, OasisScanGlobalState &gstate,
                          OasisScanLocalState &lstate, const OasisScanBindData &bind) {
	size_t group = ClaimNextMatchingGroup(context, gstate, lstate, bind);
	if (group >= gstate.total_groups) {
		return false;
	}
	DecodeGroup(context, ctx, gstate, lstate, bind, group);
	lstate.current_buf_offset = 0;
	lstate.current_group_num_rows = RowGroupNumRows(bind, group);
	lstate.current_group = group;
	return true;
}

// Emits cardinality only, for queries that project no columns (COUNT(*), EXISTS, etc.). DuckDB
// derives the aggregate from the row counts we report, so there is nothing to decode: each worker
// claims row groups off the shared cursor and emits their row counts (from the Parquet metadata)
// in STANDARD_VECTOR_SIZE slices. The hardware is never touched.
//
// This path only runs when the query has no filter. A filtered aggregate (e.g.
// SELECT COUNT(*) ... WHERE x > 5) still references the filter column, so DuckDB projects it and
// emit_cardinality_only stays false -- such queries go through OasisScanFunction's normal decode
// path, where ApplyFilters drops the non-matching rows. So here gstate.filters is always null
// and there is nothing to prune; we only skip empty row groups.
static void EmitCardinalityOnly(OasisScanGlobalState &gstate, OasisScanLocalState &lstate,
                                const OasisScanBindData &bind, DataChunk &output) {
	// Claim the next non-empty group off the shared cursor, or signal EOF once the groups run out.
	if (lstate.empty_proj_remaining == 0) {
		size_t group = ClaimNextNonEmptyGroup(gstate, bind);
		if (group >= gstate.total_groups) {
			output.SetCardinality(0);
			return;
		}
		lstate.empty_proj_remaining = RowGroupNumRows(bind, group);
		lstate.current_group = group;
	}

	size_t const emit = std::min<size_t>(lstate.empty_proj_remaining, STANDARD_VECTOR_SIZE);
	lstate.empty_proj_remaining -= emit;
	output.SetCardinality(emit);
}

// Emits the next STANDARD_VECTOR_SIZE-sized slice of the current row group into `output` (decoding
// or claiming a new group as needed), zero-copy. Returns the number of rows written before filtering,
// or 0 at end-of-data.
static size_t EmitOneSlice(ClientContext &context, oasis::OasisContext &ctx, OasisScanGlobalState &gstate,
                           OasisScanLocalState &lstate, const OasisScanBindData &bind, DataChunk &output) {
	// When the current group is fully emitted, decode/claim the next one.
	if (lstate.current_group_num_rows == 0) {
		if (!LoadNextGroup(context, ctx, gstate, lstate, bind)) {
			return 0; // EOF.
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

	for (size_t i = 0; i < gstate.projected_columns.size(); i++) {
		const auto &col = gstate.projected_columns[i];
		if (col.is_cpu) {
			auto &vec = output.data[i];
			auto &child_reader = lstate.root_reader->Cast<StructColumnReader>().GetChildReader(col.column_id);
			auto rows_read = child_reader.Read(emit, define_ptr, repeat_ptr, vec);
			if (rows_read != emit) {
				throw InternalException(
				    "ParCore CPU column %llu read %llu values, expected %llu (HW/CPU cursor desync)",
				    (unsigned long long)i, (unsigned long long)rows_read, (unsigned long long)emit);
			}
			continue;
		}

		auto &buf = lstate.current_buffers[i];
		if (buf->size / col.elem_size != total_elements) {
			throw InternalException(
			    "ParCore buffer layout mismatch across columns: column %llu has %llu elements, expected %llu",
			    (unsigned long long)i, (unsigned long long)(buf->size / col.elem_size), (unsigned long long)total_elements);
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
		FlatVector::SetData(vec, reinterpret_cast<data_ptr_t>(buf->ptr) + lstate.current_buf_offset * col.elem_size);
		vec.SetAuxiliary(make_buffer<LibstfBufferVectorBuffer>(buf));
	}

	// Advance the cursor. If we have emitted this group's last elements, release the buffers so the
	// next call's `if` branch loads the next row group. Dropping our refs here lets each buffer free as
	// soon as downstream consumers are done with it.
	lstate.current_buf_offset += emit;
	if (lstate.current_buf_offset >= total_elements) {
		lstate.current_buffers.assign(gstate.projected_columns.size(), nullptr);
		lstate.current_buf_offset = 0;
		lstate.current_group_num_rows = 0;
	}

	output.SetCardinality(emit);
	return emit;
}

// Zero-copy multi-column scan. Each worker atomically claims a row group (LoadNextGroup), decoding
// every projected column into exactly one buffer, then slices those buffers in lockstep into
// STANDARD_VECTOR_SIZE-sized vectors. The one-buffer-per-column-chunk model holds because the OBM
// buffers are sized to a whole DuckDB column chunk and DecodeGroup rejects any chunk that would
// overflow them. All columns of a row group share the same element count, so the slices stay aligned.
//
// We loop over slices until at least one row survives the pushed-down filters or we hit true EOF.
// This is required for correctness: DuckDB treats a scan call that returns an empty chunk as
// end-of-data for that thread, so returning a fully-filtered-out slice would silently truncate.
void OasisScanFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &gstate = data_p.global_state->Cast<OasisScanGlobalState>();
	auto &lstate = data_p.local_state->Cast<OasisScanLocalState>();
	auto &bind = data_p.bind_data->Cast<OasisScanBindData>();
	auto &ctx = *gstate.ctx;

	if (gstate.emit_cardinality_only) {
		EmitCardinalityOnly(gstate, lstate, bind, output);
		return;
	}

	while (true) {
		output.Reset();
		if (EmitOneSlice(context, ctx, gstate, lstate, bind, output) == 0) {
			output.SetCardinality(0); // EOF.
			return;
		}
		if (ApplyFilters(gstate, lstate, output) > 0) {
			return;
		}
	}
}

unique_ptr<NodeStatistics> OasisScanCardinality(ClientContext &, const FunctionData *bind_data) {
	auto &bind = bind_data->Cast<OasisScanBindData>();
	idx_t total_rows = 0;
	for (size_t group = 0; group < bind.metadata.groups.size(); group++) {
		total_rows += RowGroupNumRows(bind, group);
	}
	return make_uniq<NodeStatistics>(total_rows);
}

unique_ptr<BaseStatistics> OasisScanStatistics(ClientContext &context, const FunctionData *bind_data,
                                               column_t column_index) {
	if (IsVirtualColumn(column_index)) {
		return nullptr;
	}
	auto &bind = bind_data->Cast<OasisScanBindData>();
	if (column_index >= bind.metadata.column_names.size()) {
		return nullptr;
	}
	ParquetOptions parquet_opts(context);
	ParquetReader reader(context, OpenFileInfo {bind.filename}, parquet_opts);
	return reader.GetStatistics(context, bind.metadata.column_names[column_index]);
}

double OasisScanProgress(ClientContext &, const FunctionData *, const GlobalTableFunctionState *global_state) {
	auto &gstate = global_state->Cast<OasisScanGlobalState>();
	if (gstate.total_groups == 0) {
		return 100.0;
	}
	double claimed = static_cast<double>(gstate.next_group.load());
	double pct = 100.0 * claimed / static_cast<double>(gstate.total_groups);
	return pct > 100.0 ? 100.0 : pct;
}

OperatorPartitionData OasisScanGetPartitionData(ClientContext &, TableFunctionGetPartitionInput &input) {
	auto &lstate = input.local_state->Cast<OasisScanLocalState>();
	return OperatorPartitionData(lstate.current_group);
}

// Advertises the zero-width COLUMN_IDENTIFIER_EMPTY virtual column. For queries that consume no
// column values (e.g., COUNT(*), EXISTS), DuckDB's optimizer projects this sentinel instead of 
// anchoring the scan on a real column (LogicalGet::GetAnyColumn).
virtual_column_map_t OasisScanGetVirtualColumns(ClientContext &, optional_ptr<FunctionData>) {
	virtual_column_map_t result;
	result.insert(make_pair(COLUMN_IDENTIFIER_EMPTY, TableColumn("", LogicalType::BOOLEAN)));
	return result;
}

void RegisterOasisScanFunction(ExtensionLoader &loader) {
	TableFunction table_function("read_oasis",           // Function name
	                             {LogicalType::VARCHAR}, // Function arguments: Parquet file path
	                             OasisScanFunction,      // Table function
	                             OasisScanBind,          // Bind function
	                             OasisScanInitGlobal,    // Init global function
	                             OasisScanInitLocal      // Init local function
	);
	table_function.projection_pushdown = true;
	table_function.filter_pushdown = true;
	table_function.get_virtual_columns = OasisScanGetVirtualColumns;
	table_function.cardinality = OasisScanCardinality;
	table_function.statistics = OasisScanStatistics;
	table_function.table_scan_progress = OasisScanProgress;
	table_function.get_partition_data = OasisScanGetPartitionData;
	loader.RegisterFunction(table_function);
}

} // namespace duckdb
