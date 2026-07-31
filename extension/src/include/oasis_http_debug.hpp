#pragma once

#include "duckdb.hpp"
#include "duckdb/main/extension/extension_loader.hpp"

namespace duckdb {

bool HttpFpgaDebugEnabled();

void SetHttpFpgaDebug(ClientContext &context, SetScope scope, Value &parameter);

// Forces raw httpfpga:// byte reads over an ordinary host socket. Now the default behaviour (see
// HttpFpgaRawBypassEnabled), so this only still matters as an explicit override of that flag.
//
// It does NOT redirect read_oasis's column-chunk fetches: on an ENABLE_HTTP bitstream axis_host_recv
// is tied off, so host DMA cannot reach the decoder at all — the FPGA issuing its own GET is the
// only way to feed it.
bool HttpFpgaCpuFallbackEnabled();

void SetHttpFpgaCpuFallback(ClientContext &context, SetScope scope, Value &parameter);

// Legacy: route raw httpfpga:// byte reads through the FPGA's bypass stream. Only works on a
// pre-decoder bitstream (one where axi_out[BYPASS_ID] still carries the stripped body). On the
// current bitstream that stream is tied off and the read blocks forever, so this defaults to false
// and raw reads go over a host socket. Toggle with `SET httpfpga_raw_bypass = true;`.
bool HttpFpgaRawBypassEnabled();

void SetHttpFpgaRawBypass(ClientContext &context, SetScope scope, Value &parameter);

} // namespace duckdb
