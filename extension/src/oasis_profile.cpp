#include "oasis_profile.hpp"

#include "oasis_context_cache_entry.hpp"
#include "oasis/configuration.hpp"
#include "oasis/oasis_context.hpp"
#include "parcore/configuration.hpp"

#include "duckdb/function/table_function.hpp"

#include <mutex>

namespace duckdb {

namespace {

bool SameCounters(const DecoderProfileCounters &a, const DecoderProfileCounters &b) {
	return a.in_handshakes_cycles == b.in_handshakes_cycles && a.in_starved_cycles == b.in_starved_cycles &&
	       a.in_stalled_cycles == b.in_stalled_cycles && a.in_idle_cycles == b.in_idle_cycles &&
	       a.out_handshakes_cycles == b.out_handshakes_cycles && a.out_starved_cycles == b.out_starved_cycles &&
	       a.out_stalled_cycles == b.out_stalled_cycles && a.out_idle_cycles == b.out_idle_cycles;
}

DecoderProfileCounters ToCounters(const parcore::DecoderProfile &profile) {
	DecoderProfileCounters c;
	c.in_handshakes_cycles = profile.in.handshakes_cycles;
	c.in_starved_cycles = profile.in.starved_cycles;
	c.in_stalled_cycles = profile.in.stalled_cycles;
	c.in_idle_cycles = profile.in.idle_cycles;
	c.out_handshakes_cycles = profile.out.handshakes_cycles;
	c.out_starved_cycles = profile.out.starved_cycles;
	c.out_stalled_cycles = profile.out.stalled_cycles;
	c.out_idle_cycles = profile.out.idle_cycles;
	return c;
}

// What the profiler returned at its last read (by any reader). After a read the profiler holds its counters until
// the next beat re-zeroes them, so a read that returns the same values again saw no beat since: nothing was
// decoded in between, and the held values belong to an earlier period.
std::mutex last_read_mutex;
bool have_last_read = false;
DecoderProfileCounters last_read;


// Hardware facts the throughput derivation is based on: every stream handshake transports one
// 64-byte databeat, and the accelerator runs at 250 MHz (a 4 ns clock period).
constexpr double BYTES_PER_HANDSHAKE = 64.0;
constexpr double CLOCK_PERIOD_NS = 4.0;

// One materialized output row: the raw counters for a stream slot plus the derived throughput
// numbers. Decoder slots have an input and an output profiler; the RDMA bypass slot has a single
// profiler on its output stream, so its in-side columns are NULL. throughput is in GB/s (== bytes
// per nanosecond).
struct ProfileRow {
	uint64_t stream;
	bool has_in;

	parcore::DecoderProfile profile;

	double in_throughput_gbps;            // over the whole profiled window (includes idle cycles)
	double in_throughput_excl_idle_gbps;  // excluding inter-stream idle cycles
	double out_throughput_gbps;
	double out_throughput_excl_idle_gbps;
};

// Bytes transported divided by the time spent over `cycles` clock cycles, in GB/s. Returns 0 when
// there is no time to divide by so an unused stream reads as zero rather than NaN.
double ThroughputGBps(uint64_t handshakes, uint64_t cycles) {
	if (cycles == 0) {
		return 0.0;
	}
	double bytes = static_cast<double>(handshakes) * BYTES_PER_HANDSHAKE;
	double time_ns = static_cast<double>(cycles) * CLOCK_PERIOD_NS;
	return bytes / time_ns;
}

ProfileRow MakeRow(uint64_t stream, const parcore::DecoderProfile &p) {
	ProfileRow row;
	row.stream = stream;
	row.has_in = true;
	row.profile = p;

	// Overall: every cycle the profiler observed for this stream, including idle gaps between
	// streams. Excluding-idle: the cycles the stream was actually running.
	uint64_t in_total = p.in.handshakes_cycles + p.in.starved_cycles + p.in.stalled_cycles + p.in.idle_cycles;
	uint64_t in_busy = p.in.handshakes_cycles + p.in.starved_cycles + p.in.stalled_cycles;
	uint64_t out_total =
	    p.out.handshakes_cycles + p.out.starved_cycles + p.out.stalled_cycles + p.out.idle_cycles;
	uint64_t out_busy = p.out.handshakes_cycles + p.out.starved_cycles + p.out.stalled_cycles;

	row.in_throughput_gbps = ThroughputGBps(p.in.handshakes_cycles, in_total);
	row.in_throughput_excl_idle_gbps = ThroughputGBps(p.in.handshakes_cycles, in_busy);
	row.out_throughput_gbps = ThroughputGBps(p.out.handshakes_cycles, out_total);
	row.out_throughput_excl_idle_gbps = ThroughputGBps(p.out.handshakes_cycles, out_busy);
	return row;
}

// The bypass stream has one StreamProfiler on its output (the RDMA-read data feeding the output
// writer), so only the out-side of the row is populated.
ProfileRow MakeBypassRow(uint64_t stream, const parcore::StreamProfile &p) {
	ProfileRow row;
	row.stream = stream;
	row.has_in = false;
	row.profile.in = {};
	row.profile.out = p;

	uint64_t out_total = p.handshakes_cycles + p.starved_cycles + p.stalled_cycles + p.idle_cycles;
	uint64_t out_busy = p.handshakes_cycles + p.starved_cycles + p.stalled_cycles;

	row.in_throughput_gbps = 0.0;
	row.in_throughput_excl_idle_gbps = 0.0;
	row.out_throughput_gbps = ThroughputGBps(p.handshakes_cycles, out_total);
	row.out_throughput_excl_idle_gbps = ThroughputGBps(p.handshakes_cycles, out_busy);
	return row;
}

struct OasisProfileBindData : public TableFunctionData {
	vector<string> names;
	vector<LogicalType> types;
};

// Reads every decoder's counters from the hardware once at init and holds the rows to emit.
struct OasisProfileGlobalState : public GlobalTableFunctionState {
	vector<ProfileRow> rows;
	idx_t offset = 0;

	idx_t MaxThreads() const override {
		return 1;
	}
};

// Column layout, kept in one place so bind and scan stay in sync.
void DefineColumns(vector<string> &names, vector<LogicalType> &types) {
	auto add = [&](const char *name, LogicalType type) {
		names.emplace_back(name);
		types.emplace_back(std::move(type));
	};

	add("stream", LogicalType::UBIGINT);

	add("in_handshakes_cycles", LogicalType::UBIGINT);
	add("in_starved_cycles", LogicalType::UBIGINT);
	add("in_stalled_cycles", LogicalType::UBIGINT);
	add("in_idle_cycles", LogicalType::UBIGINT);
	add("in_last_handshakes", LogicalType::UBIGINT);

	add("out_handshakes_cycles", LogicalType::UBIGINT);
	add("out_starved_cycles", LogicalType::UBIGINT);
	add("out_stalled_cycles", LogicalType::UBIGINT);
	add("out_idle_cycles", LogicalType::UBIGINT);
	add("out_last_handshakes", LogicalType::UBIGINT);

	add("in_throughput_gbps", LogicalType::DOUBLE);
	add("in_throughput_excl_idle_gbps", LogicalType::DOUBLE);
	add("out_throughput_gbps", LogicalType::DOUBLE);
	add("out_throughput_excl_idle_gbps", LogicalType::DOUBLE);
}

unique_ptr<FunctionData> OasisProfileBind(ClientContext &context, TableFunctionBindInput &input,
                                          vector<LogicalType> &return_types, vector<string> &names) {
	auto bind_data = make_uniq<OasisProfileBindData>();
	DefineColumns(names, return_types);
	bind_data->names = names;
	bind_data->types = return_types;
	return std::move(bind_data);
}

unique_ptr<GlobalTableFunctionState> OasisProfileInitGlobal(ClientContext &context,
                                                            TableFunctionInitInput &input) {
	auto gstate = make_uniq<OasisProfileGlobalState>();

	auto &ctx = GetOrCreateOasisContext(context);
	auto config = ctx.config<parcore::ColumnChunkDecoderConfig>();

	auto num_decoders = config->num_decoders();
	gstate->rows.reserve(num_decoders + 1);
	for (libstf::stream_t decoder = 0; decoder < num_decoders; decoder++) {
		auto profile = config->read_profile(decoder);
		if (decoder == 0) {
			std::lock_guard<std::mutex> guard(last_read_mutex);
			have_last_read = true;
			last_read = ToCounters(profile);
		}
		gstate->rows.push_back(MakeRow(decoder, profile));
	}

	// The RDMA bypass stream occupies the last stream slot (== num_decoders) and has its own
	// StreamProfiler behind the GenericConfig. Older bitstreams have no GenericConfig and non-RDMA
	// builds expose no bypass counters, so those simply emit the decoder rows only.
	if (ctx.has_config<oasis::GenericConfig>()) {
		auto generic = ctx.config<oasis::GenericConfig>();
		if (generic->has_bypass_profile()) {
			gstate->rows.push_back(MakeBypassRow(num_decoders, generic->read_bypass_profile()));
		}
	}

	return std::move(gstate);
}

void OasisProfileFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &gstate = data_p.global_state->Cast<OasisProfileGlobalState>();

	idx_t remaining = gstate.rows.size() - gstate.offset;
	idx_t count = MinValue<idx_t>(remaining, STANDARD_VECTOR_SIZE);
	if (count == 0) {
		output.SetChildCardinality(0);
		return;
	}

	for (idx_t i = 0; i < count; i++) {
		const auto &row = gstate.rows[gstate.offset + i];
		const auto &p = row.profile;

		idx_t col = 0;
		// The bypass row has no input-side profiler; its in_* columns are NULL.
		auto in_u64 = [&](uint64_t v) {
			return row.has_in ? Value::UBIGINT(v) : Value(LogicalType::UBIGINT);
		};
		auto in_f64 = [&](double v) { return row.has_in ? Value::DOUBLE(v) : Value(LogicalType::DOUBLE); };

		output.data[col++].SetValue(i, Value::UBIGINT(row.stream));

		output.data[col++].SetValue(i, in_u64(p.in.handshakes_cycles));
		output.data[col++].SetValue(i, in_u64(p.in.starved_cycles));
		output.data[col++].SetValue(i, in_u64(p.in.stalled_cycles));
		output.data[col++].SetValue(i, in_u64(p.in.idle_cycles));
		output.data[col++].SetValue(i, in_u64(p.in.last_handshakes));

		output.data[col++].SetValue(i, Value::UBIGINT(p.out.handshakes_cycles));
		output.data[col++].SetValue(i, Value::UBIGINT(p.out.starved_cycles));
		output.data[col++].SetValue(i, Value::UBIGINT(p.out.stalled_cycles));
		output.data[col++].SetValue(i, Value::UBIGINT(p.out.idle_cycles));
		output.data[col++].SetValue(i, Value::UBIGINT(p.out.last_handshakes));

		output.data[col++].SetValue(i, in_f64(row.in_throughput_gbps));
		output.data[col++].SetValue(i, in_f64(row.in_throughput_excl_idle_gbps));
		output.data[col++].SetValue(i, Value::DOUBLE(row.out_throughput_gbps));
		output.data[col++].SetValue(i, Value::DOUBLE(row.out_throughput_excl_idle_gbps));
	}

	gstate.offset += count;
	output.SetChildCardinality(count);
}

} // namespace

DecoderProfileCounters ReadDecoderProfile(oasis::OasisContext &ctx) {
	const auto c = ToCounters(ctx.config<parcore::ColumnChunkDecoderConfig>()->read_profile(0));
	std::lock_guard<std::mutex> guard(last_read_mutex);
	if (have_last_read && SameCounters(c, last_read)) {
		return DecoderProfileCounters {};
	}
	have_last_read = true;
	last_read = c;
	return c;
}

void RegisterOasisProfileFunction(ExtensionLoader &loader) {
	TableFunction profile_function("oasis_stream_profile", {}, OasisProfileFunction, OasisProfileBind,
	                               OasisProfileInitGlobal);
	loader.RegisterFunction(profile_function);
}

} // namespace duckdb
