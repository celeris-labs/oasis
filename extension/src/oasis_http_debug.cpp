#include "oasis_http_debug.hpp"

#include "oasis/configuration.hpp"

#include <atomic>
#include <cstdlib>

namespace duckdb {

namespace {

std::atomic<bool> g_httpfpga_debug {false};

} // namespace

bool HttpFpgaDebugEnabled() {
	return g_httpfpga_debug.load();
}

bool HttpFpgaReadTraceEnabled() {
	// Read once: this is tested on every buffered read and must not cost a getenv per call.
	static const bool enabled = [] {
		const char *value = std::getenv("OASIS_READBUF_TRACE");
		return value != nullptr && value[0] != '\0' && value[0] != '0';
	}();
	return enabled;
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

} // namespace duckdb
