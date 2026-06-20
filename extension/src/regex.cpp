#include "regex.hpp"
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

#include <cstring>
#include <mutex>
#include <unordered_map>
#include <vector>

namespace duckdb {

static constexpr idx_t REGEX_HW_MAX_STATES = 8;
static constexpr idx_t REGEX_HW_MAX_CHARS = 16;
static constexpr size_t REGEX_CONFIG_BYTES = 64;
static constexpr size_t REGEX_BEAT_BYTES = 64;

static_assert(sizeof(string_t) == 16, "duckdb string_t must match the FPGA wire format");

static vector<uint8_t> CompileRegexBlob(const string &pattern) {
	NFA c(pattern,REGEX_HW_MAX_STATES,REGEX_HW_MAX_CHARS);
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



// rem_engines_async packs up to 512 one-bit match flags per 64-byte output
// word. Bit i (LSB-first within each byte) corresponds to input string i.
static bool ReadMatchBit(const uint8_t *output_bytes, size_t output_size, idx_t string_index) {
	const size_t byte_offset = string_index / 8;
	const size_t bit_in_byte = string_index % 8;
	if (byte_offset >= output_size) {
		return false;
	}
	return (output_bytes[byte_offset] >> bit_in_byte) & 1;
}

static vector<bool> RunFpgaRegexBatch(const vector<string_t>& inputs, const vector<uint8_t>& regex_blob) {
	static std::mutex fpga_mutex;
	std::lock_guard<std::mutex> lock(fpga_mutex);

	const idx_t count = inputs.size();
	if (count == 0) {
		return {};
	}
	oasis::OasisContext &ctx = oasis::OasisContext::ctx();
	std::shared_ptr<celeris::RegexConfig> config = ctx.config<celeris::RegexConfig>();

	libstf::stream_mask_t active_outputs(0);
	active_outputs.set(0);
	std::shared_ptr<libstf::OutputHandle> output_handle = ctx.output_buffer_manager()->acquire_output_handle(active_outputs);

	config->write_bat_count(static_cast<uint32_t>(count));
	config->write_regex_blob(regex_blob);

	uint64_t tight_nonlin_size = 0;
	for (idx_t i = 0; i < count; i++) {
		if (!inputs[i].IsInlined()) {
			tight_nonlin_size += inputs[i].GetSize() + 1;
		}
	}

	const uint64_t data_buffer_size = tight_nonlin_size == 0
	                                      ? 0
	                                      : ((tight_nonlin_size + REGEX_BEAT_BYTES - 1) / REGEX_BEAT_BYTES) * REGEX_BEAT_BYTES;

	libstf::Status status;
	std::shared_ptr<libstf::Buffer> struct_buffer = libstf::make_buffer(ctx.memory_pool(), count * sizeof(string_t), status);
	if (!status.ok()) {
		throw InternalException("Failed to allocate FPGA regex descriptor buffer");
	}

	std::shared_ptr<libstf::Buffer> raw_buffer;
	if (data_buffer_size > 0) {
		raw_buffer = libstf::make_buffer(ctx.memory_pool(), data_buffer_size, status);
		if (!status.ok()) {
			throw InternalException("Failed to allocate FPGA regex payload buffer");
		}
		std::memset(raw_buffer->ptr, 0, data_buffer_size);
	}

	uint64_t data_off = 0;
	for (idx_t i = 0; i < count; i++) {
		const string_t &input = inputs[i];
		string_t *descriptor = reinterpret_cast<string_t *>(static_cast<char *>(struct_buffer->ptr) + i * sizeof(string_t));
		std::memcpy(descriptor, &input, sizeof(string_t));
		if (!input.IsInlined()) {
			descriptor->SetPointer(reinterpret_cast<char *>(data_off));
			char *dest = static_cast<char *>(raw_buffer->ptr) + data_off;
			const idx_t length = input.GetSize();
			std::memcpy(dest, input.GetData(), length);
			dest[length] = '\0';
			data_off += length + 1;
		}
	}

	libstf::enqueue_stream_input(ctx.cthread(), ctx.tlb_manager(), struct_buffer->ptr, count * sizeof(string_t), 0, true);
	if (data_buffer_size > 0) {
		libstf::enqueue_stream_input(ctx.cthread(), ctx.tlb_manager(), raw_buffer->ptr, data_buffer_size, 1, true);
	}

	// Drain every acquired handle, first non-empty beat carries the match bitmap.
	std::shared_ptr<libstf::Buffer> output_buffer;
	while (output_handle->any_stream_has_more_output()) {
		std::shared_ptr<libstf::Buffer> buf = output_handle->get_next_stream_output(0);
		if (buf && output_buffer == nullptr) {
			output_buffer = buf;
		}
	}

	if (output_buffer == nullptr) {
		return vector<bool>(count, false);
	}

	const uint8_t *output_bytes = reinterpret_cast<const uint8_t *>(output_buffer->ptr);
	const size_t output_size = output_buffer->size;
	vector<bool> results(count, false);
	for (idx_t i = 0; i < count; i++) {
		results[i] = ReadMatchBit(output_bytes, output_size, i);
	}
	return results;
}

static void WriteFpgaResults(Vector &result, idx_t count, const vector<idx_t> &result_rows, const vector<bool> &matches) {
	result.SetVectorType(VectorType::FLAT_VECTOR);
	bool *result_data = FlatVector::GetData<bool>(result);
	for (idx_t i = 0; i < result_rows.size(); i++) {
		result_data[result_rows[i]] = matches[i];
	}
}

static void ExecuteFpgaBatch(ClientContext &context, Vector &strings, Vector &result, idx_t count,
                             const vector<uint8_t> &regex_blob) {

	UnifiedVectorFormat str_format;
	strings.ToUnifiedFormat(count, str_format);
	const string_t *str_data = UnifiedVectorFormat::GetData<string_t>(str_format);

	result.SetVectorType(VectorType::FLAT_VECTOR);
	ValidityMask &result_validity = FlatVector::Validity(result);
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
		return;
	}

	vector<bool> matches = RunFpgaRegexBatch(inputs, regex_blob);
	WriteFpgaResults(result, count, result_rows, matches);
}

static void ExecuteFpgaBatchGrouped(ClientContext &context, Vector &strings, Vector &patterns, Vector &result,
                                    idx_t count) {

	UnifiedVectorFormat str_format;
	UnifiedVectorFormat pat_format;
	strings.ToUnifiedFormat(count, str_format);
	patterns.ToUnifiedFormat(count, pat_format);
	const string_t *str_data = UnifiedVectorFormat::GetData<string_t>(str_format);
	const string_t *pat_data = UnifiedVectorFormat::GetData<string_t>(pat_format);

	result.SetVectorType(VectorType::FLAT_VECTOR);
	ValidityMask &result_validity = FlatVector::Validity(result);
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

	bool *result_data = FlatVector::GetData<bool>(result);
	for (const auto &pattern_entry : rows_by_pattern) {
		const string &pattern = pattern_entry.first;
		const vector<idx_t> &rows = pattern_entry.second;
		const vector<string_t> &inputs = inputs_by_pattern[pattern];
		vector<uint8_t> regex_blob = CompileRegexBlob(pattern);
		vector<bool> matches = RunFpgaRegexBatch(inputs, regex_blob);
		for (idx_t i = 0; i < rows.size(); i++) {
			result_data[rows[i]] = matches[i];
		}
	}
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
	ClientContext &context = state.GetContext();
	Vector &strings = args.data[0];
	Vector &patterns = args.data[1];
	const BoundFunctionExpression &func_expr = state.expr.Cast<BoundFunctionExpression>();
	const RegexFpgaBindData &bind_data = func_expr.bind_info->Cast<RegexFpgaBindData>();

	if (bind_data.constant_pattern) {
		ExecuteFpgaBatch(context, strings, result, args.size(), bind_data.regex_blob);
	} else {
		ExecuteFpgaBatchGrouped(context, strings, patterns, result, args.size());
	}
}

} // namespace duckdb
