#include "regex.hpp"

#include "duckdb/common/exception.hpp"
#include "duckdb/common/vector_operations/binary_executor.hpp"
#include "duckdb/common/vector_operations/unary_executor.hpp"
#include "duckdb/execution/expression_executor.hpp"
#include "duckdb/planner/expression/bound_function_expression.hpp"

#include <regex>

namespace duckdb {

static unique_ptr<std::regex> CompilePattern(const string &pattern) {
	try {
		return make_uniq<std::regex>(pattern, std::regex::ECMAScript);
	} catch (const std::regex_error &e) {
		throw InvalidInputException("Invalid regex pattern \"%s\": %s", pattern, e.what());
	}
}

struct RegexFpgaBindData : public FunctionData {
	RegexFpgaBindData(bool constant_pattern_p, string pattern_p = string())
	    : constant_pattern(constant_pattern_p), pattern(std::move(pattern_p)) {
		if (constant_pattern) {
			compiled = CompilePattern(this->pattern);
		}
	}

	bool constant_pattern;
	string pattern;
	unique_ptr<std::regex> compiled;

	unique_ptr<FunctionData> Copy() const override {
		return make_uniq<RegexFpgaBindData>(constant_pattern, pattern);
	}

	bool Equals(const FunctionData &other_p) const override {
		const RegexFpgaBindData &other = other_p.Cast<RegexFpgaBindData>();
		return constant_pattern == other.constant_pattern && pattern == other.pattern;
	}
};

static bool RegexSearch(const string_t &input, const std::regex &re) {
	return std::regex_search(string(input), re);
}

unique_ptr<FunctionData> RegexFpgaBind(ClientContext &context, ScalarFunction &bound_function,
                                         vector<unique_ptr<Expression>> &arguments) {
	D_ASSERT(arguments.size() == 2);
	if (arguments[1]->IsFoldable()) {
		Value pattern_val = ExpressionExecutor::EvaluateScalar(context, *arguments[1]);
		if (!pattern_val.IsNull()) {
			return make_uniq<RegexFpgaBindData>(true, StringValue::Get(pattern_val));
		}
	}
	return make_uniq<RegexFpgaBindData>(false);
}

void RegexFpgaFunction(DataChunk &args, ExpressionState &state, Vector &result) {
	Vector &strings = args.data[0];
	Vector &patterns = args.data[1];
	const BoundFunctionExpression &func_expr = state.expr.Cast<BoundFunctionExpression>();
	const RegexFpgaBindData &bind_data = func_expr.bind_info->Cast<RegexFpgaBindData>();

	if (bind_data.constant_pattern) {
		const std::regex &re = *bind_data.compiled;
		UnaryExecutor::Execute<string_t, bool>(strings, result, args.size(),
		                                       [&](string_t input) { return RegexSearch(input, re); });
	} else {
		BinaryExecutor::Execute<string_t, string_t, bool>(
		    strings, patterns, result, args.size(), [&](string_t input, string_t pattern) {
			    unique_ptr<std::regex> re = CompilePattern(string(pattern));
			    return RegexSearch(input, *re);
		    });
	}
}

} // namespace duckdb
