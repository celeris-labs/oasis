#define DUCKDB_EXTENSION_MAIN

#include "oasis_extension.hpp"
#include "oasis_scan.hpp"
#include "oasis_log_sink.hpp"
#include "rdma_file_system.hpp"
#include "duckdb.hpp"
#include "duckdb/function/scalar_function.hpp"
#include "duckdb/main/config.hpp"
#include "duckdb/main/database.hpp"

#include <coyote/cDefs.hpp>

namespace duckdb {

// Default verbosity for the oasis_log_level setting (and libstf's runtime threshold at load).
static constexpr const char *DEFAULT_OASIS_LOG_LEVEL = "ERROR";

static void SetOasisLogLevel(ClientContext &, SetScope, Value &parameter) {
	if (parameter.IsNull()) {
		return;
	}
	libstf::set_log_level(ParseLibstfLogLevel(parameter.GetValue<string>()));
}

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
	                          Value::UBIGINT(0));
	config.AddExtensionOption("oasis_scheduler_queue_depth",
	                          "Max splinters in flight per stream (0 = hardware config-FIFO depth)",
	                          LogicalType::UBIGINT, Value::UBIGINT(0));

	TableFunction table_function("read_oasis",           // Function name
	                             {LogicalType::VARCHAR}, // Function arguments: Parquet file path
	                             OasisScanFunction,      // Table function
	                             OasisScanBind,          // Bind function
	                             OasisScanInitGlobal,    // Init global function
	                             OasisScanInitLocal      // Init local function
	);
	table_function.projection_pushdown = true;
	table_function.get_virtual_columns = OasisScanGetVirtualColumns;
	loader.RegisterFunction(table_function);

	// RDMA file system
	config.AddExtensionOption("oasis_rdma_server",
	                          "RDMA file server IP address (required; set via `SET oasis_rdma_server = '<ip-address>';`)",
	                          LogicalType::VARCHAR, Value(LogicalType::VARCHAR));
	config.AddExtensionOption("oasis_rdma_port", "RDMA file server TCP port (for QP exchange)", LogicalType::UBIGINT,
	                          Value::UBIGINT(static_cast<uint64_t>(coyote::DEF_PORT)));

	FileSystem::GetFileSystem(instance).RegisterSubSystem(make_uniq<RDMAFileSystem>());
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
