#pragma once

#include <cstdint>

namespace duckdb {

// The counters of the column chunk decoder's input and output StreamProfiler (parcore::DecoderProfile) of one
// decoder stream, in device clock cycles (250 MHz); every handshake transports one 64-byte beat. They cover the
// time from the first beat after the profiler was last read up to its last handshake, idle cycles between the
// stream's flows included (see parcore/libstf stream_profiler.sv). Reading them re-arms the profiler.
struct DecoderProfileCounters {
	uint64_t in_handshakes_cycles = 0;
	uint64_t in_starved_cycles = 0;
	uint64_t in_stalled_cycles = 0;
	uint64_t in_idle_cycles = 0;
	uint64_t out_handshakes_cycles = 0;
	uint64_t out_starved_cycles = 0;
	uint64_t out_stalled_cycles = 0;
	uint64_t out_idle_cycles = 0;
};

} // namespace duckdb
