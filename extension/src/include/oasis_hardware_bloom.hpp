#pragma once

#include <cstdint>

namespace oasis {
class OasisContext;
} // namespace oasis

namespace duckdb {

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

} // namespace duckdb
