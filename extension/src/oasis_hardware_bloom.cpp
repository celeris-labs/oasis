#include "oasis_hardware_bloom.hpp"

#include "duckdb/common/exception.hpp"
#include "duckdb/common/multi_file/multi_file_options.hpp"
#include "duckdb/common/string_util.hpp"
#include "duckdb/common/types/vector.hpp"

#include "oasis/oasis_context.hpp"
#include "oasis_context_cache_entry.hpp"
#include "oasis_parquet_metadata.hpp"

#include "libstf/common.hpp"
#include "libstf/configuration.hpp"
#include "parcore/configuration.hpp"
#include "parcore/file_reader.hpp"
#include "parquet_reader.hpp"

#include <arrow/io/file.h>

#include <algorithm>
#include <bitset>
#include <cstdio>
#include <cstdint>
#include <limits>
#include <memory>
#include <unordered_set>

namespace duckdb {

#define OASIS_HW_BLOOM_LOG(...)                                                                                   \
        do {                                                                                                      \
                fprintf(stderr, "[OASIS][HW_BLOOM] ");                                                            \
                fprintf(stderr, __VA_ARGS__);                                                                     \
                fprintf(stderr, "\n");                                                                            \
        } while (0)

static constexpr uint64_t OASIS_HW_BLOOM_AXI_BYTES_PER_BEAT = 64;

class OasisBFConfig : public libstf::Config {
public:
        static constexpr uint32_t ID = 6;

        OasisBFConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset, uint32_t num_regs)
            : libstf::Config(std::move(cthread), addr_offset, num_regs), hash_table_size_(read_register(1).value()) {
        }

        void enqueue_materialization_config(libstf::stream_mask_t active_outputs, bool device_mat) {
                auto mat_config = std::bitset<5>(0);

                if (!active_outputs.test(0)) {
                        mat_config.set(0);
                }
                if (!active_outputs.test(1)) {
                        mat_config.set(1);
                }
                if (!active_outputs.test(2)) {
                        mat_config.set(2);
                }

                if (device_mat) {
                        if (active_outputs.test(1)) {
                                mat_config.set(3);
                        }
                        if (active_outputs.test(2)) {
                                mat_config.set(4);
                        }
                }

                OASIS_HW_BLOOM_LOG("write BFConfig materialization config=%llu active0=%d active1=%d active2=%d device_mat=%d",
                                   (unsigned long long)mat_config.to_ulong(),
                                   active_outputs.test(0) ? 1 : 0,
                                   active_outputs.test(1) ? 1 : 0,
                                   active_outputs.test(2) ? 1 : 0,
                                   device_mat ? 1 : 0);

                write_register(libstf::ConfigRegister(0, mat_config.to_ulong()));
        }

        void configure_last_injector(bool enable, uint32_t first_last_beat, uint32_t second_last_beat) {
                OASIS_HW_BLOOM_LOG("write BFConfig TLAST injector enable=%d first_last_beat=%llu second_last_beat=%llu",
                                   enable ? 1 : 0,
                                   (unsigned long long)first_last_beat,
                                   (unsigned long long)second_last_beat);

                write_register(libstf::ConfigRegister(2, first_last_beat));
                write_register(libstf::ConfigRegister(3, second_last_beat));
                write_register(libstf::ConfigRegister(4, enable ? 1 : 0));
        }

        uint64_t fetch_build_cycles() {
                return read_register(2).value();
        }

        uint64_t fetch_build_idle_cycles() {
                return read_register(3).value();
        }

        uint64_t fetch_probe_cycles() {
                return read_register(4).value();
        }

        uint64_t fetch_probe_idle_cycles() {
                return read_register(5).value();
        }

        size_t hash_table_size() const {
                return hash_table_size_;
        }

private:
        size_t hash_table_size_;
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

static parcore::metadata::Metadata BuildMetadataForFile(ClientContext &context, const string &filename) {
        ParquetOptions parquet_opts(context);
        ParquetReader parquet_reader(context, OpenFileInfo {filename}, parquet_opts);

        auto meta = BuildParcoreMetadata(context, parquet_reader);
        if (meta.groups.empty()) {
                throw InvalidInputException("OASIS hardware Bloom metadata contains no row groups: %s", filename);
        }

        return meta;
}

static uint32_t CheckedBeatIndex(uint64_t beats, const char *name) {
        if (beats == 0) {
                throw InvalidInputException("OASIS hardware Bloom: %s has zero decoded AXI beats", name);
        }

        uint64_t idx = beats - 1;
        if (idx > std::numeric_limits<uint32_t>::max()) {
                throw InvalidInputException("OASIS hardware Bloom: %s beat index exceeds uint32 range", name);
        }

        return static_cast<uint32_t>(idx);
}

static uint64_t DecodedAxiBeatsForColumnChunk(const parcore::metadata::ColumnChunk &chunk, const char *name) {
        if (!parcore::metadata::is_libstf_type(chunk.type)) {
                throw InvalidInputException("OASIS hardware Bloom: %s has non-libstf-compatible type", name);
        }

        auto libstf_type = parcore::metadata::to_libstf_type(chunk.type);
        uint64_t elem_size = libstf::size_of(libstf_type);

        if (elem_size == 0) {
                throw InternalException("OASIS hardware Bloom: %s has zero element size", name);
        }

        if (chunk.num_values == 0) {
                throw InvalidInputException("OASIS hardware Bloom: %s contains zero values", name);
        }

        if (chunk.num_values > std::numeric_limits<uint64_t>::max() / elem_size) {
                throw InvalidInputException("OASIS hardware Bloom: %s byte count overflows uint64", name);
        }

        uint64_t bytes = chunk.num_values * elem_size;
        uint64_t beats = (bytes + OASIS_HW_BLOOM_AXI_BYTES_PER_BEAT - 1) / OASIS_HW_BLOOM_AXI_BYTES_PER_BEAT;

        OASIS_HW_BLOOM_LOG("%s: num_values=%llu elem_size=%llu bytes=%llu decoded_axi_beats=%llu",
                           name,
                           (unsigned long long)chunk.num_values,
                           (unsigned long long)elem_size,
                           (unsigned long long)bytes,
                           (unsigned long long)beats);

        return beats;
}

static void EnqueueBloomStreamConfig(const char *reason, parcore::metadata::Type type) {
        if (!parcore::metadata::is_libstf_type(type)) {
                throw InvalidInputException("OASIS hardware Bloom only supports libstf-compatible key types for now");
        }

        auto &ctx = oasis::OasisContext::ctx();
        auto bf_stream_config = ctx.config<libstf::StreamConfig>();

        auto libstf_type = parcore::metadata::to_libstf_type(type);

        OASIS_HW_BLOOM_LOG("StreamConfig reason=%s stream=0 type=%d select=0",
                           reason,
                           (int)libstf_type);

        bf_stream_config->enqueue_stream_config(
            0,
            libstf_type,
            0 // 0 = Bloomfilter path, 1 = Bypass
        );
}

static void ConfigureBloomOutputStream0Only(uint32_t first_last_beat, uint32_t second_last_beat) {
        auto &ctx = oasis::OasisContext::ctx();

        auto bf_config = ctx.config<OasisBFConfig>();

        libstf::stream_mask_t active_outputs(0);
        active_outputs.set(0);

        OASIS_HW_BLOOM_LOG("configure BF active_outputs={0} device_mat=false");
        bf_config->enqueue_materialization_config(active_outputs, false);

        bf_config->configure_last_injector(true, first_last_beat, second_last_beat);

        OASIS_HW_BLOOM_LOG("BF counters after config: build=%llu build_idle=%llu probe=%llu probe_idle=%llu hash_table_size=%llu",
                           (unsigned long long)bf_config->fetch_build_cycles(),
                           (unsigned long long)bf_config->fetch_build_idle_cycles(),
                           (unsigned long long)bf_config->fetch_probe_cycles(),
                           (unsigned long long)bf_config->fetch_probe_idle_cycles(),
                           (unsigned long long)bf_config->hash_table_size());
}

static idx_t MaterializeInt64BuffersToDuckDBOutput(const std::vector<std::shared_ptr<libstf::Buffer>> &buffers,
                                                   DataChunk &output) {
        if (output.data.empty()) {
                throw InternalException("OASIS hardware Bloom: DuckDB output has no columns");
        }

        output.data[0].SetVectorType(VectorType::FLAT_VECTOR);
        auto out_data = FlatVector::GetData<int64_t>(output.data[0]);
        auto &validity = FlatVector::Validity(output.data[0]);

        idx_t written = 0;

        for (size_t buffer_idx = 0; buffer_idx < buffers.size() && written < STANDARD_VECTOR_SIZE; buffer_idx++) {
                auto &buffer = buffers[buffer_idx];

                if (!buffer) {
                        throw InternalException("OASIS hardware Bloom: received null output buffer");
                }

                if ((buffer->size % sizeof(int64_t)) != 0) {
                        throw InternalException("OASIS hardware Bloom: output buffer size is not a multiple of int64 size");
                }

                auto values = reinterpret_cast<const int64_t *>(buffer->ptr);
                size_t values_in_buffer = buffer->size / sizeof(int64_t);

                size_t remaining_capacity = STANDARD_VECTOR_SIZE - written;
                size_t values_to_copy = std::min(values_in_buffer, remaining_capacity);

                for (size_t i = 0; i < values_to_copy; i++) {
                        out_data[written++] = values[i];
                }
        }

        validity.SetAllValid(written);

        OASIS_HW_BLOOM_LOG("materialized %llu INT64 values into DuckDB output chunk",
                           (unsigned long long)written);

        return written;
}

void InitializeOasisHardwareBloom(ClientContext &context, const OasisScanBindData &probe_bind) {
        (void)context;

        OASIS_HW_BLOOM_LOG("initializing hardware bloom smoke-test");
        OASIS_HW_BLOOM_LOG("build file = %s", probe_bind.runtime_bloom_build_filename.c_str());
        OASIS_HW_BLOOM_LOG("build key  = %s", probe_bind.runtime_bloom_build_key.c_str());
        OASIS_HW_BLOOM_LOG("probe key  = %s", probe_bind.runtime_bloom_probe_key.c_str());
}

void OasisScanFunctionBloomHardware(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
        auto &gstate = data_p.global_state->Cast<OasisScanGlobalState>();
        auto &bind = data_p.bind_data->Cast<OasisScanBindData>();

        static std::unordered_set<OasisScanGlobalState *> already_ran;

        if (already_ran.find(&gstate) != already_ran.end()) {
                output.SetCardinality(0);
                return;
        }
        already_ran.insert(&gstate);

        ObjectCache::GetObjectCache(context).GetOrCreate<OasisContextCacheEntry>("oasis_context");
        auto &ctx = oasis::OasisContext::ctx();

        OASIS_HW_BLOOM_LOG("running one-shot hardware bloom test from read_oasis join path");

        if (!gstate.metadata) {
                throw InternalException("OASIS hardware Bloom: missing metadata pointer");
        }

        if (bind.runtime_bloom_build_filename.empty() || bind.runtime_bloom_build_key.empty() ||
            bind.runtime_bloom_probe_key.empty()) {
                throw InternalException("OASIS hardware Bloom: runtime bloom bind fields are incomplete");
        }

        if (gstate.total_groups == 0 || bind.metadata.groups.empty()) {
                throw InvalidInputException("OASIS hardware Bloom: probe file contains no row groups");
        }

        auto build_meta = BuildMetadataForFile(context, bind.runtime_bloom_build_filename);

        size_t build_col_id = FindColumnId(build_meta.column_names, bind.runtime_bloom_build_key);
        size_t probe_col_id = FindColumnId(bind.metadata.column_names, bind.runtime_bloom_probe_key);

        auto const &build_chunk = build_meta.groups[0].chunks[build_col_id];
        auto const &probe_chunk = bind.metadata.groups[0].chunks[probe_col_id];

        auto build_type = build_chunk.type;
        auto probe_type = probe_chunk.type;

        if (build_type != probe_type) {
                OASIS_HW_BLOOM_LOG("WARNING: build key type=%d probe key type=%d differ", (int)build_type, (int)probe_type);
        }

        // The current hardware BloomfilterOperator consumes data64_t keys.
        // The Celeris example also asserts INT64_T for both build/probe keys.
        // Keep the MVP strict to avoid feeding packed INT32 data into a data64_t Bloomfilter.
        if (build_type != parcore::metadata::Type::INT64_T) {
                throw InvalidInputException("OASIS hardware Bloom smoke-test currently supports INT64 build keys only");
        }

        if (probe_type != parcore::metadata::Type::INT64_T) {
                throw InvalidInputException("OASIS hardware Bloom smoke-test currently supports INT64 probe keys only");
        }

        uint64_t build_beats = DecodedAxiBeatsForColumnChunk(build_chunk, "build chunk");
        uint64_t probe_beats = DecodedAxiBeatsForColumnChunk(probe_chunk, "probe chunk");

        if (build_beats > std::numeric_limits<uint64_t>::max() - probe_beats) {
                throw InvalidInputException("OASIS hardware Bloom: build+probe beat count overflows uint64");
        }

        uint32_t first_last_beat = CheckedBeatIndex(build_beats, "build chunk");
        uint32_t second_last_beat = CheckedBeatIndex(build_beats + probe_beats, "build+probe chunks");

        OASIS_HW_BLOOM_LOG("TLAST injection plan: build_beats=%llu probe_beats=%llu first_last_beat=%llu second_last_beat=%llu",
                           (unsigned long long)build_beats,
                           (unsigned long long)probe_beats,
                           (unsigned long long)first_last_beat,
                           (unsigned long long)second_last_beat);

        auto column_chunk_config = ctx.config<parcore::ColumnChunkDecoderConfig>();
        auto page_config = ctx.config<parcore::PageDecoderConfig>();

        auto build_decoder = std::make_shared<parcore::ColumnChunkDecoder>(
            ctx.cthread(),
            ctx.tlb_manager(),
            ctx.output_buffer_manager(),
            column_chunk_config,
            page_config,
            0);

        auto maybe_build_file = arrow::io::ReadableFile::Open(bind.runtime_bloom_build_filename);
        if (!maybe_build_file.ok()) {
                throw IOException(maybe_build_file.status().ToString());
        }
        auto build_file = *maybe_build_file;

        parcore::FileReader build_reader(build_decoder, ctx.memory_pool(), build_meta, build_file);

        ConfigureBloomOutputStream0Only(first_last_beat, second_last_beat);

        OASIS_HW_BLOOM_LOG("enqueue BUILD side via ColumnChunkDecoder: group=0 col=%llu",
                           (unsigned long long)build_col_id);

        EnqueueBloomStreamConfig("before build_reader.enqueue_column_chunk_no_output", build_type);
        build_reader.enqueue_column_chunk_no_output(0, build_col_id);

        OASIS_HW_BLOOM_LOG("BUILD enqueued. Not reading build output because build phase should not produce stream0 rows.");

        OASIS_HW_BLOOM_LOG("enqueue PROBE side via ColumnChunkDecoder: group=0 col=%llu",
                           (unsigned long long)probe_col_id);

        EnqueueBloomStreamConfig("before probe_reader.enqueue_column_chunk", probe_type);
        gstate.reader->enqueue_column_chunk(0, probe_col_id);

        OASIS_HW_BLOOM_LOG("waiting for hardware Bloom output on stream 0 through FileReader::next_column_chunk()");
        auto buffers = gstate.reader->next_column_chunk();

        size_t total_bytes = 0;
        for (size_t i = 0; i < buffers.size(); i++) {
                total_bytes += buffers[i]->size;
                OASIS_HW_BLOOM_LOG("hardware Bloom output buffer[%llu] ptr=%p size=%llu",
                                   (unsigned long long)i,
                                   buffers[i]->ptr,
                                   (unsigned long long)buffers[i]->size);
        }

        auto bf_config = ctx.config<OasisBFConfig>();
        OASIS_HW_BLOOM_LOG("BF counters after output: build=%llu build_idle=%llu probe=%llu probe_idle=%llu",
                           (unsigned long long)bf_config->fetch_build_cycles(),
                           (unsigned long long)bf_config->fetch_build_idle_cycles(),
                           (unsigned long long)bf_config->fetch_probe_cycles(),
                           (unsigned long long)bf_config->fetch_probe_idle_cycles());

        OASIS_HW_BLOOM_LOG("HARDWARE BLOOM ANSWER RECEIVED: buffers=%llu total_bytes=%llu",
                           (unsigned long long)buffers.size(),
                           (unsigned long long)total_bytes);

        auto cardinality = MaterializeInt64BuffersToDuckDBOutput(buffers, output);
        output.SetCardinality(cardinality);
}
} // namespace duckdb