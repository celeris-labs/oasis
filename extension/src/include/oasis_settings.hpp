#pragma once

#include "duckdb.hpp"

namespace duckdb {

// Default verbosity for the oasis_logging_level setting (and libstf's runtime threshold at load).
constexpr const char *DEFAULT_OASIS_LOG_LEVEL = "ERROR";

void SetOasisLogLevel(ClientContext &context, SetScope scope, Value &parameter);

void SetSchedulerNumStreams(ClientContext &context, SetScope scope, Value &parameter);

void SetSchedulerQueueDepth(ClientContext &context, SetScope scope, Value &parameter);

} // namespace duckdb
