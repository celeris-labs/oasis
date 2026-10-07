#pragma once

#include <cstdint>

namespace duckdb {

// The hardware Bloom filter's performance counters, mirroring celeris's BFPhasePerf / BFRunPerf
// (celeris/software/celeris/configuration.hpp, see the hardware's BloomfilterPerformanceCounter).
// The clock is 250 MHz on the device.

// One phase (build or probe), counted from its first accepted input beat up to its END.
struct BloomPhasePerf {
	uint64_t cycles = 0;                 // First accepted beat up to the phase end, both included
	uint64_t idle_cycles = 0;            // Cycles without an accepted beat
	uint64_t stalled_cycles = 0;         // Idle: a beat was offered but the filter was not ready
	uint64_t cmd_wait_cycles = 0;        // Idle: no input command was available yet (host too slow)
	uint64_t stalled_mat_cycles = 0;     // Stalled: the mask buffer refuses a mask value
	uint64_t stalled_out_cycles = 0;     // Stalled: raw_out or mask_out is not drained by the host
	uint64_t stalled_credit_cycles = 0;  // Stalled: all credits of the probe creditor are in flight

	// Stalled for reasons inside the filter's pipeline (e.g. bank conflicts)
	uint64_t StalledInternalCycles() const {
		const uint64_t causes = stalled_mat_cycles + stalled_out_cycles + stalled_credit_cycles;
		return stalled_cycles > causes ? stalled_cycles - causes : 0;
	}
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

// A whole run: from the first build beat up to the last handshake on any port. All but cycles and
// out_cycles count beats (64 B each, except the mask out beats, which are 1 B).
struct BloomRunPerf {
	uint64_t cycles = 0;              // Includes the gap between build and probe, the drain and the materialization
	uint64_t keys_in_beats = 0;       // Build and probe, END beats excluded
	uint64_t values_in_beats = 0;     // Probe values
	uint64_t kept_out_beats = 0;      // Kept keys
	uint64_t mat_out_beats = 0;       // Materialized probe values
	uint64_t mask_out_beats = 0;      // 1 B each
	uint64_t out_cycles = 0;          // End of the build phase up to the last output handshake (0: no output)
	uint64_t first_out_cycles = 0;    // End of the build phase up to the first output handshake (0: no output)
	uint64_t probe_start_cycles = 0;  // End of the build phase up to the first probe key beat (0: no probe beat)

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
