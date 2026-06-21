#pragma once

#include "duckdb.hpp"

namespace duckdb {

void RegexFpgaFunction(DataChunk &args, ExpressionState &state, Vector &result);
unique_ptr<FunctionData> RegexFpgaBind(BindScalarFunctionInput &input);

} // namespace duckdb
