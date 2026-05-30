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

	OasisContextCacheEntry() {
#ifdef EN_SIMULATION
		auto pool = std::make_shared<libstf::SimpleMemoryPool>();
		oasis::OasisContext::init(std::move(pool), libstf::BYTES_PER_FPGA_TRANSFER);
#else
		auto pool = std::make_shared<libstf::HugePageMemoryPool>();
		oasis::OasisContext::init(std::move(pool), 1 << 24 /* 16MiB */);
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
