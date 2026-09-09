#define DUCKDB_EXTENSION_MAIN

#include "oasis_extension.hpp"
#include "oasis_profile.hpp"
#include "oasis_scan.hpp"
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

// Default for oasis_scan_groups_in_flight (see the AddExtensionOption below).
static constexpr uint64_t DEFAULT_GROUPS_IN_FLIGHT = 16;

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
	    LogicalType::UBIGINT, Value::UBIGINT(DEFAULT_GROUPS_IN_FLIGHT));

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
	                          "regex_fpga_scan: max rows per FPGA batch, a backstop on the "
	                          "REGEX_FPGA_TARGET_WIRE_BYTES byte target (0 = default 16384)",
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

	// Ship FSST-compressed bytes straight to the card rather than decompressing them on the
	// host and sending plaintext. DuckDB stores string columns FSST-compressed by default, so
	// today the scan pays to expand data it then pays PCIe to ship; o_comment compresses ~2.9x,
	// which is wire bandwidth the accelerator is otherwise bounded by.
	//
	// OFF, and it must stay off until the RTL carries a decompressor. The engines match
	// whatever bytes reach them, so against a plaintext bitstream this returns valid-looking
	// WRONG answers with no error -- it exists so the host side can be built and tested ahead
	// of the hardware, not because it is usable yet.
	//
	// It also needs enable_fsst_vectors=true (a DuckDB GLOBAL_ONLY setting this extension
	// cannot flip for you); regex_fpga_scan raises an error if one is set without the other.
	// Even then DuckDB only emits an FSST_VECTOR for reads that stay inside one ColumnSegment,
	// so a fraction of rows -- ~2048/rows_per_segment, which is 18% on o_comment and 100% once
	// a 256 KB segment holds fewer than 2048 rows -- arrives decompressed and falls back to the
	// host RE2 path. regex_fpga_batch_phases() reports the split as compressed_pct.
	config.AddExtensionOption("oasis_regex_fsst_passthrough",
	                          "regex_fpga_scan: send FSST-compressed bytes to the FPGA instead of "
	                          "host-decompressed plaintext (requires enable_fsst_vectors, and a "
	                          "bitstream with a decompressor -- WRONG RESULTS without one)",
	                          LogicalType::BOOLEAN, Value::BOOLEAN(false));

	// How many transfers one scan thread keeps on the card. Depth 1 makes the host and
	// the card take turns: pack a batch, submit it, block on its results, pack the next,
	// so a thread's only overlap is other threads'. Depth 2 packs the next batch while
	// the current one matches, and is the default.
	//
	// This is not independent of the scan's thread count. Every outstanding transfer
	// holds one of kRegexMaxSubmissionsInFlight (32) arm credits -- the depth of the
	// RTL's strings_in_batch queue, which does not back-pressure -- so T threads at depth
	// W need T*W <= 32 or they spend the scan taking credits off each other.
	// RegexFpgaScanInitGlobal therefore caps the scan's threads at 32/W, and the two
	// numbers are one decision: 16 x 2 beat 32 x 1 by 3.3% and won 15 of 16 paired
	// rounds, while 32 x 2 (demand 64, pool 32) lost.
	//
	// Each extra transfer also pins one more wire buffer per thread out of the huge-page
	// pool (oasis_regex_wire_buffer_bytes, 4 MiB by default); 16 threads at depth 2 is
	// the same 128 MiB the old 32-at-depth-1 default used. Set it to 1 if pages are tight
	// -- that raises the thread cap back to 32.
	config.AddExtensionOption("oasis_regex_max_in_flight",
	                          "regex_fpga_scan: transfers outstanding per scan thread (0 = default 2)",
	                          LogicalType::UBIGINT, Value::UBIGINT(0));

	// The scan already caps its own parallelism at kRegexMaxSubmissionsInFlight /
	// oasis_regex_max_in_flight (16 by default) -- see the note above and
	// RegexFpgaScanInitGlobal. This lowers that cap further, which is worth doing when the
	// rest of the query -- joins, aggregation, other scans -- wants the workers more than
	// the scan does. It can only lower the cap, never raise it above the credit bound.
	config.AddExtensionOption("oasis_regex_max_threads",
	                          "regex_fpga_scan: lower the scan's parallelism below the "
	                          "arm-credit cap of 32/oasis_regex_max_in_flight (0 = no extra cap)",
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
	// in its scan-init path, and regex_fpga_scan initializes the CelerisContext in its scan-init
	// path. Connecting eagerly here would require a specific bitstream to be loaded at
	// extension-load time, which breaks regex-only simulation runs against the Celeris regex
	// bitstream.
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
