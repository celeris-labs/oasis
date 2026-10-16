#pragma once

#include "duckdb.hpp"
#include "duckdb/main/extension/extension_loader.hpp"

namespace duckdb {

bool HttpFpgaDebugEnabled();

void SetHttpFpgaDebug(ClientContext &context, SetScope scope, Value &parameter);

// Diagnostic trace of the host read path, for the quadratic re-read measured on 2026-09-19
// (row group i costs i MiB; granule = READ_BUFFER_LEN). Logs one line per actual fetch, so the
// offsets can be checked for a repeated sweep back towards the start of the file.
//
// Deliberately environment-only (OASIS_READBUF_TRACE) and NOT wired to httpfpga_debug: that
// setting resets the FPGA counters, so it cannot be turned on during a measurement.
bool HttpFpgaReadTraceEnabled();

} // namespace duckdb
