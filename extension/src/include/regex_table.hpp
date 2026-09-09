#pragma once

#include "celeris/celeris_context.hpp"
#include "celeris/operators/regex/regex_stream.hpp"
#include "regex_fpga_batch.hpp" // batch-geometry defaults
#include "syslog_undef.hpp" // must follow the celeris include, precede the duckdb ones

#include "duckdb.hpp"
#include "duckdb/common/re2_regex.hpp"
#include "duckdb/catalog/catalog_entry/duck_table_entry.hpp"
#include "duckdb/common/types/selection_vector.hpp"
#include "duckdb/execution/expression_executor.hpp"
#include "duckdb/function/table_function.hpp"
#include "duckdb/main/client_context.hpp"
#include "duckdb/storage/data_table.hpp"
#include "duckdb/storage/storage_index.hpp"
#include "duckdb/storage/table/scan_state.hpp"
#include "libstf/buffer.hpp"

#include <atomic>
#include <deque>
#include <memory>
#include <vector>

namespace duckdb {

struct RegexFpgaScanBindData : public TableFunctionData {
	DuckTableEntry &table;
	string regex_column;
	string pattern;
	vector<uint8_t> regex_blob;
	vector<LogicalType> column_types;
	vector<StorageIndex> column_ids;
	idx_t regex_column_idx = DConstants::INVALID_INDEX;
	StorageIndex regex_column_id;

	RegexFpgaScanBindData(DuckTableEntry &table, string regex_column, string pattern, vector<uint8_t> regex_blob)
	    : table(table), regex_column(std::move(regex_column)), pattern(std::move(pattern)),
	      regex_blob(std::move(regex_blob)) {
	}
};

struct RegexFpgaScanGlobalState : public GlobalTableFunctionState {
	idx_t MaxThreads() const override;
	celeris::CelerisContext &ctx;
	ParallelTableScanState parallel_scan;
	idx_t max_threads = 1;
	// oasis_regex_dry_run: skip the device and report no matches, leaving only the host-side
	// scan-and-pack cost. Benchmarking only -- see the option's description.
	bool dry_run = false;

	explicit RegexFpgaScanGlobalState(celeris::CelerisContext &ctx) : ctx(ctx) {
	}
};

// One row the current batch decides. 12 bytes, deliberately.
//
// There is one of these per scanned row, so at 20 M rows the natural idx_t/uint64_t
// layout wrote 640 MB just to record where answers come back -- comparable to the string
// data itself, and it showed up as memory traffic in the profile. Every field has a much
// smaller real bound:
//
//   chunk_id  one per scanned DataChunk, so ~2048 rows apart; 2^32 covers 8.8e12 rows
//   row_idx   an offset within one DataChunk, so < STANDARD_VECTOR_SIZE (2048)
//   slot_idx  a slot within one batch, bounded by max_accum_count (<= 131008)
struct StagedRowRef {
	// Stable id, not an index. Several transfers are outstanding at once and each holds
	// its own refs, so a position in a container that shifts underneath them is not
	// enough -- the batch-relative index this replaced was only ever correct because
	// exactly one batch existed at a time.
	uint32_t chunk_id;
	// Transfer slot whose match bit decides this row, or kCpuResolvedSlot when the
	// verdict was computed on the CPU and is carried in cpu_match instead. Usually one
	// slot per row, but rows sharing a dictionary entry share a slot -- see the
	// dictionary fast path in AccumulateRows.
	uint32_t slot_idx;
	uint16_t row_idx;
	// Only meaningful when slot_idx is kCpuResolvedSlot. Outliers (>= outlier_bytes)
	// never reach the card, so their answer travels with the ref; keeping it here rather
	// than in a side list means AppendMatchedRows still walks one array in scan order and
	// needs no merge step.
	bool cpu_match;
};

// slot_idx sentinel for "already decided on the host". Not DConstants::INVALID_INDEX,
// which is idx_t-wide and would not fit the field above.
static constexpr uint32_t kCpuResolvedSlot = 0xFFFFFFFFu;

// A scanned chunk, held until every transfer that references it has been collected.
// Chunks are produced in scan order and released in the same order, so a deque popped
// from the front is the natural container -- and a deque of unique_ptr keeps the
// DataChunk address stable, which AccumulateRows relies on: it holds a live DataChunk&
// and UnifiedVectorFormat across submit points.
struct RetainedChunk {
	// 32-bit to match StagedRowRef::chunk_id; see the bound documented there.
	uint32_t id = 0;
	unique_ptr<DataChunk> chunk;
	// Transfers submitted and not yet collected that reference this chunk, plus one
	// for `staging_ref` while it is still held. Freed at zero.
	uint32_t pending_refs = 0;
	// Whether the staging ref is still held. The ref covers the window between the
	// chunk being scanned and the submit that carries its rows away, and it is released
	// once -- but the release runs on every submit, and one scanned chunk can span
	// several submits when a batch fills mid-chunk. Without this flag the second submit
	// releases it again, dropping a ref that belongs to an outstanding transfer and
	// freeing a chunk that transfer still has to read rows out of.
	bool staging_ref = false;
};

// One transfer submitted to the card and not yet collected.
//
// It owns everything the card is still reading or about to write: the wire buffer is
// pinned for the DMA's lifetime, and the row refs are what turn the returned bitmap
// back into output rows. Destroying one without collecting it strands its handle at
// the head of the OutputBufferManager's positional queue -- see the destructor of
// RegexFpgaScanLocalState, which is why that drain is not optional.
struct InFlightTransfer {
	RegexSubmission submission;
	std::shared_ptr<libstf::Buffer> wire_buffer;
	vector<StagedRowRef> row_refs;
	// Chunks this transfer holds a pending_refs count on, so collecting it can release
	// exactly those.
	vector<uint32_t> chunk_ids;
	idx_t count = 0;
	// Packed in full but never sent (oasis_regex_dry_run): collect returns all-zero
	// without touching the device.
	bool dry_run = false;
	// This transfer holds one of the card's symbol-table slots, released when it is
	// collected. table_decoder identifies which table, so the release matches the acquire
	// once more than one slot can be live. See TryAcquireRegexTableSlot.
	bool table_slot = false;
	// Wire audit taken at submit and re-checked at collect, under OASIS_REGEX_VERIFY_WIRE.
	// The submit-side check alone cannot see a buffer mutated after the arm and before the
	// DMA has read it; comparing the two is what closes that.
	celeris::RegexStreamPacker::Plan audit_plan;
	uint64_t audit_header_bytes = 0;
	uint64_t audit_delims = 0;
	uint64_t audit_hash = 0;
	bool     audit_compressed = false;
	bool     audit_taken = false;
	const void *table_decoder = nullptr;
};

struct RegexFpgaScanLocalState : public LocalTableFunctionState {
	TableScanState scan_state;
	DataChunk output_cache;

	vector<LogicalType> scanned_types;
	vector<LogicalType> output_types;
	idx_t scanned_regex_column_idx = DConstants::INVALID_INDEX;
	vector<idx_t> output_column_map;

	// Scanned chunks still referenced by the staging cursor or by an outstanding
	// transfer, oldest first.
	std::deque<RetainedChunk> retained_chunks;
	uint32_t next_chunk_id = 0;
	vector<StagedRowRef> batch_row_refs;

	// Transfers on the card, oldest first. Collected from the front, so results are
	// consumed in submission order and output rows stay in scan order.
	std::deque<InFlightTransfer> in_flight;
	// Row-ref vectors returned by collected transfers, kept so their capacity survives.
	// SubmitStagedBatch moves batch_row_refs into the transfer, which leaves the member
	// with capacity 0; without recycling, every batch regrew it from scratch and faulted
	// in fresh pages doing so.
	vector<vector<StagedRowRef>> free_row_refs;
	// Wire buffers not currently pinned by an outstanding transfer. A submitted buffer
	// leaves this list and comes back when its transfer is collected, so the list plus
	// the in-flight window is a fixed set of at most max_in_flight buffers.
	vector<std::shared_ptr<libstf::Buffer>> free_wire_buffers;
	// Buffer the packer is currently writing into; null between finalize and the next
	// staged row.
	std::shared_ptr<libstf::Buffer> wire_buffer;

	// Reusable scratch for compacting matched rows, sized once to avoid per-flush allocation.
	vector<vector<idx_t>> match_indices_scratch;
	SelectionVector match_sel_scratch;

	// Filters DuckDB pushed down as "optional": it does not enforce them (their evaluation is a
	// no-op marker) and keeps a FILTER above us instead. We unwrap them into a real filter set and
	// hand that to the storage scan, so rows are dropped during column reading and never reach the
	// FPGA. Must outlive scan_state, which only borrows it.
	unique_ptr<TableFilterSet> scan_filter_set;

	// Position in retained_chunks of the chunk the staging loop is reading, not an id:
	// the deque only ever grows at the back and shrinks at the front, and this is
	// adjusted when the front is popped.
	idx_t current_retained_chunk_idx = DConstants::INVALID_INDEX;
	idx_t chunk_offset = 0;
	idx_t output_cache_read_idx = 0;
	idx_t rows_in_current_row_group = 0;

	// Payload bytes staged for the card in this batch: sum of len+1 over the strings that
	// took a slot, so deduplicated rows cost nothing here just as they cost nothing on the
	// wire. Within a chunk of the finalized rectangle, so it is what the byte target is
	// tested against -- counted incrementally because the rectangle form needs a divide
	// and this is asked once per scanned row.
	uint64_t batch_payload_bytes = 0;
	// Wire-byte target for the batch being staged. Equal to REGEX_FPGA_TARGET_WIRE_BYTES
	// except during the opening ramp -- see REGEX_FPGA_FILL_RAMP_STEPS.
	uint64_t batch_target_bytes = REGEX_FPGA_TARGET_WIRE_BYTES;
	// Batches this thread has started, only to index the ramp.
	idx_t batches_started = 0;
	// Opening-ramp length for this scan; see REGEX_FPGA_FILL_RAMP_STEPS.
	idx_t fill_ramp_steps = REGEX_FPGA_FILL_RAMP_STEPS;
	// Steady-state wire-byte target; see REGEX_FPGA_TARGET_WIRE_BYTES.
	uint64_t target_wire_bytes = REGEX_FPGA_TARGET_WIRE_BYTES;
	// Whether this thread has submitted anything yet, for the fill measurement only.
	bool submitted_any = false;
	idx_t accum_count = 0; // distinct strings staged for the FPGA in this batch
	idx_t staged_rows = 0; // rows this batch decides; >= accum_count once rows share a slot
	// The storage scan has no more rows. Distinct from `finished`, which additionally
	// requires the in-flight window to be drained: with transfers still on the card the
	// scan is over but the operator is not, and GetData is re-entered to collect them.
	bool scan_exhausted = false;
	bool finished = false;

	// Dictionary fast path. When the regex column arrives dictionary-encoded, every row with the
	// same dictionary entry has the same string and therefore the same answer, so the string is
	// sent to the FPGA once and the rest of the rows read the result out of the same slot.
	// dict_slot_of maps a dictionary index to that slot; dict_slot_stamp records which
	// (chunk, batch) the mapping belongs to, so invalidating the whole map is a counter bump
	// rather than a clear -- it is invalidated on every flush and on every new chunk.
	vector<idx_t> dict_slot_of;
	vector<uint64_t> dict_slot_stamp;
	uint64_t dict_stamp = 0;

	// Rows are packed straight into the wire layout as they are scanned, so there
	// is no separate descriptor buffer and no second pass. The packer holds the
	// per-engine write cursors; the batch geometry only becomes known at submit. It
	// writes into `wire_buffer` above, which rotates through free_wire_buffers.
	celeris::RegexStreamPacker packer;

	// Batch geometry, resolved once per scan from oasis_regex_batch_rows /
	// oasis_regex_wire_buffer_bytes so a sweep does not need a rebuild. A batch ends
	// when either cap is hit: rows bind for short strings, bytes for long ones.
	idx_t max_accum_count = REGEX_FPGA_MAX_ACCUM_COUNT;
	// Row cap for the batch currently being staged, ramped from small to max_accum_count
	// over the first few batches of the scan.
	//
	// The card is idle until the first transfer is enqueued, and with a flat cap that is
	// one whole batch of scan-and-pack per thread -- every thread starts at the same
	// instant and none of them submits anything for ~1.4 ms at 32 threads. Measured with
	// the link-occupancy counters (regex_fpga_batch_phases): a 27 ms query spent 2.4 ms
	// with nothing enqueued, essentially all of it in one gap before the first
	// submission, and none at all once the window had filled.
	//
	// Ramping costs nothing in steady state because it is over after four batches, and
	// nothing in link occupancy either: a wave of 32 transfers of r rows takes the card
	// 32*r*73/12.6e9 s while the threads need r*85ns to pack the next one, a ratio of
	// ~2.2 that is independent of r. So the card stays ahead at every rung of the ramp,
	// and only the first rung is paid.
	// Row cap for the batch currently being staged. Equal to max_accum_count today --
	// kept as its own field because it is what WouldExceedFpgaBatch tests, and a scan
	// that wants to vary the cap during the scan (a ramp, a stagger) changes only this.
	// Both of those were tried and lost; see the note in RegexFpgaScanInitLocal.
	idx_t accum_cap = 0;
	uint64_t wire_buffer_bytes = REGEX_FPGA_WIRE_BUFFER_BYTES;
	// Values at or above this are matched on the CPU and never sent to the card, from
	// oasis_regex_outlier_bytes. Defaults to the celeris constant.
	//
	// The card's hazard is length *skew*: the collector pops all 64 engines together, so
	// one engine walking a multi-KB string holds the rest until their result FIFOs fill,
	// which backs pressure to the splitter and can wedge the array (see
	// kRegexOutlierBytes). Keeping outliers off the card removes the skew at its source.
	// It is also the cheaper answer on its own terms: the rectangle charges 63*L of
	// filler wire for a single outlier, so one 64 KB value would cost a 4 MiB transfer
	// to decide one row.
	uint64_t outlier_bytes = celeris::kRegexOutlierBytes;

	// oasis_regex_fsst_passthrough: ship FSST-compressed bytes to the card instead of
	// decompressing them on the host first. Off by default, and it must stay off until the
	// RTL carries a decompressor -- the engines match whatever bytes arrive, so with a
	// plaintext bitstream this returns valid-looking wrong answers rather than an error.
	//
	// Enabling it is not sufficient on its own: DuckDB only hands out an FSST_VECTOR when
	// enable_fsst_vectors is also on, and only for reads that do not straddle a
	// ColumnSegment boundary. Rows that arrive decompressed anyway fall back to the host
	// RE2 outlier path, so the setting degrades in throughput, never in correctness.
	bool fsst_passthrough = false;

	// The FSST decoder of the segment whose rows are in the batch being packed, or nullptr
	// while the batch is empty. It doubles as the segment's identity: DuckDB builds one
	// decoder per ColumnSegment, so the pointer changing means the scan has crossed into a
	// segment with a different symbol table.
	//
	// A batch carries exactly one symbol table to the card, so it must not span two. Mixing
	// them decodes the second segment's rows against the first segment's symbols, which is
	// the failure this design has to avoid above all others: every code is still a valid
	// code, so it yields plausible strings and a valid-looking wrong answer, with no error.
	const void *batch_fsst_decoder = nullptr;

	// Where this batch's symbol-table header sits in the wire buffer, or nullptr when the
	// batch carries no table. Reserved at the head of the buffer by the packer, filled once
	// the batch's segment is known -- which is the first compressed row, since the flush on
	// a decoder change guarantees a batch has only one.
	uint8_t *batch_symbol_header = nullptr;

	// RE2 for the outlier path, compiled on first use. Lazy because a scan with no
	// outlier never needs it, and because a pattern the NFA accepts is not guaranteed to
	// compile here -- failing at the point an outlier actually turns up gives a far
	// better error than failing at bind for a scan that would never have used it.
	unique_ptr<duckdb_re2::Regex> cpu_regex;

	// How many transfers this thread keeps on the card, from oasis_regex_max_in_flight.
	//
	// 2, and this is what the thread cap in RegexFpgaScanInitGlobal is derived from: a
	// window of W on T threads holds T*W arm credits, and there are only
	// kRegexMaxSubmissionsInFlight (32) because that is the RTL's strings_in_batch queue
	// depth. So the two numbers are one decision, and the pair that wins is 16 x 2.
	//
	// W=1 was the previous default and was measured against W=2 *at 32 threads*, where
	// 32x2 oversubscribes the credit pool and threads block taking credits off each
	// other -- which is what made W=1 look better. Held to 16 threads so the pool is
	// exactly saturated, W=2 wins 16 rounds out of 16 (25.98 ms against 26.5 ms), because
	// it is what stops a thread waiting out its own device round trip before it packs
	// again. W=3 measured identical to W=2, as it must: the credit pool is already full.
	//
	// Costs one wire buffer per outstanding transfer (wire_buffer_bytes, out of the
	// huge-page pool), so the default is 16 threads x 2 x 4 MiB = 128 MiB -- the same
	// footprint the old 32 x 1 default had.
	idx_t max_in_flight = REGEX_FPGA_DEFAULT_IN_FLIGHT;

	// Blocks on every outstanding transfer and discards its results.
	//
	// Not optional and not just tidiness. enqueued_handles[stream] in
	// OutputBufferManager is a process-wide *positional* FIFO: an abandoned handle
	// stays at its head and the next transfer's results -- another thread's -- are
	// delivered into it. A LIMIT or a cancel destroys a local state with transfers
	// still on the card, so without this the failure is silent cross-thread
	// corruption rather than a leak. Bounded by max_in_flight, so it is cheap.
	~RegexFpgaScanLocalState() override;
};

unique_ptr<FunctionData> RegexFpgaScanBind(ClientContext &context, TableFunctionBindInput &input,
                                           vector<LogicalType> &return_types, vector<string> &names);

unique_ptr<GlobalTableFunctionState> RegexFpgaScanInitGlobal(ClientContext &context,
                                                             TableFunctionInitInput &input);

unique_ptr<LocalTableFunctionState> RegexFpgaScanInitLocal(ExecutionContext &context,
                                                           TableFunctionInitInput &input,
                                                           GlobalTableFunctionState *global_state);

void RegexFpgaScanFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output);

void RegisterRegexFpgaScanFunction(ExtensionLoader &loader);

} // namespace duckdb
