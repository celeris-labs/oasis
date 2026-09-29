#include "oasis_hardware_bloom.hpp"

#include "duckdb/common/assert.hpp"
#include "duckdb/common/exception.hpp"
#include "duckdb/common/file_system.hpp"
#include "duckdb/logging/logger.hpp"
#include "duckdb/main/client_context.hpp"
#include "duckdb/planner/expression/bound_function_expression.hpp"
#include "duckdb/planner/filter/expression_filter.hpp"
#include "duckdb/planner/filter/table_filter_functions.hpp"
#include "duckdb/planner/table_filter.hpp"
#include "coalesced_fetcher.hpp"
#include "oasis/oasis_context.hpp"
#include "oasis/query_splinter.hpp"
#include "filter_pushdown.hpp"
#include "parquet_reader.hpp"
#include "parcore/configuration.hpp"
#include "parcore_metadata_util.hpp"
#include "rdma_file_system.hpp"

#include <coyote/cThread.hpp>
#include <libstf/configuration.hpp>

#include <algorithm>

#include <atomic>
#include <cstdio>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>

namespace duckdb {

const char *BloomStreamSelectName(BloomStreamSelect select) {
	switch (select) {
	case BloomStreamSelect::FILTER:
		return "filter";
	case BloomStreamSelect::BYPASS:
		return "bypass";
	case BloomStreamSelect::BUILD:
		return "build";
	case BloomStreamSelect::MATERIALIZE:
		return "materialize";
	}
	return "unknown";
}

namespace {

// Mirrors celeris's BFConfig (celeris/hardware/src/hdl/config/bloomfilter_config.sv): register 0
// takes the materialization commands (one per probe chunk, see PushBloomMaterializeCommand),
// register 1 the input commands.
class BloomFilterConfig : public libstf::Config {
public:
	static constexpr uint64_t ID = 6; // BLOOMFILTER_CONFIG_ID (celeris/hardware/src/hdl/common.sv)

	BloomFilterConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset, uint32_t num_regs)
	    : libstf::Config(std::move(cthread), addr_offset, num_regs) {
	}

	// {num_columns, enable}: a chunk is only materialized if enabled with at least one column
	void push_materialize_command(uint32_t num_columns) {
		uint64_t value = (uint64_t(num_columns) << 1) | (num_columns != 0 ? 1ULL : 0ULL);
		write_register(libstf::ConfigRegister(0, value));
	}

	void push_input_command(BloomInputCommand cmd) {
		write_register(libstf::ConfigRegister(1, static_cast<uint64_t>(cmd)));
	}

	// Read register 5: sticky command queue overflows, bit 0 input commands, bit 1 materialization
	// commands
	bool command_queue_overflowed() {
		return (read_register(5).value() & 0b11ULL) != 0;
	}
};

// Mirrors celeris's StreamConfig (parcore/libstf/hardware/src/hdl/config/stream_config.sv)
// instantiated with NUM_STREAMS=1 in vfpga_top.svh, selecting where decoder-stream 0 routes its
// transfer (see BloomStreamSelect).
class BloomFilterStreamConfig : public libstf::Config {
public:
	static constexpr uint64_t ID = 1; // STREAM_CONFIG_ID (parcore/libstf/hardware/src/hdl/common.sv)

	BloomFilterStreamConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset, uint32_t num_regs)
	    : libstf::Config(std::move(cthread), addr_offset, num_regs) {
	}

	// Value layout is (select << 3) | data_type, matching stream_conf_t's packed layout (data_type
	// is 3 bits, unused here).
	void select(BloomStreamSelect select) {
		constexpr uint64_t DATA_TYPE_BITS = 3;
		write_register(libstf::ConfigRegister(0, static_cast<uint64_t>(select) << DATA_TYPE_BITS));
	}
};

static std::atomic<bool> bloom_filter_in_use {false};

std::unique_ptr<oasis::SourceOperator> MakeRDMASource(RDMAFileHandle &rdma,
                                                      const parcore::metadata::ColumnChunk &cc) {
	return std::make_unique<oasis::RDMASourceOperator>(rdma.remote_offset + cc.offset, cc.total_compressed_size);
}

std::unique_ptr<oasis::SourceOperator> MakeHostSource(const CoalescedFetcher::RangeView &view) {
	auto *slice_ptr = static_cast<uint8_t *>(view.buffer->ptr) + view.offset;
	size_t capacity = view.buffer->capacity - view.offset;
	auto parent = view.buffer;
	std::shared_ptr<libstf::Buffer> slice(new libstf::Buffer {slice_ptr, view.size, capacity},
	                                      [parent](libstf::Buffer *b) { delete b; });
	return std::make_unique<oasis::LocalSourceOperator>(std::move(slice));
}

} // namespace

void PushBloomInputCommand(oasis::OasisContext &ctx, BloomInputCommand cmd) {
	ctx.config<BloomFilterConfig>()->push_input_command(cmd);
}

void PushBloomMaterializeCommand(oasis::OasisContext &ctx, uint32_t num_columns) {
	ctx.config<BloomFilterConfig>()->push_materialize_command(num_columns);
}

bool BloomCommandQueueOverflowed(oasis::OasisContext &ctx) {
	return ctx.config<BloomFilterConfig>()->command_queue_overflowed();
}

void CheckOasisHardwareBloom(oasis::OasisContext &ctx) {
	const auto num_decoders = ctx.config<parcore::ColumnChunkDecoderConfig>()->num_decoders();
	if (num_decoders != 1) {
		throw std::runtime_error("Oasis requires a hardware design with exactly one column chunk decoder "
		                         "(the Bloom filter's stream select is on decoder stream 0), but it has " +
		                         std::to_string(num_decoders));
	}
}

BloomFilterStreamSelectOperator::BloomFilterStreamSelectOperator(BloomStreamSelect select,
                                                                 std::optional<uint32_t> materialize_columns,
                                                                 bool end_side)
    : select_(select), materialize_columns_(materialize_columns), end_side_(end_side) {
	D_ASSERT(materialize_columns_.has_value() == (select_ == BloomStreamSelect::FILTER));
	D_ASSERT(!end_side_ || IsKeyChunk());
}

void BloomFilterStreamSelectOperator::apply(libstf::stream_t, oasis::OasisContext &ctx) {
	ctx.config<BloomFilterStreamConfig>()->select(select_);
	if (IsKeyChunk()) {
		PushBloomInputCommand(ctx, BloomInputCommand::CONTINUE);
	}
	if (materialize_columns_) {
		PushBloomMaterializeCommand(ctx, *materialize_columns_);
	}
	if (end_side_) {
		PushBloomInputCommand(ctx, BloomInputCommand::END);
	}
}

void BloomFilterStreamSelectOperator::print(std::ostream &os) const {
	os << "BloomFilterStreamSelect(" << BloomStreamSelectName(select_);
	if (materialize_columns_) {
		os << ", materialize " << *materialize_columns_;
	}
	if (end_side_) {
		os << ", END";
	}
	os << ")";
}

bool BloomFilterStreamSelectOperator::IsKeyChunk() const {
	return select_ == BloomStreamSelect::FILTER || select_ == BloomStreamSelect::BUILD;
}

bool IsBloomMaterializableChunk(const parcore::metadata::ColumnChunk &cc) {
	return libstf::size_of(parcore::metadata::to_libstf_type(cc.type)) == 8 && !cc.has_def_levels &&
	       !cc.has_rep_levels;
}

bool IsBloomKeyColumn(const parcore::metadata::Metadata &meta, size_t col_id) {
	for (const auto &group : meta.groups) {
		const auto &cc = group.chunks[col_id];
		if (cc.type != parcore::metadata::Type::INT64_T || cc.has_def_levels || cc.has_rep_levels) {
			return false;
		}
	}
	return true;
}

size_t CountBloomKeptRows(const libstf::Buffer &mask, size_t num_rows) {
	if (mask.size < (num_rows + 7) / 8) {
		throw InternalException("Bloom filter mask has %llu bytes for %llu rows", (unsigned long long)mask.size,
		                        (unsigned long long)num_rows);
	}
	const auto *bytes = static_cast<const uint8_t *>(mask.ptr);
	size_t kept = 0;
	for (size_t b = 0; b < num_rows / 8; b++) {
		kept += __builtin_popcount(bytes[b]);
	}
	if (num_rows % 8 != 0) {
		kept += __builtin_popcount(bytes[num_rows / 8] & ((1u << (num_rows % 8)) - 1));
	}
	return kept;
}

bool TryAcquireBloomFilter() {
	bool in_use = false;
	return bloom_filter_in_use.compare_exchange_strong(in_use, true, std::memory_order_acquire);
}

void ReleaseBloomFilter() {
	bloom_filter_in_use.store(false, std::memory_order_release);
}

std::optional<BloomBuildPlan> BuildBloomPlan(ClientContext &context, size_t probe_key_slot,
                                             const std::string &build_filename,
                                             const std::string &build_key) {
	ParquetOptions parquet_opts(context);
	ParquetReader build_reader(context, OpenFileInfo {build_filename}, parquet_opts);
	auto build_meta = BuildParcoreMetadata(build_reader);
	auto build_col = std::find(build_meta.column_names.begin(), build_meta.column_names.end(), build_key);
	if (build_col == build_meta.column_names.end()) {
		DUCKDB_LOG_DEBUG(context, "Runtime Bloom filter skipped: build key '%s' not found in '%s'.",
		                 build_key.c_str(), build_filename.c_str());
		return std::nullopt;
	}
	const size_t build_key_col_id = static_cast<size_t>(build_col - build_meta.column_names.begin());
	if (!IsBloomKeyColumn(build_meta, build_key_col_id)) {
		DUCKDB_LOG_DEBUG(context, "Runtime Bloom filter skipped: build key '%s' is not a required INT64 column.",
		                 build_key.c_str());
		return std::nullopt;
	}

	return BloomBuildPlan {probe_key_slot, std::move(build_meta), build_key_col_id};
}

BloomBuildSubmission SubmitBloomBuildSide(ClientContext &context, oasis::OasisContext &ctx,
                                         const std::string &build_filename, const BloomBuildPlan &plan) {
	const auto &build_meta = plan.build_meta;
	const size_t build_key_col_id = plan.build_key_col_id;

	auto &fs = FileSystem::GetFileSystem(context);
	auto build_handle = fs.OpenFile(build_filename, FileOpenFlags::FILE_FLAGS_READ);
	auto *rdma = dynamic_cast<RDMAFileHandle *>(build_handle.get());

	std::vector<const parcore::metadata::ColumnChunk *> build_chunks;
	for (const auto &group : build_meta.groups) {
		if (group.chunks[build_key_col_id].num_values != 0) {
			build_chunks.push_back(&group.chunks[build_key_col_id]);
		}
	}

	if (build_chunks.empty()) {
		// Nothing to build: end the (empty) build side right away. No other scan can use the
		// filter meanwhile (bloom_filter_in_use), so nothing can be queued in between.
		PushBloomInputCommand(ctx, BloomInputCommand::END);
		return BloomBuildSubmission {oasis::SplinterResultHandle {}, false, 0};
	}

	oasis::QuerySplinter splinter;
	splinter.streams.reserve(build_chunks.size());
	for (size_t k = 0; k < build_chunks.size(); k++) {
		const auto &cc = *build_chunks[k];
		// The last build chunk also ends the build side, in the same flow: right after its chunk
		const bool last = k + 1 == build_chunks.size();

		oasis::OperatorFlow flow;
		flow.push_back(std::make_unique<BloomFilterStreamSelectOperator>(BloomStreamSelect::BUILD, std::nullopt, last));
		if (rdma) {
			flow.push_back(MakeRDMASource(*rdma, cc));
		} else {
			CoalescedFetcher fetcher(*build_handle, ctx.memory_pool(),
			                         CoalescedFetcher::GroupSpan {cc.offset, cc.total_compressed_size});
			auto range = fetcher.Register(cc.offset, cc.total_compressed_size);
			fetcher.PrepareReads();
			for (size_t idx = 0; idx < fetcher.num_reads(); idx++) {
				fetcher.ExecuteMergedRead(idx);
			}
			flow.push_back(MakeHostSource(fetcher.Resolve(range))); // Keeps the read bytes alive
		}
		flow.push_back(std::make_unique<oasis::DecodeColumnChunkOperator>(
		    cc.compression, cc.num_values, parcore::metadata::to_libstf_type(cc.type), cc.has_def_levels,
		    cc.has_rep_levels));
		// The oasis top answers a build chunk with a one-byte ack
		flow.push_back(std::make_unique<oasis::LocalSinkOperator>(ctx.allocate_output_buffer(64), k));
		splinter.streams.push_back(std::move(flow));
	}

	auto handle = ctx.scheduler().submit(std::move(splinter));
	return BloomBuildSubmission {std::move(handle), true, build_chunks.size()};
}

void TeardownHardwareBloom(oasis::OasisContext *ctx, oasis::SplinterResultHandle &bloom_build,
                           bool bloom_filter_held, bool bloom_active, bool bloom_build_submitted) {
	if (!bloom_filter_held) {
		return;
	}
	// Every worker has drained its probe key chunks (~OasisScanLocalState), so all their CONTINUEs
	// were pushed: end the probe side, which also resets the filter for the next scan. If
	// SubmitBloomBuild threw after taking the filter (!bloom_active), nothing reached the filter.
	if (bloom_active && ctx) {
		try {
			while (bloom_build_submitted && bloom_build.get_next_batch()) {
			}
			PushBloomInputCommand(*ctx, BloomInputCommand::END);
			if (BloomCommandQueueOverflowed(*ctx)) {
				fprintf(stderr, "[OASIS] A hardware Bloom filter command queue overflowed, its results are not "
				                "reliable.\n");
			}
		} catch (std::exception &e) {
			fprintf(stderr, "[OASIS] Failed to end the runtime Bloom filter's probe side: %s\n", e.what());
		}
	}
	ReleaseBloomFilter();
}

idx_t ComputeBloomSliceSelection(const libstf::Buffer &mask_buf, size_t row_offset,
                                 idx_t emit, SelectionVector &bloom_sel) {
	const auto *mask = static_cast<const uint8_t *>(mask_buf.ptr);
	bloom_sel.Initialize(emit);
	idx_t bloom_kept = 0;
	for (idx_t i = 0; i < emit; i++) {
		const size_t row = row_offset + i;
		const bool keep = (mask[row / 8] >> (row % 8)) & 1;
		if (keep) {
			bloom_sel.set_index(bloom_kept++, i);
		}
	}
	return bloom_kept;
}

void VerifyBloomMaterializedBuffers(const libstf::Buffer &mask_buf, size_t num_rows, size_t group_idx,
                                   const std::vector<bool> &materialized,
                                   const std::vector<std::shared_ptr<libstf::Buffer>> &hw_buffers) {
	const size_t kept = CountBloomKeptRows(mask_buf, num_rows);
	constexpr size_t elem_size = sizeof(uint64_t);
	for (size_t i = 0; i < materialized.size(); i++) {
		if (materialized[i] && hw_buffers[i]->size != kept * elem_size) {
			throw InternalException("Bloom filter materialized %llu values of column %llu in row group %llu, "
			                        "but its mask kept %llu rows",
			                        (unsigned long long)(hw_buffers[i]->size / elem_size),
			                        (unsigned long long)i, (unsigned long long)group_idx,
			                        (unsigned long long)kept);
		}
	}
}

namespace {

uint64_t RowGroupNumRows(const OasisScanBindData &bind, size_t group) {
	const auto &chunks = bind.metadata.groups[group].chunks;
	return chunks.empty() ? 0 : chunks[0].num_values;
}

std::optional<size_t> ObtainBloomProbeKeySlot(ClientContext &context, const OasisScanBindData &bind,
                                          const OasisScanGlobalState &gstate) {
	std::optional<size_t> probe_key_slot;
	for (size_t i = 0; i < gstate.projected_columns.size(); i++) {
		const auto &col = gstate.projected_columns[i];
		if (!col.is_cpu && bind.metadata.column_names[col.column_id] == bind.runtime_bloom_probe_key) {
			probe_key_slot = i;
		}
	}
	if (!probe_key_slot) {
		DUCKDB_LOG_DEBUG(context, "Runtime Bloom filter skipped: probe key '%s' is not a hardware column of this scan.",
		                 bind.runtime_bloom_probe_key.c_str());
		return std::nullopt;
	}
	if (!IsBloomKeyColumn(bind.metadata, gstate.projected_columns[*probe_key_slot].column_id)) {
		DUCKDB_LOG_DEBUG(context, "Runtime Bloom filter skipped: probe key '%s' is not a required INT64 column.",
		                 bind.runtime_bloom_probe_key.c_str());
		return std::nullopt;
	}
	return probe_key_slot;
}

void CheckBloomRowGroupSizes(const OasisScanBindData &bind) {
	for (size_t group = 0; group < bind.metadata.groups.size(); group++) {
		if (RowGroupNumRows(bind, group) > BLOOM_MAX_PROBE_ROWS) {
			throw NotImplementedException(
			    "Runtime Bloom filter: row group %llu of '%s' has %llu rows, more than the %llu the hardware Bloom "
			    "filter supports.",
			    (unsigned long long)group, bind.filename.c_str(), (unsigned long long)RowGroupNumRows(bind, group),
			    (unsigned long long)BLOOM_MAX_PROBE_ROWS);
		}
	}
}

} // namespace

std::optional<BloomBuildPlan> PrepareBloomBuild(ClientContext &context, const OasisScanBindData &bind,
                                               const OasisScanGlobalState &gstate) {
	auto probe_key_slot = ObtainBloomProbeKeySlot(context, bind, gstate);
	if (!probe_key_slot) {
		return std::nullopt;
	}

	CheckBloomRowGroupSizes(bind);

	return BuildBloomPlan(context, *probe_key_slot, bind.runtime_bloom_build_filename, bind.runtime_bloom_build_key);
}

bool TryAcquireBloomFilter(ClientContext &context, OasisScanGlobalState &gstate) {
	if (!duckdb::TryAcquireBloomFilter()) {
		DUCKDB_LOG_DEBUG(context, "Runtime Bloom filter skipped: the hardware Bloom filter is in use by another scan.");
		return false;
	}
	gstate.bloom_filter_held = true;
	return true;
}

void SubmitBloomBuild(ClientContext &context, oasis::OasisContext &ctx, const OasisScanBindData &bind,
                      const BloomBuildPlan &plan, OasisScanGlobalState &gstate) {
	D_ASSERT(gstate.bloom_filter_held);
	auto submission = SubmitBloomBuildSide(context, ctx, bind.runtime_bloom_build_filename, plan);
	gstate.bloom_build = std::move(submission.handle);
	gstate.bloom_build_submitted = submission.submitted;
	gstate.bloom_active = true;
	gstate.bloom_probe_key_slot = plan.probe_key_slot;
	DUCKDB_LOG_DEBUG(context, "Runtime Bloom filter: submitted %llu build key chunk(s) of '%s'.",
	                 (unsigned long long)submission.num_chunks, bind.runtime_bloom_build_filename.c_str());
}

static bool IsDuckDBJoinBloomFilter(const TableFilter &filter) {
	if (filter.filter_type == TableFilterType::LEGACY_BLOOM_FILTER) {
		return true;
	}
	if (filter.filter_type != TableFilterType::EXPRESSION_FILTER) {
		return false;
	}
	// A hash join wraps its Bloom filter in an (selectivity-)optional filter, see
	// JoinFilterPushdownInfo::PushBloomFilter
	const Expression *expr = filter.Cast<ExpressionFilter>().expr.get();
	while (expr && expr->GetExpressionClass() == ExpressionClass::BOUND_FUNCTION) {
		auto &func = expr->Cast<BoundFunctionExpression>();
		const auto &name = func.Function().GetName();
		if (name == BloomFilterScalarFun::NAME) {
			return true;
		}
		if (!func.BindInfo()) {
			return false;
		}
		if (name == SelectivityOptionalFilterScalarFun::NAME) {
			expr = func.BindInfo()->Cast<SelectivityOptionalFilterFunctionData>().child_filter_expr.get();
		} else if (name == OptionalFilterScalarFun::NAME) {
			expr = func.BindInfo()->Cast<OptionalFilterFunctionData>().child_filter_expr.get();
		} else {
			return false;
		}
	}
	return false;
}

void DisableRowLevelJoinBloomFilters(ClientContext &context, const std::string &probe_key_name,
                                     size_t bloom_probe_key_slot, std::vector<OasisScanFilter> &scan_filters) {
	for (auto &scan_filter : scan_filters) {
		if (scan_filter.filter_idx == bloom_probe_key_slot && IsDuckDBJoinBloomFilter(scan_filter.filter)) {
			scan_filter.row_level = false;
			DUCKDB_LOG_DEBUG(context, "DuckDB's join Bloom filter on '%s' only prunes row groups: the "
			                          "hardware Bloom filter filters its rows.",
			                 probe_key_name.c_str());
		}
	}
}

void DrainInFlightBloomProbeSplinters(OasisScanLocalState &lstate) {
	for (auto &pending : lstate.inflight) {
		if (pending->submitted) {
			while (pending->result.get_next_batch()) {
			}
		}
	}
}

namespace {

void AppendDecodeChunk(oasis::OperatorFlow &flow,
                       oasis::OasisContext &ctx,
                       const OasisScanLocalState::PendingGroup &pending,
                       RDMAFileHandle *rdma,
                       size_t k,
                       std::unique_ptr<BloomFilterStreamSelectOperator> select,
                       size_t sink_size,
                       size_t tag) {
	const auto &cc = *pending.hw_chunks[k];
	flow.push_back(std::move(select));
	if (rdma) {
		flow.push_back(MakeRDMASource(*rdma, cc));
	} else {
		flow.push_back(MakeHostSource(pending.fetcher->Resolve(pending.host_handles[k])));
	}
	flow.push_back(std::make_unique<oasis::DecodeColumnChunkOperator>(
	    cc.compression, cc.num_values, parcore::metadata::to_libstf_type(cc.type), cc.has_def_levels,
	    cc.has_rep_levels));
	flow.push_back(std::make_unique<oasis::LocalSinkOperator>(ctx.allocate_output_buffer(sink_size), tag));
}

size_t DecodedChunkSize(const parcore::metadata::ColumnChunk &cc) {
	return cc.num_values * libstf::size_of(parcore::metadata::to_libstf_type(cc.type));
}

} // namespace

oasis::OperatorFlow ConstructBloomProbeFlow(oasis::OasisContext &ctx,
                                            OasisScanLocalState::PendingGroup &pending,
                                            RDMAFileHandle *rdma,
                                            size_t bloom_probe_key_slot,
                                            size_t num_projected_columns,
                                            std::vector<bool> &is_bypassed) {
	std::vector<size_t> mat_k;
	std::optional<size_t> probe_k;
	for (size_t k = 0; k < pending.hw_slot.size(); k++) {
		if (pending.hw_slot[k] == bloom_probe_key_slot) {
			probe_k = k;
			mat_k.push_back(k);
		} else if (IsBloomMaterializableChunk(*pending.hw_chunks[k])) {
			mat_k.push_back(k);
		}
	}
	D_ASSERT(probe_k); // The probe key is a hardware column (see SubmitBloomBuild)

	oasis::OperatorFlow bloom_flow;
	AppendDecodeChunk(bloom_flow, ctx, pending, rdma, *probe_k,
	                  std::make_unique<BloomFilterStreamSelectOperator>(BloomStreamSelect::FILTER,
	                                                                    static_cast<uint32_t>(mat_k.size())),
	                  (pending.num_rows + 7) / 8, num_projected_columns);

	for (auto k : mat_k) {
		AppendDecodeChunk(bloom_flow, ctx, pending, rdma, k,
		                  std::make_unique<BloomFilterStreamSelectOperator>(BloomStreamSelect::MATERIALIZE),
		                  DecodedChunkSize(*pending.hw_chunks[k]), pending.hw_slot[k]);
		pending.materialized[pending.hw_slot[k]] = true;
		is_bypassed[k] = false;
	}
	return bloom_flow;
}

oasis::OperatorFlow ConstructBypassFlow(oasis::OasisContext &ctx,
                                        const OasisScanLocalState::PendingGroup &pending,
                                        RDMAFileHandle *rdma,
                                        size_t k) {
	oasis::OperatorFlow flow;
	AppendDecodeChunk(flow, ctx, pending, rdma, k,
	                  std::make_unique<BloomFilterStreamSelectOperator>(BloomStreamSelect::BYPASS),
	                  DecodedChunkSize(*pending.hw_chunks[k]), pending.hw_slot[k]);
	return flow;
}

} // namespace duckdb
