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
	FILTER = 0,
	BYPASS = 1,
	BUILD = 2,
	MATERIALIZE = 3
};

const char *BloomStreamSelectName(BloomStreamSelect select);

// Checks that the hardware design fits the Bloom filter integration in hardware/src/vfpga_top.svh.
void CheckOasisHardwareBloom(oasis::OasisContext &ctx);

// Input commands of celeris's BloomfilterOperator (BFConfig register 1, see
// celeris/hardware/src/hdl/bloomfilter/bloomfilter_operator.sv)
enum class BloomInputCommand : uint8_t {
	CONTINUE = 0,
	END = 1
};

void PushBloomInputCommand(oasis::OasisContext &ctx, BloomInputCommand cmd);

// Materialization command of celeris's MaskMaterializer (BFConfig register 0, see
// celeris/hardware/src/hdl/bloomfilter/mask_materializer.sv)
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
	bool IsKeyChunk() const;

	BloomStreamSelect       select_;
	std::optional<uint32_t> materialize_columns_;
	bool                    end_side_;
};

struct BloomBuildPlan {
	size_t probe_key_slot;
	parcore::metadata::Metadata build_meta;
	std::vector<bool> build_dense_columns; // see ComputeBloomDenseColumns
	size_t build_key_col_id;
};

// BLOOM_MAX_PROBE_ROWS equals MASK_BUFF_SZ * MASK_WIDTH.
// see hardware/src/hdl/bloomfilter/mask_materializer.sv).
constexpr size_t BLOOM_MAX_PROBE_ROWS = (size_t(1) << 14) * 8;

// Per file column: whether the hardware delivers exactly one value per row for it, which is what the
// Bloom filter's mask and materializer need. That holds for a column that
//  - has a definition-level section but no repetition-level one (max_definition_level > 0 and
//    max_repetition_level == 0): the column chunk decoder strips exactly that one leading section, and
//  - has no NULLs in any row group (null_count statistics == 0), so no value is missing.
// A REQUIRED column has no level section for the decoder to strip and is deliberately excluded.
std::vector<bool> ComputeBloomDenseColumns(ParquetReader &reader);

// A 64-bit column the filter's materializer can return the kept rows of.
bool IsBloomMaterializableColumn(const std::vector<bool> &dense_columns, size_t col_id,
                                 const parcore::metadata::ColumnChunk &cc);

// An INT64 column the Bloom filter can take as its key.
bool IsBloomKeyColumn(const parcore::metadata::Metadata &meta, const std::vector<bool> &dense_columns,
                      size_t col_id);

size_t CountBloomKeptRows(const libstf::Buffer &mask, size_t num_rows);

// Atomic hardware lock ensuring only one scan uses the physical Bloom filter at a time.
bool TryAcquireBloomFilter();
void ReleaseBloomFilter();

class ClientContext;
class TableFilter;
bool IsDuckDBJoinBloomFilter(const TableFilter &filter);

struct BloomBuildSubmission {
	oasis::SplinterResultHandle handle;
	bool submitted = false;
	size_t num_chunks = 0;
};

BloomBuildSubmission SubmitBloomBuildSide(ClientContext &context, oasis::OasisContext &ctx,
                                         const std::string &build_filename, const BloomBuildPlan &plan);

void TeardownHardwareBloom(oasis::OasisContext *ctx, oasis::SplinterResultHandle &bloom_build,
                           bool bloom_filter_held, bool bloom_active, bool bloom_build_submitted);

// Populates bloom_sel with the indices of rows kept by the Bloom filter mask within the slice
// [row_offset, row_offset + emit), and returns the count of kept rows.
idx_t ComputeBloomSliceSelection(const libstf::Buffer &mask_buf, size_t row_offset,
                                 idx_t emit, SelectionVector &bloom_sel);

// Throws InternalException on verification error.
void VerifyBloomMaterializedBuffers(const libstf::Buffer &mask_buf, size_t num_rows, size_t group_idx,
                                   const std::vector<bool> &materialized,
                                   const std::vector<std::shared_ptr<libstf::Buffer>> &hw_buffers);

// Validates the probe table and and builds the BloomBuildPlan from the build Parquet file. 
// Returns std::nullopt if the probe key is missing or incompatible.
std::optional<BloomBuildPlan> PrepareBloomBuild(ClientContext &context, const OasisScanBindData &bind,
                                               const OasisScanGlobalState &gstate);

bool TryAcquireBloomFilter(ClientContext &context, OasisScanGlobalState &gstate);

void SubmitBloomBuild(ClientContext &context, oasis::OasisContext &ctx, const OasisScanBindData &bind,
                      const BloomBuildPlan &plan, OasisScanGlobalState &gstate);

void DrainInFlightBloomProbeSplinters(OasisScanLocalState &lstate);

class RDMAFileHandle;

// Constructs the unified Bloom filter probe flow (FILTER mask transfer + MATERIALIZE column transfers)
// for this row group and marks materialized columns.
oasis::OperatorFlow ConstructBloomProbeFlow(oasis::OasisContext &ctx,
                                            OasisScanLocalState::PendingGroup &pending,
                                            RDMAFileHandle *rdma,
                                            size_t bloom_probe_key_slot,
                                            const std::vector<ProjectedColumn> &projected_columns,
                                            const std::vector<bool> &dense_columns,
                                            std::vector<bool> &is_bypassed);

// Constructs a bypass decode flow for column chunk k (routing around the Bloom filter).
oasis::OperatorFlow ConstructBypassFlow(oasis::OasisContext &ctx,
                                        const OasisScanLocalState::PendingGroup &pending,
                                        RDMAFileHandle *rdma,
                                        size_t k);

} // namespace duckdb
