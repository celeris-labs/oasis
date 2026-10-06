#include "oasis_scan.hpp"

#include "coalesced_fetcher.hpp"
#include "column_reader.hpp"
#include "duckdb/common/exception.hpp"
#include "duckdb/common/multi_file/multi_file_options.hpp"
#include "duckdb/execution/operator/scan/physical_table_scan.hpp"
#include "duckdb/function/partition_stats.hpp"
#include "duckdb/logging/logger.hpp"
#include "duckdb/main/database.hpp"
#include "duckdb/main/profiler/profiling_node.hpp"
#include "duckdb/parallel/task_scheduler.hpp"
#include "duckdb/planner/expression/bound_cast_expression.hpp"
#include "duckdb/planner/operator/logical_get.hpp"
#include "duckdb/storage/statistics/numeric_stats.hpp"
#include "duckdb/main/extension/extension_loader.hpp"
#include "oasis/oasis_context.hpp"
#include "oasis/operator.hpp"
#include "oasis/query_splinter.hpp"
#include "oasis_hardware_bloom.hpp"
#include "parcore/configuration.hpp"
#include "parcore_metadata_util.hpp"
#include "parquet_reader.hpp"
#include "thrift_tools.hpp"
#include "rdma_file_system.hpp"
#include "reader/struct_column_reader.hpp"
#include "filter_pushdown.hpp"

#include <coyote/cThread.hpp>
#include <libstf/configuration.hpp>

#include <algorithm>
#include <chrono>
#include <limits>
#include <optional>
#include <string>
#include <utility>
#include <vector>

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
                                       vector<LogicalType> &return_types, vector<Identifier> &names) {
	auto parquet_file = StringValue::Get(input.inputs[0]);

	ParquetOptions parquet_opts(context);
	ParquetReader parquet_reader(context, OpenFileInfo {parquet_file}, parquet_opts);

	auto bind_data = make_uniq<OasisScanBindData>();

	for (auto &col : parquet_reader.columns) {
		names.push_back(col.name);
		return_types.push_back(col.type);
		bind_data->column_types.push_back(col.type);
	}
	bind_data->output_types = bind_data->column_types;

	auto meta = BuildParcoreMetadata(parquet_reader);
	if (meta.groups.empty()) {
		throw InvalidInputException("Parquet file contains no row groups");
	}
	bind_data->metadata = std::move(meta);
	bind_data->bloom_dense_columns = ComputeBloomDenseColumns(parquet_reader);
	bind_data->filename = parquet_file;

	bind_data->parquet_metadata = parquet_reader.metadata;
	bind_data->metadata_reader = ParquetReader::CreateMetadataReader(context, parquet_opts, parquet_reader.metadata);

	return std::move(bind_data);
}

// DuckDB type whose physical layout matches what the FPGA writes for a libstf type.
static LogicalType HardwareOutputType(libstf::type_t type) {
	switch (type) {
	case libstf::type_t::BYTE_T:
		return LogicalType::BOOLEAN;
	case libstf::type_t::INT16_T:
		return LogicalType::SMALLINT;
	case libstf::type_t::INT32_T:
		return LogicalType::INTEGER;
	case libstf::type_t::INT64_T:
		return LogicalType::BIGINT;
	case libstf::type_t::FLOAT_T:
		return LogicalType::FLOAT;
	case libstf::type_t::DOUBLE_T:
		return LogicalType::DOUBLE;
	default:
		throw InternalException("Unexpected libstf type");
	}
}

// Hardware type of the integer types a pushed-down cast can narrow a column to. The decoders
// narrow by truncation, which is correct for unsigned targets too when the values fit.
static std::optional<libstf::type_t> CastHardwareType(const LogicalType &type) {
	switch (type.id()) {
	case LogicalTypeId::INTEGER:
	case LogicalTypeId::UINTEGER:
		return libstf::type_t::INT32_T;
	case LogicalTypeId::SMALLINT:
	case LogicalTypeId::USMALLINT:
		return libstf::type_t::INT16_T;
	case LogicalTypeId::TINYINT:
	case LogicalTypeId::UTINYINT:
		return libstf::type_t::BYTE_T;
	default:
		return std::nullopt;
	}
}

// DuckDB's TYPE_PUSHDOWN offers the cast of a column that the query only uses cast, e.g. the
// BIGINT -> INTEGER casts of compressed join keys. We accept integer narrowing casts that the
// decoders can do, when the file statistics prove that every value fits the target type: Then the
// cast can neither fail nor change a value, so CAST and TRY_CAST are the same. The scan outputs
// the narrow type and DuckDB drops the cast.
static bool OasisScanPushdownCast(ClientContext &context, const TableFunctionProjectionExpressionInput &input) {
	if (!BoundCastExpression::IsCast(input.expr)) {
		return false;
	}
	Value pushdown_val;
	context.TryGetCurrentSetting("oasis_cast_pushdown", pushdown_val);
	if (pushdown_val.IsNull() || !pushdown_val.GetValue<bool>()) {
		return false;
	}

	const auto &column_id = input.get.GetColumnIds()[input.column_index];
	if (column_id.IsVirtualColumn() || column_id.IsPushdownExtract()) {
		return false;
	}
	// A filter pushed into the scan is bound to the type of the column before the cast
	if (input.get.table_filters.HasFilter(input.column_index)) {
		return false;
	}
	auto &bind = input.get.bind_data->CastNoConst<OasisScanBindData>();
	const idx_t col_id = column_id.GetPrimaryIndex();
	if (col_id >= bind.column_types.size()) {
		return false;
	}

	// Only plain signed integer columns, whose statistics are the stored values (unlike DECIMAL or
	// temporal types), and only casts to a narrower signed or unsigned integer type.
	const auto &source = bind.column_types[col_id];
	const auto &target = input.expr.GetReturnType();
	const auto cast_type = CastHardwareType(target);
	if ((source.id() != LogicalTypeId::BIGINT && source.id() != LogicalTypeId::INTEGER &&
	     source.id() != LogicalTypeId::SMALLINT) ||
	    !cast_type || GetTypeIdSize(target.InternalType()) >= GetTypeIdSize(source.InternalType())) {
		return false;
	}
	const auto &chunk = bind.metadata.groups[0].chunks[col_id];
	if (!parcore::metadata::is_libstf_type(chunk.type)) {
		return false;
	}
	if (!parcore::ColumnChunkDecoderConfig::supports_cast(parcore::metadata::to_libstf_type(chunk.type), *cast_type)) {
		return false;
	}

	// The file statistics only have min/max if every row group has them
	const auto &name = bind.metadata.column_names[col_id];
	auto stats = bind.metadata_reader->GetStatistics(context, Identifier(name));
	if (!stats || !NumericStats::HasMinMax(*stats) ||
	    NumericStats::Min(*stats).GetValue<int64_t>() < Value::MinimumValue(target).GetValue<int64_t>() ||
	    NumericStats::Max(*stats).GetValue<int64_t>() > Value::MaximumValue(target).GetValue<int64_t>()) {
		return false;
	}

	bind.output_types[col_id] = target;
	DUCKDB_LOG_DEBUG(context, "Pushed cast of column '%s' from %s to %s into read_oasis.", name.c_str(),
	                 source.ToString().c_str(), target.ToString().c_str());
	return true;
}
// DuckDB type whose physical layout matches what the FPGA writes for a libstf type.
static LogicalType HardwareOutputType(libstf::type_t type) {
	switch (type) {
	case libstf::type_t::BYTE_T:
		return LogicalType::BOOLEAN;
	case libstf::type_t::INT32_T:
		return LogicalType::INTEGER;
	case libstf::type_t::INT64_T:
		return LogicalType::BIGINT;
	case libstf::type_t::FLOAT_T:
		return LogicalType::FLOAT;
	case libstf::type_t::DOUBLE_T:
		return LogicalType::DOUBLE;
	default:
		throw InternalException("Unexpected libstf type");
	}
}
// What the runtime Bloom filter's build side needs, see PrepareBloomBuild
struct BloomBuildPlan {
	size_t probe_slot;                      // Projected column of the probe key
	parcore::metadata::Metadata build_meta; // Of the build file
	size_t build_col_id;                    // Build key column in build_meta
};

// DuckDB type whose physical layout matches what the FPGA writes for a libstf type.
static LogicalType HardwareOutputType(libstf::type_t type) {
	switch (type) {
	case libstf::type_t::BYTE_T:
		return LogicalType::BOOLEAN;
	case libstf::type_t::INT32_T:
		return LogicalType::INTEGER;
	case libstf::type_t::INT64_T:
		return LogicalType::BIGINT;
	case libstf::type_t::FLOAT_T:
		return LogicalType::FLOAT;
	case libstf::type_t::DOUBLE_T:
		return LogicalType::DOUBLE;
	default:
		throw InternalException("Unexpected libstf type");
	}
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
	if (input.op && input.op->type == PhysicalOperatorType::TABLE_SCAN) {
		gstate->physical_scan = &input.op->Cast<PhysicalTableScan>();
	}

	Value groups_in_flight_val;
	context.TryGetCurrentSetting("oasis_prefetch_depth", groups_in_flight_val);
	size_t const groups_in_flight = groups_in_flight_val.IsNull() ? 2 : groups_in_flight_val.GetValue<uint64_t>();
	gstate->synchronous = groups_in_flight == 0;
	gstate->groups_in_flight_per_worker = std::max<size_t>(1, groups_in_flight);

	Value yield_val;
	context.TryGetCurrentSetting("oasis_enable_yield", yield_val);
	gstate->yield_enabled = yield_val.IsNull() || yield_val.GetValue<bool>();

	Value narrow_val;
	context.TryGetCurrentSetting("oasis_narrow_transfer", narrow_val);
	gstate->narrow_transfer = !narrow_val.IsNull() && narrow_val.GetValue<bool>();

	for (auto col_id : input.column_ids) {
		const auto &chunk = bind_data.metadata.groups[0].chunks[col_id];
		if (parcore::metadata::is_libstf_type(chunk.type)) {
			const auto &column_type = bind_data.output_types[col_id];
			// A cast pushed into the scan is done by the decoders
			std::optional<libstf::type_t> cast_type;
			if (column_type != bind_data.column_types[col_id]) {
				cast_type = CastHardwareType(column_type);
			}
			const auto logical_type = cast_type.value_or(chunk.logical_type());
			const auto duckdb_size = GetTypeIdSize(column_type.InternalType());
			if (libstf::size_of(logical_type) != duckdb_size) {
				throw NotImplementedException(
				    "read_oasis: column '%s' has DuckDB type %s (%llu bytes) but is decoded in hardware as %s "
				    "(%llu bytes).",
				    bind_data.metadata.column_names[col_id].c_str(), column_type.ToString().c_str(),
				    (unsigned long long)duckdb_size, HardwareOutputType(logical_type).ToString().c_str(),
				    (unsigned long long)libstf::size_of(logical_type));
			}
			// Only signed 64-bit values stored as they are are narrowed, so sign-extending the INT32
			// restores them. Statistics of other types (e.g. TIMESTAMP_MS) are in converted units.
			const bool narrowable =
			    logical_type == libstf::type_t::INT64_T &&
			    (column_type.id() == LogicalTypeId::BIGINT ||
			     (column_type.id() == LogicalTypeId::DECIMAL && column_type.InternalType() == PhysicalType::INT64));
			gstate->projected_columns.push_back({col_id, duckdb_size, false, narrowable, cast_type});
		} else {
			// CPU path: Variable-length type (BYTE_ARRAY/string) decoded by DuckDB's ColumnReader.
			gstate->projected_columns.push_back({col_id, 0, true});
			gstate->has_cpu_columns = true;
		}
	}

	// filter_prune: When the plan consumes fewer columns than we scan (some are filter-only),
	// remember which projected columns are emitted so the scan can skip decoding the rest and
	// reference only the consumed columns into the output chunk.
	gstate->can_prune = input.CanRemoveFilterColumns();
	gstate->column_emitted.assign(gstate->projected_columns.size(), !gstate->can_prune);
	if (gstate->can_prune) {
		gstate->projection_ids.assign(input.projection_ids.begin(), input.projection_ids.end());
		for (auto proj_id : gstate->projection_ids) {
			gstate->column_emitted[proj_id] = true;
		}
	}

	// Register a cold-start yield budget -- roughly one yield per prospective worker, so during cold
	// start workers step aside to let others prime the pipeline breadth-first. DuckDB clamps this
	// scan's parallelism to min(MaxThreads(), scheduler threads), and MaxThreads() is total_groups.
	// INITIALIZE_ON_SCHEDULE runs this eagerly at schedule time, so we know that count before any
	// worker executes. Budget is consumed only by yields that actually happen, so any unused
	// remainder is harmless -- no reconciliation needed.
	if (gstate->yield_enabled && !gstate->synchronous) {
	// The runtime Bloom filter's build side goes to the hardware once per scan, before any worker
	// submits a probe key chunk. The filter is only taken if the scan can use it.
	if (bind_data.runtime_bloom_enabled && !gstate->emit_cardinality_only) {
		auto plan = PrepareBloomBuild(context, bind_data, *gstate);
		if (plan && TryAcquireBloomFilter(context, *gstate)) {
			SubmitBloomBuild(context, ctx, bind_data, *plan, *gstate);
		}
	}

	// Register a cold-start yield budget for hardware scans -- roughly one yield per prospective
	// worker, so during cold start workers step aside to let others prime the pipeline breadth-first.
	// The cardinality-only path never touches the hardware, so it registers nothing. DuckDB clamps
	// this scan's parallelism to min(MaxThreads(), scheduler threads), and MaxThreads() is
	// total_groups; INITIALIZE_ON_SCHEDULE runs this eagerly at schedule time so we know that count
	// before any worker executes. Budget is consumed only by yields that actually happen, so any
	// unused remainder is harmless -- no reconciliation needed.
	if (!gstate->emit_cardinality_only && gstate->yield_enabled && !gstate->synchronous) {
		size_t const num_threads =
		    std::max<size_t>(1, static_cast<size_t>(TaskScheduler::GetScheduler(context).NumberOfThreads()));
		size_t const yield_budget = std::max<size_t>(1, std::min<size_t>(gstate->total_groups, num_threads));
		ctx.add_yield_budget(yield_budget);
	}

	return std::move(gstate);
}

static void TopUpPrefetch(ClientContext &context, oasis::OasisContext &ctx, OasisScanGlobalState &gstate,
                          OasisScanLocalState &lstate, const OasisScanBindData &bind);

unique_ptr<LocalTableFunctionState> OasisScanInitLocal(ExecutionContext &context, TableFunctionInitInput &input,
                                                       GlobalTableFunctionState *global_state_p) {
	auto &gstate = global_state_p->Cast<OasisScanGlobalState>();
	auto &bind_data = input.bind_data->Cast<OasisScanBindData>();
	auto lstate = make_uniq<OasisScanLocalState>();

	// Merge in the dynamic join filters, which did not exist yet when the global state was
	// created at schedule time. The build side has completed by now (pipeline dependency), so the
	// set is final. call_once publishes gstate.filters to every worker before it builds its
	// per-worker filter states below.
	std::call_once(gstate.dynamic_filter_merge, [&]() {
		if (!gstate.physical_scan) {
			return;
		}
		auto &dynamic_filters = gstate.physical_scan->dynamic_filters;
		if (dynamic_filters && dynamic_filters->HasFilters()) {
			gstate.merged_filters = dynamic_filters->GetFinalTableFilters(*gstate.physical_scan, gstate.filters);
			if (gstate.merged_filters) {
				gstate.filters = gstate.merged_filters.get();
			}
		}
	});

	// Each worker owns its own file handle: DuckDB FileHandles are not safe to share across threads,
	// and the local source path reads from it on this worker thread.
	auto &fs = FileSystem::GetFileSystem(context.client);
	lstate->file_handle = fs.OpenFile(gstate.filename, FileOpenFlags::FILE_FLAGS_READ);
	lstate->bloom_active = gstate.bloom_active;

	// Build a per-worker ParquetReader: its per-column readers supply the per-column-chunk statistics
	// used for row-group skipping (RowGroupMatchesFilters). The CPU decode path additionally drives
	// these readers in OasisScanFunction. We project every file column (one FULL_READ ColumnIndex per
	// column), so scan_state->GetColumnReader(col_id) is keyed directly by file column id.
	ParquetOptions parquet_opts(context.client);
	lstate->parquet_reader = make_uniq<ParquetReader>(context.client, OpenFileInfo {gstate.filename}, parquet_opts,
	                                                  bind_data.parquet_metadata);
	for (idx_t c = 0; c < lstate->parquet_reader->columns.size(); c++) {
		lstate->parquet_reader->column_indexes.emplace_back(c);
	}
	lstate->scan_state = make_uniq<ParquetReaderScanState>();

	// Creates the per-column readers, which the row-group statistics use. InitGroupCPUColumns
	// re-initializes the scan state for every group it decodes on the CPU.
	lstate->parquet_reader->InitializeScan(context.client, *lstate->scan_state, 0);

	// Full-width staging chunk for filter pruning: Slices are scanned and filtered here, and only
	// the projection_ids columns are referenced into the (narrower) output chunk.
	if (gstate.can_prune) {
		vector<LogicalType> scan_types;
		scan_types.reserve(gstate.projected_columns.size());
		for (auto &col : gstate.projected_columns) {
			scan_types.push_back(bind_data.output_types[col.column_id]);
		}
		lstate->all_columns.Initialize(context.client, scan_types);
	}

	// Prepare the pushed-down filters for row-level filtering (one TableFilterState per filter,
	// owned by this worker), splitting top-level ANDs into per-conjunct filters (BuildScanFilters).
	if (gstate.filters) {
		BuildScanFilters(context.client, *gstate.filters, gstate, bind_data, lstate->scan_filters);
	}
	Value duckdb_bloom_filter;
	bool enable_duckdb_bloom = false;
	if (context.client.TryGetCurrentSetting("oasis_duckdb_bloom_filter", duckdb_bloom_filter) && !duckdb_bloom_filter.IsNull()) {
		enable_duckdb_bloom = duckdb_bloom_filter.GetValue<bool>();
	}

	if (!enable_duckdb_bloom) {
		std::vector<OasisScanFilter> new_filters;
		for (auto &f : lstate->scan_filters) {
			if (!IsDuckDBJoinBloomFilter(f.filter)) {
				new_filters.push_back(std::move(f));
			}
		}
		lstate->scan_filters = std::move(new_filters);
	}

	return std::move(lstate);
}

// Whether the chunk of the column in the group can be transferred as INT32: its statistics exist and
// both bounds fit.
static bool ChunkFitsInt32(OasisScanLocalState &lstate, size_t group, size_t column_id) {
	const auto &pq_columns = lstate.parquet_reader->GetFileMetadata()->row_groups[group].columns;
	auto stats = lstate.scan_state->GetColumnReader(column_id).Stats(group, pq_columns);
	if (!stats || !NumericStats::HasMinMax(*stats)) {
		return false;
	}
	return NumericStats::GetMin<int64_t>(*stats) >= NumericLimits<int32_t>::Minimum() &&
	       NumericStats::GetMax<int64_t>(*stats) <= NumericLimits<int32_t>::Maximum();
}

static std::unique_ptr<oasis::SourceOperator> MakeRDMASource(RDMAFileHandle &rdma,
                                                             const parcore::metadata::ColumnChunk &cc) {
	return std::make_unique<oasis::RDMASourceOperator>(rdma.remote_offset + cc.offset, cc.total_compressed_size);
}

// Every column chunk in a row group shares its row count. Take it from the first chunk.
static uint64_t RowGroupNumRows(const OasisScanBindData &bind, size_t group) {
	const auto &chunks = bind.metadata.groups[group].chunks;
	return chunks.empty() ? 0 : chunks[0].num_values;
}

OasisScanGlobalState::~OasisScanGlobalState() {
	TeardownHardwareBloom(ctx, bloom_build, bloom_filter_held, bloom_active, bloom_build_submitted);
}

OasisScanLocalState::~OasisScanLocalState() {
	if (bloom_active) {
		DrainInFlightBloomProbeSplinters(*this);
	}
}


// Submits the whole row group as one QuerySplinter: one decode flow per hardware column and, on
// the RDMA path, one raw bypass flow per CPU column fetching its compressed bytes. Each flow's
// sink is tagged with the projection index. The consumer places the tagged batches into
// hw_buffers[projection_index] / cpu_buffers[projection_index]. For RDMA, the hardware pulls bytes
// straight into the streams. On the local path the hardware-column bytes are read coalesced, 
// synchronously on the worker, before submission.
static void PrefetchGroup(ClientContext &context, oasis::OasisContext &ctx, OasisScanGlobalState &gstate,
                          OasisScanLocalState &lstate, const OasisScanBindData &bind,
                          OasisScanLocalState::PendingGroup &pending) {
	const size_t group = pending.group;
	auto *rdma = dynamic_cast<RDMAFileHandle *>(lstate.file_handle.get());

	// Collect the column chunks that will be decoded in hardware, and (RDMA only) the CPU column
	// chunks whose bytes the splinter fetches over the bypass stream.
	pending.hw_slot.reserve(gstate.projected_columns.size());
	pending.hw_chunks.reserve(gstate.projected_columns.size());
	pending.narrowed.assign(gstate.projected_columns.size(), false);
	for (size_t i = 0; i < gstate.projected_columns.size(); i++) {
		const auto &col = gstate.projected_columns[i];
		if (col.is_cpu) {
			if (rdma) {
				pending.cpu_slot.push_back(i);
				pending.cpu_chunks.push_back(&bind.metadata.groups[group].chunks[col.column_id]);
			}
			continue;
		}

		const auto &cc = bind.metadata.groups[group].chunks[col.column_id];

		pending.narrowed[i] = gstate.narrow_transfer && col.narrowable && ChunkFitsInt32(lstate, group, col.column_id);

		// Enforce the one-buffer-per-chunk invariant: the decoded output must fit in a single FPGA
		// output buffer. num_values is the row count, the element width is the transfer width.
		const size_t decoded_size = cc.num_values * (pending.narrowed[i] ? sizeof(int32_t) : col.elem_size);
		if (decoded_size > libstf::MAXIMUM_OUTPUT_WRITER_BUFFER_SIZE) {
			throw NotImplementedException(
			    "Column '%s' row group %llu decodes to %llu bytes, exceeding the %llu byte maximum "
			    "output buffer size.",
			    bind.metadata.column_names[col.column_id].c_str(), (unsigned long long)group,
			    (unsigned long long)decoded_size, (unsigned long long)libstf::MAXIMUM_OUTPUT_WRITER_BUFFER_SIZE);
		}

		pending.hw_slot.push_back(i);
		pending.hw_chunks.push_back(&cc);
	}

	if (!rdma) {
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

		// Coalesced, synchronous read of every merged range on this worker thread.
		// Note: Tried to also make this asynchronous which lead to significantly worse performance.
		for (size_t idx = 0; idx < pending.fetcher->num_reads(); idx++) {
			pending.fetcher->ExecuteMergedRead(idx);
		}
		DUCKDB_LOG_DEBUG(context, "Coalesced %llu column chunk(s) into %llu read(s) (%llu bytes) for row group %llu.",
		                 (unsigned long long)pending.fetcher->num_ranges(),
		                 (unsigned long long)pending.fetcher->num_reads(),
		                 (unsigned long long)pending.fetcher->bytes_fetched(), (unsigned long long)group);
	}

	// Build the QuerySplinter for the whole row group -- one decode flow per hardware column, one
	// raw bypass flow per CPU column (RDMA only). The scheduler capability-matches and
	// load-balances the flows across the hardware streams and closes the handle once all finish.
	oasis::QuerySplinter splinter;
	splinter.streams.reserve(pending.hw_slot.size() + pending.cpu_slot.size() + 1);

	// Every hardware column-chunk decode flow lands on a DECODE-capability stream, and stream 0
	// always routes through the Bloom filter's select-gated demultiplexer, so it needs its own
	// queued select decision -- pushed first, before the source triggers the transfer, so it's
	// queued ahead of any data that could reach the demultiplexer.
	auto append_decode_chunk = [&](oasis::OperatorFlow &flow, size_t k,
	                               std::unique_ptr<BloomFilterStreamSelectOperator> select, size_t sink_size,
	                               size_t tag) {
		const auto &cc = *pending.hw_chunks[k];
		const auto &col = gstate.projected_columns[pending.hw_slot[k]];
		auto type = parcore::metadata::to_libstf_type(cc.type);
		auto logical_type =
		    pending.narrowed[pending.hw_slot[k]] ? libstf::type_t::INT32_T : col.cast_type.value_or(cc.logical_type());

		oasis::OperatorFlow flow;
		flow.push_back(std::move(select));
		if (rdma) {
			flow.push_back(MakeRDMASource(*rdma, cc));
		} else {
			flow.push_back(MakeHostSource(pending.fetcher->Resolve(pending.host_handles[k])));
		}
		flow.push_back(std::make_unique<oasis::DecodeColumnChunkOperator>(cc.compression, cc.num_values, type,
		                                                                   cc.is_required, logical_type));
		auto sink_buffer = ctx.allocate_output_buffer(cc.num_values * libstf::size_of(logical_type));
		flow.push_back(std::make_unique<oasis::LocalSinkOperator>(std::move(sink_buffer), pending.hw_slot[k]));
		flow.push_back(std::make_unique<oasis::DecodeColumnChunkOperator>(
		    cc.compression, cc.num_values, parcore::metadata::to_libstf_type(cc.type)));
		flow.push_back(std::make_unique<oasis::LocalSinkOperator>(ctx.allocate_output_buffer(sink_size), tag));
	};
	auto decoded_size = [&](size_t k) {
		const auto &cc = *pending.hw_chunks[k];
		return cc.num_values * libstf::size_of(parcore::metadata::to_libstf_type(cc.type));
	};

	pending.materialized.assign(gstate.projected_columns.size(), false);
	std::vector<bool> is_bypassed(pending.hw_slot.size(), true);
	size_t bloom_mask_flows = 0;

	// The runtime Bloom filter filters the whole row group. Its probe key chunk goes through the
	// filter (FILTER) for its mask, one bit per row. The 64-bit columns (the key column included)
	// follow it into the filter's materializer (MATERIALIZE), which only returns their kept rows.
	// All Bloom filter transfers for this row group (the probe key match mask followed by the
	// 64-bit materialized columns) are unified into a single OperatorFlow. Because a flow is
	// scheduled atomically onto a single stream, no other flow can be interleaved between the
	// FILTER mask transfer and its subsequent MATERIALIZE transfers.
	// The other columns are decoded as usual and dropped by the mask on the CPU (see EmitOneSlice).
	//
	// Every probe chunk is sent with CONTINUE: no worker knows which chunk will be the last one
	// (groups are claimed dynamically and pruned), so the probe side is ended with END once
	// the whole scan is done (see ~OasisScanGlobalState).
	if (gstate.bloom_active) {
		splinter.streams.push_back(ConstructBloomProbeFlow(ctx, pending, rdma,
		                                                   gstate.bloom_probe_key_slot, gstate.projected_columns,
		                                                   bind.bloom_dense_columns, is_bypassed));
		bloom_mask_flows = 1;
	}

	for (size_t k = 0; k < pending.hw_slot.size(); k++) {
		if (is_bypassed[k]) {
			splinter.streams.push_back(ConstructBypassFlow(ctx, pending, rdma, k));
		}
	}
	pending.batches_remaining = pending.hw_slot.size() + bloom_mask_flows;

	// Raw fetch of each CPU column's compressed bytes: an RDMA source writing directly into one
	// sink whose buffers split the transfer into FPGA output-buffer-sized chunks, tagged with the
	// column's projection index. Each buffer surfaces as its own batch.
	for (size_t k = 0; k < pending.cpu_slot.size(); k++) {
		const auto &cc = *pending.cpu_chunks[k];

		oasis::OperatorFlow flow;
		flow.push_back(MakeRDMASource(*rdma, cc));
		std::vector<std::shared_ptr<libstf::Buffer>> sink_buffers;
		size_t remaining = cc.total_compressed_size;
		while (remaining > 0) {
			size_t chunk = std::min<size_t>(remaining, libstf::MAXIMUM_OUTPUT_WRITER_BUFFER_SIZE);
			sink_buffers.push_back(ctx.allocate_output_buffer(chunk));
			remaining -= chunk;
			pending.batches_remaining++;
		}
		flow.push_back(std::make_unique<oasis::LocalSinkOperator>(std::move(sink_buffers), pending.cpu_slot[k]));
		splinter.streams.push_back(std::move(flow));
	}

	pending.hw_buffers.assign(gstate.projected_columns.size(), nullptr);
	pending.cpu_buffers.assign(gstate.projected_columns.size(), {});

	// A group with nothing to fetch or decode in hardware (e.g. a string-only projection on the
	// local path) submits no splinter and leaves `result` default-constructed.
	if (pending.batches_remaining == 0) {
		return;
	}

	const size_t num_flows = splinter.streams.size();
	pending.result = ctx.scheduler().submit(std::move(splinter));
	pending.submitted = true;
	DUCKDB_LOG_DEBUG(context, "Submitted QuerySplinter (%llu flow(s)) for row group %llu.",
	                 (unsigned long long)num_flows, (unsigned long long)group);
}

// Positions the shared CPU readers at the start of `group`'s CPU/string columns (page-header
// parsing / I/O positioning) and bulk-prefetches their column-chunk bytes.
//
// Without this prefetch the thrift transport falls back to a raw synchronous file read for every
// page header and page body (thrift_tools.hpp read()), i.e. hundreds of tiny pread()s per string
// column per group on the worker thread. This was completely tanking performance.
static void InitGroupCPUColumns(ClientContext &context, OasisScanGlobalState &gstate, OasisScanLocalState &lstate,
                                size_t group) {
	if (!gstate.has_cpu_columns) {
		return;
	}
	// Page-header parsing and prefetch staging are part of the string-column decode cost.
	ScopedTimer timer(lstate.string_decode_time_ns);
	// Recreate the readers (and thrift protocol) for every group: ColumnReader carries page state
	// and deferred skips that are only valid within one row group, and the filtered decode path
	// can leave a group mid-page with skips still pending (rejected or filter-only column tails).
	// Discarding the readers with the group makes those leftovers harmless -- and the skipped tail
	// pages are never touched at all. The file handle (and any RDMA-staged ranges) is kept.
	lstate.parquet_reader->InitializeScan(context, *lstate.scan_state, group);
	const auto &row_group_columns = lstate.parquet_reader->GetFileMetadata()->row_groups[group].columns;
	auto &trans = reinterpret_cast<ThriftFileTransport &>(*lstate.scan_state->thrift_file_proto->getTransport());
	trans.ClearPrefetch();
	// On the RDMA path every CPU column's bytes are already staged on the handle, so each column
	// gets its own read head and is served entirely from host memory. Letting the transport merge
	// neighbouring string columns into one read head would span the hardware-decoded columns in
	// between, and those bytes are not staged: every such "gap" turns into a synchronous RDMA
	// round trip on this worker thread, on the bypass stream, while the decoders are busy with
	// the next group. On the local path merging still pays off (fewer file reads).
	const bool rdma_path =
	    dynamic_cast<RDMAFileHandle *>(lstate.scan_state->file_handle->GetFileHandle().get()) != nullptr;
	for (const auto &col : gstate.projected_columns) {
		if (col.is_cpu) {
			auto &reader = lstate.scan_state->GetColumnReader(col.column_id);
			reader.InitializeRead(group, lstate.parquet_reader->GetFileMetadata()->row_groups[group].num_rows,
			                      row_group_columns, *lstate.scan_state->thrift_file_proto);
			reader.RegisterPrefetch(trans, /*allow_merge=*/!rdma_path);
		}
	}
	trans.FinalizeRegistration();
	trans.PrefetchRegistered();
}

// Non-blocking: Drains the row group's result handle, placing each tagged batch into
// pending.hw_buffers[tag] (decoded hardware column) or pending.cpu_buffers[tag] (raw compressed
// CPU column bytes, appended in file order). Returns true if collecting the row group was
// successful.
static bool TryCollectGroup(ClientContext &context, OasisScanGlobalState &gstate, const OasisScanBindData &bind,
                            OasisScanLocalState::PendingGroup &pending) {
	while (pending.batches_remaining > 0) {
		auto poll = pending.result.try_get_next_batch();
		if (!poll.ready) {
			return false; // Nothing ready yet; come back after a readiness wake.
		}
		if (!poll.batch) {
			// Channel closed but batches are still outstanding -- a flow produced no output.
			throw InternalException("Row group %llu closed with %llu batch(es) missing",
			                        (unsigned long long)pending.group,
			                        (unsigned long long)pending.batches_remaining);
		}
		size_t const tag = poll.batch->tag;
		if (tag == gstate.projected_columns.size()) {
			// Reserved tag for the runtime Bloom filter's probe-key match mask (see PrefetchGroup) --
			// not a projected column, so it doesn't index into gstate.projected_columns.
			DUCKDB_LOG_DEBUG(context, "Row group %llu returned Bloom filter mask batch",
			                 (unsigned long long)pending.group);
			pending.bloom_mask_buffer = std::move(poll.batch->buffer);
			pending.batches_remaining--;
			continue;
		}
		size_t const col_id = gstate.projected_columns[tag].column_id;
		DUCKDB_LOG_DEBUG(context, "Row group %llu, column %llu ('%s') returned batch",
		                 (unsigned long long)pending.group, (unsigned long long)col_id,
		                 bind.metadata.column_names[col_id].c_str());
		if (gstate.projected_columns[tag].is_cpu) {
			pending.cpu_buffers[tag].push_back(std::move(poll.batch->buffer));
		} else {
			pending.hw_buffers[tag] = std::move(poll.batch->buffer);
		}
		pending.batches_remaining--;
	}
	return true;
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

// Claims the next non-empty row group that also survives filter pruning, filling
// `needs_row_filter` for the claimed group (see RowGroupMatchesFilters).
static size_t ClaimNextMatchingGroup(ClientContext &context, OasisScanGlobalState &gstate, OasisScanLocalState &lstate,
                                     const OasisScanBindData &bind, std::vector<bool> &needs_row_filter) {
	while (true) {
		size_t group = ClaimNextNonEmptyGroup(gstate, bind);
		if (group >= gstate.total_groups) {
			return gstate.total_groups;
		}
		if (RowGroupMatchesFilters(context, gstate, lstate, group, needs_row_filter)) {
			return group;
		}
	}
}

enum class LoadResult : uint8_t { LOADED, BLOCKED, EXHAUSTED };

// Keeps the pipeline full: Claims matching groups up to the per-worker budget and runs
// PrefetchGroup on each (synchronous coalesced reads + splinter submission), so later groups decode
// in hardware while we collect the head.
static void TopUpPrefetch(ClientContext &context, oasis::OasisContext &ctx, OasisScanGlobalState &gstate,
                          OasisScanLocalState &lstate, const OasisScanBindData &bind) {
	while (!lstate.groups_exhausted && lstate.inflight.size() < gstate.groups_in_flight_per_worker) {
		std::vector<bool> needs_row_filter;
		size_t group = ClaimNextMatchingGroup(context, gstate, lstate, bind, needs_row_filter);
		if (group >= gstate.total_groups) {
			lstate.groups_exhausted = true;
			break;
		}
		auto pending = make_uniq<OasisScanLocalState::PendingGroup>();
		pending->group = group;
		pending->num_rows = RowGroupNumRows(bind, group);
		pending->needs_row_filter = std::move(needs_row_filter);
		PrefetchGroup(context, ctx, gstate, lstate, bind, *pending);
		lstate.inflight.push_back(std::move(pending));
	}
}

static LoadResult GetNextGroup(ClientContext &context, oasis::OasisContext &ctx, OasisScanGlobalState &gstate,
                               OasisScanLocalState &lstate, const OasisScanBindData &bind,
                               std::vector<unique_ptr<AsyncTask>> &out_tasks) {
	// Keep the pipeline full so later groups decode in hardware while we collect the head.
	TopUpPrefetch(context, ctx, gstate, lstate, bind);

	if (lstate.inflight.empty()) {
		return LoadResult::EXHAUSTED;
	}

	auto &head = *lstate.inflight.front();

	// A group with nothing to fetch or decode in hardware (string-only projection on the local
	// path) submitted no splinter, so skip straight to loading the string columns.
	if (head.submitted) {
		if (gstate.synchronous) {
			while (!TryCollectGroup(context, gstate, bind, head)) {
				head.result.wait_ready();
			}
		} else {
			if (gstate.yield_enabled && ctx.try_consume_yield()) {
				out_tasks.push_back(make_uniq<OasisSplinterResultTask>(head.result));
				return LoadResult::BLOCKED;
			}

			if (!TryCollectGroup(context, gstate, bind, head)) {
				out_tasks.push_back(make_uniq<OasisSplinterResultTask>(head.result));
				return LoadResult::BLOCKED;
			}
		}
	}

	// The materialized columns have to hold exactly the rows the Bloom filter's mask kept
	if (head.bloom_mask_buffer) {
		VerifyBloomMaterializedBuffers(*head.bloom_mask_buffer, head.num_rows, head.group,
		                               head.materialized, head.hw_buffers);
	}

	lstate.current_buffers = std::move(head.hw_buffers);
	lstate.current_narrowed = std::move(head.narrowed);
	lstate.current_bloom_mask = std::move(head.bloom_mask_buffer);
	lstate.current_materialized = std::move(head.materialized);
	lstate.current_kept_offset = 0;
	lstate.current_needs_row_filter = std::move(head.needs_row_filter);
	lstate.current_buf_offset = 0;
	lstate.current_group_num_rows = head.num_rows;
	lstate.current_group = head.group;

	// For RDMA, stage the splinter-fetched CPU column bytes on the handle the thrift transport
	// reads through, so the prefetch in InitGroupCPUColumns is served from host memory instead of
	// blocking the worker on RDMA round trips. That handle is the scan state's own
	// (ParquetReader::InitializeScan opens it and builds the thrift protocol on it) -- NOT the
	// reader's bind-time handle (GetHandle()) and NOT lstate.file_handle. Staging on either of
	// those leaves the transport with zero staged ranges and every string column is fetched a
	// second time, synchronously, on this worker. Staging replaces the previous group's ranges
	// (releasing those buffers once the transport no longer references their bytes).
	if (!head.cpu_slot.empty()) {
		D_ASSERT(lstate.scan_state->file_handle);
		auto *rdma = dynamic_cast<RDMAFileHandle *>(lstate.scan_state->file_handle->GetFileHandle().get());
		D_ASSERT(rdma); // cpu_slot is only populated on the RDMA path
		std::vector<RDMAFileHandle::StagedRange> ranges;
		ranges.reserve(head.cpu_slot.size());
		for (size_t k = 0; k < head.cpu_slot.size(); k++) {
			const auto &cc = *head.cpu_chunks[k];
			ranges.push_back(RDMAFileHandle::StagedRange {cc.offset, cc.total_compressed_size,
			                                              std::move(head.cpu_buffers[head.cpu_slot[k]])});
		}
		std::sort(ranges.begin(), ranges.end(),
		          [](const auto &a, const auto &b) { return a.offset < b.offset; });
		rdma->StageRanges(std::move(ranges));
	}

	InitGroupCPUColumns(context, gstate, lstate, head.group);
	lstate.inflight.pop_front();
	return LoadResult::LOADED;
}

struct SliceResult {
	size_t rows = 0;                      // Rows surviving the pushed-down filters (0 with LOADED
	                                      // means the slice was fully filtered -- try the next one).
	LoadResult load = LoadResult::LOADED; // BLOCKED or EXHAUSTED when no slice could be loaded.
};

// Emits the next STANDARD_VECTOR_SIZE-sized slice of the current row group into `output` (decoding
// or claiming a new group as needed), zero-copy, with the pushed-down filters applied.
static SliceResult EmitOneSlice(ClientContext &context, oasis::OasisContext &ctx, OasisScanGlobalState &gstate,
                                OasisScanLocalState &lstate, const OasisScanBindData &bind, DataChunk &output,
                                std::vector<unique_ptr<AsyncTask>> &out_tasks) {
	// When the current group is fully emitted, decode/claim the next one.
	if (lstate.current_group_num_rows == 0) {
		auto load = GetNextGroup(context, ctx, gstate, lstate, bind, out_tasks);
		if (load != LoadResult::LOADED) {
			return {0, load}; // BLOCKED or EXHAUSTED.
		}
	}

	size_t const total_elements = lstate.current_group_num_rows;
	size_t const remaining_elements = total_elements - lstate.current_buf_offset;
	size_t const emit = std::min<size_t>(remaining_elements, STANDARD_VECTOR_SIZE);

	// With filter pruning, the slice is scanned and filtered in the full-width staging chunk and
	// only the consumed columns are referenced into the (narrower) output chunk at the end.
	DataChunk &scan_chunk = gstate.can_prune ? lstate.all_columns : output;
	if (gstate.can_prune) {
		scan_chunk.Reset();
	}

	// The runtime Bloom filter's mask selects the slice's kept rows (bloom_sel), before any other
	// filter. Both materialized and bypassed columns are prepared in bloom_kept space: materialized
	// columns are dense flat vectors directly from the FPGA, and bypassed columns are sliced by
	// bloom_sel down to bloom_kept rows.
	const bool bloom = lstate.current_bloom_mask != nullptr;
	SelectionVector bloom_sel;
	idx_t bloom_kept = emit;
	if (bloom) {
		bloom_kept = ComputeBloomSliceSelection(*lstate.current_bloom_mask, lstate.current_buf_offset, emit, bloom_sel);
	}

	for (size_t i = 0; i < gstate.projected_columns.size(); i++) {
		const auto &col = gstate.projected_columns[i];
		if (col.is_cpu) {
			continue; // Decoded by DecodeAndFilterSlice below.
		}

		auto &buf = lstate.current_buffers[i];
		const bool narrowed = lstate.current_narrowed[i];
		const size_t transfer_size = narrowed ? sizeof(int32_t) : col.elem_size;
		if (buf->size / transfer_size != total_elements) {
		if (bloom && lstate.current_materialized[i]) {
			// The values of the slice's kept rows (all checked in GetNextGroup), zero-copy as well
			if (bloom_kept == 0) {
				continue; // The whole slice is dropped, the vector is never read
			}
			auto &vec = scan_chunk.data[i];
			vec.SetVectorType(VectorType::FLAT_VECTOR);
			FlatVector::SetData(vec, reinterpret_cast<data_ptr_t>(buf->ptr) + lstate.current_kept_offset * col.elem_size,
			                    count_t(bloom_kept));
			vec.AddAuxiliaryData(make_uniq<LibstfBufferVectorBuffer>(buf));
			continue;
		}
		if (buf->size / col.elem_size != total_elements) {
			throw InternalException(
			    "ParCore buffer layout mismatch across columns: column %llu has %llu elements, expected %llu",
			    (unsigned long long)i, (unsigned long long)(buf->size / transfer_size),
			    (unsigned long long)total_elements);
		}

		auto &vec = scan_chunk.data[i];
		vec.SetVectorType(VectorType::FLAT_VECTOR);

		// A chunk transferred as INT32 is sign-extended into the vector's own memory (the reset
		// chunk's vectors own STANDARD_VECTOR_SIZE values again).
		if (narrowed) {
			auto src = reinterpret_cast<const int32_t *>(buf->ptr) + lstate.current_buf_offset;
			auto dst = FlatVector::GetDataMutable<int64_t>(vec);
			for (size_t r = 0; r < emit; r++) {
				dst[r] = src[r];
			}
			continue;
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
		FlatVector::SetData(vec, reinterpret_cast<data_ptr_t>(buf->ptr) + lstate.current_buf_offset * col.elem_size,
		                    count_t(emit));
		vec.AddAuxiliaryData(make_uniq<LibstfBufferVectorBuffer>(buf));
		if (bloom && bloom_kept > 0) {
			vec.Slice(bloom_sel, bloom_kept);
		}
	}

	// Decode the CPU columns and apply the pushed-down filters (late-materialized: Filter columns
	// first, then the surviving rows of the remaining columns).
	idx_t const rows_passed =
	    DecodeAndFilterSlice(gstate, lstate, scan_chunk, emit, bloom ? &bloom_sel : nullptr, bloom_kept);

	// Advance the cursor. If we have emitted this group's last elements, release the buffers so the
	// next call's `if` branch loads the next row group. Dropping our refs here lets each buffer free as
	// soon as downstream consumers are done with it.
	lstate.current_buf_offset += emit;
	if (bloom) {
		lstate.current_kept_offset += bloom_kept;
	}
	if (lstate.current_buf_offset >= total_elements) {
		lstate.current_buffers.assign(gstate.projected_columns.size(), nullptr);
		lstate.current_bloom_mask = nullptr;
		lstate.current_buf_offset = 0;
		lstate.current_group_num_rows = 0;
	}

	if (rows_passed > 0 && gstate.can_prune) {
		output.ReferenceColumns(lstate.all_columns, gstate.projection_ids);
	}
	return {rows_passed, LoadResult::LOADED};
}

// Zero-copy multi-column scan. Each worker atomically claims a row group, submits its query
// splinters to the Oasis scheduler, and slices the decoded buffers in lockstep into
// STANDARD_VECTOR_SIZE-sized vectors. The one-buffer-per-column-chunk model holds because the OBM
// buffers are sized to a whole DuckDB column chunk and PrefetchGroup rejects any chunk that would
// overflow them.
//
// Input reads run synchronously on the worker (coalesced, in a loop) before a splinter is
// submitted. We only avoid blocking the worker on hardware decode: when the head group's hardware
// results are not ready, we return BLOCKED via data_p.async_result with an AsyncTask that waits on
// the result handle's readiness, and the engine reschedules this scan once it completes.
//
// Otherwise we loop over slices until at least one row survives the pushed-down filters or we hit
// EOF.
void OasisScanFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &gstate = data_p.global_state->Cast<OasisScanGlobalState>();
	auto &lstate = data_p.local_state->Cast<OasisScanLocalState>();
	auto &bind = data_p.bind_data->Cast<OasisScanBindData>();
	auto &ctx = *gstate.ctx;

	while (true) {
		output.Reset();
		std::vector<unique_ptr<AsyncTask>> tasks;
		auto slice = EmitOneSlice(context, ctx, gstate, lstate, bind, output, tasks);
		if (slice.load != LoadResult::LOADED) {
			output.SetChildCardinality(0);
			if (slice.load == LoadResult::BLOCKED) {
				data_p.async_result = AsyncResult(std::move(tasks), TaskSchedulerType::ASYNC);
			}
			return;
		}
		if (slice.rows > 0) {
			return; // Filters already applied by EmitOneSlice.
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
	// The file statistics have the file type, not the type of a cast pushed into the scan
	if (column_index >= bind.metadata.column_names.size() ||
	    bind.output_types[column_index] != bind.column_types[column_index]) {
		return nullptr;
	}
	return bind.metadata_reader->GetStatistics(context, Identifier(bind.metadata.column_names[column_index]));
}

// The row groups of the file with their statistics, as read_parquet reports them. DuckDB answers
// e.g. COUNT(*), MIN and MAX from them without a scan, also when the filters keep or drop whole row
// groups.
static vector<PartitionStatistics> OasisScanGetPartitionStats(ClientContext &, GetPartitionStatsInput &input) {
	vector<PartitionStatistics> result;
	auto &bind = input.bind_data->Cast<OasisScanBindData>();
	// The statistics have the file types, not the types of casts pushed into the scan
	if (bind.output_types != bind.column_types) {
		return result;
	}
	bind.metadata_reader->GetPartitionStats(result);
	return result;
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

// Called once per worker when its scan finishes: Folds the worker's timers into the scan-wide
// totals and reports the totals on the query profiling tree (the extra_info of the scan operator,
// shown by EXPLAIN ANALYZE).
void OasisScanGetMetrics(TableFunctionGetMetricsInput &input) {
	if (!input.global_state) {
		return;
	}
	auto &gstate = input.global_state->Cast<OasisScanGlobalState>();
	if (input.local_state) {
		auto &lstate = input.local_state->Cast<OasisScanLocalState>();
		gstate.filter_time_ns += lstate.filter_time_ns;
		gstate.string_decode_time_ns += lstate.string_decode_time_ns;
		lstate.filter_time_ns = 0;
		lstate.string_decode_time_ns = 0;
	}

	// Sums over all workers, so they can exceed the operator's wall-clock time.
	auto seconds = [](uint64_t ns) { return StringUtil::Format("%.4fs", static_cast<double>(ns) / 1e9); };
	if (gstate.filters) {
		input.operator_metrics.AddExtraInfo("Filter Time", seconds(gstate.filter_time_ns.load()));
	}
	if (gstate.has_cpu_columns) {
		input.operator_metrics.AddExtraInfo("String Decode Time", seconds(gstate.string_decode_time_ns.load()));
	}
}

OperatorPartitionData OasisScanGetPartitionData(ClientContext &, TableFunctionGetPartitionInput &input) {
	auto &lstate = input.local_state->Cast<OasisScanLocalState>();
	return OperatorPartitionData(lstate.current_group);
}

// Accepts any single-column expression (e.g. NOT LIKE, single-column OR chains) as a pushed-down
// ExpressionFilter -- the optimizer only offers these when this callback is set. DecodeAndFilterSlice
// evaluates them generically post-decode, and RowGroupMatchesFilters/BuildScanFilters classify
// them per group like any other filter, so no restriction is needed (mirrors the parquet scan).
static bool OasisScanPushdownExpression(ClientContext &, const LogicalGet &, Expression &) {
	return true;
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
	table_function.filter_prune = true;
	table_function.pushdown_expression = OasisScanPushdownExpression;
	table_function.projection_expression_pushdown = OasisScanPushdownCast;
	// Initialize the global state eagerly at schedule time to register our cold workers.
	table_function.global_initialization = TableFunctionInitialization::INITIALIZE_ON_SCHEDULE;
	table_function.cardinality = OasisScanCardinality;
	table_function.statistics = OasisScanStatistics;
	table_function.get_partition_stats = OasisScanGetPartitionStats;
	table_function.table_scan_progress = OasisScanProgress;
	table_function.get_partition_data = OasisScanGetPartitionData;
	table_function.get_metrics = OasisScanGetMetrics;
	loader.RegisterFunction(table_function);
}

} // namespace duckdb
