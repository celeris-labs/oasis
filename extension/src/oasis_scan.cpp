#include "oasis_scan.hpp"

#include "duckdb/common/exception.hpp"
#include "duckdb/common/string_util.hpp"
#include "duckdb/common/multi_file/multi_file_options.hpp"

#include "oasis/oasis_context.hpp"
#include "oasis_bloom_mock.hpp"
#include "oasis_parquet_metadata.hpp"
#include "parcore/configuration.hpp"
#include "parquet_reader.hpp"

#include <cstdio>

namespace duckdb {

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

	auto meta = BuildParcoreMetadata(context, parquet_reader);
	if (meta.groups.empty()) {
		throw InvalidInputException("Parquet file contains no row groups");
	}

	bind_data->metadata = std::move(meta);
	bind_data->filename = parquet_file;

	OASIS_SCAN_LOG("bind read_oasis('%s'), columns=%llu, row_groups=%llu",
	               parquet_file.c_str(),
	               (unsigned long long)names.size(),
	               (unsigned long long)bind_data->metadata.groups.size());

	return std::move(bind_data);
}

unique_ptr<GlobalTableFunctionState> OasisScanInitGlobal(ClientContext &context, TableFunctionInitInput &input) {
	auto &bind_data = input.bind_data->Cast<OasisScanBindData>();

	ObjectCache::GetObjectCache(context).GetOrCreate<OasisContextCacheEntry>("oasis_context");
	auto &ctx = oasis::OasisContext::ctx();

	auto gstate = make_uniq<OasisScanGlobalState>();
	gstate->metadata = &bind_data.metadata;

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
		gstate->runtime_bloom_probe_col_id =
		    FindColumnId(bind_data.metadata.column_names, bind_data.runtime_bloom_probe_key);

		if (!ContainsColumnId(gstate->scan_column_ids, gstate->runtime_bloom_probe_col_id)) {
			gstate->scan_column_ids.push_back(gstate->runtime_bloom_probe_col_id);
		}

		gstate->runtime_bloom_probe_scan_idx =
		    FindScanIndex(gstate->scan_column_ids, gstate->runtime_bloom_probe_col_id);

		OASIS_SCAN_LOG("runtime bloom enabled for file=%s", bind_data.filename.c_str());
		OASIS_SCAN_LOG("probe key=%s probe_col_id=%llu",
		               bind_data.runtime_bloom_probe_key.c_str(),
		               (unsigned long long)gstate->runtime_bloom_probe_col_id);

		gstate->bloom_mock = InitializeOasisBloomMock(context, bind_data);
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

bool OasisLoadNextRowGroupIfNeeded(OasisScanGlobalState &gstate) {
	if (!gstate.current_buffers.empty() && gstate.current_buf_idx < gstate.current_buffers[0].size()) {
		return true;
	}

	if (gstate.next_group >= gstate.total_groups) {
		return false;
	}

	if (!gstate.metadata) {
		throw InternalException("OASIS: missing metadata pointer in global scan state");
	}

	OASIS_SCAN_LOG("loading row-group=%llu", (unsigned long long)gstate.next_group);

	auto &ctx = oasis::OasisContext::ctx();
	auto bf_stream_config = ctx.config<libstf::StreamConfig>();

	for (size_t col_id : gstate.scan_column_ids) {
		auto const &chunk = gstate.metadata->groups[gstate.next_group].chunks[col_id];

		if (!parcore::metadata::is_libstf_type(chunk.type)) {
			throw InternalException("Unsupported ParCore type %d in OasisLoadNextRowGroupIfNeeded",
			                        (int)chunk.type);
		}

		// Stream 0 always passes through the Bloom demux/mux in hardware.
		// Normal read_oasis scans and software Bloom mock probe scans must
		// explicitly select the bypass path.
		//
		// Hardware comment:
		//   select = 0 -> bloom-filtered path
		//   select = 1 -> bypass path
		bf_stream_config->enqueue_stream_config(
		    0,
		    parcore::metadata::to_libstf_type(chunk.type),
		    1);

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

	if (!OasisLoadNextRowGroupIfNeeded(gstate)) {
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
		size_t scan_i = gstate.output_to_scan_idx[i];
		size_t file_col_id = gstate.scan_column_ids[scan_i];

		const size_t kElemSize = elem_size(file_col_id);
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

// Zero-copy multi-column scan. For each row group we enqueue every column,
// then dequeue them in order because ParCore's output queue is a FIFO.
// The Bloom mock path is intentionally implemented outside this file.
void OasisScanFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &gstate = data_p.global_state->Cast<OasisScanGlobalState>();

	if (gstate.runtime_bloom_enabled) {
		OasisScanFunctionBloomMock(context, data_p, output);
	} else {
		OasisScanFunctionZeroCopy(context, data_p, output);
	}
}

} // namespace duckdb