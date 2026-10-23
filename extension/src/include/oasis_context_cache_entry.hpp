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
	// size: 8 MiB is about 1M rows of an 8-byte type. The OBM keeps up to OASIS_OBM_BUFFERS (64) such
	// buffers per stream.
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
