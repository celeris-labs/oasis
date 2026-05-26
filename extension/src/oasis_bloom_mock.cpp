#include "oasis_bloom_mock.hpp"

#include "duckdb/common/exception.hpp"
#include "duckdb/common/multi_file/multi_file_options.hpp"
#include "duckdb/common/string_util.hpp"

#include "libstf_buffer_vector_buffer.hpp"
#include "oasis/oasis_context.hpp"
#include "oasis_context_cache_entry.hpp"
#include "oasis_parquet_metadata.hpp"
#include "parcore/configuration.hpp"
#include "parcore/file_reader.hpp"
#include "parquet_reader.hpp"

#include <cstdio>
#include <cstdint>
#include <memory>
#include <vector>

namespace duckdb {

#define OASIS_BLOOM_LOG(...)                                                                                           \
	do {                                                                                                                \
		fprintf(stderr, "[OASIS][BLOOM] ");                                                                             \
		fprintf(stderr, __VA_ARGS__);                                                                                   \
		fprintf(stderr, "\n");                                                                                          \
	} while (0)

#define OASIS_SCAN_LOG(...)                                                                                            \
	do {                                                                                                               \
		fprintf(stderr, "[OASIS][SCAN] ");                                                                             \
		fprintf(stderr, __VA_ARGS__);                                                                                  \
		fprintf(stderr, "\n");                                                                                         \
	} while (0)

template <class NAME_VECTOR>
static size_t FindColumnId(const NAME_VECTOR &names, const string &name) {
	for (size_t i = 0; i < names.size(); i++) {
		if (StringUtil::CIEquals(string(names[i]), name)) {
			return i;
		}
	}
	throw BinderException("OASIS: column '%s' not found", name);
}

static uint64_t SplitMix64(uint64_t x) {
	x += 0x9e3779b97f4a7c15ULL;
	x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ULL;
	x = (x ^ (x >> 27)) * 0x94d049bb133111ebULL;
	return x ^ (x >> 31);
}

class OasisRuntimeBloom {
public:
	OasisRuntimeBloom(idx_t bit_count = 1 << 20, idx_t hash_count = 3)
	    : bits((bit_count + 63) / 64, 0), bit_count(bit_count), hash_count(hash_count), inserted_count(0) {
	}

	void AddInt64(int64_t value) {
		uint64_t x = static_cast<uint64_t>(value);
		for (idx_t i = 0; i < hash_count; i++) {
			auto h = SplitMix64(x + i * 0x9e3779b97f4a7c15ULL);
			auto bit = h % bit_count;
			bits[bit / 64] |= (1ULL << (bit % 64));
		}
		inserted_count++;
	}

	bool MayContainInt64(int64_t value) const {
		uint64_t x = static_cast<uint64_t>(value);
		for (idx_t i = 0; i < hash_count; i++) {
			auto h = SplitMix64(x + i * 0x9e3779b97f4a7c15ULL);
			auto bit = h % bit_count;
			if ((bits[bit / 64] & (1ULL << (bit % 64))) == 0) {
				return false;
			}
		}
		return true;
	}

	idx_t InsertedCount() const {
		return inserted_count;
	}

	idx_t BitCount() const {
		return bit_count;
	}

	idx_t HashCount() const {
		return hash_count;
	}

private:
	std::vector<uint64_t> bits;
	idx_t bit_count;
	idx_t hash_count;
	idx_t inserted_count;
};

struct OasisBloomMockState {
	std::shared_ptr<OasisRuntimeBloom> bloom;
};

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

static parcore::metadata::Metadata BuildMetadataForFile(ClientContext &context, const string &filename) {
	ParquetOptions parquet_opts(context);
	ParquetReader parquet_reader(context, OpenFileInfo {filename}, parquet_opts);

	auto meta = BuildParcoreMetadata(context, parquet_reader);
	if (meta.groups.empty()) {
		throw InvalidInputException("OASIS Bloom build metadata contains no row groups: %s", filename);
	}

	return meta;
}

static std::shared_ptr<OasisRuntimeBloom> BuildRuntimeBloomFilter(ClientContext &context,
                                                                  const OasisScanBindData &probe_bind) {
	auto build_file = probe_bind.runtime_bloom_build_filename;
	auto build_key = probe_bind.runtime_bloom_build_key;

	OASIS_BLOOM_LOG("building software runtime bloom");
	OASIS_BLOOM_LOG("build file = %s", build_file.c_str());
	OASIS_BLOOM_LOG("build key  = %s", build_key.c_str());

	auto build_meta = BuildMetadataForFile(context, build_file);

	size_t build_col_id = FindColumnId(build_meta.column_names, build_key);
	auto build_type = build_meta.groups[0].chunks[build_col_id].type;

	if (build_type != parcore::metadata::Type::INT32_T && build_type != parcore::metadata::Type::INT64_T) {
		throw InvalidInputException("OASIS runtime bloom build key must be INT32 or INT64 for MVP");
	}

	ObjectCache::GetObjectCache(context).GetOrCreate<OasisContextCacheEntry>("oasis_context");
	auto &ctx = oasis::OasisContext::ctx();

	auto column_chunk_config = ctx.config<parcore::ColumnChunkDecoderConfig>();
	auto page_config = ctx.config<parcore::PageDecoderConfig>();
	auto bf_stream_config = ctx.config<libstf::StreamConfig>();

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
		auto const &chunk = build_meta.groups[group].chunks[build_col_id];

		if (!parcore::metadata::is_libstf_type(chunk.type)) {
			throw InternalException("Unsupported ParCore type %d in BuildRuntimeBloomFilter", (int)chunk.type);
		}

		// IMPORTANT:
		// The software Bloom build scan also uses ParCore stream 0.
		// Stream 0 passes through the hardware Bloom demux/mux, so this
		// CPU-side build scan must also select the bypass path.
		bf_stream_config->enqueue_stream_config(
		    0,
		    parcore::metadata::to_libstf_type(chunk.type),
		    1);

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
	state->bloom = BuildRuntimeBloomFilter(context, probe_bind);
	return state;
}

void OasisScanFunctionBloomMock(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &gstate = data_p.global_state->Cast<OasisScanGlobalState>();
	auto &bind = data_p.bind_data->Cast<OasisScanBindData>();

	if (!gstate.bloom_mock || !gstate.bloom_mock->bloom) {
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
			if (!gstate.bloom_mock->bloom->MayContainInt64(key)) {
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
			OASIS_SCAN_LOG("bloom mock buffer done: tested=%llu passed=%llu",
			               (unsigned long long)tested,
			               (unsigned long long)passed);

			gstate.current_buf_idx++;
			gstate.current_buf_offset = 0;
		}
	}

	output.SetCardinality(out_count);
}

} // namespace duckdb