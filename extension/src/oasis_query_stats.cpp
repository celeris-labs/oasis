#include "oasis_query_stats.hpp"

#include "duckdb/logging/log_manager.hpp"
#include "duckdb/logging/logger.hpp"
#include "duckdb/main/client_config.hpp"
#include "duckdb/main/client_context.hpp"
#include "duckdb/main/connection_manager.hpp"
#include "duckdb/main/database.hpp"
#include "duckdb/main/extension_callback_manager.hpp"
#include "duckdb/main/query_profiler.hpp"
#include "duckdb/planner/extension_callback.hpp"

namespace duckdb {

static constexpr double NS_PER_MS = 1e6;

//===--------------------------------------------------------------------===//
// OasisQueryStatsLogType
//===--------------------------------------------------------------------===//
OasisQueryStatsLogType::OasisQueryStatsLogType() : LogType(NAME, LEVEL, GetLogType()) {
}

LogicalType OasisQueryStatsLogType::GetLogType() {
	child_list_t<LogicalType> child_list = {
	    {"total_query_ms", LogicalType::DOUBLE},
	    {"scan_only_ms", LogicalType::DOUBLE},
	    {"scan_celeris_bloom_ms", LogicalType::DOUBLE},
	    {"duckdb_bloom_ms", LogicalType::DOUBLE},
	    {"join_ms", LogicalType::DOUBLE},
	};
	return LogicalType::STRUCT(child_list);
}

static Value MillisecondsOrNull(double ms) {
	return ms < 0 ? Value(LogicalType::DOUBLE) : Value::DOUBLE(ms);
}

string OasisQueryStatsLogType::ConstructLogMessage(double total_query_ms, double scan_only_ms,
                                                   double scan_celeris_bloom_ms, double duckdb_bloom_ms,
                                                   double join_ms) {
	child_list_t<Value> child_list = {
	    {"total_query_ms", MillisecondsOrNull(total_query_ms)},
	    {"scan_only_ms", MillisecondsOrNull(scan_only_ms)},
	    {"scan_celeris_bloom_ms", MillisecondsOrNull(scan_celeris_bloom_ms)},
	    {"duckdb_bloom_ms", MillisecondsOrNull(duckdb_bloom_ms)},
	    {"join_ms", MillisecondsOrNull(join_ms)},
	};
	return Value::STRUCT(std::move(child_list)).ToString();
}

//===--------------------------------------------------------------------===//
// OasisBloomFilterStatsLogType
//===--------------------------------------------------------------------===//
namespace {

using Fields = vector<pair<string, uint64_t>>;

Fields PhaseFields(const BloomPhasePerf &p) {
	return {{"cycles", p.cycles},
	        {"idle_cycles", p.idle_cycles},
	        {"stalled_cycles", p.stalled_cycles},
	        {"cmd_wait_cycles", p.cmd_wait_cycles},
	        {"stalled_mat_cycles", p.stalled_mat_cycles},
	        {"stalled_out_cycles", p.stalled_out_cycles},
	        {"stalled_credit_cycles", p.stalled_credit_cycles},
	        {"stalled_internal_cycles", p.StalledInternalCycles()},
	        {"data_wait_cycles", p.DataWaitCycles()},
	        {"beats", p.Beats()}};
}

Fields RunFields(const BloomRunPerf &r) {
	return {{"cycles", r.cycles},
	        {"keys_in_beats", r.keys_in_beats},
	        {"values_in_beats", r.values_in_beats},
	        {"kept_out_beats", r.kept_out_beats},
	        {"mat_out_beats", r.mat_out_beats},
	        {"mask_out_beats", r.mask_out_beats},
	        {"out_cycles", r.out_cycles},
	        {"first_out_cycles", r.first_out_cycles},
	        {"probe_start_cycles", r.probe_start_cycles},
	        {"pipeline_cycles", r.PipelineCycles()},
	        {"out_bytes", r.OutBytes()}};
}

LogicalType FieldsType(const Fields &fields) {
	child_list_t<LogicalType> children;
	for (auto &field : fields) {
		children.emplace_back(field.first, LogicalType::UBIGINT);
	}
	return LogicalType::STRUCT(std::move(children));
}

Value FieldsValue(const Fields &fields) {
	child_list_t<Value> children;
	for (auto &field : fields) {
		children.emplace_back(field.first, Value::UBIGINT(field.second));
	}
	return Value::STRUCT(std::move(children));
}

} // namespace

OasisBloomFilterStatsLogType::OasisBloomFilterStatsLogType() : LogType(NAME, LEVEL, GetLogType()) {
}

LogicalType OasisBloomFilterStatsLogType::GetLogType() {
	child_list_t<LogicalType> child_list = {
	    {"run", LogicalType::UBIGINT},
	    {"build", FieldsType(PhaseFields({}))},
	    {"probe", FieldsType(PhaseFields({}))},
	    {"run_perf", FieldsType(RunFields({}))},
	    {"command_queue_overflowed", LogicalType::BOOLEAN},
	};
	return LogicalType::STRUCT(std::move(child_list));
}

string OasisBloomFilterStatsLogType::ConstructLogMessage(idx_t run, const BloomPerfCounters &perf) {
	child_list_t<Value> child_list = {
	    {"run", Value::UBIGINT(run)},
	    {"build", FieldsValue(PhaseFields(perf.build))},
	    {"probe", FieldsValue(PhaseFields(perf.probe))},
	    {"run_perf", FieldsValue(RunFields(perf.run))},
	    {"command_queue_overflowed", Value::BOOLEAN(perf.command_queue_overflowed)},
	};
	return Value::STRUCT(std::move(child_list)).ToString();
}

//===--------------------------------------------------------------------===//
// OasisQueryStats
//===--------------------------------------------------------------------===//
namespace {

// Gives each connection its collector as the connection is opened.
class OasisQueryStatsInstaller : public ExtensionCallback {
public:
	void OnConnectionOpened(ClientContext &context) override {
		OasisQueryStats::Get(context);
	}
};

} // namespace

shared_ptr<OasisQueryStats> OasisQueryStats::Get(ClientContext &context) {
	return context.registered_state->GetOrCreate<OasisQueryStats>(STATE_KEY);
}

namespace {

bool IsJoinOperator(const string &type) {
	return type == "HASH_JOIN" || type == "NESTED_LOOP_JOIN" || type == "BLOCKWISE_NL_JOIN" ||
	       type == "PIECEWISE_MERGE_JOIN" || type == "IE_JOIN" || type == "ASOF_JOIN" ||
	       type == "CROSS_PRODUCT" || type == "POSITIONAL_JOIN";
}

// The operator metrics keys changed between DuckDB's legacy and current result tree ("type" /
// "operator_type" / "operator.type", likewise for timing), so accept all of them.
const QueryProfileResult *FindValue(const QueryProfileResult &node, std::initializer_list<const char *> keys) {
	for (auto &child : node.children) {
		if (child->kind != QueryProfileResultKind::VALUE) {
			continue;
		}
		for (auto key : keys) {
			if (child->key == key) {
				return child.get();
			}
		}
	}
	return nullptr;
}

// Adds the "timing" (seconds) of every join operator below `node` to `seconds`.
void SumJoinTiming(const QueryProfileResult &node, double &seconds, bool &found) {
	if (node.kind == QueryProfileResultKind::OBJECT) {
		auto type = FindValue(node, {"type", "operator_type", "operator.type"});
		auto timing = FindValue(node, {"timing", "operator_timing", "operator.timing"});
		if (type && timing && !type->value.IsNull() && !timing->value.IsNull() &&
		    IsJoinOperator(type->value.ToString())) {
			seconds += timing->value.GetValue<double>();
			found = true;
		}
	}
	for (auto &child : node.children) {
		SumJoinTiming(*child, seconds, found);
	}
}

} // namespace

double OasisQueryStats::JoinTimeMs(ClientContext &context) {
	auto &profiler = QueryProfiler::Get(context);
	if (!profiler.HasRoot()) {
		return -1;
	}
	try {
		double seconds = 0;
		bool found = false;
		SumJoinTiming(profiler.GetResult(), seconds, found);
		return found ? seconds * 1e3 : -1;
	} catch (std::exception &) {
		return -1;
	}
}

void OasisQueryStats::Install(DatabaseInstance &db) {
	auto &log_manager = db.GetLogManager();
	if (!log_manager.LookupLogType(OasisQueryStatsLogType::NAME)) {
		log_manager.RegisterLogType(make_uniq<OasisQueryStatsLogType>());
	}
	if (!log_manager.LookupLogType(OasisBloomFilterStatsLogType::NAME)) {
		log_manager.RegisterLogType(make_uniq<OasisBloomFilterStatsLogType>());
	}

	ExtensionCallbackManager::Get(db).Register(make_shared_ptr<OasisQueryStatsInstaller>());

	// The connection that loads the extension is already open, and QueryEnd is the only hook that
	// can still reach it: a state registered mid-query misses that query's QueryBegin, which
	// QueryEnd tolerates.
	for (auto &connection : ConnectionManager::Get(db).GetConnectionList()) {
		Get(*connection);
	}
}

void OasisQueryStats::Reset() {
	scan_only_ns = 0;
	scan_celeris_bloom_ns = 0;
	duckdb_bloom_ns = 0;
	scans_only = 0;
	scans_celeris_bloom = 0;
	duckdb_bloom_applicable = false;
	lock_guard<std::mutex> guard(bloom_runs_mutex);
	bloom_runs.clear();
}

void OasisQueryStats::QueryBegin(ClientContext &context) {
	Reset();
	query_start_ns = NowNs();
	active = true;

	// Join timing comes from DuckDB's operator profiler. If the user has not enabled it, switch it on
	// for this query without any output; QueryEnd puts the settings back.
	profiling = false;
	profiling_forced = false;
	auto &config = ClientConfig::GetConfig(context);
	if (config.enable_profiler) {
		profiling = true;
		return;
	}
	Value measure;
	if (context.TryGetCurrentSetting("oasis_measure_join_time", measure) && !measure.IsNull() &&
	    !measure.GetValue<bool>()) {
		return;
	}
	saved_profiler_print_format = config.profiler_print_format;
	config.enable_profiler = true;
	config.profiler_print_format = "no_output";
	profiling = true;
	profiling_forced = true;
}

void OasisQueryStats::QueryEnd(ClientContext &context, optional_ptr<ErrorData>) {
	const uint64_t end_ns = NowNs();
	const bool was_active = active;
	active = false;

	// DuckDB has already ended its profiler for this query, so the profile can be read now, and the
	// settings can go back to what the user had.
	const bool had_profile = profiling;
	double join_ms = -1;
	const uint64_t only = scans_only.load();
	const uint64_t celeris = scans_celeris_bloom.load();
	const bool report = was_active && (only != 0 || celeris != 0);
	if (report && had_profile) {
		join_ms = JoinTimeMs(context);
	}
	if (profiling_forced) {
		auto &config = ClientConfig::GetConfig(context);
		config.enable_profiler = false;
		config.profiler_print_format = saved_profiler_print_format;
	}
	profiling = false;
	profiling_forced = false;

	if (!report) {
		// Not a query that scanned a read_oasis table (or one that began before the extension was
		// loaded), nothing to report.
		Reset();
		return;
	}

	const double total_ms = static_cast<double>(end_ns - query_start_ns) / NS_PER_MS;
	const double scan_only_ms = only ? static_cast<double>(scan_only_ns.load()) / NS_PER_MS : -1;
	const double celeris_ms = celeris ? static_cast<double>(scan_celeris_bloom_ns.load()) / NS_PER_MS : -1;
	const double duckdb_bloom_ms =
	    duckdb_bloom_applicable.load() ? static_cast<double>(duckdb_bloom_ns.load()) / NS_PER_MS : -1;
	DUCKDB_LOG(context, OasisQueryStatsLogType, total_ms, scan_only_ms, celeris_ms, duckdb_bloom_ms, join_ms);

	vector<BloomPerfCounters> runs;
	{
		lock_guard<std::mutex> guard(bloom_runs_mutex);
		runs = std::move(bloom_runs);
	}
	for (idx_t i = 0; i < runs.size(); i++) {
		DUCKDB_LOG(context, OasisBloomFilterStatsLogType, i, runs[i]);
	}
	Reset();
}

void OasisQueryStats::AddScan(bool celeris_bloom, uint64_t wall_ns) {
	if (celeris_bloom) {
		scan_celeris_bloom_ns += wall_ns;
		scans_celeris_bloom++;
	} else {
		scan_only_ns += wall_ns;
		scans_only++;
	}
}

void OasisQueryStats::AddBloomRun(const BloomPerfCounters &perf) {
	lock_guard<std::mutex> guard(bloom_runs_mutex);
	bloom_runs.push_back(perf);
}

void OasisQueryStats::MarkDuckDBBloomApplicable() {
	duckdb_bloom_applicable = true;
}

void OasisQueryStats::AddDuckDBBloom(uint64_t ns) {
	duckdb_bloom_ns += ns;
}

} // namespace duckdb
