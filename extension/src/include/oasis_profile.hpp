#pragma once

#include "duckdb.hpp"

namespace duckdb {

// Registers the `oasis_stream_profile` table function, which reads the per-decoder StreamProfiler
// counters out of the hardware and reports both the raw counters and derived throughput numbers.
void RegisterOasisProfileFunction(ExtensionLoader &loader);

} // namespace duckdb
