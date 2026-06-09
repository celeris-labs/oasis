#pragma once

#include "duckdb.hpp"
#include "duckdb/storage/object_cache.hpp"
#include "oasis/oasis_context.hpp"

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
	// decoded output fitting in a single buffer for now. The worst case is one DuckDB row group of
	// the widest fixed-width type:
	// DEFAULT_ROW_GROUP_SIZE (122,880 rows) x 8 bytes (INT64/DOUBLE) = 960 KiB
	// 1 MiB fits that, so it covers Parquet files written with DuckDB's default row_group_size.
	static constexpr size_t OBM_BUFFER_CAPACITY = 1ULL * 1024 * 1024;

	OasisContextCacheEntry() {
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
	}
};

} // namespace duckdb
