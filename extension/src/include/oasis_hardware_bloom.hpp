#pragma once

namespace duckdb {

// Configures the hardware Bloom filter block added to hardware/src/vfpga_top.svh and the
// top-level stream select that would route decoder-stream 0 through it. For now this always
// selects the bypass path -- actually routing a join's build/probe chunks through the Bloom
// filter is follow-up work.
//
// Requires the Oasis FPGA context to already be initialized (i.e. call after GetOrCreateOasisContext).
void ConfigureOasisHardwareBloom();

// The stream-select channel that routes decoder-stream 0 through the Bloom filter or around it is
// a per-transaction FIFO (parcore/libstf/hardware/src/hdl/config/stream_config.sv,
// MAX_OUTSTANDING_STREAMS deep), not a sticky setting -- each AXI4S transfer that will land on
// stream 0 needs its own queued decision, or the demultiplexer stalls forever waiting for one that
// never arrives. Call this once for every hardware column-chunk decode flow submitted on decoder-
// stream 0 (i.e. once per DecodeColumnChunkOperator flow in PrefetchGroup), immediately before
// submitting it to the scheduler.
//
// Only correct while N_DECODERS == 1 (the current build default): with more than one decode
// stream, the scheduler load-balances flows across them and does not report which physical stream
// a given flow actually lands on, so a flow's pushed bypass value could go unconsumed if it lands
// on a different stream. Needs the scheduler to expose per-flow dispatch stream before this
// generalizes.
void EnqueueOasisHardwareBloomBypass();

} // namespace duckdb
