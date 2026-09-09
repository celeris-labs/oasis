#include "regex_profile.hpp"

#include "regex_fpga_batch.hpp"
#include "celeris/configuration.hpp"

#include "duckdb/function/table_function.hpp"

namespace duckdb {

namespace {

// Same hardware facts oasis_profile.cpp derives from: one handshake moves a 512-bit
// beat and the shell clock is 250 MHz (aclk period 4.000 ns, user_clk_c0_0.xdc).
constexpr double BYTES_PER_HANDSHAKE = 64.0;
constexpr double CLOCK_PERIOD_NS = 4.0;

// The StreamProfiler holds its counters after a stream's last beat until the next
// stream starts, so this reports the most recent batch rather than an average.
struct ProfileRow {
	string tap;
	celeris::RegexConfig::StreamProfile profile;
};

double ThroughputGBps(uint64_t handshakes, uint64_t cycles) {
	if (cycles == 0) {
		return 0.0;
	}
	return (static_cast<double>(handshakes) * BYTES_PER_HANDSHAKE) /
	       (static_cast<double>(cycles) * CLOCK_PERIOD_NS);
}

double Percent(uint64_t part, uint64_t whole) {
	return whole == 0 ? 0.0 : 100.0 * static_cast<double>(part) / static_cast<double>(whole);
}

struct RegexProfileBindData : public TableFunctionData {};

struct RegexProfileGlobalState : public GlobalTableFunctionState {
	vector<ProfileRow> rows;
	idx_t offset = 0;
	// Sticky fault bits, read once alongside the profiles. Repeated per row rather
	// than given a table of its own: it is one bit, and anyone reading the profiles
	// after a suspect result is exactly who needs to see it.
	// The card's status register was removed in celeris 8a422ad; keep the column so the
	// table shape is stable, always false.
	bool fifo_overflow = false;

	idx_t MaxThreads() const override {
		return 1;
	}
};

void DefineColumns(vector<string> &names, vector<LogicalType> &types) {
	auto add = [&](const char *name, LogicalType type) {
		names.emplace_back(name);
		types.emplace_back(std::move(type));
	};
	// in        -> splitter input: starved means the host/DMA is not keeping the card fed
	// engine    -> engine 0's input FIFO: starved means engines idle waiting on bytes,
	//              stalled means real per-string work in rem_top_ff's byte walk
	// engine_hi -> the last engine's input FIFO. Engine 0 takes the first chunk of every
	//              interleave pass and this one the last, so they should agree; if they
	//              disagree the deal is uneven and engine 0 alone would mislead.
	// out       -> engine array result output: stalled means the collector cannot drain
	add("tap", LogicalType::VARCHAR);
	add("handshakes_cycles", LogicalType::UBIGINT);
	add("starved_cycles", LogicalType::UBIGINT);
	add("stalled_cycles", LogicalType::UBIGINT);
	add("idle_cycles", LogicalType::UBIGINT);
	add("busy_cycles", LogicalType::UBIGINT);
	add("pct_handshake", LogicalType::DOUBLE);
	add("pct_starved", LogicalType::DOUBLE);
	add("pct_stalled", LogicalType::DOUBLE);
	add("throughput_gbps", LogicalType::DOUBLE);
	// Not per-tap: a sticky, array-wide fault bit, repeated on every row. Set means an
	// engine FIFO was written while full and nlb_gfifo discarded the write, which back
	// pressure is supposed to make impossible. A dropped result bit shifts every verdict
	// after it, so a true here means the answers are wrong, not merely slow.
	add("fifo_overflow", LogicalType::BOOLEAN);
}

unique_ptr<FunctionData> RegexProfileBind(ClientContext &context, TableFunctionBindInput &input,
                                          vector<LogicalType> &return_types, vector<string> &names) {
	DefineColumns(names, return_types);
	return make_uniq<RegexProfileBindData>();
}

unique_ptr<GlobalTableFunctionState> RegexProfileInitGlobal(ClientContext &context,
                                                            TableFunctionInitInput &input) {
	auto gstate = make_uniq<RegexProfileGlobalState>();

	auto &ctx = GetCelerisContext();
	auto config = ctx.get_config<celeris::RegexConfig>();
	const celeris::RegexConfig::StreamProfiles profiles = config->read_stream_profiles();

	gstate->rows.push_back({"in", profiles.in});
	gstate->rows.push_back({"engine", profiles.engine});
	gstate->rows.push_back({"engine_hi", profiles.engine_hi});
	gstate->rows.push_back({"out", profiles.out});
	return std::move(gstate);
}

void RegexProfileFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &gstate = data_p.global_state->Cast<RegexProfileGlobalState>();

	const idx_t remaining = gstate.rows.size() - gstate.offset;
	const idx_t count = MinValue<idx_t>(remaining, STANDARD_VECTOR_SIZE);
	if (count == 0) {
		output.SetChildCardinality(0);
		return;
	}

	for (idx_t i = 0; i < count; i++) {
		const auto &row = gstate.rows[gstate.offset + i];
		const auto &p = row.profile;
		const uint64_t busy = p.busy_cycles();

		idx_t col = 0;
		output.data[col++].SetValue(i, Value(row.tap));
		output.data[col++].SetValue(i, Value::UBIGINT(p.handshakes_cycles));
		output.data[col++].SetValue(i, Value::UBIGINT(p.starved_cycles));
		output.data[col++].SetValue(i, Value::UBIGINT(p.stalled_cycles));
		output.data[col++].SetValue(i, Value::UBIGINT(p.idle_cycles));
		output.data[col++].SetValue(i, Value::UBIGINT(busy));
		output.data[col++].SetValue(i, Value::DOUBLE(Percent(p.handshakes_cycles, busy)));
		output.data[col++].SetValue(i, Value::DOUBLE(Percent(p.starved_cycles, busy)));
		output.data[col++].SetValue(i, Value::DOUBLE(Percent(p.stalled_cycles, busy)));
		output.data[col++].SetValue(i, Value::DOUBLE(ThroughputGBps(p.handshakes_cycles, busy)));
		output.data[col++].SetValue(i, Value::BOOLEAN(gstate.fifo_overflow));
	}

	gstate.offset += count;
	output.SetChildCardinality(count);
}

// ---------------------------------------------------------------------------
// regex_fpga_batch_phases(): host-side wall time per phase of the batch round
// trip, accumulated across batches. Everything measured here runs under the
// global fpga_mutex, so it is the breakdown of what a scan/pack/device
// decomposition calls "device time".
// ---------------------------------------------------------------------------

struct PhasesBindData : public TableFunctionData {};

struct PhasesGlobalState : public GlobalTableFunctionState {
	RegexBatchPhases phases;
	bool done = false;
	idx_t MaxThreads() const override { return 1; }
};

unique_ptr<FunctionData> PhasesBind(ClientContext &context, TableFunctionBindInput &input,
                                    vector<LogicalType> &return_types, vector<string> &names) {
	auto add = [&](const char *n, LogicalType t) { names.emplace_back(n); return_types.emplace_back(std::move(t)); };
	add("batches", LogicalType::UBIGINT);
	add("strings", LogicalType::UBIGINT);
	add("wire_mb", LogicalType::DOUBLE);
	add("total_ms", LogicalType::DOUBLE);
	add("mutex_wait_ms", LogicalType::DOUBLE);
	add("arm_wait_ms", LogicalType::DOUBLE);
	add("config_ms", LogicalType::DOUBLE);
	add("acquire_ms", LogicalType::DOUBLE);
	add("getconfig_ms", LogicalType::DOUBLE);
	add("handle_ms", LogicalType::DOUBLE);
	add("csr_ms", LogicalType::DOUBLE);
	add("scan_ms", LogicalType::DOUBLE);
	add("materialize_ms", LogicalType::DOUBLE);
	add("stage_ms", LogicalType::DOUBLE);
	add("emit_ms", LogicalType::DOUBLE);
	add("initlocal_ms", LogicalType::DOUBLE);
	add("wirealloc_ms", LogicalType::DOUBLE);
	add("enqueue_ms", LogicalType::DOUBLE);
	add("drain_ms", LogicalType::DOUBLE);
	add("read_ms", LogicalType::DOUBLE);
	add("ns_per_string", LogicalType::DOUBLE);
	add("drain_ns_per_string", LogicalType::DOUBLE);
	add("wall_ms", LogicalType::DOUBLE);
	add("link_idle_ms", LogicalType::DOUBLE);
	add("link_idle_pct", LogicalType::DOUBLE);
	add("mean_depth", LogicalType::DOUBLE);
	add("max_depth", LogicalType::UBIGINT);
	add("idle_events", LogicalType::UBIGINT);
	add("max_idle_ms", LogicalType::DOUBLE);
	add("fill_min_ms", LogicalType::DOUBLE);
	add("fill_mean_ms", LogicalType::DOUBLE);
	add("fill_max_ms", LogicalType::DOUBLE);
	add("fill_threads", LogicalType::UBIGINT);
	add("done_min_ms", LogicalType::DOUBLE);
	add("done_mean_ms", LogicalType::DOUBLE);
	add("done_max_ms", LogicalType::DOUBLE);
	// FSST passthrough dispositions. compressed_pct is the number to read: ~86% is working
	// as designed (the remainder is the segment-straddle DuckDB decompresses for us), while
	// 0% means the data was written by a build without the FSST fork and nothing was
	// eligible. Those two are indistinguishable from throughput alone.
	add("rows_compressed", LogicalType::UBIGINT);
	add("rows_not_fsst", LogicalType::UBIGINT);
	add("rows_mode0", LogicalType::UBIGINT);
	add("rows_outlier", LogicalType::UBIGINT);
	add("compressed_pct", LogicalType::DOUBLE);
	return make_uniq<PhasesBindData>();
}

unique_ptr<GlobalTableFunctionState> PhasesInitGlobal(ClientContext &context, TableFunctionInitInput &input) {
	auto g = make_uniq<PhasesGlobalState>();
	g->phases = GetRegexBatchPhases();
	return std::move(g);
}

void PhasesFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &g = data_p.global_state->Cast<PhasesGlobalState>();
	if (g.done) { output.SetChildCardinality(0); return; }
	const auto &p = g.phases;
	// mutex_wait and arm_wait are excluded: the first is queueing behind another
	// thread's submit, the second behind the device's arm credit. Neither is this
	// batch's own work -- but arm_wait is the one to read when asking whether the
	// pipeline is deep enough, since it is time the host spent with nothing to submit.
	const double total_ns = double(p.config_ns + p.enqueue_ns + p.drain_ns + p.read_ns);
	const double s = p.strings ? double(p.strings) : 1.0;
	idx_t c = 0;
	output.data[c++].SetValue(0, Value::UBIGINT(p.batches));
	output.data[c++].SetValue(0, Value::UBIGINT(p.strings));
	output.data[c++].SetValue(0, Value::DOUBLE(double(p.wire_bytes) / 1e6));
	output.data[c++].SetValue(0, Value::DOUBLE(total_ns / 1e6));
	output.data[c++].SetValue(0, Value::DOUBLE(double(p.mutex_wait_ns) / 1e6));
	output.data[c++].SetValue(0, Value::DOUBLE(double(p.arm_wait_ns) / 1e6));
	output.data[c++].SetValue(0, Value::DOUBLE(double(p.config_ns) / 1e6));
	output.data[c++].SetValue(0, Value::DOUBLE(double(p.acquire_ns) / 1e6));
	output.data[c++].SetValue(0, Value::DOUBLE(double(p.getconfig_ns) / 1e6));
	output.data[c++].SetValue(0, Value::DOUBLE(double(p.handle_ns) / 1e6));
	output.data[c++].SetValue(0, Value::DOUBLE(double(p.csr_ns) / 1e6));
	output.data[c++].SetValue(0, Value::DOUBLE(double(p.scan_ns) / 1e6));
	output.data[c++].SetValue(0, Value::DOUBLE(double(p.materialize_ns) / 1e6));
	output.data[c++].SetValue(0, Value::DOUBLE(double(p.stage_ns) / 1e6));
	output.data[c++].SetValue(0, Value::DOUBLE(double(p.emit_ns) / 1e6));
	output.data[c++].SetValue(0, Value::DOUBLE(double(p.initlocal_ns) / 1e6));
	output.data[c++].SetValue(0, Value::DOUBLE(double(p.wirealloc_ns) / 1e6));
	output.data[c++].SetValue(0, Value::DOUBLE(double(p.enqueue_ns) / 1e6));
	output.data[c++].SetValue(0, Value::DOUBLE(double(p.drain_ns) / 1e6));
	output.data[c++].SetValue(0, Value::DOUBLE(double(p.read_ns) / 1e6));
	output.data[c++].SetValue(0, Value::DOUBLE(total_ns / s));
	output.data[c++].SetValue(0, Value::DOUBLE(double(p.drain_ns) / s));
	const double wall = p.wall_ns ? double(p.wall_ns) : 1.0;
	output.data[c++].SetValue(0, Value::DOUBLE(double(p.wall_ns) / 1e6));
	output.data[c++].SetValue(0, Value::DOUBLE(double(p.link_idle_ns) / 1e6));
	output.data[c++].SetValue(0, Value::DOUBLE(100.0 * double(p.link_idle_ns) / wall));
	output.data[c++].SetValue(0, Value::DOUBLE(double(p.depth_ns) / wall));
	output.data[c++].SetValue(0, Value::UBIGINT(p.max_depth));
	output.data[c++].SetValue(0, Value::UBIGINT(p.idle_events));
	output.data[c++].SetValue(0, Value::DOUBLE(double(p.max_idle_ns) / 1e6));
	output.data[c++].SetValue(0, Value::DOUBLE(double(p.fill_min_ns) / 1e6));
	output.data[c++].SetValue(0, Value::DOUBLE(double(p.fill_mean_ns) / 1e6));
	output.data[c++].SetValue(0, Value::DOUBLE(double(p.fill_max_ns) / 1e6));
	output.data[c++].SetValue(0, Value::UBIGINT(p.fill_threads));
	output.data[c++].SetValue(0, Value::DOUBLE(double(p.done_min_ns) / 1e6));
	output.data[c++].SetValue(0, Value::DOUBLE(double(p.done_mean_ns) / 1e6));
	output.data[c++].SetValue(0, Value::DOUBLE(double(p.done_max_ns) / 1e6));
	const double staged = double(p.rows_compressed + p.rows_not_fsst + p.rows_mode0 + p.rows_outlier);
	output.data[c++].SetValue(0, Value::UBIGINT(p.rows_compressed));
	output.data[c++].SetValue(0, Value::UBIGINT(p.rows_not_fsst));
	output.data[c++].SetValue(0, Value::UBIGINT(p.rows_mode0));
	output.data[c++].SetValue(0, Value::UBIGINT(p.rows_outlier));
	output.data[c++].SetValue(0, Value::DOUBLE(staged > 0 ? 100.0 * double(p.rows_compressed) / staged : 0.0));
	g.done = true;
	output.SetChildCardinality(1);
}

struct ResetBindData : public TableFunctionData {};
struct ResetGlobalState : public GlobalTableFunctionState {
	bool done = false;
	idx_t MaxThreads() const override { return 1; }
};

unique_ptr<FunctionData> ResetBind(ClientContext &context, TableFunctionBindInput &input,
                                   vector<LogicalType> &return_types, vector<string> &names) {
	names.emplace_back("reset");
	return_types.emplace_back(LogicalType::BOOLEAN);
	return make_uniq<ResetBindData>();
}

unique_ptr<GlobalTableFunctionState> ResetInitGlobal(ClientContext &context, TableFunctionInitInput &input) {
	ResetRegexBatchPhases();
	return make_uniq<ResetGlobalState>();
}

void ResetFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &g = data_p.global_state->Cast<ResetGlobalState>();
	if (g.done) { output.SetChildCardinality(0); return; }
	output.data[0].SetValue(0, Value::BOOLEAN(true));
	g.done = true;
	output.SetChildCardinality(1);
}

} // namespace

void RegisterRegexProfileFunction(ExtensionLoader &loader) {
	TableFunction profile_function("regex_fpga_stream_profile", {}, RegexProfileFunction, RegexProfileBind,
	                               RegexProfileInitGlobal);
	loader.RegisterFunction(profile_function);

	TableFunction phases_function("regex_fpga_batch_phases", {}, PhasesFunction, PhasesBind, PhasesInitGlobal);
	loader.RegisterFunction(phases_function);

	TableFunction reset_function("regex_fpga_reset_phases", {}, ResetFunction, ResetBind, ResetInitGlobal);
	loader.RegisterFunction(reset_function);
}

} // namespace duckdb
