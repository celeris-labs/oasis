#include "oasis_hardware_bloom.hpp"

#undef LOG_INFO
#undef LOG_DEBUG

#include "duckdb/common/exception.hpp"
#include "duckdb/common/multi_file/multi_file_options.hpp"
#include "duckdb/common/string_util.hpp"
#include "duckdb/common/types/vector.hpp"

#include "oasis/oasis_context.hpp"
#include "oasis_context_cache_entry.hpp"
#include "oasis_parquet_metadata.hpp"
#include "oasis/query_splinter.hpp"

#include "libstf/common.hpp"
#include "libstf/configuration.hpp"
#include "parcore/configuration.hpp"
#include "parquet_reader.hpp"

#undef LOG_INFO
#undef LOG_DEBUG

#include <algorithm>
#include <bitset>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <fstream>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace duckdb {

static constexpr uint64_t OASIS_HW_BLOOM_AXI_BYTES_PER_BEAT = 64;

static bool HardwareBloomVerbose() {
        static const bool enabled = [] {
                const char *value = std::getenv("OASIS_HW_BLOOM_VERBOSE");
                return value && value[0] != '\0' && value[0] != '0';
        }();
        return enabled;
}

#define OASIS_HW_BLOOM_LOG(...)                                                                                   \
        do {                                                                                                      \
                if (HardwareBloomVerbose()) {                                                                     \
                        fprintf(stderr, "[OASIS][HW_BLOOM] ");                                                    \
                        fprintf(stderr, __VA_ARGS__);                                                             \
                        fprintf(stderr, "\n");                                                                    \
                }                                                                                                 \
        } while (0)

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

static void DisableLastInjectorNoThrow(std::atomic<bool> &enabled) noexcept {
        if (!enabled.exchange(false, std::memory_order_acq_rel)) {
                return;
        }

        try {
                auto &ctx = oasis::OasisContext::ctx();
                ctx.config<OasisBFConfig>()->configure_last_injector(false, 0, 0);
        } catch (...) {
        }
}

OasisHardwareBloomState::~OasisHardwareBloomState() {
        DisableLastInjectorNoThrow(tlast_injector_enabled);
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

static parcore::metadata::Metadata BuildMetadataForFile(ClientContext &context, const string &filename) {
        ParquetOptions parquet_opts(context);
        ParquetReader parquet_reader(context, OpenFileInfo {filename}, parquet_opts);

        auto meta = BuildParcoreMetadata(context, parquet_reader);
        if (meta.groups.empty()) {
                throw InvalidInputException("OASIS hardware Bloom metadata contains no row groups: %s", filename);
        }

        return meta;
}

static void CheckInt64KeyType(parcore::metadata::Type type, const char *side) {
        if (type != parcore::metadata::Type::INT64_T) {
                throw InvalidInputException("OASIS hardware Bloom currently supports INT64 %s keys only", side);
        }
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
        return (bytes + OASIS_HW_BLOOM_AXI_BYTES_PER_BEAT - 1) / OASIS_HW_BLOOM_AXI_BYTES_PER_BEAT;
}

static void AddChecked(uint64_t &acc, uint64_t value, const char *name) {
        if (acc > std::numeric_limits<uint64_t>::max() - value) {
                throw InvalidInputException("OASIS hardware Bloom: %s beat count overflows uint64", name);
        }
        acc += value;
}

struct KeyChunkTask {
        size_t group_id;
        const parcore::metadata::ColumnChunk *chunk;
        libstf::type_t libstf_type;
        uint64_t beats;
};

static std::vector<KeyChunkTask> CollectKeyChunks(const parcore::metadata::Metadata &metadata, size_t column_id,
                                                  const char *side, uint64_t &total_beats) {
        std::vector<KeyChunkTask> tasks;
        total_beats = 0;

        for (size_t group_id = 0; group_id < metadata.groups.size(); group_id++) {
                const auto &group = metadata.groups[group_id];
                if (column_id >= group.chunks.size()) {
                        throw InvalidInputException("OASIS hardware Bloom: %s column id out of range in row group %llu",
                                                    side, (unsigned long long)group_id);
                }

                const auto &chunk = group.chunks[column_id];
                if (chunk.num_values == 0) {
                        continue;
                }

                CheckInt64KeyType(chunk.type, side);

                uint64_t beats = DecodedAxiBeatsForColumnChunk(chunk, side);
                AddChecked(total_beats, beats, side);

                tasks.push_back(KeyChunkTask {
                    group_id,
                    &chunk,
                    parcore::metadata::to_libstf_type(chunk.type),
                    beats,
                });
        }

        if (tasks.empty()) {
                throw InvalidInputException("OASIS hardware Bloom: %s side contains no non-empty key chunks", side);
        }

        return tasks;
}

class ChunkFileReader {
public:
        explicit ChunkFileReader(string filename) : filename_(std::move(filename)), file_(filename_, std::ios::binary) {
                if (!file_) {
                        throw IOException("Could not open Bloom input file: " + filename_);
                }
        }

        std::shared_ptr<libstf::Buffer> Read(oasis::OasisContext &ctx, const parcore::metadata::ColumnChunk &cc) {
                if (cc.total_compressed_size == 0) {
                        throw InvalidInputException("OASIS hardware Bloom: column chunk has zero compressed size");
                }

                if (cc.total_compressed_size > static_cast<uint64_t>(std::numeric_limits<std::streamsize>::max())) {
                        throw InvalidInputException("OASIS hardware Bloom: column chunk too large for local read");
                }

                void *ptr = nullptr;
                auto status = ctx.memory_pool()->allocate(cc.total_compressed_size, &ptr);
                if (!status.ok()) {
                        throw IOException("Could not allocate Bloom input buffer: " + status.message());
                }

                auto buffer = libstf::make_buffer(ctx.memory_pool(), ptr, cc.total_compressed_size, cc.total_compressed_size);

                file_.clear();
                file_.seekg(static_cast<std::streamoff>(cc.offset), std::ios::beg);
                if (!file_) {
                        throw IOException("Could not seek Bloom input file: " + filename_);
                }

                file_.read(reinterpret_cast<char *>(buffer->ptr), static_cast<std::streamsize>(cc.total_compressed_size));
                if (file_.gcount() != static_cast<std::streamsize>(cc.total_compressed_size)) {
                        throw IOException("Could not read complete Bloom input column chunk from file: " + filename_);
                }

                return buffer;
        }

private:
        string filename_;
        std::ifstream file_;
};

static std::unique_ptr<oasis::SourceOperator> MakeLocalSource(oasis::OasisContext &ctx, ChunkFileReader &reader,
                                                              const parcore::metadata::ColumnChunk &cc) {
        return std::make_unique<oasis::LocalSourceOperator>(reader.Read(ctx, cc));
}

static void ConfigureBloomOutputStream0Only(OasisHardwareBloomState &hb, uint32_t first_last_beat,
                                            uint32_t second_last_beat) {
        auto &ctx = oasis::OasisContext::ctx();
        auto bf_config = ctx.config<OasisBFConfig>();

        libstf::stream_mask_t active_outputs(0);
        active_outputs.set(0);

        bf_config->enqueue_materialization_config(active_outputs, false);
        bf_config->configure_last_injector(true, first_last_beat, second_last_beat);
        hb.tlast_injector_enabled.store(true, std::memory_order_release);
}

static void DisableBloomLastInjector(OasisHardwareBloomState &hb) {
        if (!hb.tlast_injector_enabled.exchange(false, std::memory_order_acq_rel)) {
                return;
        }

        auto &ctx = oasis::OasisContext::ctx();
        ctx.config<OasisBFConfig>()->configure_last_injector(false, 0, 0);
}

static void AppendKeyChunkOperators(oasis::QuerySplinter &splinter, oasis::OasisContext &ctx, ChunkFileReader &reader,
                                    const KeyChunkTask &task) {
        splinter.operators.push_back(std::make_unique<oasis::StreamConfigOperator>(task.libstf_type, 0));
        splinter.operators.push_back(std::make_unique<oasis::DecodeColumnChunkOperator>(
            task.chunk->compression,
            task.chunk->num_values,
            task.libstf_type));
        splinter.operators.push_back(MakeLocalSource(ctx, reader, *task.chunk));
}

static void StartHardwareBloom(ClientContext &context, TableFunctionInput &data_p,
                               const std::shared_ptr<OasisHardwareBloomState> &hb) {
        auto &gstate = data_p.global_state->Cast<OasisScanGlobalState>();
        auto &bind = data_p.bind_data->Cast<OasisScanBindData>();

        ObjectCache::GetObjectCache(context).GetOrCreate<OasisContextCacheEntry>("oasis_context");
        auto &ctx = oasis::OasisContext::ctx();

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

        if (build_meta.groups.empty() || bind.metadata.groups.empty()) {
                throw InvalidInputException("OASIS hardware Bloom: build or probe metadata is empty");
        }

        CheckInt64KeyType(build_meta.groups[0].chunks[build_col_id].type, "build");
        CheckInt64KeyType(bind.metadata.groups[0].chunks[probe_col_id].type, "probe");

        uint64_t build_beats = 0;
        uint64_t probe_beats = 0;

        auto build_tasks = CollectKeyChunks(build_meta, build_col_id, "build", build_beats);
        auto probe_tasks = CollectKeyChunks(bind.metadata, probe_col_id, "probe", probe_beats);

        uint32_t first_last_beat = CheckedBeatIndex(build_beats, "build chunks");
        uint32_t second_last_beat = CheckedBeatIndex(probe_beats, "probe chunks");

        OASIS_HW_BLOOM_LOG("Bloom plan: build_groups=%llu probe_groups=%llu build_beats=%llu probe_beats=%llu",
                           (unsigned long long)build_tasks.size(),
                           (unsigned long long)probe_tasks.size(),
                           (unsigned long long)build_beats,
                           (unsigned long long)probe_beats);

        ChunkFileReader build_reader(bind.runtime_bloom_build_filename);
        ChunkFileReader probe_reader(bind.filename);

        oasis::QuerySplinter splinter;

        splinter.operators.push_back(std::make_unique<oasis::CallbackOperator>(
            "configure-bloom-output-stream0",
            [hb, first_last_beat, second_last_beat](libstf::stream_t stream, oasis::OasisContext &) {
                    if (stream != 0) {
                            throw InternalException("OASIS hardware Bloom splinter was not scheduled on stream 0");
                    }
                    ConfigureBloomOutputStream0Only(*hb, first_last_beat, second_last_beat);
            }));

        for (const auto &task : build_tasks) {
                OASIS_HW_BLOOM_LOG("enqueue BUILD group=%llu beats=%llu",
                                   (unsigned long long)task.group_id,
                                   (unsigned long long)task.beats);
                AppendKeyChunkOperators(splinter, ctx, build_reader, task);
        }

        for (const auto &task : probe_tasks) {
                OASIS_HW_BLOOM_LOG("enqueue PROBE group=%llu beats=%llu",
                                   (unsigned long long)task.group_id,
                                   (unsigned long long)task.beats);
                AppendKeyChunkOperators(splinter, ctx, probe_reader, task);
        }

        splinter.operators.push_back(std::make_unique<oasis::HostBufferSinkOperator>());

        {
                std::lock_guard<std::mutex> lock(hb->consume_mutex);
                hb->result.reset();
                hb->current_buffer.reset();
                hb->current_buffer_offset = 0;
                hb->result_drained = false;
                hb->output_buffers = 0;
                hb->output_bytes = 0;
        }

        auto result = ctx.scheduler().submit_to_stream(0, std::move(splinter));

        {
                std::lock_guard<std::mutex> lock(hb->consume_mutex);
                hb->result.emplace(std::move(result));
        }
}

static void LogFinalCounters(OasisHardwareBloomState &hb) {
        if (!HardwareBloomVerbose()) {
                return;
        }

        auto &ctx = oasis::OasisContext::ctx();
        auto bf_config = ctx.config<OasisBFConfig>();

        OASIS_HW_BLOOM_LOG("BF counters after output: build=%llu build_idle=%llu probe=%llu probe_idle=%llu buffers=%llu bytes=%llu",
                           (unsigned long long)bf_config->fetch_build_cycles(),
                           (unsigned long long)bf_config->fetch_build_idle_cycles(),
                           (unsigned long long)bf_config->fetch_probe_cycles(),
                           (unsigned long long)bf_config->fetch_probe_idle_cycles(),
                           (unsigned long long)hb.output_buffers,
                           (unsigned long long)hb.output_bytes);
}

static idx_t EmitBloomResultZeroCopy(OasisHardwareBloomState &hb, DataChunk &output) {
        if (output.data.empty()) {
                throw InternalException("OASIS hardware Bloom: DuckDB output has no columns");
        }

        std::lock_guard<std::mutex> lock(hb.consume_mutex);

        while (true) {
                if (hb.current_buffer) {
                        auto &buf = hb.current_buffer;

                        if ((buf->size % sizeof(int64_t)) != 0) {
                                throw InternalException("OASIS hardware Bloom: output buffer size is not a multiple of int64 size");
                        }

                        const size_t values_in_buffer = buf->size / sizeof(int64_t);
                        if (hb.current_buffer_offset < values_in_buffer) {
                                const size_t remaining_values = values_in_buffer - hb.current_buffer_offset;
                                const idx_t emit = static_cast<idx_t>(std::min<size_t>(remaining_values, STANDARD_VECTOR_SIZE));

                                auto &vec = output.data[0];
                                vec.SetVectorType(VectorType::FLAT_VECTOR);
                                FlatVector::SetData(
                                    vec,
                                    reinterpret_cast<data_ptr_t>(buf->ptr) + hb.current_buffer_offset * sizeof(int64_t));
                                vec.SetAuxiliary(make_buffer<LibstfBufferVectorBuffer>(buf));
                                FlatVector::Validity(vec).SetAllValid(emit);

                                hb.current_buffer_offset += emit;
                                if (hb.current_buffer_offset >= values_in_buffer) {
                                        hb.current_buffer.reset();
                                        hb.current_buffer_offset = 0;
                                }

                                output.SetCardinality(emit);
                                return emit;
                        }

                        hb.current_buffer.reset();
                        hb.current_buffer_offset = 0;
                }

                if (hb.result_drained) {
                        output.SetCardinality(0);
                        return 0;
                }

                if (!hb.result.has_value()) {
                        throw InternalException("OASIS hardware Bloom result was not started");
                }

                auto next = hb.result->get_next_batch();
                if (!next) {
                        hb.result_drained = true;
                        DisableBloomLastInjector(hb);
                        LogFinalCounters(hb);
                        output.SetCardinality(0);
                        return 0;
                }

                hb.output_buffers++;
                hb.output_bytes += (*next)->size;

                if ((*next)->size == 0) {
                        continue;
                }

                hb.current_buffer = std::move(*next);
                hb.current_buffer_offset = 0;
        }
}

void InitializeOasisHardwareBloom(ClientContext &context, const OasisScanBindData &probe_bind) {
        (void)context;

        OASIS_HW_BLOOM_LOG("initializing hardware bloom build_file=%s build_key=%s probe_key=%s",
                           probe_bind.runtime_bloom_build_filename.c_str(),
                           probe_bind.runtime_bloom_build_key.c_str(),
                           probe_bind.runtime_bloom_probe_key.c_str());
}

void OasisScanFunctionBloomHardware(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
        auto &gstate = data_p.global_state->Cast<OasisScanGlobalState>();

        if (!gstate.hardware_bloom) {
                throw InternalException("OASIS hardware Bloom state is not initialized");
        }

        auto hb = gstate.hardware_bloom;

        if (!hb->executed.load(std::memory_order_acquire)) {
                std::lock_guard<std::mutex> lock(hb->launch_mutex);
                if (!hb->executed.load(std::memory_order_relaxed)) {
                        StartHardwareBloom(context, data_p, hb);
                        hb->executed.store(true, std::memory_order_release);
                }
        }

        EmitBloomResultZeroCopy(*hb, output);
}

} // namespace duckdb
