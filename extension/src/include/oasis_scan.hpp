#pragma once

#include "column_reader.hpp"
#include "duckdb.hpp"
#include "libstf_buffer_vector_buffer.hpp"
#include "oasis/oasis_context.hpp"
#include "oasis_context_cache_entry.hpp"
#include "parcore/metadata/metadata.hpp"
#include "parquet_reader.hpp"

#undef LOG_INFO
#undef LOG_DEBUG

#include <atomic>
#include <memory>
#include <mutex>
#include <vector>

namespace duckdb {

struct OasisHardwareBloomState;

struct OasisScanBindData : public TableFunctionData {
        string filename;
        parcore::metadata::Metadata metadata;

        bool runtime_bloom_enabled = false;
        string runtime_bloom_build_filename;
        string runtime_bloom_build_key;
        string runtime_bloom_probe_key;
};

struct OasisScanGlobalState : public GlobalTableFunctionState {
        string filename;
        oasis::OasisContext *ctx = nullptr;

        vector<size_t> column_ids;
        vector<size_t> elem_sizes;
        vector<bool> is_cpu_column;
        bool has_cpu_columns = false;

        bool runtime_bloom_enabled = false;
        bool hardware_bloom_enabled = false;

        size_t runtime_bloom_probe_col_id = DConstants::INVALID_INDEX;

        std::shared_ptr<OasisHardwareBloomState> hardware_bloom;

        bool emit_cardinality_only = false;

        std::atomic<size_t> next_group {0};
        size_t total_groups = 0;

        idx_t MaxThreads() const override {
                return total_groups == 0 ? 1 : total_groups;
        }
};

struct OasisScanLocalState : public LocalTableFunctionState {
        unique_ptr<FileHandle> file_handle;

        unique_ptr<ParquetReader> parquet_reader;
        unique_ptr<ParquetReaderScanState> scan_state;
        unique_ptr<ColumnReader> root_reader;

        std::vector<std::shared_ptr<libstf::Buffer>> current_buffers;
        size_t current_buf_offset = 0;
        size_t current_group_num_rows = 0;

        size_t empty_proj_remaining = 0;
};

unique_ptr<FunctionData> OasisScanBind(ClientContext &context, TableFunctionBindInput &input,
                                       vector<LogicalType> &return_types, vector<string> &names);

unique_ptr<GlobalTableFunctionState> OasisScanInitGlobal(ClientContext &context, TableFunctionInitInput &input);

unique_ptr<LocalTableFunctionState> OasisScanInitLocal(ExecutionContext &context, TableFunctionInitInput &input,
                                                       GlobalTableFunctionState *global_state_p);

void OasisScanFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output);

virtual_column_map_t OasisScanGetVirtualColumns(ClientContext &context, optional_ptr<FunctionData> bind_data);

} // namespace duckdb