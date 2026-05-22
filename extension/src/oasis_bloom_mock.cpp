#include "oasis_bloom_mock.hpp"

#include "duckdb/common/exception.hpp"
#include "duckdb/common/string_util.hpp"
#include "oasis/oasis_context.hpp"
#include "oasis_context_cache_entry.hpp"
#include "oasis_parquet_metadata.hpp"
#include "oasis_runtime_bloom.hpp"
#include "parcore/configuration.hpp"

#include <cstdio>

namespace duckdb {

#define OASIS_BLOOM_LOG(...)                                                                                           \
	do {                                                                                                                \
		fprintf(stderr, "[OASIS][BLOOM] ");                                                                             \
		fprintf(stderr, __VA_ARGS__);                                                                                   \
		fprintf(stderr, "\n");                                                                                          \
	} while (0)

struct OasisBloomMockState {
	std::shared_ptr<OasisRuntimeBloom> runtime_bloom;
};

template <class NAME_VECTOR>
static size_t FindColumnId(const NAME_VECTOR &names, const string &name) {
	for (size_t i = 0; i < names.size(); i++) {
		if (StringUtil::CIEquals(string(names[i]), name)) {
			return i;
		}
	}
	throw BinderException("OASIS: column '%s' not found", name);
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

	auto build_meta = BuildParcoreMetadataFromParquet(context, build_file);

	if (build_meta.groups.empty()) {
		throw InvalidInputException("OASIS Bloom build metadata contains no row groups: %s", build_file);
	}

	size_t build_col_id = FindColumnId(build_meta.column_names, build_key);
	auto build_type = build_meta.groups[0].chunks[build_col_id].type;

	if (build_type != parcore::metadata::Type::INT32_T &&
	    build_type != parcore::metadata::Type::INT64_T) {
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

std::shared_ptr<OasisBloomMockState> InitializeOasisBloomMock(ClientContext &context,
                                                              const OasisScanBindData &probe_bind) {
	auto state = std::make_shared<OasisBloomMockState>();
	state->runtime_bloom = BuildRuntimeBloomFilter(context, probe_bind);
	return state;
}

void OasisScanFunctionBloomMock(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &gstate = data_p.global_state->Cast<OasisScanGlobalState>();
	auto &bind = data_p.bind_data->Cast<OasisScanBindData>();

	if (!gstate.bloom_mock || !gstate.bloom_mock->runtime_bloom) {
		throw InternalException("OASIS Bloom mock state was not initialized");
	}

	idx_t out_count = 0;
	idx_t tested = 0;
	idx_t passed = 0;

	while (out_count < STANDARD_VECTOR_SIZE) {
		if (!OasisLoadNextRowGroupIfNeeded(gstate)) {
			break;
		}

		size_t key_file_col_id = gstate.runtime_bloom_probe_col_id;
		auto key_type = bind.metadata.groups[gstate.next_group - 1].chunks[key_file_col_id].type;

		auto &key_buf = gstate.current_buffers[gstate.runtime_bloom_probe_scan_idx][gstate.current_buf_idx];
		size_t total_elements = BufferElementCount(key_buf, key_type);

		while (gstate.current_buf_offset < total_elements && out_count < STANDARD_VECTOR_SIZE) {
			size_t row = gstate.current_buf_offset++;
			tested++;

			int64_t key = ReadIntKey(key_buf, row, key_type);
			if (!gstate.bloom_mock->runtime_bloom->MayContainInt64(key)) {
				continue;
			}

			passed++;

			for (size_t out_i = 0; out_i < gstate.column_ids.size(); out_i++) {
				size_t scan_i = gstate.output_to_scan_idx[out_i];
				size_t file_col_id = gstate.scan_column_ids[scan_i];
				auto type = bind.metadata.groups[gstate.next_group - 1].chunks[file_col_id].type;
				auto &buf = gstate.current_buffers[scan_i][gstate.current_buf_idx];

				output.SetValue(out_i, out_count, ReadValue(buf, row, type));
			}

			out_count++;
		}

		if (gstate.current_buf_offset >= total_elements) {
			OASIS_BLOOM_LOG("bloom mock buffer done: tested=%llu passed=%llu",
			                (unsigned long long)tested,
			                (unsigned long long)passed);

			gstate.current_buf_idx++;
			gstate.current_buf_offset = 0;
		}
	}

	output.SetCardinality(out_count);
}

} // namespace duckdb