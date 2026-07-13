#include "oasis_settings.hpp"

#include "oasis_context_cache_entry.hpp"
#include "oasis_log_sink.hpp"
#include "duckdb/common/exception.hpp"

namespace duckdb {

void SetOasisLogLevel(ClientContext &, SetScope, Value &parameter) {
	if (parameter.IsNull()) {
		return;
	}
	libstf::set_log_level(ParseLibstfLogLevel(parameter.GetValue<string>()));
}

void SetSchedulerNumStreams(ClientContext &context, SetScope, Value &parameter) {
	if (parameter.IsNull()) {
		return;
	}
	auto streams = parameter.GetValue<uint64_t>();
	auto &scheduler = GetOrCreateOasisContext(context).scheduler();
	auto available = static_cast<uint64_t>(scheduler.num_decode_streams());
	if (streams < 1 || streams > available) {
		throw InvalidInputException("oasis_scheduler_num_streams must be between 1 and %llu (got %llu)",
		                            (unsigned long long)available, (unsigned long long)streams);
	}
	scheduler.set_active_streams(static_cast<libstf::stream_t>(streams));
}

void SetSchedulerQueueDepth(ClientContext &context, SetScope, Value &parameter) {
	if (parameter.IsNull()) {
		return;
	}
	auto depth = parameter.GetValue<uint64_t>();
	if (depth < 1) {
		throw InvalidInputException("oasis_scheduler_queue_depth must be at least 1 (got %llu)",
		                            (unsigned long long)depth);
	}
	GetOrCreateOasisContext(context).scheduler().set_pipeline_depth(static_cast<size_t>(depth));
}

} // namespace duckdb
