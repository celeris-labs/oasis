#include "oasis_scan.hpp"

#include "column_reader.hpp"
#include "duckdb/common/exception.hpp"
#include "duckdb/common/multi_file/multi_file_options.hpp"
#include "duckdb/common/string_util.hpp"
#include "duckdb/logging/logger.hpp"
#include "oasis/oasis_context.hpp"
#include "oasis/operator.hpp"
#include "oasis/query_splinter.hpp"
#include "oasis_hardware_bloom.hpp"
#include "parcore/configuration.hpp"
#include "parquet_reader.hpp"
#include "parquet_types.h"
#include "rdma_file_system.hpp"
#include "reader/struct_column_reader.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>

// oasis_scan.hpp transitively pulls in Coyote, which includes <syslog.h>. That
// header defines LOG_INFO / LOG_DEBUG as numeric macros that collide with the
// duckdb::LogLevel enum values, turning e.g. `LogLevel::LOG_DEBUG` into
// `LogLevel::7`. #undef them so the LogLevel:: use sites below compile.
#undef LOG_INFO
#undef LOG_DEBUG

namespace duckdb {

#define OASIS_SCAN_LOG(...)                                                                                       \
        do {                                                                                                      \
                fprintf(stderr, "[OASIS][SCAN] ");                                                                \
                fprintf(stderr, __VA_ARGS__);                                                                     \
                fprintf(stderr, "\n");                                                                            \
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
                return parcore::metadata::Type::INT64_T;
        case duckdb_parquet::Type::DOUBLE:
                return parcore::metadata::Type::DOUBLE_T;
        case duckdb_parquet::Type::BYTE_ARRAY:
                return parcore::metadata::Type::BYTE_ARRAY;
        default:
                throw InvalidInputException("Parquet physical type %d not supported by ParCore", (int)t);
        }
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
        (void)context;

        auto *file_meta = parquet_reader.GetFileMetadata();

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
                        parcore_cc.offset = static_cast<uint64_t>(
                            cmd.__isset.dictionary_page_offset ? cmd.dictionary_page_offset : cmd.data_page_offset);
                        parcore_cc.total_compressed_size = static_cast<uint64_t>(cmd.total_compressed_size);

                        parcore_rg.chunks.push_back(std::move(parcore_cc));
                }

                meta.groups.push_back(std::move(parcore_rg));
        }

        return meta;
}

static uint64_t ColumnChunkFileOffset(const parcore::metadata::ColumnChunk &cc) {
        return cc.offset;
}

static uint64_t ColumnChunkCompressedSize(const parcore::metadata::ColumnChunk &cc) {
        return cc.total_compressed_size;
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

static bool UseHardwareBloomByDefault() {
        auto env = std::getenv("OASIS_USE_SOFTWARE_BLOOM");
        if (!env) {
                return true;
        }

        string value(env);
        return !(value == "1" || value == "true" || value == "TRUE" || value == "yes" || value == "YES");
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
                       (unsigned long long)bind_data->metadata.groups.size());

        return std::move(bind_data);
}

static oasis::OasisContext &GetOasisContext(ClientContext &context) {
        return ObjectCache::GetObjectCache(context).GetOrCreate<OasisContextCacheEntry>("oasis_context")->ctx();
}

// Applies the oasis_scheduler_num_streams / oasis_scheduler_queue_depth SET parameters to the live
// scheduler. A value of 0 (the default) leaves the corresponding knob at its current value, so the
// hardware defaults chosen at context init stay in effect until the user overrides them.
static void ApplySchedulerSettings(ClientContext &context, oasis::Scheduler &scheduler) {
        Value value;
        if (context.TryGetCurrentSetting("oasis_scheduler_num_streams", value) && !value.IsNull()) {
                auto streams = value.GetValue<uint64_t>();
                if (streams > 0) {
                        scheduler.set_active_streams(static_cast<libstf::stream_t>(streams));
                }
        }
        if (context.TryGetCurrentSetting("oasis_scheduler_queue_depth", value) && !value.IsNull()) {
                auto depth = value.GetValue<uint64_t>();
                if (depth > 0) {
                        scheduler.set_pipeline_depth(static_cast<size_t>(depth));
                }
        }
}

unique_ptr<GlobalTableFunctionState> OasisScanInitGlobal(ClientContext &context, TableFunctionInitInput &input) {
        auto &bind_data = input.bind_data->Cast<OasisScanBindData>();
        auto &ctx = GetOasisContext(context);
        auto gstate = make_uniq<OasisScanGlobalState>();

        ApplySchedulerSettings(context, ctx.scheduler());

        gstate->ctx = &ctx;
        gstate->filename = bind_data.filename;
        gstate->total_groups = bind_data.metadata.groups.size();

        for (auto col_id : input.column_ids) {
                if (col_id == COLUMN_IDENTIFIER_EMPTY) {
                        gstate->emit_cardinality_only = true;
                        continue;
                }

                auto t = bind_data.metadata.groups[0].chunks[col_id].type;
                gstate->column_ids.push_back(col_id);
                if (parcore::metadata::is_libstf_type(t)) {
                        // Hardware path: Fixed-width type the ParCore decoder handles.
                        gstate->is_cpu_column.push_back(false);
                        gstate->elem_sizes.push_back(libstf::size_of(parcore::metadata::to_libstf_type(t)));
                } else {
                        // CPU path: Variable-length type (BYTE_ARRAY/string) decoded by DuckDB's ColumnReader.
                        gstate->is_cpu_column.push_back(true);
                        gstate->elem_sizes.push_back(0);
                        gstate->has_cpu_columns = true;
                }
        }

        if (bind_data.runtime_bloom_enabled) {
                gstate->runtime_bloom_enabled = true;
                gstate->runtime_bloom_probe_col_id =
                    FindColumnId(bind_data.metadata.column_names, bind_data.runtime_bloom_probe_key);

                OASIS_SCAN_LOG("runtime bloom enabled for file=%s", bind_data.filename.c_str());
                OASIS_SCAN_LOG("probe key=%s probe_col_id=%llu",
                               bind_data.runtime_bloom_probe_key.c_str(),
                               (unsigned long long)gstate->runtime_bloom_probe_col_id);

                if (UseHardwareBloomByDefault()) {
                        OASIS_SCAN_LOG("using hardware bloom path");
                        gstate->hardware_bloom_enabled = true;
                        InitializeOasisHardwareBloom(context, bind_data);
                } else {
                        throw NotImplementedException("OASIS software Bloom mock was removed; unset OASIS_USE_SOFTWARE_BLOOM");
                }
        } else {
                OASIS_SCAN_LOG("runtime bloom disabled for file=%s", bind_data.filename.c_str());
        }

        return std::move(gstate);
}

unique_ptr<LocalTableFunctionState> OasisScanInitLocal(ExecutionContext &context, TableFunctionInitInput &input,
                                                       GlobalTableFunctionState *global_state_p) {
        auto &gstate = global_state_p->Cast<OasisScanGlobalState>();
        auto lstate = make_uniq<OasisScanLocalState>();

        // Each worker owns its own file handle: DuckDB FileHandles are not safe to share across threads,
        // and the local source path reads from it on this worker thread.
        auto &fs = FileSystem::GetFileSystem(context.client);
        lstate->file_handle = fs.OpenFile(gstate.filename, FileOpenFlags::FILE_FLAGS_READ);

        if (gstate.has_cpu_columns) {
                ParquetOptions parquet_opts(context.client);
                lstate->parquet_reader = make_uniq<ParquetReader>(context.client, OpenFileInfo {gstate.filename}, parquet_opts);
                lstate->scan_state = make_uniq<ParquetReaderScanState>();

                vector<idx_t> groups_to_read;
                groups_to_read.reserve(gstate.total_groups);
                for (idx_t g = 0; g < gstate.total_groups; g++) {
                        groups_to_read.push_back(g);
                }
                lstate->parquet_reader->InitializeScan(context.client, *lstate->scan_state, std::move(groups_to_read));
                lstate->root_reader = std::move(lstate->scan_state->root_reader);
        }

        return std::move(lstate);
}

// Builds the source operator for one column chunk. The transport (remote RDMA vs. local host DMA) is
// chosen once, here, and hidden behind the SourceOperator interface; the scheduler never sees it.
static std::unique_ptr<oasis::SourceOperator> MakeSource(oasis::OasisContext &ctx, OasisScanLocalState &lstate,
                                                         const parcore::metadata::ColumnChunk &cc) {
        const uint64_t offset = ColumnChunkFileOffset(cc);
        const uint64_t size = ColumnChunkCompressedSize(cc);

        if (auto *rdma = dynamic_cast<RDMAFileHandle *>(lstate.file_handle.get())) {
                return std::make_unique<oasis::RDMASourceOperator>(rdma->remote_offset + offset, size);
        }

        void *ptr;
        auto status = ctx.memory_pool()->allocate(size, &ptr);
        if (!status.ok()) {
                throw IOException("Could not allocate input buffer: " + status.message());
        }
        auto buffer = libstf::make_buffer(ctx.memory_pool(), ptr, size, size);
        lstate.file_handle->Read(buffer->ptr, size, offset);
        return std::make_unique<oasis::LocalSourceOperator>(std::move(buffer));
}

// Submits one splinter per projected hardware column of `group` to the shared scheduler and collects
// all decoded output batches for each column. The OBM may split a decoded column chunk into multiple
// output buffers; this function merges those buffers into one contiguous libstf::Buffer so the
// downstream DuckDB vector handoff can keep slicing one buffer per projected column.
static void DecodeGroup(Logger &logger, oasis::OasisContext &ctx, OasisScanGlobalState &gstate,
                        OasisScanLocalState &lstate, const OasisScanBindData &bind, size_t group) {
        // Submit one query splinter per hardware column. CPU columns are skipped here and decoded inline.
        std::vector<oasis::SplinterResultHandle> results;
        results.reserve(gstate.column_ids.size());
        for (size_t i = 0; i < gstate.column_ids.size(); i++) {
                if (gstate.is_cpu_column[i]) {
                        results.emplace_back();
                        continue;
                }

                const auto &cc = bind.metadata.groups[group].chunks[gstate.column_ids[i]];
                auto type = parcore::metadata::to_libstf_type(cc.type);

                oasis::QuerySplinter splinter;

                // Stream 0 is physically routed through the Bloomfilter/bypass block. Normal scans
                // must use select=1 there. On streams >0 StreamConfigOperator is a no-op.
                splinter.operators.push_back(std::make_unique<oasis::StreamConfigOperator>(type, 1));
                splinter.operators.push_back(
                    std::make_unique<oasis::DecodeColumnChunkOperator>(cc.compression, cc.num_values, type));
                splinter.operators.push_back(MakeSource(ctx, lstate, cc));
                splinter.operators.push_back(std::make_unique<oasis::HostBufferSinkOperator>());
                results.push_back(ctx.scheduler().submit(std::move(splinter)));
        }

        // InitializeRead(...) does the page-header parsing / I/O positioning for the row group.
        if (gstate.has_cpu_columns) {
                lstate.root_reader->InitializeRead(group, lstate.parquet_reader->GetFileMetadata()->row_groups[group].columns,
                                                   *lstate.scan_state->thrift_file_proto);
        }

        // Collect each hardware column in submit order (restores per-column order even though splinters
        // may finish on different streams out of order). A single decoded column chunk may produce
        // multiple OBM buffers, so collect until the expected decoded byte count has arrived.
        lstate.current_buffers.assign(gstate.column_ids.size(), nullptr);
        for (size_t i = 0; i < results.size(); i++) {
                if (gstate.is_cpu_column[i]) {
                        continue;
                }

                size_t const col_id = gstate.column_ids[i];
                const auto &cc = bind.metadata.groups[group].chunks[col_id];
                const size_t expected_bytes = static_cast<size_t>(cc.num_values) * gstate.elem_sizes[i];

                std::vector<std::shared_ptr<libstf::Buffer>> batches;
                size_t total_bytes = 0;

                while (auto batch = results[i].get_next_batch()) {
                        total_bytes += (*batch)->size;
                        batches.push_back(std::move(*batch));

                        if (total_bytes >= expected_bytes) {
                                break;
                        }
                }

                if (batches.empty()) {
                        throw InternalException("Column %llu produced no output for row group %llu",
                                                (unsigned long long)i, (unsigned long long)group);
                }

                if (total_bytes != expected_bytes) {
                        throw InternalException(
                            "Hardware decoder for row group %llu, column %llu ('%s') produced %llu bytes, expected %llu",
                            (unsigned long long)group, (unsigned long long)col_id,
                            bind.metadata.column_names[col_id].c_str(),
                            (unsigned long long)total_bytes, (unsigned long long)expected_bytes);
                }

                void *merged_ptr = nullptr;
                auto status = ctx.memory_pool()->allocate(expected_bytes, &merged_ptr);
                if (!status.ok()) {
                        throw IOException("Could not allocate merged ParCore output buffer: " + status.message());
                }

                auto merged = libstf::make_buffer(ctx.memory_pool(), merged_ptr, expected_bytes, expected_bytes);

                size_t offset = 0;
                for (auto &buf : batches) {
                        memcpy(reinterpret_cast<uint8_t *>(merged->ptr) + offset, buf->ptr, buf->size);
                        offset += buf->size;
                }

                logger.WriteLog(DefaultLogType::NAME, LogLevel::LOG_DEBUG,
                    StringUtil::Format("Hardware decoder for row group %llu, column %llu ('%s') returned %llu batches, merged %llu bytes",
                                       (unsigned long long)group, (unsigned long long)col_id,
                                       bind.metadata.column_names[col_id].c_str(),
                                       (unsigned long long)batches.size(), (unsigned long long)total_bytes));

                lstate.current_buffers[i] = std::move(merged);
        }
}

// Claims the next non-empty row group off the shared atomic cursor, returning its index (or
// total_groups once all groups are consumed).
static size_t ClaimNextNonEmptyGroup(OasisScanGlobalState &gstate, const OasisScanBindData &bind) {
        while (true) {
                size_t group = gstate.next_group.fetch_add(1);
                if (group >= gstate.total_groups) {
                        return gstate.total_groups;
                }
                // Every column chunk in a row group shares its row count; take it from the first chunk.
                if (bind.metadata.groups[group].chunks[0].num_values != 0) {
                        return group;
                }
        }
}

// Loads the next row group's buffers into lstate.current_buffers, claiming groups off the shared
// cursor. Returns false once all groups are consumed. Each worker owns its group's buffers privately.
static bool LoadNextGroup(Logger &logger, oasis::OasisContext &ctx, OasisScanGlobalState &gstate,
                          OasisScanLocalState &lstate, const OasisScanBindData &bind) {
        size_t group = ClaimNextNonEmptyGroup(gstate, bind);
        if (group >= gstate.total_groups) {
                return false;
        }
        DecodeGroup(logger, ctx, gstate, lstate, bind, group);
        lstate.current_buf_offset = 0;
        lstate.current_group_num_rows = bind.metadata.groups[group].chunks[0].num_values;
        return true;
}

// Emits cardinality only, for queries that project no columns (COUNT(*), EXISTS, etc.). DuckDB
// derives the aggregate from the row counts we report, so there is nothing to decode: each worker
// claims row groups off the shared cursor and emits their row counts (from the Parquet metadata)
// in STANDARD_VECTOR_SIZE slices. The hardware is never touched.
static void EmitCardinalityOnly(OasisScanGlobalState &gstate, OasisScanLocalState &lstate,
                                const OasisScanBindData &bind, DataChunk &output) {
        // Claim the next group with rows off the shared cursor (ClaimNextNonEmptyGroup skips empty groups
        // for us) or signal EOF once the groups run out.
        if (lstate.empty_proj_remaining == 0) {
                size_t group = ClaimNextNonEmptyGroup(gstate, bind);
                if (group >= gstate.total_groups) {
                        output.SetCardinality(0);
                        return;
                }
                // Every column chunk in a row group shares its row count; take it from the first chunk.
                lstate.empty_proj_remaining = bind.metadata.groups[group].chunks[0].num_values;
        }

        size_t const emit = std::min<size_t>(lstate.empty_proj_remaining, STANDARD_VECTOR_SIZE);
        lstate.empty_proj_remaining -= emit;
        output.SetCardinality(emit);
}

// Multi-column scan. Each worker atomically claims a row group (LoadNextGroup), decoding every
// projected hardware column into a contiguous merged buffer, then slicing those buffers in lockstep
// into STANDARD_VECTOR_SIZE-sized vectors. All columns of a row group share the same element count,
// so the slices stay aligned.
void OasisScanFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
        auto &gstate = data_p.global_state->Cast<OasisScanGlobalState>();
        auto &lstate = data_p.local_state->Cast<OasisScanLocalState>();
        auto &bind = data_p.bind_data->Cast<OasisScanBindData>();
        auto &ctx = *gstate.ctx;

        if (gstate.runtime_bloom_enabled) {
                if (!gstate.hardware_bloom_enabled) {
                        throw NotImplementedException("OASIS software Bloom mock was removed");
                }
                OasisScanFunctionBloomHardware(context, data_p, output);
                return;
        }

        if (gstate.emit_cardinality_only) {
                EmitCardinalityOnly(gstate, lstate, bind, output);
                return;
        }

        // When the current group is fully emitted, decode/claim the next one.
        if (lstate.current_group_num_rows == 0) {
                if (!LoadNextGroup(Logger::Get(context), ctx, gstate, lstate, bind)) {
                        output.SetCardinality(0);
                        return;
                }
        }

        size_t const total_elements = lstate.current_group_num_rows;
        size_t const remaining_elements = total_elements - lstate.current_buf_offset;
        size_t const emit = std::min<size_t>(remaining_elements, STANDARD_VECTOR_SIZE);

        // Scratch define/repeat buffers shared by this worker's CPU column readers for this call.
        uint8_t *define_ptr = nullptr;
        uint8_t *repeat_ptr = nullptr;
        if (gstate.has_cpu_columns) {
                lstate.scan_state->define_buf.zero();
                lstate.scan_state->repeat_buf.zero();
                define_ptr = reinterpret_cast<uint8_t *>(lstate.scan_state->define_buf.ptr);
                repeat_ptr = reinterpret_cast<uint8_t *>(lstate.scan_state->repeat_buf.ptr);
        }

        for (size_t i = 0; i < gstate.column_ids.size(); i++) {
                if (gstate.is_cpu_column[i]) {
                        auto &vec = output.data[i];
                        auto &child_reader = lstate.root_reader->Cast<StructColumnReader>().GetChildReader(gstate.column_ids[i]);
                        auto rows_read = child_reader.Read(emit, define_ptr, repeat_ptr, vec);
                        if (rows_read != emit) {
                                throw InternalException(
                                    "ParCore CPU column %llu read %llu values, expected %llu (HW/CPU cursor desync)",
                                    (unsigned long long)i, (unsigned long long)rows_read, (unsigned long long)emit);
                        }
                        continue;
                }

                const size_t kElemSize = gstate.elem_sizes[i];

                auto &buf = lstate.current_buffers[i];
                if (!buf) {
                        throw InternalException("ParCore buffer for column %llu is null", (unsigned long long)i);
                }
                if (buf->size / kElemSize != total_elements) {
                        throw InternalException(
                            "ParCore buffer layout mismatch across columns: column %llu has %llu elements, expected %llu",
                            (unsigned long long)i, (unsigned long long)(buf->size / kElemSize), (unsigned long long)total_elements);
                }

                // The actual zero-copy handoff. Two things happen here:
                //
                //  1. FlatVector::SetData points the vector's raw data pointer directly
                //     into the merged libstf buffer (+ byte offset for the
                //     STANDARD_VECTOR_SIZE slice we're emitting this call).
                //
                //  2. SetAuxiliary hands the buffer's shared_ptr to DuckDB's Vector
                //     lifetime slot (wrapped in LibstfBufferVectorBuffer, because
                //     DuckDB's slot is typed to shared_ptr<VectorBuffer>, not our
                //     shared_ptr<libstf::Buffer>). DuckDB copies this shared_ptr whenever
                //     it copies the vector, so the underlying memory stays alive as long
                //     as any downstream consumer references it.
                //
                // Two refcount holders protect the memory while it's in flight:
                //   - lstate.current_buffers holds the one merged buffer per column and keeps it
                //     alive across scan calls while we slice it into multiple
                //     STANDARD_VECTOR_SIZE emissions (auxiliary gets cleared on each
                //     output.Reset()).
                //   - vector auxiliary (set here) keeps it alive for any downstream
                //     consumer that holds onto the vector past our next scan call.
                auto &vec = output.data[i];
                vec.SetVectorType(VectorType::FLAT_VECTOR);
                FlatVector::SetData(vec, reinterpret_cast<data_ptr_t>(buf->ptr) + lstate.current_buf_offset * kElemSize);
                vec.SetAuxiliary(make_buffer<LibstfBufferVectorBuffer>(buf));
        }

        // Advance the cursor. If we have emitted this group's last elements, release the buffers so the
        // next scan call's `if` branch loads the next row group. Dropping our refs here lets each buffer
        // free as soon as downstream consumers are done with it.
        lstate.current_buf_offset += emit;
        if (lstate.current_buf_offset >= total_elements) {
                lstate.current_buffers.assign(gstate.column_ids.size(), nullptr);
                lstate.current_buf_offset = 0;
                lstate.current_group_num_rows = 0;
        }

        output.SetCardinality(emit);
}

// Advertises the zero-width COLUMN_IDENTIFIER_EMPTY virtual column. For queries that consume no
// column values (e.g., COUNT(*), EXISTS), DuckDB's optimizer projects this sentinel instead of
// anchoring the scan on a real column (LogicalGet::GetAnyColumn).
virtual_column_map_t OasisScanGetVirtualColumns(ClientContext &, optional_ptr<FunctionData>) {
        virtual_column_map_t result;
        result.insert(make_pair(COLUMN_IDENTIFIER_EMPTY, TableColumn("", LogicalType::BOOLEAN)));
        return result;
}

} // namespace duckdb
