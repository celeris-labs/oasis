#define DUCKDB_EXTENSION_MAIN

#include "oasis_extension.hpp"
#include "oasis_profile.hpp"
#include "oasis_scan.hpp"
#include "regex.hpp"
#include "oasis_context_cache_entry.hpp"
#include "oasis_settings.hpp"
#include "oasis_log_sink.hpp"
#include "rdma_file_system.hpp"
#include "duckdb.hpp"
#include "duckdb/function/scalar_function.hpp"
#include "duckdb/main/config.hpp"
#include "duckdb/main/database.hpp"

#include <coyote/cDefs.hpp>

namespace duckdb {

static void LoadInternal(ExtensionLoader &loader) {
	auto &instance = loader.GetDatabaseInstance();
	auto &config = DBConfig::GetConfig(instance);

	config.AddExtensionOption("oasis_logging_level",
	                          "libSTF/ParCore/OAL log verbosity (TRACE, DEBUG, INFO, WARNING, ERROR, FATAL, OFF). "
	                          "Records also pass through DuckDB's logging_level before reaching duckdb_logs",
	                          LogicalType::VARCHAR, Value(DEFAULT_OASIS_LOG_LEVEL), SetOasisLogLevel);
	libstf::set_log_level(ParseLibstfLogLevel(DEFAULT_OASIS_LOG_LEVEL));

	// Oasis table function
	config.AddExtensionOption("oasis_scheduler_num_streams",
	                          "Number of streams the scheduler drives (0 = all available)", LogicalType::UBIGINT,
	                          Value::UBIGINT(0), SetSchedulerNumStreams);
	config.AddExtensionOption("oasis_scheduler_queue_depth",
	                          "Max splinters in flight per stream (0 = hardware config-FIFO depth)",
	                          LogicalType::UBIGINT, Value::UBIGINT(0), SetSchedulerQueueDepth);
	config.AddExtensionOption(
	    "oasis_scan_groups_in_flight",
	    "Row groups a single read_oasis scan keeps submitted but not yet collected, overlapping "
	    "submission with collection. Split across the scan's worker threads (each worker keeps "
	    "ceil(value / threads) groups in flight but at least 1).",
	    LogicalType::UBIGINT, Value::UBIGINT(16));

	// Oasis scan table function
	RegisterOasisScanFunction(loader);

	// Stream profiler readout table function
	RegisterOasisProfileFunction(loader);

	// RDMA file system
	config.AddExtensionOption(
	    "oasis_rdma_server",
	    "RDMA file server IP address (required; set via `SET oasis_rdma_server = '<ip-address>';`)",
	    LogicalType::VARCHAR, Value(LogicalType::VARCHAR));
	config.AddExtensionOption("oasis_rdma_port", "RDMA file server TCP port (for QP exchange)", LogicalType::UBIGINT,
	                          Value::UBIGINT(static_cast<uint64_t>(coyote::DEF_PORT)));

	FileSystem::GetFileSystem(instance).RegisterSubSystem(make_uniq<RDMAFileSystem>());

	// FPGA contexts are established lazily on first use: read_oasis initializes the OasisContext
	// in its scan-init path, and regex_fpga initializes the CelerisContext on first execution.
	// Connecting eagerly here would require a specific bitstream to be loaded at extension-load
	// time, which breaks regex-only simulation runs against the Celeris regex bitstream.
	ScalarFunction regex_function("regex_fpga",
	                              {LogicalType::VARCHAR, LogicalType::VARCHAR}, // string, pattern
	                              LogicalType::BOOLEAN, RegexFpgaFunction, RegexFpgaBind);
	loader.RegisterFunction(regex_function);
}

void OasisExtension::Load(ExtensionLoader &loader) {
	LoadInternal(loader);
}

std::string OasisExtension::Name() {
	return "Oasis";
}

std::string OasisExtension::Version() const {
#ifdef EXT_VERSION_OASIS
	return EXT_VERSION_OASIS;
#else
	return "";
#endif
}

} // namespace duckdb

extern "C" {
DUCKDB_CPP_EXTENSION_ENTRY(oasis, loader) {
	duckdb::LoadInternal(loader);
}
}
