#pragma once

#include <cstdint>

namespace duckdb {

// The hardware Bloom filter's performance counters, mirroring celeris's BFPhasePerf / BFRunPerf
// (celeris/software/celeris/configuration.hpp, see the hardware's BloomfilterPerformanceCounter).

struct BloomPhasePerf {
	uint64_t cycles = 0;
	uint64_t idle_cycles = 0;
	uint64_t stalled_cycles = 0;
	uint64_t cmd_wait_cycles = 0;

	// Idle because the host has not delivered the data of a beat yet
	uint64_t DataWaitCycles() const {
		const uint64_t other = stalled_cycles + cmd_wait_cycles;
		return idle_cycles > other ? idle_cycles - other : 0;
	}
	// Accepted beats (the END's beat included)
	uint64_t Beats() const {
		return cycles > idle_cycles ? cycles - idle_cycles : 0;
	}
};

struct BloomRunPerf {
	uint64_t cycles = 0;
	uint64_t keys_in_beats = 0;
	uint64_t values_in_beats = 0;
	uint64_t kept_out_beats = 0;
	uint64_t mat_out_beats = 0;
	uint64_t mask_out_beats = 0;
	uint64_t out_cycles = 0;
	uint64_t first_out_cycles = 0;
	uint64_t probe_start_cycles = 0;

	// Latency of the filter's pipeline: first probe key beat to first output
	uint64_t PipelineCycles() const {
		return first_out_cycles > probe_start_cycles ? first_out_cycles - probe_start_cycles : 0;
	}
	uint64_t OutBytes() const {
		return (kept_out_beats + mat_out_beats) * 64 + mask_out_beats;
	}
};

struct BloomPerfCounters {
	BloomPhasePerf build;
	BloomPhasePerf probe;
	BloomRunPerf run;
	// Sticky: a write to one of the command queues was lost because it was full
	bool command_queue_overflowed = false;
};

} // namespace duckdb
