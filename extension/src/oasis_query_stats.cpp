#include "oasis_query_stats.hpp"

#include "duckdb/logging/log_manager.hpp"
#include "duckdb/logging/logger.hpp"
#include "duckdb/main/client_context.hpp"
#include "duckdb/main/connection_manager.hpp"
#include "duckdb/main/database.hpp"
#include "duckdb/main/extension_callback_manager.hpp"
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
	};
	return LogicalType::STRUCT(child_list);
}

static Value MillisecondsOrNull(double ms) {
	return ms < 0 ? Value(LogicalType::DOUBLE) : Value::DOUBLE(ms);
}

string OasisQueryStatsLogType::ConstructLogMessage(double total_query_ms, double scan_only_ms,
                                                   double scan_celeris_bloom_ms, double duckdb_bloom_ms) {
	child_list_t<Value> child_list = {
	    {"total_query_ms", MillisecondsOrNull(total_query_ms)},
	    {"scan_only_ms", MillisecondsOrNull(scan_only_ms)},
	    {"scan_celeris_bloom_ms", MillisecondsOrNull(scan_celeris_bloom_ms)},
	    {"duckdb_bloom_ms", MillisecondsOrNull(duckdb_bloom_ms)},
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

void OasisQueryStats::Install(DatabaseInstance &db) {
	auto &log_manager = db.GetLogManager();
	if (!log_manager.LookupLogType(OasisQueryStatsLogType::NAME)) {
		log_manager.RegisterLogType(make_uniq<OasisQueryStatsLogType>());
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
}

void OasisQueryStats::QueryBegin(ClientContext &) {
	Reset();
	query_start_ns = NowNs();
	active = true;
}

void OasisQueryStats::QueryEnd(ClientContext &context, optional_ptr<ErrorData>) {
	const uint64_t end_ns = NowNs();
	const bool was_active = active;
	active = false;

	const uint64_t only = scans_only.load();
	const uint64_t celeris = scans_celeris_bloom.load();
	if (!was_active || (only == 0 && celeris == 0)) {
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
	DUCKDB_LOG(context, OasisQueryStatsLogType, total_ms, scan_only_ms, celeris_ms, duckdb_bloom_ms);
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

void OasisQueryStats::MarkDuckDBBloomApplicable() {
	duckdb_bloom_applicable = true;
}

void OasisQueryStats::AddDuckDBBloom(uint64_t ns) {
	duckdb_bloom_ns += ns;
}

} // namespace duckdb
