#include "oasis_mock_scan.hpp"

#include "duckdb/common/exception.hpp"
#include "duckdb/common/types/vector.hpp"

#include <sstream>

namespace duckdb {

MockBloomFilter::MockBloomFilter(idx_t bit_count, idx_t hash_count)
    : bits(bit_count, false), bit_count(bit_count), hash_count(hash_count) {
}

void MockBloomFilter::Add(int32_t value) {
	for (idx_t i = 0; i < hash_count; i++) {
		bits[Hash(value, i) % bit_count] = true;
	}
}

bool MockBloomFilter::MayContain(int32_t value) const {
	for (idx_t i = 0; i < hash_count; i++) {
		if (!bits[Hash(value, i) % bit_count]) {
			return false;
		}
	}
	return true;
}

uint64_t MockBloomFilter::Hash(int32_t value, idx_t seed) {
	uint64_t x = static_cast<uint64_t>(static_cast<uint32_t>(value));
	x ^= seed + 0x9e3779b97f4a7c15ULL + (x << 6) + (x >> 2);
	x ^= x >> 30;
	x *= 0xbf58476d1ce4e5b9ULL;
	x ^= x >> 27;
	x *= 0x94d049bb133111ebULL;
	x ^= x >> 31;
	return x;
}

static MockBloomFilter BuildBloomFilterFromString(const string &keys_string) {
	MockBloomFilter filter(1024, 3);

	std::stringstream ss(keys_string);
	string item;

	while (std::getline(ss, item, ',')) {
		if (item.empty()) {
			continue;
		}
		filter.Add(std::stoi(item));
	}

	return filter;
}

unique_ptr<FunctionData> OasisMockScanBind(ClientContext &context, TableFunctionBindInput &input,
                                           vector<LogicalType> &return_types, vector<string> &names) {
	names.emplace_back("id");
	return_types.emplace_back(LogicalType::INTEGER);

	names.emplace_back("passed_mock_bloom_filter");
	return_types.emplace_back(LogicalType::BOOLEAN);

	auto bind_data = make_uniq<OasisMockScanBindData>();
	bind_data->row_count = 10;

	auto bloom_keys_string = StringValue::Get(input.inputs[1]);
	bind_data->bloom_filter = BuildBloomFilterFromString(bloom_keys_string);

	return std::move(bind_data);
}

unique_ptr<GlobalTableFunctionState> OasisMockScanInitGlobal(ClientContext &context, TableFunctionInitInput &input) {
	auto &bind_data = input.bind_data->Cast<OasisMockScanBindData>();

	auto gstate = make_uniq<OasisMockScanGlobalState>();
	gstate->position = 0;
	gstate->row_count = bind_data.row_count;
	gstate->bloom_filter = bind_data.bloom_filter;

	return std::move(gstate);
}

unique_ptr<LocalTableFunctionState> OasisMockScanInitLocal(ExecutionContext &context, TableFunctionInitInput &input,
                                                           GlobalTableFunctionState *global_state_p) {
	return make_uniq<OasisMockScanLocalState>();
}

void OasisMockScanFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &gstate = data_p.global_state->Cast<OasisMockScanGlobalState>();

	idx_t emit = 0;

	while (gstate.position < gstate.row_count && emit < STANDARD_VECTOR_SIZE) {
		auto id = static_cast<int32_t>(gstate.position);
		gstate.position++;

		if (!gstate.bloom_filter.MayContain(id)) {
			continue;
		}

		FlatVector::GetData<int32_t>(output.data[0])[emit] = id;
		FlatVector::GetData<bool>(output.data[1])[emit] = true;
		emit++;
	}

	output.SetCardinality(emit);
}

} // namespace duckdb
