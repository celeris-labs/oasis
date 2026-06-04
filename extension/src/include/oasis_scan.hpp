#pragma once

#include "duckdb.hpp"
#include "libstf_buffer_vector_buffer.hpp"
#include "oasis_context_cache_entry.hpp"
#include "oasis_reader.hpp"
#include "parcore/column_chunk_decoder.hpp"
#include "parcore/metadata/metadata.hpp"
#include <parcore/reader.hpp>
#include "parquet_reader.hpp"

namespace duckdb {

struct OasisScanBindData : public TableFunctionData {
	string filename;
	parcore::metadata::Metadata metadata;
};

struct OasisScanGlobalState : public GlobalTableFunctionState {
	std::shared_ptr<parcore::ColumnChunkDecoder> decoder;
	std::unique_ptr<OasisReader> hw_reader;

	// Persistent ParquetReader for the cpu path. The ColumnReaders below hold
	// references into this reader and its schema, so it must outlive them.
	// scan_state owns the thrift protocol / file handle / define+repeat buffers
	// that InitializeRead and Read need; it is set up via InitializeScan.
	std::unique_ptr<ParquetReader> parquet_reader;
	ParquetReaderScanState scan_state;

	// ParCore column indices for the projected columns, in output order.
	vector<size_t> column_ids;
	// column readers, for columns that use the cpu path
	std::vector<unique_ptr<ColumnReader>> column_readers;

	// Scan cursor: which row group we'll enqueue next, and where we are
	// inside the buffers returned for the currently-in-flight chunk.
	size_t next_group = 0;
	size_t total_groups = 0;
	std::vector<std::vector<std::shared_ptr<libstf::Buffer>>> hw_buffers;
	// the index of the buffers (hw)
	size_t hw_buf_idx = 0;
	// the idx within the buffers (hw)
	size_t hw_buf_offset = 0;
	size_t first_hw_col_idx = 0;
};

struct OasisScanLocalState : public LocalTableFunctionState {};

unique_ptr<FunctionData> OasisScanBind(ClientContext &context, TableFunctionBindInput &input,
                                       vector<LogicalType> &return_types, vector<string> &names);

unique_ptr<GlobalTableFunctionState> OasisScanInitGlobal(ClientContext &context, TableFunctionInitInput &input);

unique_ptr<LocalTableFunctionState> OasisScanInitLocal(ExecutionContext &context, TableFunctionInitInput &input,
                                                       GlobalTableFunctionState *global_state_p);

void OasisScanFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output);

} // namespace duckdb
