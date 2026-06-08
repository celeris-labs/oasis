#pragma once

#include "oasis_scan.hpp"

namespace duckdb {

void InitializeOasisHardwareBloom(ClientContext &context, const OasisScanBindData &probe_bind);

void OasisScanFunctionBloomHardware(ClientContext &context, TableFunctionInput &data_p, DataChunk &output);

} // namespace duckdb