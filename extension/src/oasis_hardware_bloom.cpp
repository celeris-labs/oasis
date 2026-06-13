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
#include <cstdint>
#include <fstream>
#include <limits>
#include <memory>
#include <mutex>
#include <vector>

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

static std::unique_ptr<oasis::SourceOperator>
MakeLocalSource(oasis::OasisContext &ctx, const string &filename, const parcore::metadata::ColumnChunk &cc) {
        if (cc.total_compressed_size == 0) {
                throw InvalidInputException("OASIS hardware Bloom: column chunk has zero compressed size");
        }

        void *ptr = nullptr;
        auto status = ctx.memory_pool()->allocate(cc.total_compressed_size, &ptr);
        if (!status.ok()) {
                throw IOException("Could not allocate Bloom input buffer: " + status.message());
        }

        auto buffer = libstf::make_buffer(ctx.memory_pool(), ptr, cc.total_compressed_size, cc.total_compressed_size);

        std::ifstream file(filename, std::ios::binary);
        if (!file) {
                throw IOException("Could not open Bloom input file: " + filename);
        }

        file.seekg(static_cast<std::streamoff>(cc.offset), std::ios::beg);
        if (!file) {
                throw IOException("Could not seek Bloom input file: " + filename);
        }

        file.read(reinterpret_cast<char *>(buffer->ptr), static_cast<std::streamsize>(cc.total_compressed_size));
        if (file.gcount() != static_cast<std::streamsize>(cc.total_compressed_size)) {
                throw IOException("Could not read complete Bloom input column chunk from file: " + filename);
        }

        return std::make_unique<oasis::LocalSourceOperator>(std::move(buffer));
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

static idx_t EmitBloomBuffersZeroCopy(OasisHardwareBloomState &hb, DataChunk &output) {
        if (output.data.empty()) {
                throw InternalException("OASIS hardware Bloom: DuckDB output has no columns");
        }

        std::lock_guard<std::mutex> lock(hb.consume_mutex);

        while (hb.current_buffer_idx < hb.buffers.size()) {
                auto &buf = hb.buffers[hb.current_buffer_idx];

                if (!buf) {
                        throw InternalException("OASIS hardware Bloom: received null output buffer");
                }

                if ((buf->size % sizeof(int64_t)) != 0) {
                        throw InternalException("OASIS hardware Bloom: output buffer size is not a multiple of int64 size");
                }

                const size_t values_in_buffer = buf->size / sizeof(int64_t);

                if (hb.current_buffer_offset >= values_in_buffer) {
                        hb.current_buffer_idx++;
                        hb.current_buffer_offset = 0;
                        continue;
                }

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
                        hb.current_buffer_idx++;
                        hb.current_buffer_offset = 0;
                }

                output.SetCardinality(emit);
                return emit;
        }

        output.SetCardinality(0);
        return 0;
}

static void ExecuteHardwareBloomOnce(ClientContext &context, TableFunctionInput &data_p, OasisHardwareBloomState &hb) {
        auto &gstate = data_p.global_state->Cast<OasisScanGlobalState>();
        auto &bind = data_p.bind_data->Cast<OasisScanBindData>();

        ObjectCache::GetObjectCache(context).GetOrCreate<OasisContextCacheEntry>("oasis_context");
        auto &ctx = oasis::OasisContext::ctx();

        OASIS_HW_BLOOM_LOG("running one-shot hardware bloom test from read_oasis join path");

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

        auto build_libstf_type = parcore::metadata::to_libstf_type(build_type);
        auto probe_libstf_type = parcore::metadata::to_libstf_type(probe_type);

        oasis::QuerySplinter splinter;

        splinter.operators.push_back(std::make_unique<oasis::CallbackOperator>(
            "configure-bloom-output-stream0",
            [first_last_beat, second_last_beat](libstf::stream_t stream, oasis::OasisContext &) {
                    if (stream != 0) {
                            throw InternalException("OASIS hardware Bloom splinter was not scheduled on stream 0");
                    }
                    ConfigureBloomOutputStream0Only(first_last_beat, second_last_beat);
            }));

        OASIS_HW_BLOOM_LOG("enqueue BUILD side through scheduler: group=0 col=%llu",
                           (unsigned long long)build_col_id);

        splinter.operators.push_back(std::make_unique<oasis::StreamConfigOperator>(build_libstf_type, 0));
        splinter.operators.push_back(std::make_unique<oasis::DecodeColumnChunkOperator>(
            build_chunk.compression,
            build_chunk.num_values,
            build_libstf_type));
        splinter.operators.push_back(MakeLocalSource(ctx, bind.runtime_bloom_build_filename, build_chunk));

        OASIS_HW_BLOOM_LOG("enqueue PROBE side through scheduler: group=0 col=%llu",
                           (unsigned long long)probe_col_id);

        splinter.operators.push_back(std::make_unique<oasis::StreamConfigOperator>(probe_libstf_type, 0));
        splinter.operators.push_back(std::make_unique<oasis::DecodeColumnChunkOperator>(
            probe_chunk.compression,
            probe_chunk.num_values,
            probe_libstf_type));
        splinter.operators.push_back(MakeLocalSource(ctx, bind.filename, probe_chunk));

        splinter.operators.push_back(std::make_unique<oasis::HostBufferSinkOperator>());

        OASIS_HW_BLOOM_LOG("submit Bloom BUILD+PROBE splinter pinned to stream 0");
        auto result = ctx.scheduler().submit_to_stream(0, std::move(splinter));

        OASIS_HW_BLOOM_LOG("waiting for hardware Bloom output on stream 0 through Scheduler result");

        hb.buffers.clear();
        hb.current_buffer_idx = 0;
        hb.current_buffer_offset = 0;

        while (auto batch = result.get_next_batch()) {
                hb.buffers.push_back(std::move(*batch));
        }

        size_t total_bytes = 0;
        for (size_t i = 0; i < hb.buffers.size(); i++) {
                total_bytes += hb.buffers[i]->size;
                OASIS_HW_BLOOM_LOG("hardware Bloom output buffer[%llu] ptr=%p size=%llu",
                                   (unsigned long long)i,
                                   hb.buffers[i]->ptr,
                                   (unsigned long long)hb.buffers[i]->size);
        }

        auto bf_config = ctx.config<OasisBFConfig>();
        OASIS_HW_BLOOM_LOG("BF counters after output: build=%llu build_idle=%llu probe=%llu probe_idle=%llu",
                           (unsigned long long)bf_config->fetch_build_cycles(),
                           (unsigned long long)bf_config->fetch_build_idle_cycles(),
                           (unsigned long long)bf_config->fetch_probe_cycles(),
                           (unsigned long long)bf_config->fetch_probe_idle_cycles());

        OASIS_HW_BLOOM_LOG("HARDWARE BLOOM ANSWER RECEIVED: buffers=%llu total_bytes=%llu",
                           (unsigned long long)hb.buffers.size(),
                           (unsigned long long)total_bytes);
}

void InitializeOasisHardwareBloom(ClientContext &context, const OasisScanBindData &probe_bind) {
        (void)context;

        OASIS_HW_BLOOM_LOG("initializing hardware bloom");
        OASIS_HW_BLOOM_LOG("build file = %s", probe_bind.runtime_bloom_build_filename.c_str());
        OASIS_HW_BLOOM_LOG("build key  = %s", probe_bind.runtime_bloom_build_key.c_str());
        OASIS_HW_BLOOM_LOG("probe key  = %s", probe_bind.runtime_bloom_probe_key.c_str());
}

void OasisScanFunctionBloomHardware(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
        auto &gstate = data_p.global_state->Cast<OasisScanGlobalState>();

        if (!gstate.hardware_bloom) {
                throw InternalException("OASIS hardware Bloom state is not initialized");
        }

        auto &hb = *gstate.hardware_bloom;

        if (!hb.executed.load(std::memory_order_acquire)) {
                std::lock_guard<std::mutex> lock(hb.launch_mutex);
                if (!hb.executed.load(std::memory_order_relaxed)) {
                        ExecuteHardwareBloomOnce(context, data_p, hb);
                        hb.executed.store(true, std::memory_order_release);
                }
        }

        EmitBloomBuffersZeroCopy(hb, output);
}

} // namespace duckdb