#define DUCKDB_EXTENSION_MAIN

#include "oasis_extension.hpp"
#include "oasis_scan.hpp"
#include "duckdb.hpp"
#include "duckdb/function/scalar_function.hpp"

namespace duckdb {

static void LoadInternal(ExtensionLoader &loader) {
	TableFunction table_function("read_oasis",           // Function name
	                             {LogicalType::VARCHAR}, // Function arguments: Parquet file path
	                             OasisScanFunction,      // Table function
	                             OasisScanBind,          // Bind function
	                             OasisScanInitGlobal,    // Init global function
	                             OasisScanInitLocal      // Init local function
	);
	table_function.projection_pushdown = true;
	table_function.filter_pushdown = true;
	table_function.pushdown_complex_filter = OasisPushdownComplexFilter;
	loader.RegisterFunction(table_function);
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
