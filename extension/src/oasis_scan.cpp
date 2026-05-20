#include "oasis_scan.hpp"

#include "duckdb/common/exception.hpp"
#include "duckdb/common/string_util.hpp"
#include "duckdb/common/multi_file/multi_file_options.hpp"
#include "oasis/oasis_context.hpp"
#include "parcore/configuration.hpp"
#include "parquet_reader.hpp"
#include "parquet_types.h"
#include "thrift_tools.hpp"

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

static parcore::metadata::Type parquet_type_to_parcore(duckdb_parquet::Type::type t) {
	switch (t) {
	case duckdb_parquet::Type::BOOLEAN:
		return parcore::metadata::Type::BYTE_T;
	case duckdb_parquet::Type::INT32:
        return parcore::metadata::Type::INT32_T;
	case duckdb_parquet::Type::FLOAT:
		return parcore::metadata::Type::FLOAT_T;
	case duckdb_parquet::Type::INT64:
        return parcore::metadata::Type::DOUBLE_T;
	case duckdb_parquet::Type::DOUBLE:
		return parcore::metadata::Type::INT64_T;
	case duckdb_parquet::Type::BYTE_ARRAY:
		return parcore::metadata::Type::BYTE_ARRAY;
	default:
		throw InvalidInputException("Parquet physical type %d not supported by ParCore", (int)t);
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

static parcore::metadata::Compression parquet_codec_to_parcore(duckdb_parquet::CompressionCodec::type c) {
	switch (c) {
	case duckdb_parquet::CompressionCodec::UNCOMPRESSED:
		return parcore::metadata::Compression::RAW;
	case duckdb_parquet::CompressionCodec::SNAPPY:
		return parcore::metadata::Compression::SNAPPY;
	default:
		throw InvalidInputException("Parquet compression codec %d not supported by ParCore", (int)c);
	}
}

static parcore::metadata::Metadata build_parcore_metadata(ClientContext &context, ParquetReader &parquet_reader) {
	auto *file_meta = parquet_reader.GetFileMetadata();
	auto &file_handle = parquet_reader.GetHandle();

    // TODO: Remove the fetching of page meta data after adding a page header parser to the hardware
	auto proto = duckdb_base_std::make_shared<ThriftFileTransport>(file_handle, false);
	auto thrift_proto =
	    make_uniq<duckdb_apache::thrift::protocol::TCompactProtocolT<ThriftFileTransport>>(proto);

	parcore::metadata::Metadata meta;

	for (auto &col : parquet_reader.columns) {
		meta.column_names.push_back(col.name);
	}

	for (auto &rg : file_meta->row_groups) {
		parcore::metadata::RowGroup parcore_rg;

		for (auto &col_chunk : rg.columns) {
			auto &cmd = col_chunk.meta_data;

			parcore::metadata::ColumnChunk parcore_cc;
			parcore_cc.type = parquet_type_to_parcore(cmd.type);
			parcore_cc.num_values = static_cast<uint64_t>(cmd.num_values);
			parcore_cc.compression = parquet_codec_to_parcore(cmd.codec);

			// Walk page headers to collect individual pages
			int64_t start_offset =
			    cmd.__isset.dictionary_page_offset ? cmd.dictionary_page_offset : cmd.data_page_offset;
			int64_t end_offset = start_offset + cmd.total_compressed_size;

			proto->SetLocation(static_cast<idx_t>(start_offset));

			uint64_t hybrid_num_values = 0;

			while (proto->GetLocation() < static_cast<idx_t>(end_offset)) {
				idx_t page_header_start = proto->GetLocation();

				duckdb_parquet::PageHeader page_hdr;
				page_hdr.read(thrift_proto.get());

				idx_t page_data_offset = proto->GetLocation();
				uint64_t page_size = static_cast<uint64_t>(page_hdr.compressed_page_size);

				parcore::metadata::Page parcore_page;
				parcore_page.offset = page_data_offset;
				parcore_page.size = page_size;

				if (page_hdr.type == duckdb_parquet::PageType::DICTIONARY_PAGE) {
					parcore_page.encoding = parcore::metadata::Encoding::PLAIN;
					parcore_page.num_values =
					    static_cast<uint64_t>(page_hdr.dictionary_page_header.num_values);
					parcore_cc.dictionary = parcore_page;
				} else if (page_hdr.type == duckdb_parquet::PageType::DATA_PAGE) {
					auto enc = page_hdr.data_page_header.encoding;
					if (enc == duckdb_parquet::Encoding::RLE_DICTIONARY ||
					    enc == duckdb_parquet::Encoding::PLAIN_DICTIONARY) {
						parcore_page.encoding = parcore::metadata::Encoding::HYBRID;
						parcore_page.num_values =
						    static_cast<uint64_t>(page_hdr.data_page_header.num_values);
						hybrid_num_values += parcore_page.num_values;
					} else {
						parcore_page.encoding = parcore::metadata::Encoding::PLAIN;
						parcore_page.num_values =
						    static_cast<uint64_t>(page_hdr.data_page_header.num_values);
					}
					parcore_cc.data.push_back(parcore_page);
				} else if (page_hdr.type == duckdb_parquet::PageType::DATA_PAGE_V2) {
					auto enc = page_hdr.data_page_header_v2.encoding;
					if (enc == duckdb_parquet::Encoding::RLE_DICTIONARY ||
					    enc == duckdb_parquet::Encoding::PLAIN_DICTIONARY) {
						parcore_page.encoding = parcore::metadata::Encoding::HYBRID;
						parcore_page.num_values =
						    static_cast<uint64_t>(page_hdr.data_page_header_v2.num_values);
						hybrid_num_values += parcore_page.num_values;
					} else {
						parcore_page.encoding = parcore::metadata::Encoding::PLAIN;
						parcore_page.num_values =
						    static_cast<uint64_t>(page_hdr.data_page_header_v2.num_values);
					}
					parcore_cc.data.push_back(parcore_page);
				}

				proto->SetLocation(page_data_offset + page_size);
			}

			parcore_cc.hybrid_num_values = hybrid_num_values;
			parcore_rg.chunks.push_back(std::move(parcore_cc));
		}

		meta.groups.push_back(std::move(parcore_rg));
	}

	return meta;
}

unique_ptr<FunctionData> OasisScanBind(ClientContext &context, TableFunctionBindInput &input,
                                       vector<LogicalType> &return_types, vector<string> &names) {
	auto parquet_file = StringValue::Get(input.inputs[0]);

	ParquetOptions parquet_opts(context);
	ParquetReader parquet_reader(context, OpenFileInfo {parquet_file}, parquet_opts);

	auto bind_data = make_uniq<OasisScanBindData>();

	for (auto &col : parquet_reader.columns) {
		names.push_back(col.name);
		return_types.push_back(col.type);
	}

	auto meta = build_parcore_metadata(context, parquet_reader);
	if (meta.groups.empty()) {
		throw InvalidInputException("Parquet file contains no row groups");
	}
	bind_data->metadata = std::move(meta);
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
		auto t = bind_data.metadata.groups[0].chunks[col_id].type;
		if (!parcore::metadata::is_libstf_type(t)) {
			throw InvalidInputException("Column '%s' has type BYTE_ARRAY which is not supported by ParCore",
			                            bind_data.metadata.column_names[col_id].c_str());
		}
		gstate->column_ids.push_back(col_id);
        gstate->scan_column_ids.push_back(col_id);
	}

	if (bind_data.runtime_bloom_enabled) {
		gstate->runtime_bloom_enabled = true;
		gstate->runtime_bloom_probe_col_id = FindColumnId(bind_data.metadata.column_names, bind_data.runtime_bloom_probe_key);

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

	for (auto out_col_id : gstate->column_ids) {
		gstate->output_to_scan_idx.push_back(FindScanIndex(gstate->scan_column_ids, out_col_id));
	}

	gstate->current_buffers.assign(gstate->scan_column_ids.size(), {});
	gstate->current_buf_idx = 0;
	gstate->current_buf_offset = 0;

	OASIS_SCAN_LOG("init global file=%s output_cols=%llu scan_cols=%llu",
	               bind_data.filename.c_str(),
	               (unsigned long long)gstate->column_ids.size(),
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

	auto elem_size = [&](size_t col_file_idx) -> size_t {
		// next_group has already been incremented, so the in-flight group is next_group - 1.
		auto t = bind.metadata.groups[gstate.next_group - 1].chunks[col_file_idx].type;
		if (!parcore::metadata::is_libstf_type(t)) {
			throw InternalException("Unsupported ParCore type %d in elem_size", (int)t);
		}
		return libstf::size_of(parcore::metadata::to_libstf_type(t));
	};

	size_t const col0_file_idx = gstate.column_ids[0];
	size_t const total_elements =
	    gstate.current_buffers[0][gstate.current_buf_idx]->size / elem_size(col0_file_idx);
	size_t const remaining_elements = total_elements - gstate.current_buf_offset;
	size_t const emit = std::min<size_t>(remaining_elements, STANDARD_VECTOR_SIZE);
	for (size_t i = 0; i < gstate.column_ids.size(); i++) {
		const size_t kElemSize = elem_size(gstate.column_ids[i]);
		size_t scan_i = gstate.output_to_scan_idx[i];
		size_t file_col_id = gstate.scan_column_ids[scan_i];

		auto &buf = gstate.current_buffers[scan_i][gstate.current_buf_idx];

		if (buf->size / kElemSize != total_elements) {
			throw InternalException(
			    "ParCore buffer layout mismatch across columns: column %llu has %llu elements, expected %llu",
			    (unsigned long long)scan_i,
			    (unsigned long long)(buf->size / kElemSize),
			    (unsigned long long)total_elements);
		}

		auto &vec = output.data[i];
		vec.SetVectorType(VectorType::FLAT_VECTOR);
		FlatVector::SetData(vec, reinterpret_cast<data_ptr_t>(buf->ptr) + gstate.current_buf_offset * kElemSize);
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
        auto key_type = bind.metadata.groups[gstate.next_group - 1].chunks[key_file_col_id].type;

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

// Zero-copy multi-column scan. For each row group we enqueue every column,
// then dequeue them in order (ParCore's output queue is a FIFO) and slice each
// column's buffers in lockstep into STANDARD_VECTOR_SIZE-sized vectors. This
// assumes ParCore returns the same buffer layout (same buffer count, same
// elements per buffer at each index) across all columns of a row group; we
// assert this below.
void OasisScanFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &gstate = data_p.global_state->Cast<OasisScanGlobalState>();

	if (gstate.runtime_bloom_enabled) {
		OasisScanFunctionBloomMock(context, data_p, output);
	} else {
		OasisScanFunctionZeroCopy(context, data_p, output);
	}
}

} // namespace duckdb