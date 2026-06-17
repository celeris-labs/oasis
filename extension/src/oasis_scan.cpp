#include "oasis_scan.hpp"

#include "coalesced_fetcher.hpp"
#include "column_reader.hpp"
#include "duckdb/common/exception.hpp"
#include "duckdb/common/multi_file/multi_file_options.hpp"
#include "duckdb/logging/logger.hpp"
#include "duckdb/main/database.hpp"
#include "duckdb/parallel/task_scheduler.hpp"
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

namespace {

class OasisSplinterResultTask : public AsyncTask {
public:
	explicit OasisSplinterResultTask(oasis::SplinterResultHandle result) : result(std::move(result)) {
	}

	void Execute() override {
		result.wait_ready();
	}

private:
	oasis::SplinterResultHandle result;
};

} // namespace

unique_ptr<FunctionData> OasisScanBind(ClientContext &context, TableFunctionBindInput &input,
                                       vector<LogicalType> &return_types, vector<string> &names) {
	auto parquet_file = StringValue::Get(input.inputs[0]);

	ParquetOptions parquet_opts(context);
	ParquetReader parquet_reader(context, OpenFileInfo {parquet_file}, parquet_opts);

	auto bind_data = make_uniq<OasisScanBindData>();

	for (auto &col : parquet_reader.columns) {
		names.push_back(col.name.GetIdentifierName());
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

	// Split the scan-wide groups-in-flight budget across the worker threads this scan will run on.
	Value groups_in_flight_val;
	context.TryGetCurrentSetting("oasis_scan_groups_in_flight", groups_in_flight_val);
	size_t const groups_in_flight = groups_in_flight_val.IsNull() ? 16 : groups_in_flight_val.GetValue<uint64_t>();
	size_t const num_threads =
	    std::max<size_t>(1, static_cast<size_t>(TaskScheduler::GetScheduler(context).NumberOfThreads()));
	gstate->groups_in_flight_per_worker = std::max<size_t>(2, (groups_in_flight + num_threads - 1) / num_threads);

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

	// Build a per-worker ParquetReader: its per-column readers supply the per-column-chunk statistics
    // used for row-group skipping (RowGroupMatchesFilters). The CPU decode path additionally drives
    // these readers in OasisScanFunction. We project every file column (one FULL_READ ColumnIndex per
    // column), so scan_state->GetColumnReader(col_id) is keyed directly by file column id.
	ParquetOptions parquet_opts(context.client);
	lstate->parquet_reader = make_uniq<ParquetReader>(context.client, OpenFileInfo {gstate.filename},
                                                      parquet_opts, bind_data.parquet_metadata);
	for (idx_t c = 0; c < lstate->parquet_reader->columns.size(); c++) {
		lstate->parquet_reader->column_indexes.emplace_back(c);
	}
	lstate->scan_state = make_uniq<ParquetReaderScanState>();

	vector<idx_t> groups_to_read;
	groups_to_read.reserve(gstate.total_groups);
	for (idx_t g = 0; g < gstate.total_groups; g++) {
		groups_to_read.push_back(g);
	}
	lstate->parquet_reader->InitializeScan(context.client, *lstate->scan_state, std::move(groups_to_read));

	// Prepare the pushed-down filters for row-level filtering (one TableFilterState per filter,
	// owned by this worker).
	if (gstate.filters) {
		for (auto &entry : *gstate.filters) {
			lstate->scan_filters.emplace_back(context.client, entry.GetIndex(), entry.Filter());
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

static void DecodeCPUColumns(OasisScanGlobalState &gstate, OasisScanLocalState &lstate, size_t num_rows,
                             std::vector<std::vector<unique_ptr<Vector>>> &out);

// Select the hardware-decoded column chunks, allocate their host input buffers, and emit one
// AsyncTask per coalesced read (host path). For RDMA, the hardware pulls bytes straight into the
// stream during decode, so there are no tasks. Leaves `pending` in the IO_PENDING phase.
static void BeginGroupIO(ClientContext &context, oasis::OasisContext &ctx, OasisScanGlobalState &gstate,
                         OasisScanLocalState &lstate, const OasisScanBindData &bind,
                         OasisScanLocalState::PendingGroup &pending) {
	const size_t group = pending.group;
	const size_t buffer_capacity = ctx.output_buffer_manager()->buffer_capacity();
	auto *rdma = dynamic_cast<RDMAFileHandle *>(lstate.file_handle.get());

	// Collect the column chunks that will be decoded in hardware.
	pending.hw_slot.reserve(gstate.projected_columns.size());
	pending.hw_chunks.reserve(gstate.projected_columns.size());
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

		pending.hw_slot.push_back(i);
		pending.hw_chunks.push_back(&cc);
	}

	if (rdma) {
		return; // No host reads on the RDMA path.
	}

	// Full byte span of the row group: [min chunk offset, max chunk end) over ALL chunks.
	CoalescedFetcher::GroupSpan group_span {0, 0};
	uint64_t span_begin = std::numeric_limits<uint64_t>::max();
	uint64_t span_end = 0;
	for (const auto &cc : bind.metadata.groups[group].chunks) {
		span_begin = std::min<uint64_t>(span_begin, cc.offset);
		span_end = std::max<uint64_t>(span_end, cc.offset + cc.total_compressed_size);
	}
	if (span_end > span_begin) {
		group_span = {span_begin, span_end - span_begin};
	}

	pending.fetcher = make_uniq<CoalescedFetcher>(*lstate.file_handle, ctx.memory_pool(), group_span);
	pending.host_handles.reserve(pending.hw_chunks.size());
	for (const auto *cc : pending.hw_chunks) {
		pending.host_handles.push_back(pending.fetcher->Register(cc->offset, cc->total_compressed_size));
	}
	pending.fetcher->PrepareReads();

	auto *fetcher = pending.fetcher.get();
	pending.io_tasks = fetcher->BuildReadTasks();
	DUCKDB_LOG_DEBUG(context, "Coalesced %llu column chunk(s) into %llu read(s) (%llu bytes) for row group %llu.",
	                 (unsigned long long)fetcher->num_ranges(), (unsigned long long)fetcher->num_reads(),
	                 (unsigned long long)fetcher->bytes_fetched(), (unsigned long long)group);
}

// Build and submit the whole row group as ONE QuerySplinter (one flow per hardware column), then 
// initialize and fully decode the CPU/string columns. Each flow's sink is tagged with its 
// projection index, so the consumer places the tagged batches into hw_buffers[projection_index].
static void FinishGroupIO(ClientContext &context, oasis::OasisContext &ctx, OasisScanGlobalState &gstate,
                          OasisScanLocalState &lstate, const OasisScanBindData &bind,
                          OasisScanLocalState::PendingGroup &pending) {
	const size_t group = pending.group;
	auto *rdma = dynamic_cast<RDMAFileHandle *>(lstate.file_handle.get());

	// Build one QuerySplinter for the whole row group -- one flow per hardware column. The scheduler
	// load-balances the flows across hardware streams and closes the handle once all flows finish.
	oasis::QuerySplinter splinter;
	splinter.streams.reserve(pending.hw_slot.size());
	for (size_t k = 0; k < pending.hw_slot.size(); k++) {
		const auto &cc = *pending.hw_chunks[k];
		auto type = parcore::metadata::to_libstf_type(cc.type);

		oasis::OperatorFlow flow;
		if (rdma) {
			flow.push_back(MakeRDMASource(*rdma, cc));
		} else {
			flow.push_back(MakeHostSource(ctx, pending.fetcher->Resolve(pending.host_handles[k])));
		}
		flow.push_back(
		    std::make_unique<oasis::DecodeColumnChunkOperator>(cc.compression, cc.num_values, type));
		flow.push_back(std::make_unique<oasis::LocalSinkOperator>(pending.hw_slot[k]));
		splinter.streams.push_back(std::move(flow));
	}

	pending.result = ctx.scheduler().submit(std::move(splinter));
	DUCKDB_LOG_DEBUG(context, "Submitted QuerySplinter (%llu flow(s)) for row group %llu.",
	                 (unsigned long long)pending.hw_slot.size(), (unsigned long long)group);

	pending.hw_buffers.assign(gstate.projected_columns.size(), nullptr);
	pending.hw_columns_remaining = pending.hw_slot.size();

	// InitializeRead(...) does the page-header parsing / I/O positioning for the CPU/string columns,
	// then DecodeCPUColumns drains them in full. Both run while the FPGA splinters are in flight.
	if (gstate.has_cpu_columns) {
		const auto &row_group_columns = lstate.parquet_reader->GetFileMetadata()->row_groups[group].columns;
		for (const auto &col : gstate.projected_columns) {
			if (col.is_cpu) {
				lstate.scan_state->GetColumnReader(col.column_id)
				    .InitializeRead(group, row_group_columns, *lstate.scan_state->thrift_file_proto);
			}
		}
	}
	DecodeCPUColumns(gstate, lstate, pending.num_rows, pending.cpu_slices);

	pending.phase = OasisScanLocalState::PendingGroup::Phase::DECODING;
}

// Non-blocking: Drains the row group's result handle, placing each tagged column chunk into
// pending.hw_buffers[tag]. Returns true if collecting the row group was successful.
static bool TryCollectRowGroup(ClientContext &context, OasisScanGlobalState &gstate, const OasisScanBindData &bind,
                                   OasisScanLocalState::PendingGroup &pending) {
	while (pending.hw_columns_remaining > 0) {
		auto poll = pending.result.try_get_next_batch();
		if (!poll.ready) {
			return false; // Nothing ready yet; come back after a readiness wake.
		}
		if (!poll.batch) {
			// Channel closed but columns are still outstanding -- a column produced no output.
			throw InternalException("Row group %llu closed with %llu hardware column(s) missing",
			                        (unsigned long long)pending.group,
			                        (unsigned long long)pending.hw_columns_remaining);
		}
		size_t const tag = poll.batch->tag;
		size_t const col_id = gstate.projected_columns[tag].column_id;
		DUCKDB_LOG_DEBUG(context, "Hardware decoder for row group %llu, column %llu ('%s') returned batch",
		                 (unsigned long long)pending.group, (unsigned long long)col_id,
		                 bind.metadata.column_names[col_id].c_str());
		pending.hw_buffers[tag] = std::move(poll.batch->buffer);
		pending.hw_columns_remaining--;
	}
	return true;
}

// Fully decodes every CPU/string column of the current group into per-slice Vectors written to
// `out` (indexed [projection_index][slice]).
static void DecodeCPUColumns(OasisScanGlobalState &gstate, OasisScanLocalState &lstate, size_t num_rows,
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
		auto &child_reader = lstate.scan_state->GetColumnReader(col.column_id);

		auto &slices = out[i];
		for (size_t off = 0; off < num_rows; off += STANDARD_VECTOR_SIZE) {
			size_t const emit = std::min<size_t>(num_rows - off, STANDARD_VECTOR_SIZE);

			// The reader writes into define/repeat scratch as a side effect; zero per slice so a short
			// final slice can't inherit a previous slice's levels.
			lstate.scan_state->define_buf.zero();
			lstate.scan_state->repeat_buf.zero();

			auto vec = make_uniq<Vector>(child_reader.Type());
			ColumnReaderInput input(emit, define_ptr, repeat_ptr);
			auto rows_read = child_reader.Read(input, *vec);
			if (rows_read != emit) {
				throw InternalException("ParCore CPU column %llu read %llu values, expected %llu (decode desync)",
				                        (unsigned long long)i, (unsigned long long)rows_read, (unsigned long long)emit);
			}

			FlatVector::SetSize(*vec, count_t(emit));

			// Since we retain every slice's vector until emit, flatten here so each slice owns its
            // own data and stops aliasing that shared scratch state.
			vec->Flatten();
			slices.push_back(std::move(vec));
		}
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

// Keeps the pipeline full: Claims matching groups up to the per-worker budget and runs BeginGroupIO
// on each (selecting chunks + allocating buffers, no IO). New groups start IO_PENDING.
static void TopUpInflight(ClientContext &context, oasis::OasisContext &ctx, OasisScanGlobalState &gstate,
                          OasisScanLocalState &lstate, const OasisScanBindData &bind) {
	while (!lstate.groups_exhausted && lstate.inflight.size() < gstate.groups_in_flight_per_worker) {
		size_t group = ClaimNextMatchingGroup(context, gstate, lstate, bind);
		if (group >= gstate.total_groups) {
			lstate.groups_exhausted = true;
			break;
		}
		auto pending = make_uniq<OasisScanLocalState::PendingGroup>();
		pending->group = group;
		pending->num_rows = RowGroupNumRows(bind, group);
		BeginGroupIO(context, ctx, gstate, lstate, bind, *pending);
		lstate.inflight.push_back(std::move(pending));
	}
}

static LoadResult LoadNextGroup(ClientContext &context, oasis::OasisContext &ctx, OasisScanGlobalState &gstate,
                                OasisScanLocalState &lstate, const OasisScanBindData &bind,
                                std::vector<unique_ptr<AsyncTask>> &out_tasks) {
	using Phase = OasisScanLocalState::PendingGroup::Phase;

	// Keep the pipeline full so later groups overlap IO/decode with collecting the head.
	TopUpInflight(context, ctx, gstate, lstate, bind);

	// Promote to DECODING every group whose host reads have completed (its scheduled AsyncResult
	// finished before this re-entry, see Decision 3) or that needs no host IO at all (RDMA, or no
	// hardware columns). This submits their splinters so FPGA decode of all ready groups overlaps.
	for (auto &pending : lstate.inflight) {
		if (pending->phase == Phase::IO_PENDING && (pending->io_scheduled || pending->io_tasks.empty())) {
			FinishGroupIO(context, ctx, gstate, lstate, bind, *pending);
		}
	}

	if (lstate.inflight.empty()) {
		return LoadResult::EXHAUSTED;
	}
	auto &head = *lstate.inflight.front();

	// If the head still needs host reads, schedule the reads for every not-yet-started inflight 
    // group as one AsyncResult and return that we are blocked.
	if (head.phase == Phase::IO_PENDING) {
		for (auto &pending : lstate.inflight) {
			if (pending->phase == Phase::IO_PENDING && !pending->io_scheduled) {
				for (auto &task : pending->io_tasks) {
					out_tasks.push_back(std::move(task));
				}
				pending->io_tasks.clear();
				pending->io_scheduled = true;
			}
		}
		return LoadResult::BLOCKED;
	}

	// Head is DECODING: Collect its hardware buffers without blocking. If any column is still
	// outstanding, block on the result handle via an async task (which frees the worker until the
	// handle next becomes ready) and return BLOCKED.
	if (!TryCollectRowGroup(context, gstate, bind, head)) {
		out_tasks.push_back(make_uniq<OasisSplinterResultTask>(head.result));
		return LoadResult::BLOCKED;
	}

	lstate.current_buffers = std::move(head.hw_buffers);
	lstate.current_cpu_slices = std::move(head.cpu_slices);
	lstate.current_buf_offset = 0;
	lstate.current_group_num_rows = head.num_rows;
	lstate.current_group = head.group;
	lstate.inflight.pop_front();
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
			output.SetChildCardinality(0);
			return;
		}
		lstate.empty_proj_remaining = RowGroupNumRows(bind, group);
		lstate.current_group = group;
	}

	size_t const emit = std::min<size_t>(lstate.empty_proj_remaining, STANDARD_VECTOR_SIZE);
	lstate.empty_proj_remaining -= emit;
	output.SetChildCardinality(emit);
}

struct SliceResult {
	size_t rows = 0;
	LoadResult load = LoadResult::LOADED; // BLOCKED or EXHAUSTED when rows == 0.
};

// Emits the next STANDARD_VECTOR_SIZE-sized slice of the current row group into `output` (decoding
// or claiming a new group as needed), zero-copy.
static SliceResult EmitOneSlice(ClientContext &context, oasis::OasisContext &ctx, OasisScanGlobalState &gstate,
                                OasisScanLocalState &lstate, const OasisScanBindData &bind, DataChunk &output,
                                std::vector<unique_ptr<AsyncTask>> &out_tasks) {
	// When the current group is fully emitted, decode/claim the next one.
	if (lstate.current_group_num_rows == 0) {
		auto load = LoadNextGroup(context, ctx, gstate, lstate, bind, out_tasks);
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
		FlatVector::SetData(vec, reinterpret_cast<data_ptr_t>(buf->ptr) + lstate.current_buf_offset * col.elem_size,
		                    count_t(emit));
		vec.AddAuxiliaryData(make_uniq<LibstfBufferVectorBuffer>(buf));
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

	output.CheckCardinality(emit);
	return {emit, LoadResult::LOADED};
}

// Zero-copy multi-column scan. Each worker atomically claims a row group, submits its query
// splinters to the Oasis scheduler, and slices the decoded buffers in lockstep into
// STANDARD_VECTOR_SIZE-sized vectors. The one-buffer-per-column-chunk model holds because the OBM
// buffers are sized to a whole DuckDB column chunk and BeginGroupIO rejects any chunk that would
// overflow them.
//
// Rather than block a DuckDB worker thread on IO or FPGA decode, we return BLOCKED via
// data_p.async_result with AsyncTasks: input reads run on DuckDB's async pool, and FPGA-readiness
// waits run there too (each bridging the result handle's readiness callback). The engine reschedules
// this scan once the tasks complete.
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

	while (true) {
		output.Reset();
		std::vector<unique_ptr<AsyncTask>> tasks;
		auto slice = EmitOneSlice(context, ctx, gstate, lstate, bind, output, tasks);
		if (slice.rows == 0) {
			output.SetChildCardinality(0);
			if (slice.load == LoadResult::BLOCKED) {
				data_p.async_result = AsyncResult(std::move(tasks), TaskSchedulerType::ASYNC);
			}
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
	return reader.GetStatistics(context, Identifier(bind.metadata.column_names[column_index]));
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
