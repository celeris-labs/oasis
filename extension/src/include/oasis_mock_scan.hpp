#pragma once

#include "duckdb.hpp"

#include <cstdint>
#include <vector>

namespace duckdb {

class MockBloomFilter {
public:
	explicit MockBloomFilter(idx_t bit_count = 1024, idx_t hash_count = 3);
	void Add(int32_t value);
	bool MayContain(int32_t value) const;

private:
	std::vector<bool> bits;
	idx_t bit_count;
	idx_t hash_count;

	static uint64_t Hash(int32_t value, idx_t seed);
};

struct OasisMockScanBindData : public TableFunctionData {
	idx_t row_count = 10;
	MockBloomFilter bloom_filter;
};

struct OasisMockScanGlobalState : public GlobalTableFunctionState {
	idx_t position = 0;
	idx_t row_count = 10;
	MockBloomFilter bloom_filter;
};

struct OasisMockScanLocalState : public LocalTableFunctionState {};

unique_ptr<FunctionData> OasisMockScanBind(ClientContext &context, TableFunctionBindInput &input,
                                           vector<LogicalType> &return_types, vector<string> &names);

unique_ptr<GlobalTableFunctionState> OasisMockScanInitGlobal(ClientContext &context, TableFunctionInitInput &input);

unique_ptr<LocalTableFunctionState> OasisMockScanInitLocal(ExecutionContext &context, TableFunctionInitInput &input,
                                                           GlobalTableFunctionState *global_state_p);

void OasisMockScanFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output);

} // namespace duckdb
