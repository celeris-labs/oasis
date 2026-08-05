#include "oasis_http_debug.hpp"

#include "oasis/configuration.hpp"

#include <atomic>

namespace duckdb {

namespace {

std::atomic<bool> g_httpfpga_debug {false};
std::atomic<bool> g_httpfpga_cpu_fallback {false};
std::atomic<bool> g_httpfpga_raw_bypass {false};

} // namespace

bool HttpFpgaDebugEnabled() {
	return g_httpfpga_debug.load();
}

void SetHttpFpgaDebug(ClientContext &, SetScope, Value &parameter) {
	const bool enabled = !parameter.IsNull() && parameter.GetValue<bool>();
	g_httpfpga_debug.store(enabled);
	// Also turn on the FPGA-side trace (latched CSR echo, handler status, request-ring occupancy).
	// Those messages used to be reachable only via the OASIS_HTTP_DEBUG environment variable, so
	// this setting lit up the host-socket path and left the hardware dark -- which is precisely
	// backwards when a read hangs on the FPGA.
	oasis::set_http_debug(enabled);
}

bool HttpFpgaCpuFallbackEnabled() {
	return g_httpfpga_cpu_fallback.load();
}

void SetHttpFpgaCpuFallback(ClientContext &, SetScope, Value &parameter) {
	g_httpfpga_cpu_fallback.store(!parameter.IsNull() && parameter.GetValue<bool>());
}

bool HttpFpgaRawBypassEnabled() {
	return g_httpfpga_raw_bypass.load();
}

void SetHttpFpgaRawBypass(ClientContext &, SetScope, Value &parameter) {
	g_httpfpga_raw_bypass.store(!parameter.IsNull() && parameter.GetValue<bool>());
}

} // namespace duckdb
