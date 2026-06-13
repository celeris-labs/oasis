#pragma once

#include "duckdb/common/file_system.hpp"
#include "libstf/buffer.hpp"
#include "libstf/memory_pool.hpp"

#include <cstdint>
#include <memory>
#include <set>
#include <vector>

namespace duckdb {

// Two-step coalesced host fetcher:
//
//   1. Register every (offset, size) range you intend to read. Ranges that overlap, are adjacent, 
//      or sit within ALLOW_GAP bytes of each other are merged into a single physical read.
//   2. Fetch() issues one host read per merged range, into one libstf buffer per merged range.
//
// Not thread-safe: each worker owns its own fetcher, mirroring the per-worker file_handle ownership 
// in OasisScanLocalState.
class CoalescedFetcher {
public:
	// Default gap (in bytes) within which two ranges are still merged. Matches the Parquet reader's 
    // ReadHeadComparator::ALLOW_GAP (16 KiB).
	static constexpr uint64_t DEFAULT_ALLOW_GAP = 1 << 14;

	// When the projected bytes of a row group cover at least this fraction of the group's full byte 
    // span, the caller should fetch the whole span in one read rather than per-column. Matches the 
    // Parquet reader's ParquetReaderPrefetchConfig::WHOLE_GROUP_PREFETCH_MINIMUM_SCAN.
	static constexpr double WHOLE_GROUP_PREFETCH_MINIMUM_SCAN = 0.95;

	// Opaque handle to a registered range. Resolve it with Resolve() once Fetch() has run.
	using RangeHandle = size_t;

	// `group_span` is the full byte span of the row group being fetched: [min chunk offset, max 
    // chunk end) over ALL chunks, not just the projected ones (matches ParquetReader::GetGroupSpan).
	struct GroupSpan {
		uint64_t offset;
		uint64_t size;
	};

	CoalescedFetcher(FileHandle &file_handle, std::shared_ptr<libstf::MemoryPool> memory_pool,
	                 GroupSpan group_span, uint64_t allow_gap = DEFAULT_ALLOW_GAP);

	// Register a range to be read. Returns a handle to resolve after Fetch(). May be merged with
    // previously registered ranges. Must be called before Fetch().
	RangeHandle Register(uint64_t offset, uint64_t size);

	// Issue the coalesced reads. Must be called exactly once, after all Register() calls and before 
    // any Resolve().
	void Fetch();

	struct RangeView {
		std::shared_ptr<libstf::Buffer> buffer;
		uint64_t offset;
		uint64_t size;

		void *data() const {
			return static_cast<uint8_t *>(buffer->ptr) + offset;
		}
	};

	RangeView Resolve(RangeHandle handle) const;

	size_t num_ranges() const {
		return ranges.size();
	}
	size_t num_reads() const {
		return merged.size();
	}
	uint64_t bytes_fetched() const {
		return total_fetched;
	}

private:
	struct Range {
		uint64_t offset;
		uint64_t size;
		size_t merged_idx; // index into `merged`, assigned at registration
	};

	struct MergedRead {
		uint64_t offset;
		uint64_t size;
		std::shared_ptr<libstf::Buffer> buffer;
	};

	// Orders MergedReads by start offset and treats two reads as "the same slot" when the later one 
    // starts within allow_gap of the earlier one's end.
	struct MergeComparator {
		uint64_t allow_gap;
		bool operator()(size_t a, size_t b) const;
		const std::vector<MergedRead> *reads;
	};

	FileHandle &file_handle;
	std::shared_ptr<libstf::MemoryPool> memory_pool;
	GroupSpan group_span;
	uint64_t allow_gap;

	// Sum of sizes passed to Register(), i.e. the projected bytes; compared against group_span in
	// Fetch() to decide whether to read the whole span in one go.
	uint64_t registered_bytes = 0;

	std::vector<Range> ranges;
	std::vector<MergedRead> merged;
	// Indices into `merged`, kept sorted/merged so registration is ~O(log n).
	std::set<size_t, MergeComparator> merge_set;

	bool fetched = false;
	uint64_t total_fetched = 0;
};

} // namespace duckdb
