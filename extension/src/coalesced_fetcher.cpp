#include "coalesced_fetcher.hpp"

#include "duckdb/common/exception.hpp"

#include <algorithm>

namespace duckdb {

bool CoalescedFetcher::MergeComparator::operator()(size_t a, size_t b) const {
	const auto &ra = (*reads)[a];
	const auto &rb = (*reads)[b];

	uint64_t a_end = ra.offset + ra.size;
	if (a_end <= NumericLimits<uint64_t>::Maximum() - allow_gap) {
		a_end += allow_gap;
	}
	return ra.offset < rb.offset && a_end < rb.offset;
}

CoalescedFetcher::CoalescedFetcher(FileHandle &file_handle_p, std::shared_ptr<libstf::MemoryPool> memory_pool_p,
                                   GroupSpan group_span_p, uint64_t allow_gap_p)
    : file_handle(file_handle_p), memory_pool(std::move(memory_pool_p)), group_span(group_span_p),
      allow_gap(allow_gap_p), merge_set(MergeComparator {allow_gap_p, &merged}) {
}

CoalescedFetcher::RangeHandle CoalescedFetcher::Register(uint64_t offset, uint64_t size) {
	if (fetched) {
		throw InternalException("CoalescedFetcher::Register called after PrepareReads");
	}

	RangeHandle handle = ranges.size();
	registered_bytes += size;

	// Probe the merge set with a throwaway MergedRead describing the new range. If an existing 
    // merged read is "equivalent", grow it to cover the union and attach this range to it.
	merged.push_back(MergedRead {offset, size, nullptr});
	size_t probe = merged.size() - 1;

	auto it = merge_set.find(probe);
	if (it != merge_set.end()) {
		// Found a neighbour: Drop the probe, widen the existing merged read.
		merged.pop_back();
		size_t target = *it;
		auto &m = merged[target];
		uint64_t new_start = std::min<uint64_t>(m.offset, offset);
		uint64_t new_end = std::max<uint64_t>(m.offset + m.size, offset + size);
		// Note: widening can only ever extend the merged range's end (its start
		// never moves left past a smaller existing neighbour's start without
		// staying within the same set slot).
		m.offset = new_start;
		m.size = new_end - new_start;
		ranges.push_back(Range {offset, size, target});
		return handle;
	}

	// No neighbour: The probe becomes a new merged read in its own slot.
	merge_set.insert(probe);
	ranges.push_back(Range {offset, size, probe});
	return handle;
}

void CoalescedFetcher::PrepareReads() {
	if (fetched) {
		throw InternalException("CoalescedFetcher::PrepareReads called twice");
	}

	// Whole-row-group prefetch heuristic: When the registered (projected) bytes cover more than
	// WHOLE_GROUP_PREFETCH_MINIMUM_SCAN of the group's full byte span, register the whole span.
	if (group_span.size > 0 &&
	    (double)registered_bytes / (double)group_span.size > WHOLE_GROUP_PREFETCH_MINIMUM_SCAN) {
		Register(group_span.offset, group_span.size);
	}

	fetched = true;
	merge_set.clear();

	for (auto &m : merged) {
		void *ptr;
		auto status = memory_pool->allocate(m.size, &ptr);
		if (!status.ok()) {
			throw IOException("CoalescedFetcher could not allocate %llu byte input buffer: %s",
			                  (unsigned long long)m.size, status.message().c_str());
		}
		m.buffer = libstf::make_buffer(memory_pool, ptr, m.size, m.size);
		total_fetched += m.size;
	}
}

void CoalescedFetcher::ExecuteMergedRead(size_t idx) {
	if (!fetched) {
		throw InternalException("CoalescedFetcher::ExecuteMergedRead called before PrepareReads");
	}
	if (idx >= merged.size()) {
		throw InternalException("CoalescedFetcher::ExecuteMergedRead invalid index %llu", (unsigned long long)idx);
	}
	auto &m = merged[idx];
	file_handle.Read(m.buffer->ptr, m.size, m.offset);
}

namespace {

class MergedReadTask : public AsyncTask {
public:
	MergedReadTask(CoalescedFetcher &fetcher, size_t idx) : fetcher(fetcher), idx(idx) {
	}

	void Execute() override {
		fetcher.ExecuteMergedRead(idx);
	}

private:
	CoalescedFetcher &fetcher;
	size_t idx;
};

} // namespace

vector<unique_ptr<AsyncTask>> CoalescedFetcher::BuildReadTasks() {
	if (!fetched) {
		throw InternalException("CoalescedFetcher::BuildReadTasks called before PrepareReads");
	}
	vector<unique_ptr<AsyncTask>> tasks;
	tasks.reserve(merged.size());
	for (size_t idx = 0; idx < merged.size(); idx++) {
		tasks.push_back(make_uniq<MergedReadTask>(*this, idx));
	}
	return tasks;
}

CoalescedFetcher::RangeView CoalescedFetcher::Resolve(RangeHandle handle) const {
	if (!fetched) {
		throw InternalException("CoalescedFetcher::Resolve called before PrepareReads");
	}
	if (handle >= ranges.size()) {
		throw InternalException("CoalescedFetcher::Resolve invalid handle %llu", (unsigned long long)handle);
	}
	const auto &r = ranges[handle];
	const auto &m = merged[r.merged_idx];
	return RangeView {m.buffer, r.offset - m.offset, r.size};
}

} // namespace duckdb
