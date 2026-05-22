#pragma once

#include "oasis_scan.hpp"

namespace duckdb {

struct OasisBloomMockState;

std::shared_ptr<OasisBloomMockState> InitializeOasisBloomMock(ClientContext &context,
                                                              const OasisScanBindData &probe_bind);

void OasisScanFunctionBloomMock(ClientContext &context, TableFunctionInput &data_p, DataChunk &output);

} // namespace duckdb