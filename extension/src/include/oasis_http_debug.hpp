#pragma once

#include "duckdb.hpp"
#include "duckdb/main/extension/extension_loader.hpp"

namespace duckdb {

bool HttpFpgaDebugEnabled();

void SetHttpFpgaDebug(ClientContext &context, SetScope scope, Value &parameter);

// When enabled, httpfpga:// reads fetch bytes over an ordinary host socket instead of the FPGA.
// Correct but bypasses the FPGA data path entirely — a stopgap while the HW receive path is
// validated. Toggle with `SET httpfpga_cpu_fallback = true;`.
bool HttpFpgaCpuFallbackEnabled();

void SetHttpFpgaCpuFallback(ClientContext &context, SetScope scope, Value &parameter);

} // namespace duckdb
