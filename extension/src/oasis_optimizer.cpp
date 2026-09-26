#include "oasis_optimizer.hpp"
#include "oasis_scan.hpp"

#include "duckdb/common/enum_util.hpp"
#include "duckdb/logging/log_manager.hpp"
#include "duckdb/main/extension_callback_manager.hpp"
#include "duckdb/optimizer/optimizer_extension.hpp"
#include "duckdb/planner/expression.hpp"
#include "duckdb/planner/expression/bound_columnref_expression.hpp"
#include "duckdb/planner/operator/logical_comparison_join.hpp"
#include "duckdb/planner/operator/logical_get.hpp"

namespace duckdb {

// What one optimizer pass (one query) works with. Its decisions are logged at debug level
// (duckdb_logs), like the scan's.
struct OasisOptimizerPass {
	ClientContext &context;
	bool bloom_enabled; // oasis_runtime_bloom_filter
};

static LogicalGet *FindSingleGet(LogicalOperator &op) {
	if (op.type == LogicalOperatorType::LOGICAL_GET) {
		return &op.Cast<LogicalGet>();
	}
	if (op.children.size() != 1) {
		return nullptr;
	}

	switch (op.type) {
	case LogicalOperatorType::LOGICAL_FILTER:
	case LogicalOperatorType::LOGICAL_ORDER_BY:
		// Filtering the scan's rows before these does not change the join's result
		return FindSingleGet(*op.children[0]);
	default:
		// LIMIT, TOP_N, SAMPLE, WINDOW, DISTINCT ON, ... decide which rows reach the join
		return nullptr;
	}
}

static bool IsOasisGet(LogicalGet &get) {
	return get.function.name == "read_oasis";
}

static bool TryExtractColumnRef(const Expression &expr, LogicalGet &get, string &column_name, idx_t &column_idx) {
	if (expr.GetExpressionType() != ExpressionType::BOUND_COLUMN_REF) {
		return false;
	}

	auto &colref = expr.Cast<BoundColumnRefExpression>();
	auto &binding = colref.Binding();

	if (binding.table_index != get.table_index) {
		return false;
	}

	// The binding indexes the get's output columns, not its file columns: map it through the
	// projection (if any) and the projected column ids to the file column.
	idx_t output_idx = binding.column_index;
	if (!get.projection_ids.empty()) {
		if (output_idx >= get.projection_ids.size()) {
			return false;
		}
		output_idx = get.projection_ids[output_idx];
	}
	const auto &column_ids = get.GetColumnIds();
	if (output_idx >= column_ids.size() || column_ids[output_idx].IsVirtualColumn()) {
		return false;
	}
	const idx_t file_column = column_ids[output_idx].GetPrimaryIndex();
	if (file_column >= get.names.size()) {
		return false;
	}

	column_idx = file_column;
	column_name = get.names[file_column].GetIdentifierName();
	return true;
}

static bool TryApplyOasisBloomRewrite(LogicalComparisonJoin &join, OasisOptimizerPass &pass) {
	auto &context = pass.context;
	if (join.children.size() != 2) {
		return false;
	}

	if (!pass.bloom_enabled) {
		DUCKDB_LOG_DEBUG(context, "join skipped: oasis_runtime_bloom_filter is off");
		return false;
	}

	// Filtering the probe side drops its rows without a match, which only an inner join does as well
	// (e.g. a left join keeps them, padded with NULLs)
	if (join.join_type != JoinType::INNER) {
		DUCKDB_LOG_DEBUG(context, "join skipped: %s join, only inner joins are rewritten", EnumUtil::ToChars(join.join_type));
		return false;
	}

	auto *left_get = FindSingleGet(*join.children[0]);
	auto *right_get = FindSingleGet(*join.children[1]);

	if (!left_get || !right_get) {
		DUCKDB_LOG_DEBUG(context, "join skipped: could not find single LogicalGet on both sides");
		return false;
	}

	if (!IsOasisGet(*left_get) || !IsOasisGet(*right_get)) {
		DUCKDB_LOG_DEBUG(context, "join skipped: not both sides are read_oasis");
		return false;
	}

	auto *left_bind = &left_get->bind_data->Cast<OasisScanBindData>();
	auto *right_bind = &right_get->bind_data->Cast<OasisScanBindData>();

	if (join.conditions.empty()) {
		DUCKDB_LOG_DEBUG(context, "join skipped: no comparison conditions");
		return false;
	}

	for (auto &cond : join.conditions) {
		if (cond.GetComparisonType() != ExpressionType::COMPARE_EQUAL) {
			continue;
		}

		string left_key;
		string right_key;
		idx_t left_key_idx = DConstants::INVALID_INDEX;
		idx_t right_key_idx = DConstants::INVALID_INDEX;

		bool normal =
		    TryExtractColumnRef(cond.GetLHS(), *left_get, left_key, left_key_idx) &&
		    TryExtractColumnRef(cond.GetRHS(), *right_get, right_key, right_key_idx);

		bool swapped =
		    TryExtractColumnRef(cond.GetLHS(), *right_get, right_key, right_key_idx) &&
		    TryExtractColumnRef(cond.GetRHS(), *left_get, left_key, left_key_idx);

		if (!normal && !swapped) {
			DUCKDB_LOG_DEBUG(context, "condition skipped: equality is not left read_oasis col = right read_oasis col");
			continue;
		}

		auto left_score = OasisScanCardinality(context, left_bind)->estimated_cardinality;
		auto right_score = OasisScanCardinality(context, right_bind)->estimated_cardinality;

		OasisScanBindData *build_bind;
		OasisScanBindData *probe_bind;
		string build_key;
		string probe_key;

		if (left_score <= right_score) {
			build_bind = left_bind;
			probe_bind = right_bind;
			build_key = left_key;
			probe_key = right_key;
		} else {
			build_bind = right_bind;
			probe_bind = left_bind;
			build_key = right_key;
			probe_key = left_key;
		}

		probe_bind->runtime_bloom_enabled = true;
		probe_bind->runtime_bloom_build_filename = build_bind->filename;
		probe_bind->runtime_bloom_build_key = build_key;
		probe_bind->runtime_bloom_probe_key = probe_key;

		DUCKDB_LOG_DEBUG(context,
		                 "Runtime Bloom filter rewrite: build side '%s' (key '%s', %llu rows), probe side '%s' (key "
		                 "'%s', %llu rows).",
		                 build_bind->filename.c_str(), build_key.c_str(),
		                 (unsigned long long)(build_bind == left_bind ? left_score : right_score),
		                 probe_bind->filename.c_str(), probe_key.c_str(),
		                 (unsigned long long)(probe_bind == left_bind ? left_score : right_score));

		return true;
	}

	DUCKDB_LOG_DEBUG(context, "join skipped: no usable equality condition");

	return false;
}

static void RewritePlan(LogicalOperator &op, OasisOptimizerPass &pass) {
	for (auto &child : op.children) {
		RewritePlan(*child, pass);
	}

	if (op.type != LogicalOperatorType::LOGICAL_COMPARISON_JOIN) {
		return;
	}

	auto &join = op.Cast<LogicalComparisonJoin>();
	TryApplyOasisBloomRewrite(join, pass);
}

static void OasisOptimize(OptimizerExtensionInput &input, unique_ptr<LogicalOperator> &plan) {
	if (!plan) {
		return;
	}

	// The setting only disables the Bloom filter rewrite, not the whole pass
	Value runtime_bloom_filter;
	OasisOptimizerPass pass {input.context, !input.context.TryGetCurrentSetting("oasis_runtime_bloom_filter", runtime_bloom_filter) ||
	                                    runtime_bloom_filter.IsNull() || runtime_bloom_filter.GetValue<bool>()};

	RewritePlan(*plan, pass);
}

void RegisterOasisOptimizer(ExtensionLoader &loader) {
	auto &instance = loader.GetDatabaseInstance();

	OptimizerExtension optimizer_extension;
	optimizer_extension.optimize_function = OasisOptimize;

	auto &callback_manager = ExtensionCallbackManager::Get(instance);
	callback_manager.Register(std::move(optimizer_extension));
}

} // namespace duckdb