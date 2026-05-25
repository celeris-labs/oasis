#pragma once

#include "duckdb.hpp"

namespace duckdb {

void RegexFpgaFunction(DataChunk &args, ExpressionState &state, Vector &result);
unique_ptr<FunctionData> RegexFpgaBind(ClientContext &context, ScalarFunction &bound_function,
                                         vector<unique_ptr<Expression>> &arguments);

} // namespace duckdb
