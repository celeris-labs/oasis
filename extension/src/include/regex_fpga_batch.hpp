#pragma once

#include "celeris/celeris_context.hpp"
#include "celeris/operators/regex/regex_config.hpp" // REGEX_CONFIG_BLOB_BYTES
#include "celeris/operators/regex/regex_stream.hpp"
#include "syslog_undef.hpp" // must follow the celeris include, precede the duckdb ones

#include "duckdb/common/types/string_type.hpp"
#include "libstf/buffer.hpp"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <memory>
#include <vector>

namespace duckdb {

static constexpr uint64_t REGEX_FPGA_BEAT_BYTES = 64;

// Rows per batch. The device round trip costs a fixed ~134 us per batch on top of a
// per-string term, so fewer, larger batches amortise it -- measured at threads=1:
// 16 B strings 4.48 -> 3.06 ns/string going from 65536 to 131072 (1.46x), 33 B 1.33x,
// 72 B 1.16x, 256 B 1.07x. Short strings gain most because the *row* cap is what binds
// for them; long ones hit the byte cap first and barely move.
//
// Kept at 65536 deliberately. 131072 is the absolute ceiling --
// kRegexMaxStringsPerEngine (2048) x 64 engines -- so defaulting to it leaves the
// parallel-pop result FIFOs *exactly* full, with none of the skew slack the deadlock
// analysis relies on. Tried as a default and backed out: a 12-case sweep exhausted the
// 1 GiB huge-page pool mid-run and five cases disagreed with software. End to end it was
// only worth ~5% anyway (the device is ~48% of the wall clock at 32 threads, so device
// savings convert at roughly 40%), which does not buy that risk.
//
// Still worth raising for single-threaded device work, where it is a real 1.3-1.5x on
// short strings: use oasis_regex_batch_rows per session rather than changing this.
static constexpr idx_t REGEX_FPGA_MAX_ACCUM_COUNT = 1ULL << 16;

// How much wire buffer one scan thread holds. This is a host-memory bound and
// nothing more: the 1 MiB REGEX_FPGA_RAW_BATCH_LIMIT it replaces was the
// german_string_decoder Dictionary's BRAM depth showing through into the host,
// and the card no longer stores the payload at all.
//
// It is per thread and comes out of the huge-page pool, so it is not free: at 32
// threads this is 128 MiB. Deliberately left at 4 MiB even though the row cap is now
// 131072: raising it to 16 MiB was measured neutral-to-negative end to end (c_comment
// 64.0 -> 69.6 ms) while costing 512 MiB of huge pages at 32 threads, from a pool that
// leaks. Short columns do not need it -- 131072 x 17 B is 2.2 MB -- and long ones are
// exactly where the extra memory buys least. Overridable with
// oasis_regex_wire_buffer_bytes.
static constexpr uint64_t REGEX_FPGA_WIRE_BUFFER_BYTES = 4ULL << 20;

void EnsureCelerisContext();
celeris::CelerisContext &GetCelerisContext();

// Per-phase wall time inside RunFpgaRegexPackedBatch, accumulated across batches.
// Everything here happens under the global fpga_mutex, so it is serialized across
// threads and is exactly the cost that shows up as "device time" in a
// scan/pack/device decomposition. Four clock reads per batch is nothing against a
// batch measured in hundreds of microseconds, so this is always on.
//
// mutex_wait is time queued behind another thread and is only meaningful above one
// thread; the rest are the phases of one batch's round trip.
struct RegexBatchPhases {
	uint64_t batches = 0;
	uint64_t strings = 0;
	uint64_t mutex_wait_ns = 0;
	uint64_t config_ns = 0;
	uint64_t enqueue_ns = 0;
	uint64_t drain_ns = 0;
	uint64_t read_ns = 0;
};

RegexBatchPhases GetRegexBatchPhases();
void ResetRegexBatchPhases();

// Every string now travels in the payload, including the ones DuckDB inlines
// into the 16 B string_t: there is no descriptor stream for them to ride along in
// any more. That trades 16 B/row of descriptor for len+1 B/row of payload, which
// is a win for anything under 15 B and a much bigger one for everything else,
// since the descriptor used to be sent *as well* as the payload.

uint64_t align_to_64_multiple(uint64_t size);

// One verdict per slot, kept in the card's own packed layout. The collector emits
// bit i for string i (see the parallel-pop note in RunFpgaRegexPackedBatch), so the
// device buffer is already in destination order and the read-back is a memcpy.
//
// This replaced a std::vector<bool> that was filled a bit at a time. That loop
// skipped whole zero bytes, so it was nearly free on a selective pattern but cost a
// read-modify-write per match on a dense one -- ~1.9 ns/match, which showed up as
// the operator losing 1.32x of its throughput going from 0% to 100% selectivity.
// The device datapath is identical either way (stream profiles match to two
// decimals across 0/25/100%), so that slope was pure host overhead.
struct RegexMatchBitmap {
	std::vector<uint8_t> bits;
	idx_t count = 0;

	void assign_zero(idx_t n) {
		count = n;
		bits.assign((n + 7) / 8, 0);
	}
	// `src_bytes` is what the card returned; anything it does not cover reads false.
	void assign_from_device(const uint8_t *src, size_t src_bytes, idx_t n) {
		count = n;
		const size_t needed = (static_cast<size_t>(n) + 7) / 8;
		const size_t copied = std::min(needed, src_bytes);
		bits.resize(needed);
		std::memcpy(bits.data(), src, copied);
		if (copied < needed) {
			std::memset(bits.data() + copied, 0, needed - copied);
		}
	}
	bool test(idx_t i) const {
		return (bits[i >> 3] >> (i & 7)) & 1;
	}
};

// Runs a batch already packed into `wire_ptr` by a RegexStreamPacker. `count` is
// the number of real strings; `plan` carries the padded result geometry the card
// needs. Returns one verdict per slot, in slot order.
RegexMatchBitmap RunFpgaRegexPackedBatch(celeris::CelerisContext &ctx, void *wire_ptr,
                                         const celeris::RegexStreamPacker::Plan &plan, idx_t count,
                                         const std::vector<uint8_t> &regex_blob);

std::vector<bool> RunFpgaRegexBatch(celeris::CelerisContext &ctx, const std::vector<string_t> &inputs,
                                    const std::vector<uint8_t> &regex_blob);

} // namespace duckdb
