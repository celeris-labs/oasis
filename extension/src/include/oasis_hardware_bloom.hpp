#pragma once

namespace oasis {
class OasisContext;
} // namespace oasis

namespace duckdb {

// Configures the hardware Bloom filter block added to hardware/src/vfpga_top.svh. Does not touch the top-level stream select -- that's per-transaction
// (see BloomFilterStreamSelectOperator in oasis_scan.cpp), not a one-time setting.
void ConfigureOasisHardwareBloom(oasis::OasisContext &ctx);

} // namespace duckdb
