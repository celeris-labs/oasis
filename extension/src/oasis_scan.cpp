#include "oasis_scan.hpp"

#include "duckdb/common/exception.hpp"
#include "duckdb/common/string_util.hpp"
#include "oasis/oasis_context.hpp"
#include "parcore/configuration.hpp"

#include <cstdio>

namespace duckdb {

#define OASIS_SCAN_LOG(...)                                                                                            \
	do {                                                                                                               \
		fprintf(stderr, "[OASIS][SCAN] ");                                                                             \
		fprintf(stderr, __VA_ARGS__);                                                                                  \
		fprintf(stderr, "\n");                                                                                         \
	} while (0)

#define OASIS_BLOOM_LOG(...)                                                                                           \
	do {                                                                                                                \
		fprintf(stderr, "[OASIS][BLOOM] ");                                                                             \
		fprintf(stderr, __VA_ARGS__);                                                                                   \
		fprintf(stderr, "\n");                                                                                          \
	} while (0)

static LogicalType ParcoreTypeToLogical(parcore::metadata::Type type) {
	switch (type) {
	case parcore::metadata::Type::INT32_T:
		return LogicalType::INTEGER;
	case parcore::metadata::Type::INT64_T:
		return LogicalType::BIGINT;
	case parcore::metadata::Type::FLOAT_T:
		return LogicalType::FLOAT;
	case parcore::metadata::Type::DOUBLE_T:
		return LogicalType::DOUBLE;
	case parcore::metadata::Type::BYTE_T:
		return LogicalType::TINYINT;
	case parcore::metadata::Type::BYTE_ARRAY:
		return LogicalType::VARCHAR;
	default:
		throw InternalException("Unsupported ParCore type: %d", static_cast<int>(type));
	}
}

template <class NAME_VECTOR>
static size_t FindColumnId(const NAME_VECTOR &names, const string &name) {
	for (size_t i = 0; i < names.size(); i++) {
		if (StringUtil::CIEquals(string(names[i]), name)) {
			return i;
		}
	}
	throw BinderException("OASIS: column '%s' not found", name);
}

static bool ContainsColumnId(const vector<size_t> &ids, size_t id) {
	for (auto existing : ids) {
		if (existing == id) {
			return true;
		}
	}
	return false;
}

static size_t FindScanIndex(const vector<size_t> &scan_ids, size_t col_id) {
	for (size_t i = 0; i < scan_ids.size(); i++) {
		if (scan_ids[i] == col_id) {
			return i;
		}
	}
	throw InternalException("OASIS: scan column mapping missing for column id %llu", (unsigned long long)col_id);
}

static int64_t ReadIntKey(const std::shared_ptr<libstf::Buffer> &buf, size_t row, parcore::metadata::Type type) {
	switch (type) {
	case parcore::metadata::Type::INT32_T:
		return reinterpret_cast<int32_t *>(buf->ptr)[row];
	case parcore::metadata::Type::INT64_T:
		return reinterpret_cast<int64_t *>(buf->ptr)[row];
	default:
		throw InvalidInputException("OASIS runtime bloom currently supports only INT32/INT64 join keys");
	}
}

static Value ReadValue(const std::shared_ptr<libstf::Buffer> &buf, size_t row, parcore::metadata::Type type) {
	switch (type) {
	case parcore::metadata::Type::INT32_T:
		return Value::INTEGER(reinterpret_cast<int32_t *>(buf->ptr)[row]);
	case parcore::metadata::Type::INT64_T:
		return Value::BIGINT(reinterpret_cast<int64_t *>(buf->ptr)[row]);
	case parcore::metadata::Type::FLOAT_T:
		return Value::FLOAT(reinterpret_cast<float *>(buf->ptr)[row]);
	case parcore::metadata::Type::DOUBLE_T:
		return Value::DOUBLE(reinterpret_cast<double *>(buf->ptr)[row]);
	case parcore::metadata::Type::BYTE_T:
		return Value::TINYINT(reinterpret_cast<int8_t *>(buf->ptr)[row]);
	case parcore::metadata::Type::BYTE_ARRAY:
		throw NotImplementedException(
		    "OASIS software Bloom mock cannot materialize BYTE_ARRAY/VARCHAR yet. "
		    "This is only needed for the CPU mock path; FPGA path should return compact buffers.");
	default:
		throw InternalException("Unsupported ParCore type in OASIS ReadValue");
	}
}

static size_t BufferElementCount(const std::shared_ptr<libstf::Buffer> &buf, parcore::metadata::Type type) {
	const size_t elem_size = libstf::size_of(parcore::metadata::to_libstf_type(type));
	return buf->size / elem_size;
}

static std::shared_ptr<OasisRuntimeBloom> BuildRuntimeBloomFilter(ClientContext &context,
                                                                  const OasisScanBindData &probe_bind) {
	auto build_file = probe_bind.runtime_bloom_build_filename;
	auto build_key = probe_bind.runtime_bloom_build_key;

	OASIS_BLOOM_LOG("building software runtime bloom");
	OASIS_BLOOM_LOG("build file = %s", build_file.c_str());
	OASIS_BLOOM_LOG("build key  = %s", build_key.c_str());

	auto build_meta = parcore::metadata::from_file(build_file + ".meta");

	if (build_meta.groups.empty()) {
		throw InvalidInputException("OASIS Bloom build metadata contains no row groups: %s", build_file);
	}

	size_t build_col_id = FindColumnId(build_meta.column_names, build_key);
	auto build_type = build_meta.groups[0].chunks[build_col_id].type;

	if (build_type != parcore::metadata::Type::INT32_T && build_type != parcore::metadata::Type::INT64_T) {
		throw InvalidInputException("OASIS runtime bloom build key must be INT32 or INT64 for MVP");
	}

	ObjectCache::GetObjectCache(context).GetOrCreate<OasisContextCacheEntry>("oasis_context");
	auto &ctx = oasis::OasisContext::ctx();

	auto column_chunk_config = ctx.config<parcore::ColumnChunkDecoderConfig>();
	auto page_config = ctx.config<parcore::PageDecoderConfig>();

	auto decoder = std::make_shared<parcore::ColumnChunkDecoder>(
	    ctx.cthread(), ctx.tlb_manager(), ctx.output_buffer_manager(), column_chunk_config, page_config, 0);

	auto maybe_file = arrow::io::ReadableFile::Open(build_file);
	if (!maybe_file.ok()) {
		throw IOException(maybe_file.status().ToString());
	}
	auto file = *maybe_file;

	parcore::FileReader reader(decoder, ctx.memory_pool(), build_meta, file);

	auto bloom = std::make_shared<OasisRuntimeBloom>();

	for (size_t group = 0; group < build_meta.groups.size(); group++) {
		reader.enqueue_column_chunk(group, build_col_id);
		auto buffers = reader.next_column_chunk();

		idx_t group_inserted_before = bloom->InsertedCount();

		for (auto &buf : buffers) {
			auto count = BufferElementCount(buf, build_type);
			for (size_t row = 0; row < count; row++) {
				bloom->AddInt64(ReadIntKey(buf, row, build_type));
			}
		}

		OASIS_BLOOM_LOG("build row-group=%llu inserted=%llu",
		                (unsigned long long)group,
		                (unsigned long long)(bloom->InsertedCount() - group_inserted_before));
	}

	OASIS_BLOOM_LOG("build complete: inserted=%llu bits=%llu hashes=%llu",
	                (unsigned long long)bloom->InsertedCount(),
	                (unsigned long long)bloom->BitCount(),
	                (unsigned long long)bloom->HashCount());

	return bloom;
}

unique_ptr<FunctionData> OasisScanBind(ClientContext &context, TableFunctionBindInput &input,
                                       vector<LogicalType> &return_types, vector<string> &names) {
	auto parquet_file = StringValue::Get(input.inputs[0]);
	auto meta = parcore::metadata::from_file(parquet_file + ".meta");

	if (meta.groups.empty()) {
		throw InvalidInputException("Parquet metadata contains no row groups");
	}

	auto bind_data = make_uniq<OasisScanBindData>();

	for (size_t i = 0; i < meta.groups[0].chunks.size(); i++) {
		auto &chunk = meta.groups[0].chunks[i];
		names.push_back(meta.column_names[i]);
		return_types.push_back(ParcoreTypeToLogical(chunk.type));
		bind_data->parcore_types.push_back(chunk.type);
		bind_data->column_names.push_back(meta.column_names[i]);
	}

	bind_data->metadata = meta;
	bind_data->filename = parquet_file;

	OASIS_SCAN_LOG("bind read_oasis('%s'), columns=%llu, row_groups=%llu",
	               parquet_file.c_str(),
	               (unsigned long long)names.size(),
	               (unsigned long long)meta.groups.size());

	return std::move(bind_data);
}

unique_ptr<GlobalTableFunctionState> OasisScanInitGlobal(ClientContext &context, TableFunctionInitInput &input) {
	auto &bind_data = input.bind_data->Cast<OasisScanBindData>();

	ObjectCache::GetObjectCache(context).GetOrCreate<OasisContextCacheEntry>("oasis_context");
	auto &ctx = oasis::OasisContext::ctx();

	auto gstate = make_uniq<OasisScanGlobalState>();

	auto column_chunk_config = ctx.config<parcore::ColumnChunkDecoderConfig>();
	auto page_config = ctx.config<parcore::PageDecoderConfig>();

	gstate->decoder = std::make_shared<parcore::ColumnChunkDecoder>(
	    ctx.cthread(), ctx.tlb_manager(), ctx.output_buffer_manager(), column_chunk_config, page_config, 0);

	auto maybe_file = arrow::io::ReadableFile::Open(bind_data.filename);
	if (!maybe_file.ok()) {
		throw IOException(maybe_file.status().ToString());
	}
	gstate->file = *maybe_file;

	gstate->reader =
	    std::make_unique<parcore::FileReader>(gstate->decoder, ctx.memory_pool(), bind_data.metadata, gstate->file);

	gstate->total_groups = bind_data.metadata.groups.size();

	for (auto col_id : input.column_ids) {
		if (col_id == COLUMN_IDENTIFIER_ROW_ID) {
			continue;
		}
		gstate->output_column_ids.push_back(col_id);
		gstate->scan_column_ids.push_back(col_id);
	}

	if (bind_data.runtime_bloom_enabled) {
		gstate->runtime_bloom_enabled = true;
		gstate->runtime_bloom_probe_col_id = FindColumnId(bind_data.column_names, bind_data.runtime_bloom_probe_key);

		if (!ContainsColumnId(gstate->scan_column_ids, gstate->runtime_bloom_probe_col_id)) {
			gstate->scan_column_ids.push_back(gstate->runtime_bloom_probe_col_id);
		}

		gstate->runtime_bloom_probe_scan_idx =
		    FindScanIndex(gstate->scan_column_ids, gstate->runtime_bloom_probe_col_id);

		OASIS_SCAN_LOG("runtime bloom enabled for file=%s", bind_data.filename.c_str());
		OASIS_SCAN_LOG("probe key=%s probe_col_id=%llu",
		               bind_data.runtime_bloom_probe_key.c_str(),
		               (unsigned long long)gstate->runtime_bloom_probe_col_id);

		gstate->runtime_bloom = BuildRuntimeBloomFilter(context, bind_data);
	} else {
		OASIS_SCAN_LOG("runtime bloom disabled for file=%s", bind_data.filename.c_str());
	}

	for (auto out_col_id : gstate->output_column_ids) {
		gstate->output_to_scan_idx.push_back(FindScanIndex(gstate->scan_column_ids, out_col_id));
	}

	gstate->current_buffers.assign(gstate->scan_column_ids.size(), {});
	gstate->current_buf_idx = 0;
	gstate->current_buf_offset = 0;

	OASIS_SCAN_LOG("init global file=%s output_cols=%llu scan_cols=%llu",
	               bind_data.filename.c_str(),
	               (unsigned long long)gstate->output_column_ids.size(),
	               (unsigned long long)gstate->scan_column_ids.size());

	return std::move(gstate);
}

unique_ptr<LocalTableFunctionState> OasisScanInitLocal(ExecutionContext &context, TableFunctionInitInput &input,
                                                       GlobalTableFunctionState *global_state_p) {
	return make_uniq<OasisScanLocalState>();
}

static bool LoadNextRowGroupIfNeeded(OasisScanGlobalState &gstate) {
	if (!gstate.current_buffers.empty() && gstate.current_buf_idx < gstate.current_buffers[0].size()) {
		return true;
	}

	if (gstate.next_group >= gstate.total_groups) {
		return false;
	}

	OASIS_SCAN_LOG("loading row-group=%llu", (unsigned long long)gstate.next_group);

	for (size_t col_id : gstate.scan_column_ids) {
		gstate.reader->enqueue_column_chunk(gstate.next_group, col_id);
	}

	for (size_t i = 0; i < gstate.scan_column_ids.size(); i++) {
		gstate.current_buffers[i] = gstate.reader->next_column_chunk();
	}

	gstate.current_buf_idx = 0;
	gstate.current_buf_offset = 0;
	gstate.next_group++;

	return true;
}

static void OasisScanFunctionZeroCopy(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &gstate = data_p.global_state->Cast<OasisScanGlobalState>();
	auto &bind = data_p.bind_data->Cast<OasisScanBindData>();

	if (!LoadNextRowGroupIfNeeded(gstate)) {
		output.SetCardinality(0);
		return;
	}

	size_t const col0_file_idx = gstate.scan_column_ids[0];
	size_t const total_elements =
	    gstate.current_buffers[0][gstate.current_buf_idx]->size /
	    libstf::size_of(parcore::metadata::to_libstf_type(bind.parcore_types[col0_file_idx]));

	size_t const remaining_elements = total_elements - gstate.current_buf_offset;
	size_t const emit = std::min<size_t>(remaining_elements, STANDARD_VECTOR_SIZE);

	for (size_t out_i = 0; out_i < gstate.output_column_ids.size(); out_i++) {
		size_t scan_i = gstate.output_to_scan_idx[out_i];
		size_t file_col_id = gstate.scan_column_ids[scan_i];

		const size_t elem_size =
		    libstf::size_of(parcore::metadata::to_libstf_type(bind.parcore_types[file_col_id]));

		auto &buf = gstate.current_buffers[scan_i][gstate.current_buf_idx];

		if (buf->size / elem_size != total_elements) {
			throw InternalException(
			    "ParCore buffer layout mismatch across columns: column %llu has %llu elements, expected %llu",
			    (unsigned long long)scan_i,
			    (unsigned long long)(buf->size / elem_size),
			    (unsigned long long)total_elements);
		}

		auto &vec = output.data[out_i];
		vec.SetVectorType(VectorType::FLAT_VECTOR);
		FlatVector::SetData(vec, reinterpret_cast<data_ptr_t>(buf->ptr) + gstate.current_buf_offset * elem_size);
		vec.SetAuxiliary(make_buffer<LibstfBufferVectorBuffer>(buf));
	}

	gstate.current_buf_offset += emit;
	if (gstate.current_buf_offset >= total_elements) {
		gstate.current_buf_idx++;
		gstate.current_buf_offset = 0;
	}

	output.SetCardinality(emit);
}

static void OasisScanFunctionBloomMock(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &gstate = data_p.global_state->Cast<OasisScanGlobalState>();
	auto &bind = data_p.bind_data->Cast<OasisScanBindData>();

	idx_t out_count = 0;
	idx_t tested = 0;
	idx_t passed = 0;

	while (out_count < STANDARD_VECTOR_SIZE) {
		if (!LoadNextRowGroupIfNeeded(gstate)) {
			break;
		}

		size_t key_file_col_id = gstate.runtime_bloom_probe_col_id;
		auto key_type = bind.parcore_types[key_file_col_id];

		auto &key_buf = gstate.current_buffers[gstate.runtime_bloom_probe_scan_idx][gstate.current_buf_idx];
		size_t total_elements = BufferElementCount(key_buf, key_type);

		while (gstate.current_buf_offset < total_elements && out_count < STANDARD_VECTOR_SIZE) {
			size_t row = gstate.current_buf_offset++;
			tested++;

			int64_t key = ReadIntKey(key_buf, row, key_type);
			if (!gstate.runtime_bloom->MayContainInt64(key)) {
				continue;
			}

			passed++;

			for (size_t out_i = 0; out_i < gstate.output_column_ids.size(); out_i++) {
				size_t scan_i = gstate.output_to_scan_idx[out_i];
				size_t file_col_id = gstate.scan_column_ids[scan_i];
				auto type = bind.parcore_types[file_col_id];
				auto &buf = gstate.current_buffers[scan_i][gstate.current_buf_idx];

				output.SetValue(out_i, out_count, ReadValue(buf, row, type));
			}

			out_count++;
		}

		if (gstate.current_buf_offset >= total_elements) {
			OASIS_SCAN_LOG("bloom mock buffer done: tested=%llu passed=%llu",
			               (unsigned long long)tested,
			               (unsigned long long)passed);

			gstate.current_buf_idx++;
			gstate.current_buf_offset = 0;
		}
	}

	output.SetCardinality(out_count);
}

void OasisScanFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &gstate = data_p.global_state->Cast<OasisScanGlobalState>();

	if (gstate.runtime_bloom_enabled) {
		OasisScanFunctionBloomMock(context, data_p, output);
	} else {
		OasisScanFunctionZeroCopy(context, data_p, output);
	}
}

} // namespace duckdb