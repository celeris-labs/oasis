#pragma once

#include <cstdint>

namespace oasis {
class OasisContext;
} // namespace oasis

namespace duckdb {

// Configures the hardware Bloom filter block added to hardware/src/vfpga_top.svh. Does not touch the top-level stream select -- that's per-transaction
// (see BloomFilterStreamSelectOperator in oasis_scan.cpp), not a one-time setting.
void ConfigureOasisHardwareBloom(oasis::OasisContext &ctx);

// Input commands of celeris's BloomfilterOperator (BFConfig register 1, see
// celeris/hardware/src/hdl/bloomfilter/bloomfilter_operator.sv). Every transfer through the filter
// (a build or probe key chunk) needs one, written before the transfer and in transfer order, so it
// has to be pushed from the flow's operator on the dispatcher (like the stream select). The core
// switches build -> probe -> flush only on a side's END/END_ONLY; every transfer is its own chunk
// with its own mask.
enum class BloomInputCommand : uint8_t {
	CONTINUE = 0, // The next transfer belongs to the current side, more follow
	END = 1,      // The next transfer is the last one of its side
	END_ONLY = 2  // Ends the current side without a transfer
};

void PushBloomInputCommand(oasis::OasisContext &ctx, BloomInputCommand cmd);

// Materialization command of celeris's MaskMaterializer (BFConfig register 0, see
// celeris/hardware/src/hdl/bloomfilter/mask_materializer.sv): every probe key chunk needs one, in
// chunk order, pushed with its input command. It gives the number of columns (MATERIALIZE
// transfers of 64-bit values) that follow the chunk and are materialized with its mask, 0 for none.
void PushBloomMaterializeCommand(oasis::OasisContext &ctx, uint32_t num_columns);

// Whether a write to one of the (1024-entry) command queues was ever lost because it was full.
bool BloomCommandQueueOverflowed(oasis::OasisContext &ctx);

} // namespace duckdb
