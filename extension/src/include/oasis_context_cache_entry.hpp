#pragma once

#include "duckdb.hpp"
#include "duckdb/storage/object_cache.hpp"
#include "oasis/oasis_context.hpp"
#include "oasis_log_sink.hpp"

namespace duckdb {

// Thin ObjectCacheEntry that ensures oasis::OasisContext is initialized exactly
// once for the lifetime of the DatabaseInstance and across all connections.
struct OasisContextCacheEntry : public ObjectCacheEntry {
	static std::string ObjectType() {
		return "oasis_context";
	}
	std::string GetObjectType() override {
		return ObjectType();
	}
	optional_idx GetEstimatedCacheMemory() const override {
		return optional_idx();
	}

	// Auto-enqueued (managed-stream) OBM buffer capacity. The scan relies on a column chunk's
	// decoded output fitting in a single buffer for now, so this value is a hard cap on row group
	// size: one row group of the widest fixed-width type must fit.
	//
	//   DuckDB's default row_group_size (122,880 rows) x 8 bytes (INT64/DOUBLE) = 960 KiB
	//
	// which is 94% of the 1 MiB this used to be -- so the default was also, in practice, the
	// maximum. That matters for throughput and not just for compatibility: over httpfpga:// the
	// FPGA issues one ranged GET per column chunk, and each one costs a TCP connect, the server's
	// time-to-first-byte and a teardown. Small row groups mean many chunks mean many round trips,
	// and the decoder idles through all of them. 8 MiB allows row groups up to ~1M rows of INT64,
	// which cuts the request count (and therefore the dead time) by roughly 8x on files written
	// with ROW_GROUP_SIZE 1000000. The cost is host memory: the OBM allocates 2 buffers per stream.
	static constexpr size_t OBM_BUFFER_CAPACITY = 8ULL * 1024 * 1024;

	explicit OasisContextCacheEntry(DatabaseInstance &db) : log_sink(db) {
		libstf::set_log_sink(&log_sink);
#ifdef EN_SIMULATION
		// Simulation uses a small buffer to keep sim runtime/memory tractable. Sim test fixtures
		// must use row groups small enough that a decoded column chunk fits in this single buffer.
		auto pool = std::make_shared<libstf::SimpleMemoryPool>();
		oasis::OasisContext::init(std::move(pool), libstf::BYTES_PER_FPGA_TRANSFER);
#else
		auto pool = std::make_shared<libstf::HugePageMemoryPool>();
		oasis::OasisContext::init(std::move(pool), OBM_BUFFER_CAPACITY);
#endif
	}

	oasis::OasisContext &ctx() {
		return oasis::OasisContext::ctx();
	}

	~OasisContextCacheEntry() override {
		oasis::OasisContext::shutdown();
		libstf::set_log_sink(nullptr);
	}

private:
	OasisLogSink log_sink;
};

inline oasis::OasisContext &GetOrCreateOasisContext(ClientContext &context) {
	return ObjectCache::GetObjectCache(context)
	    .GetOrCreate<OasisContextCacheEntry>("oasis_context", *context.db)
	    ->ctx();
}

} // namespace duckdb
