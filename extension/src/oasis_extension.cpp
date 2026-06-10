#define DUCKDB_EXTENSION_MAIN

#include "oasis_extension.hpp"
#include "oasis_scan.hpp"
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

	// Oasis table function
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

	config.AddExtensionOption("oasis_scheduler_num_streams",
	                          "Number of streams the scheduler drives (0 = all available)", LogicalType::UBIGINT,
	                          Value::UBIGINT(0));
	config.AddExtensionOption("oasis_scheduler_queue_depth",
	                          "Max splinters in flight per stream (0 = hardware config-FIFO depth)",
	                          LogicalType::UBIGINT, Value::UBIGINT(0));

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
