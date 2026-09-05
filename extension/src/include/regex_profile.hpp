#pragma once

#include "duckdb.hpp"
#include "duckdb/main/extension/extension_loader.hpp"

namespace duckdb {

// Registers regex_fpga_stream_profile(): reads the StreamProfiler counters that
// regex_top taps on the splitter input, an engine input FIFO and the result
// output, so starvation and backpressure can be attributed on real hardware.
void RegisterRegexProfileFunction(ExtensionLoader &loader);

} // namespace duckdb
