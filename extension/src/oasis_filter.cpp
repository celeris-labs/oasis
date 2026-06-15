#include "oasis_filter.hpp"

#include "duckdb/common/exception.hpp"
#include "duckdb/planner/expression/bound_between_expression.hpp"
#include "duckdb/planner/expression/bound_columnref_expression.hpp"
#include "duckdb/planner/expression/bound_comparison_expression.hpp"
#include "duckdb/planner/expression/bound_conjunction_expression.hpp"
#include "duckdb/planner/expression/bound_constant_expression.hpp"
#include "duckdb/planner/filter/conjunction_filter.hpp"
#include "duckdb/planner/filter/constant_filter.hpp"
#include "duckdb/planner/filter/in_filter.hpp"
#include "duckdb/planner/filter/optional_filter.hpp"
#include "duckdb/planner/operator/logical_get.hpp"
#include "oasis_scan.hpp"

#include <numeric>

namespace duckdb {

static oasis::FilterComparison filter_comparison_to_oasis(ExpressionType comparison) {
	switch (comparison) {
	case ExpressionType::COMPARE_EQUAL:
		return oasis::FilterComparison::EQUAL;
	case ExpressionType::COMPARE_NOTEQUAL:
		return oasis::FilterComparison::NOT_EQUAL;
	case ExpressionType::COMPARE_GREATERTHAN:
		return oasis::FilterComparison::GREATER;
	case ExpressionType::COMPARE_LESSTHAN:
		return oasis::FilterComparison::LOWER;
	case ExpressionType::COMPARE_GREATERTHANOREQUALTO:
		return oasis::FilterComparison::GREATER_EQUAL;
	case ExpressionType::COMPARE_LESSTHANOREQUALTO:
		return oasis::FilterComparison::LOWER_EQUAL;
	default:
		throw InvalidInputException("Oasis hardware filter does not support comparison type %d", (int)comparison);
	}
}

static uint64_t filter_rhs(const Value &constant) {
	if (constant.IsNull()) {
		throw InvalidInputException("Oasis hardware filtering does not support NULL constants");
	}
	return static_cast<uint64_t>(constant.DefaultCastAs(LogicalType::BIGINT).GetValue<int64_t>());
}

static OasisFilter make_list_filter(const vector<Value> &values) {
	constexpr size_t MAX_LIST_VALUES =
	    oasis::FilterConfig::NUM_RHS + oasis::FilterConfig::NUM_ADDITIONAL_RHS;
	if (values.size() < 2 || values.size() > MAX_LIST_VALUES) {
		throw InvalidInputException("Oasis hardware IN filtering supports between 2 and %llu values",
		                            static_cast<unsigned long long>(MAX_LIST_VALUES));
	}

	OasisFilter result;
	result.comparison = values.size() == oasis::FilterConfig::NUM_RHS
	                        ? oasis::FilterComparison::ONE_OF
	                        : oasis::FilterComparison::IN_LIST;

	for (size_t i = 0; i < values.size(); i++) {
		auto rhs = filter_rhs(values[i]);
		if (i < oasis::FilterConfig::NUM_RHS) {
			result.rhs[i] = rhs;
		} else {
			const auto additional_index = i - oasis::FilterConfig::NUM_RHS;
			result.additional_rhs[additional_index] = rhs;
			result.additional_rhs_mask |= uint8_t {1} << additional_index;
		}
	}
	return result;
}

using FilterTerm = pair<ExpressionType, Value>;

static bool make_filter(const vector<FilterTerm> &terms, OasisFilter &result) {
	if (terms.size() == 1) {
		result = {filter_comparison_to_oasis(terms[0].first), {filter_rhs(terms[0].second)}};
		return true;
	}
	if (terms.size() != 2) {
		return false;
	}

	const FilterTerm *lower = nullptr;
	const FilterTerm *upper = nullptr;
	for (const auto &term : terms) {
		if (term.first == ExpressionType::COMPARE_GREATERTHANOREQUALTO) {
			lower = &term;
		} else if (term.first == ExpressionType::COMPARE_LESSTHAN ||
		           term.first == ExpressionType::COMPARE_LESSTHANOREQUALTO) {
			upper = &term;
		}
	}
	if (!lower || !upper) {
		return false;
	}
	result.comparison = upper->first == ExpressionType::COMPARE_LESSTHAN
	                        ? oasis::FilterComparison::IN_RANGE
	                        : oasis::FilterComparison::IN_BETWEEN;
	result.rhs = {filter_rhs(lower->second), filter_rhs(upper->second)};
	return true;
}

static OasisFilter translate_filter(const TableFilter &filter) {
	if (filter.filter_type == TableFilterType::CONSTANT_COMPARISON) {
		auto &constant = filter.Cast<ConstantFilter>();
		OasisFilter result;
		make_filter({{constant.comparison_type, constant.constant}}, result);
		return result;
	}
	if (filter.filter_type == TableFilterType::OPTIONAL_FILTER) {
		auto &optional = filter.Cast<OptionalFilter>();
		if (optional.child_filter) {
			return translate_filter(*optional.child_filter);
		}
	}
	if (filter.filter_type == TableFilterType::IN_FILTER) {
		return make_list_filter(filter.Cast<InFilter>().values);
	}
	if (filter.filter_type != TableFilterType::CONJUNCTION_AND &&
	    filter.filter_type != TableFilterType::CONJUNCTION_OR) {
		throw InvalidInputException("Oasis hardware filter type is not supported");
	}

	auto &children = filter.filter_type == TableFilterType::CONJUNCTION_AND
	                     ? filter.Cast<ConjunctionAndFilter>().child_filters
	                     : filter.Cast<ConjunctionOrFilter>().child_filters;
	vector<FilterTerm> terms;
	vector<Value> values;
	for (const auto &child : children) {
		if (child->filter_type != TableFilterType::CONSTANT_COMPARISON) {
			break;
		}
		auto &constant = child->Cast<ConstantFilter>();
		terms.emplace_back(constant.comparison_type, constant.constant);
		if (constant.comparison_type == ExpressionType::COMPARE_EQUAL) {
			values.push_back(constant.constant);
		}
	}

	OasisFilter result;
	if (filter.filter_type == TableFilterType::CONJUNCTION_AND &&
	    terms.size() == children.size() && make_filter(terms, result)) {
		return result;
	}
	if (filter.filter_type == TableFilterType::CONJUNCTION_OR &&
	    values.size() == children.size()) {
		return make_list_filter(values);
	}
	throw InvalidInputException(
	    "Oasis hardware filtering supports comparisons, bounded ranges, and equality lists");
}

static bool bound_column_id(const Expression &expr, const LogicalGet &get, idx_t &column_id) {
	if (expr.GetExpressionClass() != ExpressionClass::BOUND_COLUMN_REF) {
		return false;
	}
	auto &column_ref = expr.Cast<BoundColumnRefExpression>();
	if (column_ref.depth != 0 || column_ref.binding.table_index != get.table_index) {
		return false;
	}
	const auto &column_ids = get.GetColumnIds();
	if (column_ref.binding.column_index >= column_ids.size()) {
		return false;
	}
	column_id = column_ids[column_ref.binding.column_index].GetPrimaryIndex();
	return true;
}

static bool bound_filter_term(const Expression &expr, const LogicalGet &get, idx_t &column_id,
                              FilterTerm &term) {
	if (expr.GetExpressionClass() != ExpressionClass::BOUND_COMPARISON) {
		return false;
	}

	auto &comparison = expr.Cast<BoundComparisonExpression>();
	const BoundConstantExpression *constant = nullptr;
	if (bound_column_id(*comparison.left, get, column_id) &&
	    comparison.right->GetExpressionClass() == ExpressionClass::BOUND_CONSTANT) {
		constant = &comparison.right->Cast<BoundConstantExpression>();
		term.first = comparison.GetExpressionType();
	} else if (bound_column_id(*comparison.right, get, column_id) &&
	           comparison.left->GetExpressionClass() == ExpressionClass::BOUND_CONSTANT) {
		constant = &comparison.left->Cast<BoundConstantExpression>();
		term.first = FlipComparisonExpression(comparison.GetExpressionType());
	} else {
		return false;
	}

	switch (term.first) {
	case ExpressionType::COMPARE_EQUAL:
	case ExpressionType::COMPARE_NOTEQUAL:
	case ExpressionType::COMPARE_GREATERTHAN:
	case ExpressionType::COMPARE_LESSTHAN:
	case ExpressionType::COMPARE_GREATERTHANOREQUALTO:
	case ExpressionType::COMPARE_LESSTHANOREQUALTO:
		break;
	default:
		return false;
	}
	if (constant->value.IsNull()) {
		return false;
	}
	term.second = constant->value;
	return true;
}

static bool collect_filter_terms(const Expression &expr, const LogicalGet &get,
                                 map<idx_t, vector<FilterTerm>> &terms) {
	if (expr.GetExpressionClass() == ExpressionClass::BOUND_CONJUNCTION &&
	    expr.GetExpressionType() == ExpressionType::CONJUNCTION_AND) {
		auto &conjunction = expr.Cast<BoundConjunctionExpression>();
		for (const auto &child : conjunction.children) {
			if (!collect_filter_terms(*child, get, terms)) {
				return false;
			}
		}
		return true;
	}

	if (expr.GetExpressionClass() == ExpressionClass::BOUND_BETWEEN) {
		auto &between = expr.Cast<BoundBetweenExpression>();
		idx_t column_id;
		if (!between.lower_inclusive || !bound_column_id(*between.input, get, column_id) ||
		    between.lower->GetExpressionClass() != ExpressionClass::BOUND_CONSTANT ||
		    between.upper->GetExpressionClass() != ExpressionClass::BOUND_CONSTANT ||
		    terms.find(column_id) != terms.end()) {
			return false;
		}
		auto &lower = between.lower->Cast<BoundConstantExpression>();
		auto &upper = between.upper->Cast<BoundConstantExpression>();
		if (lower.value.IsNull() || upper.value.IsNull()) {
			return false;
		}
		terms[column_id] = {{ExpressionType::COMPARE_GREATERTHANOREQUALTO, lower.value},
		                    {between.UpperComparisonType(), upper.value}};
		return true;
	}

	idx_t column_id;
	FilterTerm term;
	if (!bound_filter_term(expr, get, column_id, term)) {
		return false;
	}
	terms[column_id].push_back(std::move(term));
	return true;
}

static bool translate_branch(const Expression &expr, const LogicalGet &get, OasisFilterLayer &layer) {
	map<idx_t, vector<FilterTerm>> terms;
	if (!collect_filter_terms(expr, get, terms)) {
		return false;
	}
	for (auto &entry : terms) {
		OasisFilter filter;
		if (!make_filter(entry.second, filter)) {
			return false;
		}
		layer.emplace(entry.first, std::move(filter));
	}
	return !layer.empty();
}

static size_t column_position(const vector<size_t> &columns, idx_t column_id) {
	auto column = std::find(columns.begin(), columns.end(), column_id);
	if (column == columns.end()) {
		throw InternalException("Oasis filter column is not available in the scan");
	}
	return column - columns.begin();
}

static string filter_value(uint64_t value) {
	return to_string(static_cast<int64_t>(value));
}

static string filter_to_string(const string &column, const OasisFilter &filter) {
	const auto lhs = filter_value(filter.rhs[0]);
	const auto rhs = filter_value(filter.rhs[1]);
	switch (filter.comparison) {
	case oasis::FilterComparison::ALWAYS_TRUE:
		return "TRUE";
	case oasis::FilterComparison::ALWAYS_FALSE:
		return "FALSE";
	case oasis::FilterComparison::EQUAL:
		return column + " = " + lhs;
	case oasis::FilterComparison::NOT_EQUAL:
		return column + " != " + lhs;
	case oasis::FilterComparison::GREATER:
		return column + " > " + lhs;
	case oasis::FilterComparison::LOWER:
		return column + " < " + lhs;
	case oasis::FilterComparison::GREATER_EQUAL:
		return column + " >= " + lhs;
	case oasis::FilterComparison::LOWER_EQUAL:
		return column + " <= " + lhs;
	case oasis::FilterComparison::IN_BETWEEN:
		return column + " BETWEEN " + lhs + " AND " + rhs;
	case oasis::FilterComparison::IN_RANGE:
		return lhs + " <= " + column + " < " + rhs;
	case oasis::FilterComparison::ONE_OF:
	case oasis::FilterComparison::IN_LIST: {
		vector<string> values = {lhs, rhs};
		for (size_t i = 0; i < filter.additional_rhs.size(); i++) {
			if (filter.additional_rhs_mask & (uint8_t {1} << i)) {
				values.push_back(filter_value(filter.additional_rhs[i]));
			}
		}
		return column + " IN (" + StringUtil::Join(values, ", ") + ")";
	}
	}
	throw InternalException("Unknown Oasis filter comparison");
}

void OasisPushdownComplexFilter(ClientContext &, LogicalGet &get, FunctionData *bind_data_p,
                                vector<unique_ptr<Expression>> &filters) {
	if (filters.size() != 1 || filters[0]->GetExpressionClass() != ExpressionClass::BOUND_CONJUNCTION ||
	    filters[0]->GetExpressionType() != ExpressionType::CONJUNCTION_OR) {
		return;
	}

	auto &conjunction = filters[0]->Cast<BoundConjunctionExpression>();
	if (conjunction.children.size() < 2 || conjunction.children.size() > oasis::FilterConfig::NUM_LAYERS) {
		return;
	}

	vector<OasisFilterLayer> layers;
	for (const auto &branch : conjunction.children) {
		OasisFilterLayer layer;
		if (!translate_branch(*branch, get, layer)) {
			return;
		}
		layers.push_back(std::move(layer));
	}

	auto &bind_data = bind_data_p->Cast<OasisScanBindData>();
	bind_data.filter_layers = std::move(layers);
	filters.clear();
}

InsertionOrderPreservingMap<string> OasisScanToString(TableFunctionToStringInput &input) {
	InsertionOrderPreservingMap<string> result;
	auto &bind_data = input.bind_data->Cast<OasisScanBindData>();
	result["Function"] = StringUtil::Upper(input.table_function.name);
	result["File"] = bind_data.filename;
	if (bind_data.filter_layers.empty()) {
		return result;
	}

	vector<string> layers;
	for (size_t layer_index = 0; layer_index < bind_data.filter_layers.size(); layer_index++) {
		vector<string> predicates;
		for (const auto &entry : bind_data.filter_layers[layer_index]) {
			if (entry.first >= bind_data.metadata.column_names.size()) {
				throw InternalException("Oasis filter column index is out of range");
			}
			predicates.push_back(
			    filter_to_string(bind_data.metadata.column_names[entry.first], entry.second));
		}
		layers.push_back("Layer " + to_string(layer_index + 1) + ": " +
		                 StringUtil::Join(predicates, " AND "));
	}
	result["Hardware Filters"] = StringUtil::Join(layers, "\nOR ");
	return result;
}

vector<OasisFilterLayer> NormalizeOasisFilters(const TableFunctionInitInput &input,
                                               const OasisScanBindData &bind_data) {
	const bool has_table_filters = input.filters && !input.filters->filters.empty();
	if (!bind_data.filter_layers.empty()) {
		if (has_table_filters) {
			throw InternalException("Oasis received both complex and table filter pushdown");
		}
		return bind_data.filter_layers;
	}

	if (!has_table_filters) {
		return {};
	}

	OasisFilterLayer layer;
	for (const auto &filter_entry : input.filters->filters) {
		if (filter_entry.first >= input.column_ids.size()) {
			throw InternalException("Oasis filter column index is out of range");
		}
		layer.emplace(input.column_ids[filter_entry.first], translate_filter(*filter_entry.second));
	}
	return {std::move(layer)};
}

vector<libstf::stream_t> AssignOasisFilterStreams(const vector<size_t> &columns,
                                                  const vector<OasisFilterLayer> &layers) {
	optional_idx additional_rhs_column;
	for (const auto &layer : layers) {
		for (const auto &entry : layer) {
			if (!entry.second.additional_rhs_mask) {
				continue;
			}
			if (additional_rhs_column.IsValid() &&
			    additional_rhs_column.GetIndex() != entry.first) {
				throw InvalidInputException(
				    "Oasis additional RHS values must use the same column across all layers");
			}
			additional_rhs_column = entry.first;
		}
	}

	vector<libstf::stream_t> streams(columns.size());
	std::iota(streams.begin(), streams.end(), 0);
	if (additional_rhs_column.IsValid()) {
		const auto position = column_position(columns, additional_rhs_column.GetIndex());
		std::rotate(streams.begin(), streams.begin() + 1, streams.begin() + position + 1);
	}
	return streams;
}

void ConfigureOasisFilters(oasis::FilterConfig &config, const vector<size_t> &columns,
                           const vector<libstf::stream_t> &streams,
                           const vector<OasisFilterLayer> &layers) {
	vector<oasis::FilterConfig::Stream> stream_config;
	vector<oasis::FilterConfig::Predicate> predicates;
	vector<oasis::FilterConfig::AdditionalRhs> additional_rhs;

	for (const auto stream : streams) {
		stream_config.push_back({stream, libstf::type_t::INT64_T, true});
	}
	for (size_t layer = 0; layer < layers.size(); layer++) {
		for (const auto &entry : layers[layer]) {
			auto stream = streams[column_position(columns, entry.first)];
			predicates.push_back({stream, layer, entry.second.comparison, entry.second.rhs});
			if (entry.second.additional_rhs_mask) {
				if (stream != 0) {
					throw InternalException("Oasis additional RHS column was not assigned to stream 0");
				}
				additional_rhs.push_back(
				    {layer, entry.second.additional_rhs, entry.second.additional_rhs_mask});
			}
		}
	}
	config.configure(stream_config, predicates, additional_rhs);
}

} // namespace duckdb
