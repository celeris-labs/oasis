#include "oasis_scan.hpp"

#include "coalesced_fetcher.hpp"
#include "column_reader.hpp"
#include "duckdb/common/exception.hpp"
#include "duckdb/common/multi_file/multi_file_options.hpp"
#include "duckdb/logging/logger.hpp"
#include "duckdb/main/database.hpp"
#include "duckdb/execution/executor.hpp"
#include "duckdb/parallel/pipeline.hpp"
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

static void InitScanWorker(ClientContext &client, OasisScanGlobalState &gstate, const OasisScanBindData &bind_data,
                           OasisScanLocalState &lstate);
static void SubmitPrefetchWindow(ClientContext &context, oasis::OasisContext &ctx, OasisScanGlobalState &gstate,
                                 const OasisScanBindData &bind);

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

	// Cross-pipeline prefetch warm depth (oasis_scan_prefetch_groups). Defaults to groups_in_flight,
	// capped at total_groups. 0 disables prefetch for this scan.
	Value prefetch_groups_val;
	context.TryGetCurrentSetting("oasis_scan_prefetch_groups", prefetch_groups_val);
	size_t const prefetch_groups =
	    prefetch_groups_val.IsNull() ? groups_in_flight : prefetch_groups_val.GetValue<uint64_t>();
	gstate->prefetch_groups = std::min<size_t>(prefetch_groups, gstate->total_groups);
	gstate->bind_data = &bind_data;
	gstate->source_op = input.op.get();

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

	// Cardinality-only scans (COUNT(*), EXISTS) decode nothing and never touch the FPGA, so there is
	// no window to warm. input.op is the source operator the executor matches in PrefetchNextPipelines;
	// without it this scan can never be warmed, so disable prefetch.
	if (gstate->emit_cardinality_only || !input.op) {
		gstate->prefetch_groups = 0;
	}

	// Build the global-state prefetch worker so this scan's window can be submitted later, when a
	// predecessor pipeline drains and the executor fires OasisScanPrefetch on this source. The first
	// scan of a query has no predecessor and cold-starts (its window is never submitted).
	if (gstate->prefetch_groups > 0) {
		gstate->prefetch_worker = make_uniq<OasisScanLocalState>();
		InitScanWorker(context, *gstate, bind_data, *gstate->prefetch_worker);
	}

	return std::move(gstate);
}

// Builds the per-worker file handle, ParquetReader, root reader, and filter states for one scan
// worker context. Shared by OasisScanInitLocal (live workers) and the global-state prefetch worker
// (which warms the FPGA from outside any pipeline's local-state lifetime). Both need an independent
// file handle (DuckDB FileHandles are not thread-safe) and reader (supplies per-chunk statistics for
// row-group skipping and drives CPU/string decode).
static void InitScanWorker(ClientContext &client, OasisScanGlobalState &gstate, const OasisScanBindData &bind_data,
                           OasisScanLocalState &lstate) {
	auto &fs = FileSystem::GetFileSystem(client);
	lstate.file_handle = fs.OpenFile(gstate.filename, FileOpenFlags::FILE_FLAGS_READ);

	ParquetOptions parquet_opts(client);
	lstate.parquet_reader =
	    make_uniq<ParquetReader>(client, OpenFileInfo {gstate.filename}, parquet_opts, bind_data.parquet_metadata);
	lstate.scan_state = make_uniq<ParquetReaderScanState>();

	vector<idx_t> groups_to_read;
	groups_to_read.reserve(gstate.total_groups);
	for (idx_t g = 0; g < gstate.total_groups; g++) {
		groups_to_read.push_back(g);
	}
	lstate.parquet_reader->InitializeScan(client, *lstate.scan_state, std::move(groups_to_read));
	lstate.root_reader = std::move(lstate.scan_state->root_reader);

	// Prepare the pushed-down filters for row-level filtering (one TableFilterState per filter,
	// owned by this worker).
	if (gstate.filters) {
		for (auto &filter_entry : gstate.filters->filters) {
			lstate.scan_filters.emplace_back(client, filter_entry.first, *filter_entry.second);
		}
	}
}

unique_ptr<LocalTableFunctionState> OasisScanInitLocal(ExecutionContext &context, TableFunctionInitInput &input,
                                                       GlobalTableFunctionState *global_state_p) {
	auto &gstate = global_state_p->Cast<OasisScanGlobalState>();
	auto &bind_data = input.bind_data->Cast<OasisScanBindData>();
	auto lstate = make_uniq<OasisScanLocalState>();

	InitScanWorker(context.client, gstate, bind_data, *lstate);

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

// Submits the whole row group `group` to the shared scheduler as ONE splinter (one flow per
// projected hardware column), returning the single result handle. Each flow's sink is tagged with
// its projection index, so the consumer places the tagged batches into hw_buffers[projection_index].
static oasis::SplinterResultHandle
SubmitRowGroupSplinter(ClientContext &context, oasis::OasisContext &ctx, OasisScanGlobalState &gstate,
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

	// Phase 1: Build one QuerySplinter for the whole row group -- one flow per hardware column. The 
    // scheduler load-balances the flows across hardware streams and closes the handle once all 
    // flows finish.
	oasis::QuerySplinter splinter;
	splinter.streams.reserve(hw_slot.size());
	for (size_t k = 0; k < hw_slot.size(); k++) {
		const auto &cc = *hw_chunks[k];
		auto type = parcore::metadata::to_libstf_type(cc.type);

		oasis::OperatorFlow flow;
		if (rdma) {
			flow.push_back(MakeRDMASource(*rdma, cc));
		} else {
			flow.push_back(MakeHostSource(ctx, fetcher.Resolve(host_handles[k])));
		}
		flow.push_back(
		    std::make_unique<oasis::DecodeColumnChunkOperator>(cc.compression, cc.num_values, type));
		flow.push_back(std::make_unique<oasis::LocalSinkOperator>(hw_slot[k]));
		splinter.streams.push_back(std::move(flow));
	}

	// Phase 2: Submit the whole row group as one splinter.
	auto result = ctx.scheduler().submit(std::move(splinter));
    DUCKDB_LOG_DEBUG(context, "Submitted QuerySplinter (%llu flow(s)) for row group %llu.",
		             (unsigned long long)hw_slot.size(), (unsigned long long)group);
	return result;
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

// Arms a one-shot readiness callback on the row group's single result handle. When the handle
// becomes ready it calls InterruptState::Callback() to reschedule the blocked DuckDB task, which
// then re-polls. Returns true if the callback was armed. If the channel is ALREADY ready,
// set_ready_callback registers nothing and returns false: the caller must re-poll.
static bool ArmReadinessCallbacks(OasisScanGlobalState &gstate, OasisScanLocalState::PendingGroup &pending,
                                  InterruptState interrupt_state) {
	(void)gstate;
	pending.wake_guard->clear();
	auto guard = pending.wake_guard;
	auto cb = [interrupt_state, guard]() {
		if (!guard->test_and_set()) {
			interrupt_state.Callback();
		}
	};
	return pending.result.set_ready_callback(std::move(cb));
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
// Decodes the deferred CPU/string columns of an already-HW-submitted prefetched group, using the
// adopting worker's local reader. No-op when the group's CPU columns were decoded at BeginGroup time.
static void DecodeDeferredCpuColumns(OasisScanGlobalState &gstate, OasisScanLocalState &lstate,
                                     const OasisScanBindData &bind, OasisScanLocalState::PendingGroup &pending) {
	if (!pending.cpu_decode_deferred) {
		return;
	}
	if (gstate.has_cpu_columns) {
		lstate.root_reader->InitializeRead(pending.group,
		                                   lstate.parquet_reader->GetFileMetadata()->row_groups[pending.group].columns,
		                                   *lstate.scan_state->thrift_file_proto);
	}
	DecodeCpuColumns(gstate, lstate, pending.num_rows, pending.cpu_slices);
	pending.cpu_decode_deferred = false;
}

static unique_ptr<OasisScanLocalState::PendingGroup>
BeginGroup(ClientContext &context, oasis::OasisContext &ctx, OasisScanGlobalState &gstate,
           OasisScanLocalState &lstate, const OasisScanBindData &bind, size_t group, bool defer_cpu_decode = false) {
	auto pending = make_uniq<OasisScanLocalState::PendingGroup>();
	pending->group = group;
	pending->num_rows = RowGroupNumRows(bind, group);
	pending->result = SubmitRowGroupSplinter(context, ctx, gstate, lstate, bind, group);
	pending->hw_buffers.assign(gstate.projected_columns.size(), nullptr);

	// Count the hardware columns we expect to collect from the single channel.
	pending->hw_columns_remaining = 0;
	for (const auto &col : gstate.projected_columns) {
		if (!col.is_cpu) {
			pending->hw_columns_remaining++;
		}
	}

	// Prefetch (defer_cpu_decode) submits only the hardware splinter -- the part that warms the FPGA
	// -- and leaves CPU/string columns for the worker that adopts the group to decode lazily. The CPU
	// reader is single-threaded and row-group-ordered, so decoding it on the prefetch worker would
	// serialize string decode across the whole prefetch window; the goal here is purely FPGA warmup.
	if (defer_cpu_decode && gstate.has_cpu_columns) {
		pending->cpu_decode_deferred = true;
		return pending;
	}

	// InitializeRead(...) does the page-header parsing / I/O positioning for the CPU/string columns,
	// then DecodeCpuColumns drains them in full. Both run while the FPGA splinters are in flight.
	if (gstate.has_cpu_columns) {
		lstate.root_reader->InitializeRead(group, lstate.parquet_reader->GetFileMetadata()->row_groups[group].columns,
		                                   *lstate.scan_state->thrift_file_proto);
	}
	DecodeCpuColumns(gstate, lstate, pending->num_rows, pending->cpu_slices);
	return pending;
}

static size_t ClaimNextMatchingGroup(ClientContext &context, OasisScanGlobalState &gstate,
                                     OasisScanLocalState &lstate, const OasisScanBindData &bind);

// Submits this scan's prefetch window: claims up to gstate.prefetch_groups matching row groups off
// the shared cursor and HW-submits each (CPU decode deferred), parking the warm PendingGroups in the
// global-state prefetch worker's inflight deque for live workers to adopt. Runs exactly once per
// scan, driven by OasisScanPrefetch when a predecessor pipeline drains and the executor fires the
// prefetch hook on this source. The shared cursor (gstate.next_group) guarantees prefetched groups
// are never re-claimed by live workers. Fires the waiter list once submitted to wake any worker that
// parked in ColdStartYield.
static void SubmitPrefetchWindow(ClientContext &context, oasis::OasisContext &ctx, OasisScanGlobalState &gstate,
                                 const OasisScanBindData &bind) {
	std::vector<OasisScanGlobalState::WakeFn> waiters;
	{
		std::lock_guard<std::mutex> guard(gstate.prefetch_mutex);
		if (gstate.prefetch_worker && gstate.prefetch_groups > 0) {
			auto &worker = *gstate.prefetch_worker;
			while (worker.inflight.size() < gstate.prefetch_groups) {
				size_t group = ClaimNextMatchingGroup(context, gstate, worker, bind);
				if (group >= gstate.total_groups) {
					break;
				}
				worker.inflight.push_back(
				    BeginGroup(context, ctx, gstate, worker, bind, group, /*defer_cpu_decode=*/true));
			}
		}
		gstate.prefetch_submitted.store(true, std::memory_order_release);
		// Take the waiter list under the lock; fire it outside so a woken worker's reschedule never
		// runs while we hold prefetch_mutex.
		waiters.swap(gstate.prefetch_waiters);
	}
	for (auto &wake : waiters) {
		wake();
	}
}

// Executor-driven prefetch hook (table_function.prefetch). Fired by Executor::PrefetchNextPipelines
// on this scan's source the instant its last predecessor pipeline stops submitting. Sets
// prefetch_expected so a worker that reaches this scan first yields instead of cold-starting, then
// submits the prefetch window exactly once. Self-contained: everything it needs is on the gstate.
static void OasisScanPrefetch(ClientContext &context, GlobalTableFunctionState &gstate_p) {
	auto &gstate = gstate_p.Cast<OasisScanGlobalState>();
	// Flag set first, before submitting, so a worker racing in between sees prefetch_expected and
	// yields rather than claiming a cold window. (A worker that checks between the flag and the window
	// being ready registers a waiter and is woken by SubmitPrefetchWindow below.)
	gstate.prefetch_expected.store(true, std::memory_order_release);
	if (gstate.prefetch_hook_fired.test_and_set()) {
		return; // already submitted by an earlier firing
	}
	if (!gstate.ctx || !gstate.bind_data) {
		return;
	}
	SubmitPrefetchWindow(context, *gstate.ctx, gstate, *gstate.bind_data);
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

// Phase 4: the first worker to run this scan drains the already-submitted prefetch window from the
// global state into its own inflight deque, inheriting a warm window instead of an empty one. The
// shared cursor guarantees these groups are never re-claimed. Only one worker adopts; later workers
// find the window empty and claim fresh groups. cpu_decode_deferred is left set -- the adopting
// worker decodes the CPU columns lazily when each group reaches the head (LoadNextGroup).
static void AdoptPrefetchWindow(OasisScanGlobalState &gstate, OasisScanLocalState &lstate) {
	if (lstate.adopted_prefetch || !gstate.prefetch_worker) {
		return;
	}
	lstate.adopted_prefetch = true;
	std::lock_guard<std::mutex> guard(gstate.prefetch_mutex);
	if (!gstate.prefetch_worker) {
		return;
	}
	auto &window = gstate.prefetch_worker->inflight;
	while (!window.empty()) {
		lstate.inflight.push_back(std::move(window.front()));
		window.pop_front();
	}
}

static void TopUpInflight(ClientContext &context, oasis::OasisContext &ctx, OasisScanGlobalState &gstate,
                          OasisScanLocalState &lstate, const OasisScanBindData &bind) {
	// Inherit any warm prefetched groups before claiming new ones (first call only).
	AdoptPrefetchWindow(gstate, lstate);

	while (!lstate.groups_exhausted && lstate.inflight.size() < gstate.groups_in_flight_per_worker) {
		size_t group = ClaimNextMatchingGroup(context, gstate, lstate, bind);
		if (group >= gstate.total_groups) {
			lstate.groups_exhausted = true;
			// The cursor is exhausted -- whichever worker observes this first has just claimed this
			// scan's last group. Tell the executor this pipeline has drained (exactly once); it owns
			// the dependency graph and fires prefetch on the genuinely-next pipeline's source,
			// overlapping this scan's drain tail with the successor's FPGA warmup.
			if (gstate.source_op && !gstate.last_splinter_fired.test_and_set()) {
				context.GetExecutor().PrefetchNextPipelines(*gstate.source_op);
			}
			break;
		}
		lstate.inflight.push_back(BeginGroup(context, ctx, gstate, lstate, bind, group));
	}
}

// Cold-start yield. If this scan is reached before its prefetch window has been submitted AND a
// predecessor is going to submit it (prefetch_expected, set by the executor's prefetch hook), yield
// (BLOCKED) instead of claiming a cold window ourselves, registering a wake that SubmitPrefetchWindow
// fires once the window lands. This overlaps the predecessor's drain tail with our warmup rather than
// racing it cold. A first scan never gets prefetch_expected -> never yields. Once we have kept a group
// in flight (warmed_up), we never take this path again -- normal BLOCKED-on-head behavior only.
// Returns true if the worker yielded (caller returns BLOCKED).
static bool ColdStartYield(OasisScanGlobalState &gstate, OasisScanLocalState &lstate, InterruptState interrupt_state) {
	if (lstate.warmed_up || gstate.prefetch_groups == 0) {
		return false;
	}
	// No predecessor will warm us (first scan / un-gated): claim cold, do not yield.
	if (!gstate.prefetch_expected.load(std::memory_order_acquire)) {
		return false;
	}
	// Already warm: proceed to adopt the submitted window.
	if (gstate.prefetch_submitted.load(std::memory_order_acquire)) {
		return false;
	}
	// A predecessor is warming us but the window has not landed yet -- park, registering a one-shot
	// wake under the same lock that guards the submitted flag and the waiter list, so we never miss the
	// transition (the window cannot be submitted between our check and the registration).
	auto guard = std::make_shared<std::atomic_flag>();
	std::lock_guard<std::mutex> lock(gstate.prefetch_mutex);
	if (gstate.prefetch_submitted.load(std::memory_order_acquire)) {
		return false; // landed between the check above and the lock: proceed (it is warm now).
	}
	gstate.prefetch_waiters.push_back([interrupt_state, guard]() {
		if (!guard->test_and_set()) {
			interrupt_state.Callback();
		}
	});
	return true;
}

static LoadResult LoadNextGroup(ClientContext &context, oasis::OasisContext &ctx, OasisScanGlobalState &gstate,
                                OasisScanLocalState &lstate, const OasisScanBindData &bind, InterruptState interrupt_state) {
	if (ColdStartYield(gstate, lstate, interrupt_state)) {
		return LoadResult::BLOCKED;
	}

	// Submit phase: Keep the pipeline full so later groups decode in hardware while we collect the head.
	TopUpInflight(context, ctx, gstate, lstate, bind);

	// Once we are keeping groups in flight, never take the cold-yield path again.
	if (!lstate.inflight.empty()) {
		lstate.warmed_up = true;
	}

	if (lstate.inflight.empty()) {
		return LoadResult::EXHAUSTED;
	}
	auto &head = *lstate.inflight.front();

	// Poll phase: Collect the head group's hardware buffers without blocking. If any column is still
    // outstanding, arm readiness callbacks and return BLOCKED so the worker thread is released.
	//
	// Arming and polling race against the completion thread, so we loop: The loop terminates
    // because each iteration either collects at least one more column or successfully arms every
    // remaining one.
	while (!TryCollectRowGroup(context, gstate, bind, head)) {
		if (ArmReadinessCallbacks(gstate, head, interrupt_state)) {
			return LoadResult::BLOCKED;
		}
	}

	// Adopted prefetch groups deferred their CPU/string decode (no local reader existed at prefetch
	// time). Decode them now, on this worker's reader, before the slices are consumed. No-op for
	// groups this worker decoded itself in BeginGroup.
	DecodeDeferredCpuColumns(gstate, lstate, bind, head);

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
	table_function.global_initialization = TableFunctionInitialization::INITIALIZE_ON_SCHEDULE;
	table_function.get_virtual_columns = OasisScanGetVirtualColumns;
	table_function.cardinality = OasisScanCardinality;
	table_function.statistics = OasisScanStatistics;
	table_function.table_scan_progress = OasisScanProgress;
	table_function.get_partition_data = OasisScanGetPartitionData;
	// Executor-driven cross-pipeline prefetch: the executor fires this on the genuinely-next
	// pipeline's source when its last predecessor drains (see Executor::PrefetchNextPipelines).
	table_function.prefetch = OasisScanPrefetch;
	loader.RegisterFunction(table_function);
}

} // namespace duckdb
