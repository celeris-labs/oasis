#define DUCKDB_EXTENSION_MAIN

#include "oasis_extension.hpp"
#include "oasis_profile.hpp"
#include "oasis_scan.hpp"
#include "regex.hpp"
#include "regex_table.hpp"
#include "regex_profile.hpp"
#include "oasis_context_cache_entry.hpp"
#include "oasis_settings.hpp"
#include "oasis_log_sink.hpp"
#include "rdma_file_system.hpp"
#include "duckdb.hpp"
#include "duckdb/function/scalar_function.hpp"
#include "duckdb/main/config.hpp"
#include "duckdb/main/database.hpp"

#include <coyote/cDefs.hpp>

namespace duckdb {

static void LoadInternal(ExtensionLoader &loader) {
	auto &instance = loader.GetDatabaseInstance();
	auto &config = DBConfig::GetConfig(instance);

	config.AddExtensionOption("oasis_logging_level",
	                          "libSTF/ParCore/OAL log verbosity (TRACE, DEBUG, INFO, WARNING, ERROR, FATAL, OFF). "
	                          "Records also pass through DuckDB's logging_level before reaching duckdb_logs",
	                          LogicalType::VARCHAR, Value(DEFAULT_OASIS_LOG_LEVEL), SetOasisLogLevel);
	libstf::set_log_level(ParseLibstfLogLevel(DEFAULT_OASIS_LOG_LEVEL));

	// Oasis table function
	config.AddExtensionOption("oasis_scheduler_num_streams",
	                          "Number of streams the scheduler drives (0 = all available)", LogicalType::UBIGINT,
	                          Value::UBIGINT(0), SetSchedulerNumStreams);
	config.AddExtensionOption("oasis_scheduler_queue_depth",
	                          "Max splinters in flight per stream (0 = hardware config-FIFO depth)",
	                          LogicalType::UBIGINT, Value::UBIGINT(0), SetSchedulerQueueDepth);
	config.AddExtensionOption(
	    "oasis_scan_groups_in_flight",
	    "Row groups a single read_oasis scan keeps submitted but not yet collected, overlapping "
	    "submission with collection. Split across the scan's worker threads (each worker keeps "
	    "ceil(value / threads) groups in flight but at least 1).",
	    LogicalType::UBIGINT, Value::UBIGINT(16));

	// Benchmarking knob: run regex_fpga_scan's whole host pipeline -- storage scan, string
	// decompression and packing into the FPGA wire format -- but skip the device round trip and
	// treat every row as non-matching. Timing this against the real scan separates the cost of
	// *preparing* bytes for the FPGA from the cost of moving and matching them, which is what
	// decides whether the host can keep a faster decoder fed. Results are wrong by construction.
	config.AddExtensionOption("oasis_regex_dry_run",
	                          "Benchmarking only: skip the FPGA round trip in regex_fpga_scan and "
	                          "return no matches, leaving just the host-side scan and packing",
	                          LogicalType::BOOLEAN, Value::BOOLEAN(false));

	// Batch geometry for regex_fpga_scan. A batch ends when either cap is hit: rows bind for
	// short strings, bytes for long ones. Exposed as settings so the batch-size/string-length
	// trade-off can be swept without a rebuild. Rows are clamped to the result-FIFO depth
	// (kRegexMaxStringsPerEngine * 64); the wire buffer is per scan thread and comes out of the
	// huge-page pool, so large values times many threads will exhaust it.
	config.AddExtensionOption("oasis_regex_batch_rows",
	                          "regex_fpga_scan: max rows per FPGA batch (0 = default 65536)",
	                          LogicalType::UBIGINT, Value::UBIGINT(0));
	config.AddExtensionOption("oasis_regex_wire_buffer_bytes",
	                          "regex_fpga_scan: per-thread wire buffer in bytes (0 = default 4 MiB)",
	                          LogicalType::UBIGINT, Value::UBIGINT(0));
	// Strings at or above this get a solo batch. The default (kRegexOutlierBytes, 2 KiB) is a
	// deadlock budget derived for *adversarial length skew* -- one multi-KB laggard among 1-byte
	// neighbours, where the neighbours fill their result FIFOs and wedge the splitter. On data of
	// uniform length no engine can run ahead of another, so the hazard does not arise and the
	// threshold is pure cost: solo batching means one device round trip per string. Exposed so that
	// regime can be measured. Raising it on skewed data risks wedging the array -- see
	// kRegexOutlierBytes in celeris regex_stream.hpp.
	config.AddExtensionOption("oasis_regex_outlier_bytes",
	                          "regex_fpga_scan: solo-batch threshold in bytes (0 = default 2048)",
	                          LogicalType::UBIGINT, Value::UBIGINT(0));

	// How many transfers one scan thread keeps on the card. Depth 1 is the old
	// behaviour: pack a batch, submit it, block on its results, pack the next -- so the
	// host and the card take turns and neither is ever busy while the other works.
	// Depth 2 packs the next batch while the current one matches.
	//
	// Each extra transfer pins one more wire buffer per thread out of the huge-page
	// pool (oasis_regex_wire_buffer_bytes, 4 MiB by default), and the *process-wide*
	// ceiling is separate and lower -- kRegexMaxSubmissionsInFlight arm credits, which
	// the RTL's single-entry arm mailbox fixes at 2 until Stage 2 lands. So on a
	// many-thread scan the threads are already sharing those credits and a deeper
	// per-thread window only costs pool; set it to 1 there if huge pages are tight.
	config.AddExtensionOption("oasis_regex_max_in_flight",
	                          "regex_fpga_scan: transfers outstanding per scan thread (0 = default 1)",
	                          LogicalType::UBIGINT, Value::UBIGINT(0));

	// regex_fpga_scan saturates the card at ~12 scan threads (scripts/regex_report.py -s threads),
	// so past that point extra threads buy the scan nothing while still occupying workers that the
	// rest of the query -- joins, aggregation, other scans -- could be using. Capping the scan's
	// own parallelism leaves those workers free without lowering DuckDB's global thread count.
	config.AddExtensionOption("oasis_regex_max_threads",
	                          "regex_fpga_scan: cap the scan's own parallelism (0 = no cap)",
	                          LogicalType::UBIGINT, Value::UBIGINT(0));

	// Oasis scan table function
	RegisterOasisScanFunction(loader);

	// Stream profiler readout table function
	RegisterOasisProfileFunction(loader);

	// RDMA file system
	config.AddExtensionOption(
	    "oasis_rdma_server",
	    "RDMA file server IP address (required; set via `SET oasis_rdma_server = '<ip-address>';`)",
	    LogicalType::VARCHAR, Value(LogicalType::VARCHAR));
	config.AddExtensionOption("oasis_rdma_port", "RDMA file server TCP port (for QP exchange)", LogicalType::UBIGINT,
	                          Value::UBIGINT(static_cast<uint64_t>(coyote::DEF_PORT)));

	FileSystem::GetFileSystem(instance).RegisterSubSystem(make_uniq<RDMAFileSystem>());

	// FPGA contexts are established lazily on first use: read_oasis initializes the OasisContext
	// in its scan-init path, and regex_fpga initializes the CelerisContext on first execution.
	// Connecting eagerly here would require a specific bitstream to be loaded at extension-load
	// time, which breaks regex-only simulation runs against the Celeris regex bitstream.
	ScalarFunction regex_function("regex_fpga",
	                              {LogicalType::VARCHAR, LogicalType::VARCHAR}, // string, pattern
	                              LogicalType::BOOLEAN, RegexFpgaFunction, RegexFpgaBind);
	loader.RegisterFunction(regex_function);

	RegisterRegexFpgaScanFunction(loader);

	// Stream-profiler readout for the regex datapath (see regex_profile.cpp).
	RegisterRegexProfileFunction(loader);
}

void OasisExtension::Load(ExtensionLoader &loader) {
	LoadInternal(loader);
}

std::string OasisExtension::Name() {
	return "Oasis";
}

std::string OasisExtension::Version() const {
#ifdef EXT_VERSION_OASIS
	return EXT_VERSION_OASIS;
#else
	return "";
#endif
}

} // namespace duckdb

extern "C" {
DUCKDB_CPP_EXTENSION_ENTRY(oasis, loader) {
	duckdb::LoadInternal(loader);
}
}
