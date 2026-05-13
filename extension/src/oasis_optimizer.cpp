#include "oasis_optimizer.hpp"
#include "oasis_scan.hpp"

#include "duckdb/main/extension_callback_manager.hpp"
#include "duckdb/optimizer/optimizer_extension.hpp"
#include "duckdb/planner/expression.hpp"
#include "duckdb/planner/expression/bound_columnref_expression.hpp"
#include "duckdb/planner/operator/logical_comparison_join.hpp"
#include "duckdb/planner/operator/logical_get.hpp"

#include <cstdio>

namespace duckdb {

#define OASIS_OPT_LOG(...)                                                                                             \
	do {                                                                                                               \
		fprintf(stderr, "[OASIS][OPT] ");                                                                              \
		fprintf(stderr, __VA_ARGS__);                                                                                  \
		fprintf(stderr, "\n");                                                                                         \
	} while (0)

struct OasisOptimizerInfo : public OptimizerExtensionInfo {
	bool enabled = true;
	bool verbose = true;
	idx_t rewrites_applied = 0;
};

static LogicalGet *FindSingleGet(LogicalOperator &op) {
	if (op.type == LogicalOperatorType::LOGICAL_GET) {
		return &op.Cast<LogicalGet>();
	}

	if (op.children.size() != 1) {
		return nullptr;
	}

	return FindSingleGet(*op.children[0]);
}

static bool IsOasisGet(LogicalGet &get) {
	return get.function.name == "read_oasis";
}

static OasisScanBindData *TryGetOasisBind(LogicalGet &get) {
	if (!get.bind_data) {
		return nullptr;
	}

	try {
		return &get.bind_data->Cast<OasisScanBindData>();
	} catch (...) {
		return nullptr;
	}
}

static idx_t EstimateSizeScore(const OasisScanBindData &bind) {
	return bind.metadata.groups.size();
}

static bool TryExtractColumnRef(const Expression &expr, LogicalGet &get, string &column_name, idx_t &column_idx) {
	if (expr.type != ExpressionType::BOUND_COLUMN_REF) {
		return false;
	}

	auto &colref = expr.Cast<BoundColumnRefExpression>();

	if (colref.binding.table_index != get.table_index) {
		return false;
	}

	if (colref.binding.column_index >= get.names.size()) {
		return false;
	}

	column_idx = colref.binding.column_index;
	column_name = get.names[column_idx];
	return true;
}

static bool TryApplyOasisBloomRewrite(LogicalComparisonJoin &join, OasisOptimizerInfo &info) {
	if (join.children.size() != 2) {
		return false;
	}

	auto *left_get = FindSingleGet(*join.children[0]);
	auto *right_get = FindSingleGet(*join.children[1]);

	if (!left_get || !right_get) {
		if (info.verbose) {
			OASIS_OPT_LOG("join skipped: could not find single LogicalGet on both sides");
		}
		return false;
	}

	if (!IsOasisGet(*left_get) || !IsOasisGet(*right_get)) {
		if (info.verbose) {
			OASIS_OPT_LOG("join skipped: not both sides are read_oasis");
		}
		return false;
	}

	auto *left_bind = TryGetOasisBind(*left_get);
	auto *right_bind = TryGetOasisBind(*right_get);

	if (!left_bind || !right_bind) {
		if (info.verbose) {
			OASIS_OPT_LOG("join skipped: could not cast bind_data to OasisScanBindData");
		}
		return false;
	}

	if (join.conditions.empty()) {
		if (info.verbose) {
			OASIS_OPT_LOG("join skipped: no comparison conditions");
		}
		return false;
	}

	for (auto &cond : join.conditions) {
		if (cond.comparison != ExpressionType::COMPARE_EQUAL) {
			continue;
		}

		string left_key;
		string right_key;
		idx_t left_key_idx = DConstants::INVALID_INDEX;
		idx_t right_key_idx = DConstants::INVALID_INDEX;

		bool normal =
		    TryExtractColumnRef(*cond.left, *left_get, left_key, left_key_idx) &&
		    TryExtractColumnRef(*cond.right, *right_get, right_key, right_key_idx);

		bool swapped =
		    TryExtractColumnRef(*cond.left, *right_get, right_key, right_key_idx) &&
		    TryExtractColumnRef(*cond.right, *left_get, left_key, left_key_idx);

		if (!normal && !swapped) {
			if (info.verbose) {
				OASIS_OPT_LOG("condition skipped: equality is not left read_oasis col = right read_oasis col");
			}
			continue;
		}

		auto left_score = EstimateSizeScore(*left_bind);
		auto right_score = EstimateSizeScore(*right_bind);

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

		info.rewrites_applied++;

		OASIS_OPT_LOG("found read_oasis equi-join");
		OASIS_OPT_LOG("left file    = %s", left_bind->filename.c_str());
		OASIS_OPT_LOG("right file   = %s", right_bind->filename.c_str());
		OASIS_OPT_LOG("left key     = %s", left_key.c_str());
		OASIS_OPT_LOG("right key    = %s", right_key.c_str());
		OASIS_OPT_LOG("left score   = %llu row-groups", (unsigned long long)left_score);
		OASIS_OPT_LOG("right score  = %llu row-groups", (unsigned long long)right_score);
		OASIS_OPT_LOG("build file   = %s", build_bind->filename.c_str());
		OASIS_OPT_LOG("build key    = %s", build_key.c_str());
		OASIS_OPT_LOG("probe file   = %s", probe_bind->filename.c_str());
		OASIS_OPT_LOG("probe key    = %s", probe_key.c_str());
		OASIS_OPT_LOG("rewrite done: probe read_oasis bind_data marked runtime_bloom_enabled=true");

		return true;
	}

	if (info.verbose) {
		OASIS_OPT_LOG("join skipped: no usable equality condition");
	}

	return false;
}

static void RewritePlan(LogicalOperator &op, OasisOptimizerInfo &info) {
	for (auto &child : op.children) {
		RewritePlan(*child, info);
	}

	if (op.type != LogicalOperatorType::LOGICAL_COMPARISON_JOIN) {
		return;
	}

	auto &join = op.Cast<LogicalComparisonJoin>();
	TryApplyOasisBloomRewrite(join, info);
}

static void OasisOptimize(OptimizerExtensionInput &input, unique_ptr<LogicalOperator> &plan) {
	auto *info = dynamic_cast<OasisOptimizerInfo *>(input.info.get());
	if (!info || !info->enabled || !plan) {
		return;
	}

	if (info->verbose) {
		OASIS_OPT_LOG("optimizer pass started");
	}

	RewritePlan(*plan, *info);

	if (info->verbose) {
		OASIS_OPT_LOG("optimizer pass finished, rewrites_applied=%llu", (unsigned long long)info->rewrites_applied);
	}
}

void RegisterOasisOptimizer(ExtensionLoader &loader) {
	auto &instance = loader.GetDatabaseInstance();

	auto info = make_shared_ptr<OasisOptimizerInfo>();
	info->enabled = true;
	info->verbose = true;

	OptimizerExtension optimizer_extension;
	optimizer_extension.optimize_function = OasisOptimize;
	optimizer_extension.optimizer_info = std::move(info);

	auto &callback_manager = ExtensionCallbackManager::Get(instance);
	callback_manager.Register(std::move(optimizer_extension));

	OASIS_OPT_LOG("registered optimizer extension through ExtensionCallbackManager");
}

} // namespace duckdb