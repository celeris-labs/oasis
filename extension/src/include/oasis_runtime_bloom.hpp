#pragma once

#include "duckdb.hpp"

#include <cstdint>
#include <vector>

namespace duckdb {

class OasisRuntimeBloom {
public:
	explicit OasisRuntimeBloom(idx_t bits = 1 << 20, idx_t hashes = 3)
	    : bit_count(bits), hash_count(hashes), words((bits + 63) / 64, 0) {
	}

	void AddInt64(int64_t value) {
		for (idx_t i = 0; i < hash_count; i++) {
			auto h = Hash(value, i) % bit_count;
			words[h / 64] |= uint64_t(1) << (h % 64);
		}
		inserted++;
	}

	bool MayContainInt64(int64_t value) const {
		for (idx_t i = 0; i < hash_count; i++) {
			auto h = Hash(value, i) % bit_count;
			if ((words[h / 64] & (uint64_t(1) << (h % 64))) == 0) {
				return false;
			}
		}
		return true;
	}

	idx_t InsertedCount() const {
		return inserted;
	}

	idx_t BitCount() const {
		return bit_count;
	}

	idx_t HashCount() const {
		return hash_count;
	}

private:
	static uint64_t Mix64(uint64_t x) {
		x += 0x9e3779b97f4a7c15ULL;
		x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ULL;
		x = (x ^ (x >> 27)) * 0x94d049bb133111ebULL;
		return x ^ (x >> 31);
	}

	static uint64_t Hash(int64_t value, idx_t seed) {
		return Mix64(static_cast<uint64_t>(value) ^ (seed * 0x9e3779b97f4a7c15ULL));
	}

	idx_t bit_count;
	idx_t hash_count;
	idx_t inserted = 0;
	std::vector<uint64_t> words;
};

} // namespace duckdb