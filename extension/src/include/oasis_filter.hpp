#pragma once

#include "duckdb.hpp"
#include "oasis/configuration.hpp"

namespace duckdb {

class LogicalGet;
struct OasisScanBindData;

struct OasisFilter {
	oasis::FilterComparison comparison = oasis::FilterComparison::ALWAYS_TRUE;
	std::array<uint64_t, oasis::FilterConfig::NUM_RHS> rhs = {};
	std::array<uint64_t, oasis::FilterConfig::NUM_ADDITIONAL_RHS> additional_rhs = {};
	uint8_t additional_rhs_mask = 0;
};

using OasisFilterLayer = map<idx_t, OasisFilter>;

void OasisPushdownComplexFilter(ClientContext &context, LogicalGet &get, FunctionData *bind_data,
                                vector<unique_ptr<Expression>> &filters);

InsertionOrderPreservingMap<string> OasisScanToString(TableFunctionToStringInput &input);

vector<OasisFilterLayer> NormalizeOasisFilters(const TableFunctionInitInput &input,
                                               const OasisScanBindData &bind_data);

vector<libstf::stream_t> AssignOasisFilterStreams(const vector<size_t> &columns,
                                                  const vector<OasisFilterLayer> &layers);

void ConfigureOasisFilters(oasis::FilterConfig &config, const vector<size_t> &columns,
                           const vector<libstf::stream_t> &streams,
                           const vector<OasisFilterLayer> &layers);

} // namespace duckdb
