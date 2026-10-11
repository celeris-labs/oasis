#pragma once

#include "duckdb/logging/log_type.hpp"
#include "duckdb/main/client_context_state.hpp"
#include "oasis_bloom_perf.hpp"

#include <atomic>
#include <chrono>
#include <mutex>
#include <vector>

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
//   join_ms                 DuckDB's own operator timing of the query's join operators (hash, nested
//                           loop, piecewise merge, IE, as-of, cross and positional joins), the same
//                           "timing" EXPLAIN ANALYZE shows: CPU time summed over workers, covering
//                           the build and probe sides of the join itself but not the scans below it.
//                           NULL when the query has no join, or when oasis_measure_join_time is off
//                           (it needs DuckDB's profiler, which the collector switches on, silently,
//                           for the length of each query unless the user already did).
class OasisQueryStatsLogType : public LogType {
public:
	static constexpr const char *NAME = "OasisQueryStats";
	static constexpr LogLevel LEVEL = LogLevel::LOG_INFO;

	OasisQueryStatsLogType();

	static LogicalType GetLogType();

	// A negative value stands for NULL.
	static string ConstructLogMessage(double total_query_ms, double scan_only_ms, double scan_celeris_bloom_ms,
	                                  double duckdb_bloom_ms, double join_ms);
};

// One record per run of the hardware Bloom filter (one per scan that used it; a query with several
// such joins writes several), written when the query ends, next to the OasisQueryStats record:
//
//   SELECT message.* FROM duckdb_logs WHERE type = 'OasisBloomFilterStats';
//
// `run` numbers the runs of the query from 0. `build` and `probe` are the phases' counters and `run_perf`
// the whole run's, as in celeris's examples/06_bloomfilter (all in device clock cycles, 250 MHz, and
// beats of 64 B except the mask out beats, which are 1 B). See oasis_bloom_perf.hpp for what each
// counts. The extra fields derive from the raw ones (stalled_internal_cycles, data_wait_cycles, beats,
// pipeline_cycles, out_bytes). `command_queue_overflowed` is the hardware's sticky status flag: it is only
// cleared by a device reset, so once set, every later run reports it too. If true, results from the
// run that overflowed are not reliable.
class OasisBloomFilterStatsLogType : public LogType {
public:
	static constexpr const char *NAME = "OasisBloomFilterStats";
	static constexpr LogLevel LEVEL = LogLevel::LOG_INFO;

	OasisBloomFilterStatsLogType();

	static LogicalType GetLogType();

	static string ConstructLogMessage(idx_t run, const BloomPerfCounters &perf);
};

// What one finished read_oasis scan spent its time on, written when the query ends (one record per
// scan, next to the OasisQueryStats record):
//
//   SELECT message.* FROM duckdb_logs WHERE type = 'OasisScanTimings';
//
// `bloom` says the scan used the hardware Bloom filter. Everything is milliseconds of *CPU time summed
// over the scan's workers* (so it can exceed `wall_ms`), except `wall_ms`, which is the scan's wall
// clock as in scan_only_ms / scan_celeris_bloom_ms.
//
//   read_ms              synchronous coalesced reads of the row groups' column chunks (local path)
//   flow_prep_ms         building each row group's QuerySplinter: all flows, bloom ones included
//   submit_ms            handing the splinters to the scheduler
//   collect_ms           collecting the hardware results of the head row group (polling, and the wait
//                        when oasis_prefetch_depth = 0)
//   decode_filter_ms     CPU column decode and pushed-down filters (DecodeAndFilterSlice)
//   hw_wait_ms           wall time workers spent suspended waiting for the hardware to finish a row
//                        group (the waits overlap across workers, so it can exceed wall_ms), and
//   hw_waits             how many such waits there were
//
//   Only on a scan that uses the hardware Bloom filter, NULL otherwise:
//   bloom_flow_ms        building the probe flow (a part of flow_prep_ms)
//   bloom_verify_ms      checking each group's mask against the materialized buffers (popcount)
//   bloom_select_ms      turning each slice's mask bits into a selection vector
//   bloom_slice_ms       applying it: pointing at the materialized values, slicing the other columns
//   bloom_setup_ms       reading and submitting the build side (wall, on the scheduling thread)
//   bloom_drain_ms       workers waiting for their in-flight probe flows when they finish
//   bloom_teardown_ms    ending the probe side, reading the counters, releasing the filter
//
//   groups, slices       row groups submitted and slices emitted
//   rows_in, rows_kept   rows of the slices before and after the Bloom filter's mask
struct OasisScanTimings {
	string file;
	bool bloom = false;
	uint64_t wall_ns = 0;
	uint64_t groups = 0;
	uint64_t slices = 0;
	uint64_t rows_in = 0;
	uint64_t rows_kept = 0;
	uint64_t read_ns = 0;
	uint64_t flow_prep_ns = 0;
	uint64_t submit_ns = 0;
	uint64_t collect_ns = 0;
	uint64_t decode_filter_ns = 0;
	uint64_t hw_wait_ns = 0;
	uint64_t hw_waits = 0;
	uint64_t bloom_flow_ns = 0;
	uint64_t bloom_verify_ns = 0;
	uint64_t bloom_select_ns = 0;
	uint64_t bloom_slice_ns = 0;
	uint64_t bloom_setup_ns = 0;
	uint64_t bloom_drain_ns = 0;
	uint64_t bloom_teardown_ns = 0;
};

class OasisScanTimingsLogType : public LogType {
public:
	static constexpr const char *NAME = "OasisScanTimings";
	static constexpr LogLevel LEVEL = LogLevel::LOG_INFO;

	OasisScanTimingsLogType();

	static LogicalType GetLogType();

	static string ConstructLogMessage(const OasisScanTimings &timings);
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
	// The counters of one finished run of the hardware Bloom filter.
	void AddBloomRun(const BloomPerfCounters &perf);
	// The timers of one finished scan.
	void AddScanTimings(OasisScanTimings timings);

private:
	void Reset();

	// Sums DuckDB's operator timing of the join operators in the finished query's profile, in
	// milliseconds, or -1 if the query has none or its profile is unavailable.
	static double JoinTimeMs(ClientContext &context);

	// Written by the connection's own thread, which also runs QueryBegin and QueryEnd.
	bool active = false;
	uint64_t query_start_ns = 0;
	// DuckDB's profiler records this query (the user had it on, or the collector switched it on).
	bool profiling = false;
	// The collector switched the profiler on for this query and restores the user's settings.
	bool profiling_forced = false;
	string saved_profiler_print_format;

	std::atomic<uint64_t> scan_only_ns {0};
	std::atomic<uint64_t> scan_celeris_bloom_ns {0};
	std::atomic<uint64_t> duckdb_bloom_ns {0};
	std::atomic<uint64_t> scans_only {0};
	std::atomic<uint64_t> scans_celeris_bloom {0};
	std::atomic<bool> duckdb_bloom_applicable {false};

	std::mutex bloom_runs_mutex;
	vector<BloomPerfCounters> bloom_runs;

	std::mutex scan_timings_mutex;
	vector<OasisScanTimings> scan_timings;
};

} // namespace duckdb
