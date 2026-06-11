#define DUCKDB_EXTENSION_MAIN

#include "oasis_extension.hpp"
#include "oasis_scan.hpp"
#include "oasis_optimizer.hpp"
#include "duckdb.hpp"
#include "duckdb/function/scalar_function.hpp"
#include "duckdb/main/config.hpp"
#include "duckdb/main/database.hpp"

#include <coyote/cDefs.hpp>

namespace duckdb {

static void LoadInternal(ExtensionLoader &loader) {
	TableFunction table_function("read_oasis",
	                             {LogicalType::VARCHAR},
	                             OasisScanFunction,
	                             OasisScanBind,
	                             OasisScanInitGlobal,
	                             OasisScanInitLocal);
	table_function.projection_pushdown = true;
	table_function.get_virtual_columns = OasisScanGetVirtualColumns;
	loader.RegisterFunction(table_function);

	RegisterOasisOptimizer(loader);
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
