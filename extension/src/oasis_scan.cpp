#include "oasis_scan.hpp"

#include "coalesced_fetcher.hpp"
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
#include <cstring>
#include <limits>
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

	bind_data->parquet_metadata = parquet_reader.metadata;

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
	auto &bind_data = input.bind_data->Cast<OasisScanBindData>();
	auto lstate = make_uniq<OasisScanLocalState>();

	// Each worker owns its own file handle: DuckDB FileHandles are not safe to share across threads,
	// and the local source path reads from it on this worker thread.
	auto &fs = FileSystem::GetFileSystem(context.client);
	lstate->file_handle = fs.OpenFile(gstate.filename, FileOpenFlags::FILE_FLAGS_READ);

	// Build a per-worker ParquetReader: The root_reader supplies the per-column-chunk statistics 
    // used for row-group skipping (RowGroupMatchesFilters). The CPU decode path additionally drives 
    // this reader's child readers in OasisScanFunction.
	ParquetOptions parquet_opts(context.client);
	lstate->parquet_reader = make_uniq<ParquetReader>(context.client, OpenFileInfo {gstate.filename}, 
                                                      parquet_opts, bind_data.parquet_metadata);
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

static std::unique_ptr<oasis::SourceOperator> MakeRDMASource(RDMAFileHandle &rdma,
                                                             const parcore::metadata::ColumnChunk &cc) {
	return std::make_unique<oasis::RDMASourceOperator>(rdma.remote_offset + cc.offset, cc.total_compressed_size);
}

static std::unique_ptr<oasis::SourceOperator>
MakeHostSource(oasis::OasisContext &ctx, const CoalescedFetcher::RangeView &view) {
	if ((reinterpret_cast<uintptr_t>(view.data()) % 64) == 0) {
		// Zero-copy for aligned ranges: A libstf::Buffer that describes just this chunk's slice, 
        // owning a shared_ptr to the whole coalesced allocation so the backing bytes stay alive for 
        // the splinter's lifetime.
		auto *slice_ptr = static_cast<uint8_t *>(view.buffer->ptr) + view.offset;
		size_t capacity = view.buffer->capacity - view.offset;
		// Custom deleter keeps the parent coalesced buffer alive and frees only the wrapper struct.
		auto parent = view.buffer;
		std::shared_ptr<libstf::Buffer> slice(new libstf::Buffer {slice_ptr, view.size, capacity},
		                                      [parent](libstf::Buffer *b) { delete b; });
		return std::make_unique<oasis::LocalSourceOperator>(std::move(slice));
	}

	// TODO: REMOVE unaligned slice: Copy it out into its own aligned buffer.
	void *ptr;
	auto status = ctx.memory_pool()->allocate(view.size, &ptr);
	if (!status.ok()) {
		throw IOException("Could not allocate input buffer: " + status.message());
	}
	std::memcpy(ptr, view.data(), view.size);
	auto buffer = libstf::make_buffer(ctx.memory_pool(), ptr, view.size, view.size);
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
	auto *rdma = dynamic_cast<RDMAFileHandle *>(lstate.file_handle.get());

	// Phase 0: Collect the column chunks that will be decoded in hardware and fetch them.
	std::vector<size_t> hw_slot; // projection indices of the hardware columns, in order
	std::vector<const parcore::metadata::ColumnChunk *> hw_chunks;
	hw_slot.reserve(gstate.projected_columns.size());
	hw_chunks.reserve(gstate.projected_columns.size());

	for (size_t i = 0; i < gstate.projected_columns.size(); i++) {
		const auto &col = gstate.projected_columns[i];
		if (col.is_cpu) {
			continue;
		}

		const auto &cc = bind.metadata.groups[group].chunks[col.column_id];

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

		hw_slot.push_back(i);
		hw_chunks.push_back(&cc);
	}

	CoalescedFetcher::GroupSpan group_span {0, 0};
	if (!rdma) {
		// Full byte span of the row group: [min chunk offset, max chunk end) over ALL chunks.
		uint64_t span_begin = std::numeric_limits<uint64_t>::max();
		uint64_t span_end = 0;
		for (const auto &cc : bind.metadata.groups[group].chunks) {
			span_begin = std::min<uint64_t>(span_begin, cc.offset);
			span_end = std::max<uint64_t>(span_end, cc.offset + cc.total_compressed_size);
		}
		if (span_end > span_begin) {
			group_span = {span_begin, span_end - span_begin};
		}
	}

	std::vector<CoalescedFetcher::RangeHandle> host_handles;
	CoalescedFetcher fetcher(*lstate.file_handle, ctx.memory_pool(), group_span);
	if (!rdma) {
		host_handles.reserve(hw_chunks.size());
		for (const auto *cc : hw_chunks) {
			host_handles.push_back(fetcher.Register(cc->offset, cc->total_compressed_size));
		}

		fetcher.Fetch();
		DUCKDB_LOG_DEBUG(context, "Coalesced %llu column chunk(s) into %llu read(s) (%llu bytes) for row group %llu.",
		                 (unsigned long long)fetcher.num_ranges(), (unsigned long long)fetcher.num_reads(),
		                 (unsigned long long)fetcher.bytes_fetched(), (unsigned long long)group);
	}

	// Phase 1: Build every hardware column's splinter, drawing host inputs from the coalesced buffers.
	std::vector<oasis::QuerySplinter> splinters;
	std::vector<size_t> splinter_slot;
	splinters.reserve(hw_slot.size());
	splinter_slot.reserve(hw_slot.size());
	for (size_t k = 0; k < hw_slot.size(); k++) {
		const auto &cc = *hw_chunks[k];
		auto type = parcore::metadata::to_libstf_type(cc.type);

		oasis::QuerySplinter splinter;
		if (rdma) {
			splinter.operators.push_back(MakeRDMASource(*rdma, cc));
		} else {
			splinter.operators.push_back(MakeHostSource(ctx, fetcher.Resolve(host_handles[k])));
		}
		splinter.operators.push_back(
		    std::make_unique<oasis::DecodeColumnChunkOperator>(cc.compression, cc.num_values, type));
		splinter.operators.push_back(std::make_unique<oasis::HostBufferSinkOperator>());
		splinters.push_back(std::move(splinter));
		splinter_slot.push_back(hw_slot[k]);
	}

	// Phase 2: Submit the whole row group at once.
	auto handles = ctx.scheduler().submit(std::move(splinters));
    DUCKDB_LOG_DEBUG(context, "Submitted %llu QuerySplinter(s) for row group %llu.",
		             (unsigned long long)splinter_slot.size(), (unsigned long long)group);
	std::vector<oasis::SplinterResultHandle> results(gstate.projected_columns.size());
	for (size_t k = 0; k < handles.size(); k++) {
		results[splinter_slot[k]] = std::move(handles[k]);
	}
	return results;
}

// Non-blocking: Polls each not-yet-collected hardware column's result channel and retains every 
// ready batch in pending.hw_buffers. Returns true once every hardware column has been collected.
static bool TryCollectColumnChunks(ClientContext &context, OasisScanGlobalState &gstate, const OasisScanBindData &bind, 
                                   OasisScanLocalState::PendingGroup &pending) {
	for (size_t i = 0; i < pending.results.size(); i++) {
		if (gstate.projected_columns[i].is_cpu || pending.hw_buffers[i]) {
			continue; // CPU column, or hardware column already collected.
		}
		auto poll = pending.results[i].try_get_next_batch();
		if (!poll.ready) {
			return false;
		}
		if (!poll.batch) {
			throw InternalException("Column %llu produced no output for row group %llu", (unsigned long long)i,
			                        (unsigned long long)pending.group);
		}
		size_t const col_id = gstate.projected_columns[i].column_id;
		DUCKDB_LOG_DEBUG(context, "Hardware decoder for row group %llu, column %llu ('%s') returned batch",
		                 (unsigned long long)pending.group, (unsigned long long)col_id,
		                 bind.metadata.column_names[col_id].c_str());
		pending.hw_buffers[i] = std::move(*poll.batch);
	}
	return true;
}

// Arms a one-shot readiness callback on every outstanding channel of `pending`. When a channel 
// becomes ready it calls InterruptState::Callback() to reschedule the blocked DuckDB task. The task 
// then re-polls all channels. 
//
// Returns true only if every outstanding channel was armed. If any channel was ALREADY ready,
// set_ready_callback registers nothing and returns false for that channel, and this function returns
// false: The caller must re-poll (which will collect that channel) rather than block.
static bool ArmReadinessCallbacks(OasisScanGlobalState &gstate, OasisScanLocalState::PendingGroup &pending,
                                  InterruptState interrupt_state) {
	pending.wake_guard->clear();
	auto guard = pending.wake_guard;
	bool all_armed = true;
	for (size_t i = 0; i < pending.results.size(); i++) {
		if (gstate.projected_columns[i].is_cpu || pending.hw_buffers[i]) {
			continue; // CPU column, or already collected.
		}
		auto cb = [interrupt_state, guard]() {
			if (!guard->test_and_set()) {
				interrupt_state.Callback();
			}
		};
		if (!pending.results[i].set_ready_callback(std::move(cb))) {
			all_armed = false;
		}
	}
	return all_armed;
}

// Fully decodes every CPU/string column of the current group into per-slice Vectors written to
// `out` (indexed [projection_index][slice]).
static void DecodeCpuColumns(OasisScanGlobalState &gstate, OasisScanLocalState &lstate, size_t num_rows,
                             std::vector<std::vector<unique_ptr<Vector>>> &out) {
	out.clear();
	out.resize(gstate.projected_columns.size());
	if (!gstate.has_cpu_columns) {
		return;
	}

	auto *define_ptr = reinterpret_cast<uint8_t *>(lstate.scan_state->define_buf.ptr);
	auto *repeat_ptr = reinterpret_cast<uint8_t *>(lstate.scan_state->repeat_buf.ptr);

	for (size_t i = 0; i < gstate.projected_columns.size(); i++) {
		const auto &col = gstate.projected_columns[i];
		if (!col.is_cpu) {
			continue;
		}
		auto &child_reader = lstate.root_reader->Cast<StructColumnReader>().GetChildReader(col.column_id);

		auto &slices = out[i];
		for (size_t off = 0; off < num_rows; off += STANDARD_VECTOR_SIZE) {
			size_t const emit = std::min<size_t>(num_rows - off, STANDARD_VECTOR_SIZE);

			// The reader writes into define/repeat scratch as a side effect; zero per slice so a short
			// final slice can't inherit a previous slice's levels.
			lstate.scan_state->define_buf.zero();
			lstate.scan_state->repeat_buf.zero();

			auto vec = make_uniq<Vector>(child_reader.Type());
			auto rows_read = child_reader.Read(emit, define_ptr, repeat_ptr, *vec);
			if (rows_read != emit) {
				throw InternalException("ParCore CPU column %llu read %llu values, expected %llu (decode desync)",
				                        (unsigned long long)i, (unsigned long long)rows_read, (unsigned long long)emit);
			}

			// Since we retain every slice's vector until emit, flatten here so each slice owns its 
            // own data and stops aliasing that shared scratch state.
			vec->Flatten(emit);
			slices.push_back(std::move(vec));
		}
	}
}

// Begins decoding one row group without blocking: submit a splinter per hardware column, then fully
// decode the CPU/string columns (overlapping with the hardware round trip). The hardware results 
// are left draining; the returned PendingGroup holds the result handles for the caller to poll. CPU
// slices are decoded here (in row-group order, as the sequential CPU reader requires) and stashed 
// on the PendingGroup.
static unique_ptr<OasisScanLocalState::PendingGroup>
BeginGroup(ClientContext &context, oasis::OasisContext &ctx, OasisScanGlobalState &gstate,
           OasisScanLocalState &lstate, const OasisScanBindData &bind, size_t group) {
	auto pending = make_uniq<OasisScanLocalState::PendingGroup>();
	pending->group = group;
	pending->num_rows = RowGroupNumRows(bind, group);
	pending->results = SubmitColumnSplinters(context, ctx, gstate, lstate, bind, group);
	pending->hw_buffers.assign(gstate.projected_columns.size(), nullptr);

	// InitializeRead(...) does the page-header parsing / I/O positioning for the CPU/string columns,
	// then DecodeCpuColumns drains them in full. Both run while the FPGA splinters are in flight.
	if (gstate.has_cpu_columns) {
		lstate.root_reader->InitializeRead(group, lstate.parquet_reader->GetFileMetadata()->row_groups[group].columns,
		                                   *lstate.scan_state->thrift_file_proto);
	}
	DecodeCpuColumns(gstate, lstate, pending->num_rows, pending->cpu_slices);
	return pending;
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

enum class LoadResult : uint8_t {
	LOADED,
	BLOCKED,
	EXHAUSTED
};

// Drives the async load of the next row group. On the first call for a group it claims one off the
// shared cursor and submits it (lstate.pending). Then and in later calls it polls the hardware
// channels. Once every hardware column is ready it moves the buffers/CPU slices into the current_*
// fields and clears pending, returning LOADED. If any hardware column is still outstanding it arms
// readiness callbacks and returns BLOCKED. Returns EXHAUSTED when no group remains.
static LoadResult LoadNextGroup(ClientContext &context, oasis::OasisContext &ctx, OasisScanGlobalState &gstate,
                                OasisScanLocalState &lstate, const OasisScanBindData &bind, InterruptState interrupt_state) {
	// Submit phase: Start a group if none is in flight.
	if (!lstate.pending) {
		size_t group = ClaimNextMatchingGroup(context, gstate, lstate, bind);
		if (group >= gstate.total_groups) {
			return LoadResult::EXHAUSTED;
		}
		lstate.pending = BeginGroup(context, ctx, gstate, lstate, bind, group);
	}

	// Poll phase: Collect the hardware buffers without blocking. If any column is still 
    // outstanding, arm readiness callbacks and return BLOCKED so the worker thread is released.
	//
	// Arming and polling race against the completion thread, so we loop: The loop terminates 
    // because each iteration either collects at least one more column or successfully arms every 
    // remaining one.
	while (!TryCollectColumnChunks(context, gstate, bind, *lstate.pending)) {
		if (ArmReadinessCallbacks(gstate, *lstate.pending, interrupt_state)) {
			return LoadResult::BLOCKED;
		}
	}

	lstate.current_buffers = std::move(lstate.pending->hw_buffers);
	lstate.current_cpu_slices = std::move(lstate.pending->cpu_slices);
	lstate.current_buf_offset = 0;
	lstate.current_group_num_rows = lstate.pending->num_rows;
	lstate.current_group = lstate.pending->group;
	lstate.pending.reset();
	return LoadResult::LOADED;
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

struct SliceResult {
	size_t rows = 0;
	LoadResult load = LoadResult::LOADED; // BLOCKED or EXHAUSTED when rows == 0.
};

// Emits the next STANDARD_VECTOR_SIZE-sized slice of the current row group into `output` (decoding
// or claiming a new group as needed), zero-copy.
static SliceResult EmitOneSlice(ClientContext &context, oasis::OasisContext &ctx, OasisScanGlobalState &gstate,
                                OasisScanLocalState &lstate, const OasisScanBindData &bind, DataChunk &output,
                                InterruptState interrupt_state) {
	// When the current group is fully emitted, decode/claim the next one.
	if (lstate.current_group_num_rows == 0) {
		auto load = LoadNextGroup(context, ctx, gstate, lstate, bind, std::move(interrupt_state));
		if (load != LoadResult::LOADED) {
			return {0, load}; // BLOCKED or EXHAUSTED.
		}
	}

	size_t const total_elements = lstate.current_group_num_rows;
	size_t const remaining_elements = total_elements - lstate.current_buf_offset;
	size_t const emit = std::min<size_t>(remaining_elements, STANDARD_VECTOR_SIZE);

	size_t const slice_idx = lstate.current_buf_offset / STANDARD_VECTOR_SIZE;

	for (size_t i = 0; i < gstate.projected_columns.size(); i++) {
		const auto &col = gstate.projected_columns[i];
		if (col.is_cpu) {
			output.data[i].Reference(*lstate.current_cpu_slices[i][slice_idx]);
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
		lstate.current_cpu_slices.clear();
		lstate.current_cpu_slices.resize(gstate.projected_columns.size());
		lstate.current_buf_offset = 0;
		lstate.current_group_num_rows = 0;
	}

	output.SetCardinality(emit);
	return {emit, LoadResult::LOADED};
}

// Zero-copy multi-column scan. Each worker atomically claims a row group, submits its query 
// splinters to the Oasis scheduler, and slices the decoded buffers in lockstep into
// STANDARD_VECTOR_SIZE-sized vectors. The one-buffer-per-column-chunk model holds because the OBM
// buffers are sized to a whole DuckDB column chunk and BeginGroup rejects any chunk that would
// overflow them.
//
// Rather than block a DuckDB worker thread while the FPGA decodes, we signal data_p.blocked 
// whenever the hardware results are not ready, after arming a readiness callback that the 
// Oasis scheduler's completion thread fires to reschedule this task.
//
// Otherwise we loop over slices until at least one row survives the pushed-down filters or we hit
// EOF.
void OasisScanFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &gstate = data_p.global_state->Cast<OasisScanGlobalState>();
	auto &lstate = data_p.local_state->Cast<OasisScanLocalState>();
	auto &bind = data_p.bind_data->Cast<OasisScanBindData>();
	auto &ctx = *gstate.ctx;

	if (gstate.emit_cardinality_only) {
		EmitCardinalityOnly(gstate, lstate, bind, output);
		return;
	}

	InterruptState interrupt_state = data_p.interrupt_state ? *data_p.interrupt_state : InterruptState();

	while (true) {
		output.Reset();
		auto slice = EmitOneSlice(context, ctx, gstate, lstate, bind, output, interrupt_state);
		if (slice.rows == 0) {
			output.SetCardinality(0);
			data_p.blocked = (slice.load == LoadResult::BLOCKED);
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
