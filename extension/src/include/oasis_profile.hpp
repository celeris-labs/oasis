#pragma once

#include "duckdb.hpp"
#include "oasis_decoder_perf.hpp"

namespace oasis {
class OasisContext;
} // namespace oasis

namespace duckdb {

// Reads (and thereby re-arms) the StreamProfiler counters of decoder stream 0, the only decoder of the
// bitstream. The profiler counts from the first beat after the previous read, so a read between two phases of a
// query splits its counters there. Registers are plain MMIO reads, safe from any thread.
DecoderProfileCounters ReadDecoderProfile(oasis::OasisContext &ctx);

// Registers the `oasis_stream_profile` table function, which reads the per-decoder StreamProfiler
// counters out of the hardware and reports both the raw counters and derived throughput numbers.
void RegisterOasisProfileFunction(ExtensionLoader &loader);

} // namespace duckdb
