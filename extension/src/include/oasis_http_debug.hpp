#pragma once

#include "duckdb.hpp"
#include "duckdb/main/extension/extension_loader.hpp"

#include <cstdint>
#include <mutex>
#include <string>

namespace duckdb {

struct HttpFpgaLastTrigger {
	bool valid = false;
	uint32_t bypass_stream = 0;
	uint32_t server_ip = 0;
	uint16_t server_port = 0;
	uint32_t file_len = 0;
	uint64_t range_begin = 0;
	uint64_t range_end = 0;
	uint32_t size = 0;
	std::string path;
};

void RegisterOasisHttpStateFunction(ExtensionLoader &loader);

bool HttpFpgaDebugEnabled();

void SetHttpFpgaDebug(ClientContext &context, SetScope scope, Value &parameter);

// When enabled, httpfpga:// reads fetch bytes over an ordinary host socket instead of the FPGA.
// Correct but bypasses the FPGA data path entirely — a stopgap while the HW receive path is
// validated. Toggle with `SET httpfpga_cpu_fallback = true;`.
bool HttpFpgaCpuFallbackEnabled();

void SetHttpFpgaCpuFallback(ClientContext &context, SetScope scope, Value &parameter);

void RecordHttpFpgaTrigger(uint32_t bypass_stream, uint32_t server_ip, uint16_t server_port, const std::string &path,
                           uint64_t range_begin, uint64_t range_end, uint32_t size);

HttpFpgaLastTrigger LastHttpFpgaTrigger();

} // namespace duckdb
