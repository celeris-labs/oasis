#include "regex.hpp"
#include "regex_fpga_batch.hpp"
#include "celeris/celeris_context.hpp"
#include "nfa.hpp"

#include "celeris/configuration.hpp"
#include "celeris/operators/regex/fregex.h"
#include "duckdb/common/exception.hpp"
#include "duckdb/common/types/vector.hpp"
#include "duckdb/execution/expression_executor.hpp"
#include "duckdb/planner/expression/bound_function_expression.hpp"
#include "duckdb/storage/object_cache.hpp"
#include "libstf/buffer.hpp"
#include "libstf/util.hpp"
#include "oasis/oasis_context.hpp"
#include "oasis_profiling.hpp"

#include <cstring>
#include <unordered_map>
#include <vector>

namespace duckdb {

// These must equal the flashed bitstream's rem_top_ff STATE_COUNT / CHAR_COUNT:
// NFA below emits the config blob, and a mismatch shifts every field after
// state_pred, so the card decodes a valid-looking but wrong pattern.
//
// Taken from the compile definitions rather than restated, because restating is
// how this drifted: these sat at 12/12 against a 24-state, 32-char bitstream
// while regex_table.cpp had been updated, so the scalar regex_fpga() path
// compiled blobs the card could not decode. OASIS_REGEX_MAX_STATES /
// OASIS_REGEX_MAX_TOKENS in CMakeLists.txt is the single source for both paths.
#if !defined(REGEX_MAX_STATES) || !defined(REGEX_MAX_TOKENS)
#error "REGEX_MAX_STATES / REGEX_MAX_TOKENS must be set from CMake (see OASIS_REGEX_MAX_*)"
#endif
static constexpr idx_t REGEX_HW_MAX_STATES = REGEX_MAX_STATES;
static constexpr idx_t REGEX_HW_MAX_CHARS = REGEX_MAX_TOKENS;

static vector<uint8_t> CompileRegexBlob(const string &pattern) {
	CALI_CXX_MARK_FUNCTION;
	NFA c(pattern, REGEX_HW_MAX_STATES, REGEX_HW_MAX_CHARS);
	return c.dump_binary();
}

struct RegexFpgaBindData : public FunctionData {
	RegexFpgaBindData(bool constant_pattern_p, string pattern_p = string())
	    : constant_pattern(constant_pattern_p), pattern(std::move(pattern_p)) {
		if (constant_pattern) {
			regex_blob = CompileRegexBlob(this->pattern);
		}
	}

	RegexFpgaBindData(bool constant_pattern_p, string pattern_p, vector<uint8_t> regex_blob_p)
	    : constant_pattern(constant_pattern_p), pattern(std::move(pattern_p)), regex_blob(std::move(regex_blob_p)) {
	}

	bool constant_pattern;
	string pattern;
	vector<uint8_t> regex_blob;

	unique_ptr<FunctionData> Copy() const override {
		return make_uniq<RegexFpgaBindData>(constant_pattern, pattern, regex_blob);
	}

	bool Equals(const FunctionData &other_p) const override {
		const RegexFpgaBindData &other = other_p.Cast<RegexFpgaBindData>();
		return constant_pattern == other.constant_pattern && pattern == other.pattern;
	}
};

static void WriteFpgaResults(Vector &result, idx_t count, const vector<idx_t> &result_rows, const vector<bool> &matches) {
	result.SetVectorType(VectorType::FLAT_VECTOR);
	bool *result_data = FlatVector::GetDataMutable<bool>(result);
	for (idx_t i = 0; i < result_rows.size(); i++) {
		result_data[result_rows[i]] = matches[i];
	}
}

static void ExecuteFpgaBatch(ClientContext &context, Vector &strings, Vector &result, idx_t count,
                             const vector<uint8_t> &regex_blob) {
	CALI_MARK_BEGIN("ExecuteFpgaBatch");

	UnifiedVectorFormat str_format;
	strings.ToUnifiedFormat(str_format);
	const string_t *str_data = UnifiedVectorFormat::GetData<string_t>(str_format);

	result.SetVectorType(VectorType::FLAT_VECTOR);
	ValidityMask &result_validity = FlatVector::ValidityMutable(result);
	result_validity.Initialize(count);

	vector<string_t> inputs;
	vector<idx_t> result_rows;
	inputs.reserve(count);
	result_rows.reserve(count);

	for (idx_t row = 0; row < count; row++) {
		const idx_t idx = str_format.sel->get_index(row);
		if (!str_format.validity.RowIsValid(idx)) {
			result_validity.SetInvalid(row);
			continue;
		}
		inputs.push_back(str_data[idx]);
		result_rows.push_back(row);
	}

	if (inputs.empty()) {
		CALI_MARK_END("ExecuteFpgaBatch");
		return;
	}

	celeris::CelerisContext &ctx = GetCelerisContext();
	vector<bool> matches = RunFpgaRegexBatch(ctx, inputs, regex_blob);
	WriteFpgaResults(result, count, result_rows, matches);
	CALI_MARK_END("ExecuteFpgaBatch");
}

static void ExecuteFpgaBatchGrouped(ClientContext &context, Vector &strings, Vector &patterns, Vector &result,
                                    idx_t count) {

	CALI_MARK_BEGIN("ExecuteFpgaBatchGrouped_withoutExecution");

	UnifiedVectorFormat str_format;
	UnifiedVectorFormat pat_format;
	strings.ToUnifiedFormat(str_format);
	patterns.ToUnifiedFormat(pat_format);
	const string_t *str_data = UnifiedVectorFormat::GetData<string_t>(str_format);
	const string_t *pat_data = UnifiedVectorFormat::GetData<string_t>(pat_format);

	result.SetVectorType(VectorType::FLAT_VECTOR);
	ValidityMask &result_validity = FlatVector::ValidityMutable(result);
	result_validity.Initialize(count);

	std::unordered_map<string, vector<idx_t>> rows_by_pattern;
	std::unordered_map<string, vector<string_t>> inputs_by_pattern;

	for (idx_t row = 0; row < count; row++) {
		const idx_t str_idx = str_format.sel->get_index(row);
		const idx_t pat_idx = pat_format.sel->get_index(row);
		if (!str_format.validity.RowIsValid(str_idx) || !pat_format.validity.RowIsValid(pat_idx)) {
			result_validity.SetInvalid(row);
			continue;
		}

		const string pattern_key = string(pat_data[pat_idx]);
		inputs_by_pattern[pattern_key].push_back(str_data[str_idx]);
		rows_by_pattern[pattern_key].push_back(row);
	}

	CALI_MARK_END("ExecuteFpgaBatchGrouped_withoutExecution");
	celeris::CelerisContext &ctx = GetCelerisContext();
	bool *result_data = FlatVector::GetDataMutable<bool>(result);
	for (const auto &pattern_entry : rows_by_pattern) {
		const string &pattern = pattern_entry.first;
		const vector<idx_t> &rows = pattern_entry.second;
		const vector<string_t> &inputs = inputs_by_pattern[pattern];
		vector<uint8_t> pattern_blob = CompileRegexBlob(pattern);
		vector<bool> matches = RunFpgaRegexBatch(ctx, inputs, pattern_blob);
		for (idx_t i = 0; i < rows.size(); i++) {
			result_data[rows[i]] = matches[i];
		}
	}
}

unique_ptr<FunctionData> RegexFpgaBind(BindScalarFunctionInput &input) {
	auto &context = input.GetClientContext();
	auto &arguments = input.GetArguments();
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
	ClientContext &context = state.GetContext();
	Vector &strings = args.data[0];
	Vector &patterns = args.data[1];
	const BoundFunctionExpression &func_expr = state.expr.Cast<BoundFunctionExpression>();
	const RegexFpgaBindData &bind_data = func_expr.BindInfo()->Cast<RegexFpgaBindData>();

	if (bind_data.constant_pattern) {
		ExecuteFpgaBatch(context, strings, result, args.size(), bind_data.regex_blob);
	} else {
		ExecuteFpgaBatchGrouped(context, strings, patterns, result, args.size());
	}
}

} // namespace duckdb
