#pragma once

#include "duckdb/logging/log_type.hpp"
#include "duckdb/main/client_context_state.hpp"

#include <atomic>
#include <chrono>

namespace duckdb {

class DatabaseInstance;

// One record per query that scanned a read_oasis table, written to DuckDB's log when the query
// ends (after enable_logging, e.g. `CALL enable_logging(level = 'info')`):
//
//   SELECT message.* FROM duckdb_logs WHERE type = 'OasisQueryStats';
//
// All values are in milliseconds, NULL where the statistic does not apply to the query.
//
//   total_query_ms          wall clock from the query's start to its end, planning included.
//   scan_only_ms            wall clock of the read_oasis scans that did not use the hardware Bloom
//                           filter (first worker start to last worker finish), summed over scans.
//   scan_celeris_bloom_ms   same for the scans that used the hardware Bloom filter, plus the time
//                           spent submitting its build side and ending it again.
//   duckdb_bloom_ms         time evaluating DuckDB's join Bloom filters inside the scans
//                           (oasis_duckdb_bloom_filter = true), summed over all workers. Unlike the
//                           others it is CPU time, so it can exceed the scans' wall clock.
class OasisQueryStatsLogType : public LogType {
public:
	static constexpr const char *NAME = "OasisQueryStats";
	static constexpr LogLevel LEVEL = LogLevel::LOG_INFO;

	OasisQueryStatsLogType();

	static LogicalType GetLogType();

	// A negative value stands for NULL.
	static string ConstructLogMessage(double total_query_ms, double scan_only_ms, double scan_celeris_bloom_ms,
	                                  double duckdb_bloom_ms);
};

// Per-connection collector of the statistics above. The scans add to it from any thread while the
// query runs. DuckDB destroys the scans' states before it calls QueryEnd, so by then every scan has
// reported.
class OasisQueryStats : public ClientContextState {
public:
	using Clock = std::chrono::steady_clock;

	static constexpr const char *STATE_KEY = "oasis_query_stats";

	// The connection's collector, created on first use.
	static shared_ptr<OasisQueryStats> Get(ClientContext &context);

	// Makes every connection (already open, or opened later) collect, so that QueryBegin sees the
	// first query as well.
	static void Install(DatabaseInstance &db);

	static uint64_t NowNs() {
		return static_cast<uint64_t>(
		    std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now().time_since_epoch()).count());
	}

	using ClientContextState::QueryEnd;
	void QueryBegin(ClientContext &context) override;
	void QueryEnd(ClientContext &context, optional_ptr<ErrorData> error) override;

	// One finished read_oasis scan, `celeris_bloom` if it used the hardware Bloom filter.
	void AddScan(bool celeris_bloom, uint64_t wall_ns);
	// A scan kept DuckDB's join Bloom filters, so duckdb_bloom_ms applies to this query.
	void MarkDuckDBBloomApplicable();
	void AddDuckDBBloom(uint64_t ns);

private:
	void Reset();

	// Written by the connection's own thread, which also runs QueryEnd.
	bool active = false;
	uint64_t query_start_ns = 0;

	std::atomic<uint64_t> scan_only_ns {0};
	std::atomic<uint64_t> scan_celeris_bloom_ns {0};
	std::atomic<uint64_t> duckdb_bloom_ns {0};
	std::atomic<uint64_t> scans_only {0};
	std::atomic<uint64_t> scans_celeris_bloom {0};
	std::atomic<bool> duckdb_bloom_applicable {false};
};

} // namespace duckdb
