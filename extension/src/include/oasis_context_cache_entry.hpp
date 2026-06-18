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

	explicit OasisContextCacheEntry(DatabaseInstance &db) : log_sink(db) {
		libstf::set_log_sink(&log_sink);
#ifdef EN_SIMULATION
		auto pool = std::make_shared<libstf::SimpleMemoryPool>();
#else
		auto pool = std::make_shared<libstf::HugePageMemoryPool>();
#endif
		oasis::OasisContext::init(std::move(pool));
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
