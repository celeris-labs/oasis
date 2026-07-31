#include "oasis_http_debug.hpp"

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
	g_httpfpga_debug.store(!parameter.IsNull() && parameter.GetValue<bool>());
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
