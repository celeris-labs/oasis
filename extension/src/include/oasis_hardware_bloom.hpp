#pragma once

#include "oasis/operator.hpp"
#include "parcore/metadata/metadata.hpp"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <ostream>

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

} // namespace duckdb
