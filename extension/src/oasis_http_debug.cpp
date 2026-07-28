#include "oasis_http_debug.hpp"

#include "oasis_context_cache_entry.hpp"
#include "oasis/oasis_context.hpp"
#include "oasis/configuration.hpp"
#include "parcore/configuration.hpp"

#include "duckdb/function/table_function.hpp"

#include <atomic>
#include <mutex>

namespace duckdb {

namespace {

std::atomic<bool> g_httpfpga_debug {false};
std::atomic<bool> g_httpfpga_cpu_fallback {false};
std::mutex g_last_trigger_mtx;
HttpFpgaLastTrigger g_last_trigger;

struct OasisHttpStateBindData : public TableFunctionData {
	vector<string> names;
	vector<LogicalType> types;
};

struct OasisHttpStateGlobalState : public GlobalTableFunctionState {
	bool emitted = false;

	idx_t MaxThreads() const override {
		return 1;
	}
};

void DefineColumns(vector<string> &names, vector<LogicalType> &types) {
	auto add = [&](const char *name, LogicalType type) {
		names.emplace_back(name);
		types.emplace_back(std::move(type));
	};
	add("http_enabled", LogicalType::BOOLEAN);
	add("http_bypass_stream", LogicalType::UBIGINT);
	add("num_mem_streams", LogicalType::UBIGINT);
	add("num_decoders", LogicalType::UBIGINT);
	add("config_id", LogicalType::UBIGINT);
	add("config_num_streams", LogicalType::UBIGINT);
	add("last_trigger_valid", LogicalType::BOOLEAN);
	add("last_server_ip", LogicalType::UBIGINT);
	add("last_server_port", LogicalType::UBIGINT);
	add("last_file_len", LogicalType::UBIGINT);
	add("last_range_begin", LogicalType::UBIGINT);
	add("last_range_end", LogicalType::UBIGINT);
	add("last_http_size", LogicalType::UBIGINT);
	add("last_path", LogicalType::VARCHAR);
	add("note", LogicalType::VARCHAR);
}

} // namespace

bool HttpFpgaDebugEnabled() {
	return g_httpfpga_debug.load();
}

void SetHttpFpgaDebug(ClientContext &, SetScope, Value &parameter) {
	g_httpfpga_debug.store(!parameter.IsNull() && parameter.GetValue<bool>());
}

bool HttpFpgaCpuFallbackEnabled() {
	return g_httpfpga_cpu_fallback.load();
}

void SetHttpFpgaCpuFallback(ClientContext &, SetScope, Value &parameter) {
	g_httpfpga_cpu_fallback.store(!parameter.IsNull() && parameter.GetValue<bool>());
}

void RecordHttpFpgaTrigger(uint32_t bypass_stream, uint32_t server_ip, uint16_t server_port, const string &path,
                           uint64_t range_begin, uint64_t range_end, uint32_t size) {
	std::lock_guard<std::mutex> lock(g_last_trigger_mtx);
	g_last_trigger.valid = true;
	g_last_trigger.bypass_stream = bypass_stream;
	g_last_trigger.server_ip = server_ip;
	g_last_trigger.server_port = server_port;
	g_last_trigger.file_len = static_cast<uint32_t>(std::min(path.size(), size_t {32}));
	g_last_trigger.range_begin = range_begin;
	g_last_trigger.range_end = range_end;
	g_last_trigger.size = size;
	g_last_trigger.path = path;
}

HttpFpgaLastTrigger LastHttpFpgaTrigger() {
	std::lock_guard<std::mutex> lock(g_last_trigger_mtx);
	return g_last_trigger;
}

unique_ptr<FunctionData> OasisHttpStateBind(ClientContext &, TableFunctionBindInput &,
                                            vector<LogicalType> &return_types, vector<string> &names) {
	auto bind_data = make_uniq<OasisHttpStateBindData>();
	DefineColumns(names, return_types);
	bind_data->names = names;
	bind_data->types = return_types;
	return std::move(bind_data);
}

unique_ptr<GlobalTableFunctionState> OasisHttpStateInitGlobal(ClientContext &, TableFunctionInitInput &) {
	return make_uniq<OasisHttpStateGlobalState>();
}

void OasisHttpStateFunction(ClientContext &context, TableFunctionInput &input, DataChunk &output) {
	auto &gstate = input.global_state->Cast<OasisHttpStateGlobalState>();
	if (gstate.emitted) {
		output.SetCardinality(0);
		return;
	}

	auto &ctx = GetOrCreateOasisContext(context);
	auto mem_config = ctx.config<libstf::MemConfig>();
	auto cc_config = ctx.config<parcore::ColumnChunkDecoderConfig>();
	const auto bypass_stream = ctx.httpBypassStream();
	const auto last = LastHttpFpgaTrigger();

	idx_t col = 0;
	output.SetValue(col++, 0, Value::BOOLEAN(ctx.isHTTPEnabled()));
	output.SetValue(col++, 0, Value::UBIGINT(static_cast<uint64_t>(bypass_stream)));
	output.SetValue(col++, 0, Value::UBIGINT(static_cast<uint64_t>(mem_config->num_streams())));
	output.SetValue(col++, 0, Value::UBIGINT(static_cast<uint64_t>(cc_config->num_decoders())));

	uint64_t config_id = 0;
	uint64_t config_num_streams = 0;
	if (ctx.isHTTPEnabled()) {
		auto http_cfg = ctx.config<oasis::HTTPReadConfig>();
		config_id = http_cfg->read_register(0).value();
		config_num_streams = http_cfg->read_register(1).value();
	}
	output.SetValue(col++, 0, Value::UBIGINT(config_id));
	output.SetValue(col++, 0, Value::UBIGINT(config_num_streams));
	output.SetValue(col++, 0, Value::BOOLEAN(last.valid));
	output.SetValue(col++, 0, Value::UBIGINT(static_cast<uint64_t>(last.server_ip)));
	output.SetValue(col++, 0, Value::UBIGINT(static_cast<uint64_t>(last.server_port)));
	output.SetValue(col++, 0, Value::UBIGINT(static_cast<uint64_t>(last.file_len)));
	output.SetValue(col++, 0, Value::UBIGINT(last.range_begin));
	output.SetValue(col++, 0, Value::UBIGINT(last.range_end));
	output.SetValue(col++, 0, Value::UBIGINT(static_cast<uint64_t>(last.size)));
	output.SetValue(col++, 0, Value(last.valid ? last.path : string()));
	output.SetValue(col++, 0,
	                Value("last_* = values passed to http_cfg->read(). HTTP write CSRs are not host-readable "
	                      "(getCSR returns 0). config_num_streams is not TCP state. server_ip 0x524dfa0a = "
	                      "10.253.74.82."));

	gstate.emitted = true;
	output.SetCardinality(1);
}

void RegisterOasisHttpStateFunction(ExtensionLoader &loader) {
	TableFunction fn("oasis_http_state", {}, OasisHttpStateFunction, OasisHttpStateBind, OasisHttpStateInitGlobal);
	loader.RegisterFunction(fn);
}

} // namespace duckdb
