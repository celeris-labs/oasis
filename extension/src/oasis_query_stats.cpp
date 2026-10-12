#include "oasis_query_stats.hpp"

#include "oasis_context_cache_entry.hpp"
#include "oasis_profile.hpp"

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
// OasisScanTimingsLogType
//===--------------------------------------------------------------------===//
namespace {

// The millisecond fields, in record order. `bloom_only` fields are NULL on a scan without the filter.
struct TimingField {
	const char *name;
	uint64_t OasisScanTimings::*member;
	bool bloom_only;
};

const TimingField TIMING_FIELDS[] = {
    {"read_ms", &OasisScanTimings::read_ns, false},
    {"flow_prep_ms", &OasisScanTimings::flow_prep_ns, false},
    {"submit_ms", &OasisScanTimings::submit_ns, false},
    {"collect_ms", &OasisScanTimings::collect_ns, false},
    {"decode_filter_ms", &OasisScanTimings::decode_filter_ns, false},
    {"hw_wait_ms", &OasisScanTimings::hw_wait_ns, false},
    {"bloom_flow_ms", &OasisScanTimings::bloom_flow_ns, true},
    {"bloom_verify_ms", &OasisScanTimings::bloom_verify_ns, true},
    {"bloom_select_ms", &OasisScanTimings::bloom_select_ns, true},
    {"bloom_slice_ms", &OasisScanTimings::bloom_slice_ns, true},
    {"bloom_setup_ms", &OasisScanTimings::bloom_setup_ns, true},
    {"bloom_drain_ms", &OasisScanTimings::bloom_drain_ns, true},
    {"bloom_teardown_ms", &OasisScanTimings::bloom_teardown_ns, true},
};

} // namespace

OasisScanTimingsLogType::OasisScanTimingsLogType() : LogType(NAME, LEVEL, GetLogType()) {
}

LogicalType OasisScanTimingsLogType::GetLogType() {
	child_list_t<LogicalType> child_list = {
	    {"file", LogicalType::VARCHAR},
	    {"bloom", LogicalType::BOOLEAN},
	    {"wall_ms", LogicalType::DOUBLE},
	};
	for (auto &field : TIMING_FIELDS) {
		child_list.emplace_back(field.name, LogicalType::DOUBLE);
	}
	child_list.emplace_back("hw_waits", LogicalType::UBIGINT);
	child_list.emplace_back("groups", LogicalType::UBIGINT);
	child_list.emplace_back("slices", LogicalType::UBIGINT);
	child_list.emplace_back("rows_in", LogicalType::UBIGINT);
	child_list.emplace_back("rows_kept", LogicalType::UBIGINT);
	return LogicalType::STRUCT(std::move(child_list));
}

string OasisScanTimingsLogType::ConstructLogMessage(const OasisScanTimings &t) {
	child_list_t<Value> child_list = {
	    {"file", Value(t.file)},
	    {"bloom", Value::BOOLEAN(t.bloom)},
	    {"wall_ms", Value::DOUBLE(static_cast<double>(t.wall_ns) / NS_PER_MS)},
	};
	for (auto &field : TIMING_FIELDS) {
		if (field.bloom_only && !t.bloom) {
			child_list.emplace_back(field.name, Value(LogicalType::DOUBLE));
		} else {
			child_list.emplace_back(field.name, Value::DOUBLE(static_cast<double>(t.*field.member) / NS_PER_MS));
		}
	}
	child_list.emplace_back("hw_waits", Value::UBIGINT(t.hw_waits));
	child_list.emplace_back("groups", Value::UBIGINT(t.groups));
	child_list.emplace_back("slices", Value::UBIGINT(t.slices));
	child_list.emplace_back("rows_in", Value::UBIGINT(t.rows_in));
	child_list.emplace_back("rows_kept", Value::UBIGINT(t.rows_kept));
	return Value::STRUCT(std::move(child_list)).ToString();
}

//===--------------------------------------------------------------------===//
// OasisDecoderProfileLogType
//===--------------------------------------------------------------------===//
OasisDecoderProfileLogType::OasisDecoderProfileLogType() : LogType(NAME, LEVEL, GetLogType()) {
}

LogicalType OasisDecoderProfileLogType::GetLogType() {
	child_list_t<LogicalType> child_list = {
	    {"segment", LogicalType::UBIGINT},
	    {"label", LogicalType::VARCHAR},
	    {"file", LogicalType::VARCHAR},
	    {"in_handshakes_cycles", LogicalType::UBIGINT},
	    {"in_starved_cycles", LogicalType::UBIGINT},
	    {"in_stalled_cycles", LogicalType::UBIGINT},
	    {"in_idle_cycles", LogicalType::UBIGINT},
	    {"out_handshakes_cycles", LogicalType::UBIGINT},
	    {"out_starved_cycles", LogicalType::UBIGINT},
	    {"out_stalled_cycles", LogicalType::UBIGINT},
	    {"out_idle_cycles", LogicalType::UBIGINT},
	};
	return LogicalType::STRUCT(std::move(child_list));
}

string OasisDecoderProfileLogType::ConstructLogMessage(idx_t segment, const OasisDecoderSegment &s) {
	const auto &c = s.counters;
	child_list_t<Value> child_list = {
	    {"segment", Value::UBIGINT(segment)},
	    {"label", Value(s.label)},
	    {"file", Value(s.file)},
	    {"in_handshakes_cycles", Value::UBIGINT(c.in_handshakes_cycles)},
	    {"in_starved_cycles", Value::UBIGINT(c.in_starved_cycles)},
	    {"in_stalled_cycles", Value::UBIGINT(c.in_stalled_cycles)},
	    {"in_idle_cycles", Value::UBIGINT(c.in_idle_cycles)},
	    {"out_handshakes_cycles", Value::UBIGINT(c.out_handshakes_cycles)},
	    {"out_starved_cycles", Value::UBIGINT(c.out_starved_cycles)},
	    {"out_stalled_cycles", Value::UBIGINT(c.out_stalled_cycles)},
	    {"out_idle_cycles", Value::UBIGINT(c.out_idle_cycles)},
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
	if (!log_manager.LookupLogType(OasisDecoderProfileLogType::NAME)) {
		log_manager.RegisterLogType(make_uniq<OasisDecoderProfileLogType>());
	}
	if (!log_manager.LookupLogType(OasisScanTimingsLogType::NAME)) {
		log_manager.RegisterLogType(make_uniq<OasisScanTimingsLogType>());
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
	{
		lock_guard<std::mutex> guard(bloom_runs_mutex);
		bloom_runs.clear();
	}
	{
		lock_guard<std::mutex> guard(scan_timings_mutex);
		scan_timings.clear();
	}
	lock_guard<std::mutex> guard(decoder_mutex);
	decoder_segments.clear();
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

	// The decoder's counters of the last segment (from the start of the last scan). The scans are done, so the
	// hardware is idle, and the read re-arms the profiler for the next query
	if (report) {
		bool have_boundary;
		string last_file;
		{
			lock_guard<std::mutex> guard(decoder_mutex);
			have_boundary = !decoder_segments.empty();
			if (have_boundary) {
				last_file = decoder_segments.back().file;
			}
		}
		if (have_boundary) {
			try {
				auto &oasis_ctx = GetOrCreateOasisContext(context);
				lock_guard<std::mutex> guard(decoder_mutex);
				decoder_segments.push_back({"final", last_file, ReadDecoderProfile(oasis_ctx)});
			} catch (std::exception &) {
				// No decoder profile for this query; the other statistics are still reported
			}
		}
	}

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

	vector<OasisDecoderSegment> segments;
	{
		lock_guard<std::mutex> guard(decoder_mutex);
		segments = std::move(decoder_segments);
	}
	for (idx_t i = 0; i < segments.size(); i++) {
		DUCKDB_LOG(context, OasisDecoderProfileLogType, i, segments[i]);
	}

	vector<OasisScanTimings> timings;
	{
		lock_guard<std::mutex> guard(scan_timings_mutex);
		timings = std::move(scan_timings);
	}
	for (auto &t : timings) {
		DUCKDB_LOG(context, OasisScanTimingsLogType, t);
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

void OasisQueryStats::AddScanTimings(OasisScanTimings timings) {
	lock_guard<std::mutex> guard(scan_timings_mutex);
	scan_timings.push_back(std::move(timings));
}

void OasisQueryStats::AddDecoderBoundary(const string &file, const DecoderProfileCounters &counters) {
	lock_guard<std::mutex> guard(decoder_mutex);
	decoder_segments.push_back({"before_scan", file, counters});
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
