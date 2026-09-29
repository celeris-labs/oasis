#pragma once

#include "duckdb/common/types/selection_vector.hpp"
#include "oasis/operator.hpp"
#include "oasis/query_splinter.hpp"
#include "oasis/splinter_result.hpp"
#include "oasis_scan.hpp"
#include "parcore/metadata/metadata.hpp"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <ostream>
#include <string>

namespace oasis {
class OasisContext;
} // namespace oasis

namespace duckdb {

// Where decoder-stream 0's transfer goes, see the demultiplexer/multiplexer in vfpga_top.svh.
enum class BloomStreamSelect : uint64_t {
	FILTER = 0,     // Through the Bloom filter as a probe key chunk, yields its mask
	BYPASS = 1,     // Around the Bloom filter, yields the decoded values unchanged
	BUILD = 2,      // Through the Bloom filter as a build key chunk, yields a one-byte ack
	MATERIALIZE = 3 // A 64-bit column of the last probe key chunk, yields the values of its kept rows
};

const char *BloomStreamSelectName(BloomStreamSelect select);

// Checks that the hardware design fits the Bloom filter integration in hardware/src/vfpga_top.svh
// (one decoder stream, whose flows each push a stream select, see BloomFilterStreamSelectOperator in
// oasis_scan.cpp). There is nothing to configure once: all Bloom filter commands are per chunk.
void CheckOasisHardwareBloom(oasis::OasisContext &ctx);

// Input commands of celeris's BloomfilterOperator (BFConfig register 1, see
// celeris/hardware/src/hdl/bloomfilter/bloomfilter_operator.sv), in transfer order: CONTINUE before
// every transfer through the filter (a build or probe key chunk, its own chunk with its own mask),
// END after the last one of a side. So they have to be pushed from the flows' operators on the
// dispatcher (like the stream select). The core switches build -> probe -> flush only on END.
enum class BloomInputCommand : uint8_t {
	CONTINUE = 0, // The next transfer is a chunk of the current side
	END = 1       // Ends the current side, without a transfer
};

void PushBloomInputCommand(oasis::OasisContext &ctx, BloomInputCommand cmd);

// Materialization command of celeris's MaskMaterializer (BFConfig register 0, see
// celeris/hardware/src/hdl/bloomfilter/mask_materializer.sv): every probe key chunk needs one, in
// chunk order, pushed with its input command. It gives the number of columns (MATERIALIZE
// transfers of 64-bit values) that follow the chunk and are materialized with its mask, 0 for none.
void PushBloomMaterializeCommand(oasis::OasisContext &ctx, uint32_t num_columns);

// Whether a write to one of the (1024-entry) command queues was ever lost because it was full.
bool BloomCommandQueueOverflowed(oasis::OasisContext &ctx);

// Pushes one stream-select decision when applied, and for key chunks through the Bloom filter (FILTER,
// BUILD) also their input command (CONTINUE, see BloomInputCommand) and, for probe key chunks, their
// materialization command (the number of MATERIALIZE flows following it, see
// PushBloomMaterializeCommand). With end_side, it also ends the side after the chunk (END): the
// last build chunk ends the build side like this.
class BloomFilterStreamSelectOperator final : public oasis::Operator {
public:
	explicit BloomFilterStreamSelectOperator(BloomStreamSelect select,
	                                         std::optional<uint32_t> materialize_columns = std::nullopt,
	                                         bool end_side = false);

	void apply(libstf::stream_t stream, oasis::OasisContext &ctx) override;
	void print(std::ostream &os) const override;

private:
	// A key chunk through the Bloom filter, which takes an input command
	bool IsKeyChunk() const;

	BloomStreamSelect       select_;
	std::optional<uint32_t> materialize_columns_;
	bool                    end_side_;
};

// What the runtime Bloom filter's build side needs, see PrepareBloomBuild
struct BloomBuildPlan {
	size_t probe_slot;                      // Projected column of the probe key
	parcore::metadata::Metadata build_meta; // Of the build file
	size_t build_col_id;                    // Build key column in build_meta
};

// The most rows a probe row group can have: the Bloom filter's materializer holds its whole mask
// (2^LOG_MASK_BUFF_SZ bytes with LOG_MASK_BUFF_SZ = 14, celeris
// hardware/src/hdl/bloomfilter/mask_materializer.sv). DuckDB writes row groups of 122880 rows.
constexpr size_t BLOOM_MAX_PROBE_ROWS = (size_t(1) << 14) * 8;

// Whether the Bloom filter can materialize this column chunk: 64-bit values (the materializer's
// width) and exactly one decoded value per row (it pairs the i-th value with the i-th mask bit).
bool IsBloomMaterializableChunk(const parcore::metadata::ColumnChunk &cc);

// Whether the Bloom filter hardware can take this key column: 64-bit keys (the filter hashes 8 of
// them per 512-bit beat) and exactly one decoded value per row (the mask is positional, so the
// decoder must not drop NULLs).
bool IsBloomKeyColumn(const parcore::metadata::Metadata &meta, size_t col_id);

// Number of rows the runtime Bloom filter kept: the set bits of the group's mask.
size_t CountBloomKeptRows(const libstf::Buffer &mask, size_t num_rows);

// Atomic hardware lock ensuring only one scan uses the physical Bloom filter at a time.
bool TryAcquireBloomFilter();
void ReleaseBloomFilter();

class ClientContext;

// Loads build-side Parquet metadata, verifies the build key column is a valid INT64 Bloom key,
// and constructs the BloomBuildPlan. Returns nullopt if the key is missing or incompatible.
std::optional<BloomBuildPlan> BuildBloomPlan(ClientContext &context, size_t probe_slot,
                                             const std::string &build_filename,
                                             const std::string &build_key);

struct BloomBuildSubmission {
	oasis::SplinterResultHandle handle;
	bool submitted = false;
	size_t num_chunks = 0;
};

// Submits the build side of the runtime Bloom filter to the hardware.
// If the build side has no non-empty chunks, it immediately sends BloomInputCommand::END.
BloomBuildSubmission SubmitBloomBuildSide(ClientContext &context, oasis::OasisContext &ctx,
                                         const std::string &build_filename, const BloomBuildPlan &plan);

// Drains any pending build batches, pushes BloomInputCommand::END to end the probe side,
// checks for command queue overflow, and releases the Bloom filter hardware lock.
void TeardownHardwareBloom(oasis::OasisContext *ctx, oasis::SplinterResultHandle &bloom_build,
                           bool bloom_filter_held, bool bloom_active, bool bloom_build_submitted);

// Populates bloom_sel with the indices of rows kept by the Bloom filter mask within the slice
// [row_offset, row_offset + emit), and returns the count of kept rows.
idx_t ComputeBloomSliceSelection(const libstf::Buffer &mask_buf, size_t row_offset,
                                 idx_t emit, SelectionVector &bloom_sel);

// Verifies that all materialized column buffers have exactly the expected size (kept rows * 8 bytes).
// Throws InternalException on size mismatch.
void VerifyBloomMaterializedBuffers(const libstf::Buffer &mask_buf, size_t num_rows, size_t group_idx,
                                   const std::vector<bool> &materialized,
                                   const std::vector<std::shared_ptr<libstf::Buffer>> &hw_buffers);

// Validates probe key column, checks that all row group sizes fit within BLOOM_MAX_PROBE_ROWS,
// and builds the BloomBuildPlan from the build Parquet file. Returns std::nullopt if the probe key
// is missing or incompatible.
std::optional<BloomBuildPlan> PrepareBloomBuild(ClientContext &context, const OasisScanBindData &bind,
                                               const OasisScanGlobalState &gstate);

// Attempts to acquire the hardware Bloom filter for this scan. Returns true if acquired and sets
// gstate.bloom_filter_held.
bool TryAcquireBloomFilter(ClientContext &context, OasisScanGlobalState &gstate);

// Submits the runtime Bloom filter build side and updates gstate with the build handle and active flag.
void SubmitBloomBuild(ClientContext &context, oasis::OasisContext &ctx, const OasisScanBindData &bind,
                      const BloomBuildPlan &plan, OasisScanGlobalState &gstate);

// Disables row-level evaluation for DuckDB join Bloom filters on the hardware probe column,
// leaving them active only for row-group pruning.
void DisableRowLevelJoinBloomFilters(ClientContext &context, const std::string &probe_key_name,
                                     size_t bloom_probe_slot, std::vector<OasisScanFilter> &scan_filters);

// Drains any submitted but unfinished splinters in the worker's inflight queue on early termination,
// ensuring all probe transfers finish before the probe side is ended.
void DrainInFlightBloomProbeSplinters(OasisScanLocalState &lstate);

class RDMAFileHandle;

// Constructs the unified Bloom filter probe flow (FILTER mask transfer + MATERIALIZE column transfers)
// for this row group and marks materialized columns.
oasis::OperatorFlow ConstructBloomProbeFlow(oasis::OasisContext &ctx,
                                            OasisScanLocalState::PendingGroup &pending,
                                            RDMAFileHandle *rdma,
                                            size_t bloom_probe_slot,
                                            size_t num_projected_columns,
                                            std::vector<bool> &is_bypassed);

// Constructs a bypass decode flow for column chunk k (routing around the Bloom filter).
oasis::OperatorFlow ConstructBypassFlow(oasis::OasisContext &ctx,
                                        const OasisScanLocalState::PendingGroup &pending,
                                        RDMAFileHandle *rdma,
                                        size_t k);

} // namespace duckdb
