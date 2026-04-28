#define DUCKDB_EXTENSION_MAIN

#include "maximus_extension.hpp"
#include "duckdb.hpp"
#include "duckdb/common/exception.hpp"
#include "duckdb/common/types/vector_buffer.hpp"
#include "duckdb/function/scalar_function.hpp"
#include <coyote/bFunc.hpp>
#include <coyote/cThread.hpp>
#include "libstf/buffer.hpp"
#include "libstf/memory_pool.hpp"
#include "libstf/output_buffer_manager.hpp"
#include "libstf/tlb_manager.hpp"
#include "parcore/column_chunk_decoder.hpp"
#include "parcore/configuration.hpp"
#include "parcore/file_reader.hpp"
#include "parcore/metadata/utils.hpp"

#include <parcore/reader.hpp>

// Default vFPGA to assign cThreads to; for designs with one region (vFPGA) this
// is the only possible value
#define DEFAULT_VFPGA_ID 0
#define ENABLE_SIMULATION 1

std::shared_ptr<libstf::OutputBufferManager> obm;

static void handle_fpga_interrupt(int value) {
	// The nullptr is a bit ugly but this function is private any can only be
	// called from the cthread, which means the private constructor was executed
	// and the context has been initialized!
	//
	// Note that we needed to implement the "handle_fpga_interrupt" function as a
	// static function due to a limitation in Coyote. The reason is that we need
	// to register a function pointer with Coyote to call when an interrupt is
	// triggered on the FPGA. However, Coyote only accepts a raw function pointer.
	// Raw function points can only be created in C++ from static methods. See
	// https://isocpp.org/wiki/faq/pointers-to-members#fnptr-vs-memfnptr-types In
	// particular, they cannot be created from what's called a
	// pointer-to-member-function: > NOTE: do not attempt to “cast” a poi
	// ter-to-member-function into a pointer-to-function; > the result is
	// undefined and probably disastrous.
	//   (From above link)
	obm->handle_fpga_interrupt(value);
}

namespace duckdb {

static LogicalType ParcoreTypeToLogical(parcore::metadata::Type type) {
	switch (type) {
	case parcore::metadata::Type::INT32_T:
		return LogicalType::INTEGER;
	case parcore::metadata::Type::INT64_T:
		return LogicalType::BIGINT;
	case parcore::metadata::Type::FLOAT_T:
		return LogicalType::FLOAT;
	case parcore::metadata::Type::DOUBLE_T:
		return LogicalType::DOUBLE;
	case parcore::metadata::Type::BYTE_T:
		return LogicalType::TINYINT;
	default:
		throw InternalException("Unsupported parcore type");
	}
}

struct ParcoreBindData : public TableFunctionData {
	string filename;
	parcore::metadata::Metadata metadata;
	vector<size_t> elem_sizes;
};

unique_ptr<FunctionData> ParcoreBind(ClientContext &context, TableFunctionBindInput &input,
                                     vector<LogicalType> &return_types, vector<string> &names) {
	auto parquet_file = StringValue::Get(input.inputs[0]);
	auto meta = parcore::metadata::from_file(parquet_file + ".meta");
	names.assign(meta.column_names.begin(), meta.column_names.end());
	if (meta.groups.empty()) { throw InvalidInputException("Parquet metadata contains no row groups"); }

	auto bind_data = make_uniq<ParcoreBindData>();
	for (auto &chunk : meta.groups[0].chunks) {
		return_types.push_back(ParcoreTypeToLogical(chunk.type));
		bind_data->elem_sizes.push_back(libstf::size_of(parcore::metadata::to_libstf_type(chunk.type)));
	}
	bind_data->metadata	= meta;
	bind_data->filename = parquet_file;

	return std::move(bind_data);
}

// Type-system adapter that lets us hand a `shared_ptr<libstf::Buffer>` to
// DuckDB's Vector lifetime machinery. DuckDB's Vector owns lifetime via
// `buffer_ptr<VectorBuffer>` (== `shared_ptr<VectorBuffer>`) — it doesn't
// accept arbitrary `shared_ptr<T>`, so we wrap ours in a trivial VectorBuffer
// subclass. No logic, no copy: this exists purely so that when DuckDB drops
// its shared_ptr<VectorBuffer>, our shared_ptr<libstf::Buffer> refcount ticks
// down and, eventually, libstf::BufferDeleter returns the memory to the pool.
class LibstfBufferVectorBuffer : public VectorBuffer {
public:
	explicit LibstfBufferVectorBuffer(std::shared_ptr<libstf::Buffer> buf)
	    : VectorBuffer(VectorBufferType::OPAQUE_BUFFER), buffer(std::move(buf)) {
	}

private:
	std::shared_ptr<libstf::Buffer> buffer;
};

struct ParcoreGlobalState : public GlobalTableFunctionState {
	// Parcore infra. All of this must outlive every scan call, so it lives on
	// the global state (previously it was local to ParcoreInitGlobal and got
	// destroyed before the first scan). The obm itself stays a file-scope
	// global due to the static-function interrupt callback limitation above.
	std::shared_ptr<coyote::cThread> cthread;
	std::shared_ptr<libstf::MemoryPool> pool;
	std::shared_ptr<libstf::TLBManager> tlb;
	std::shared_ptr<parcore::ColumnChunkDecoder> decoder;
	std::shared_ptr<arrow::io::ReadableFile> file;
	std::unique_ptr<parcore::FileReader> reader;

	// Scan cursor: which row group we'll enqueue next, and where we are
	// inside the buffers returned for the currently-in-flight chunk.
	size_t next_group = 0;
	size_t total_groups = 0;
	std::vector<std::shared_ptr<libstf::Buffer>> current_buffers;
	size_t current_buf_idx = 0;
	size_t current_buf_byte_offset = 0;
};

unique_ptr<GlobalTableFunctionState> ParcoreInitGlobal(ClientContext &context, TableFunctionInitInput &input) {
	auto &bind_data = input.bind_data->Cast<ParcoreBindData>();

	auto gstate = make_uniq<ParcoreGlobalState>();

	gstate->cthread = std::make_shared<coyote::cThread>(DEFAULT_VFPGA_ID, getpid(), 0, &handle_fpga_interrupt);

#ifdef ENABLE_SIMULATION
	gstate->pool = std::make_shared<libstf::SimpleMemoryPool>();
#else
	gstate->pool = std::make_shared<libstf::HugePageMemoryPool>();
#endif

	gstate->tlb = std::make_shared<libstf::TLBManager>(gstate->cthread, gstate->pool);

#ifndef ENABLE_SIMULATION
	auto *huge_pool = dynamic_cast<libstf::HugePageMemoryPool *>(gstate->pool.get());
	gstate->tlb->ensure_tlb_mapping(huge_pool->initial_address(), huge_pool->total_capacity());
#endif

	libstf::GlobalConfig global_config(gstate->cthread);
	auto mem_config = global_config.get_config<libstf::MemConfig>();
	auto column_chunk_config = global_config.get_config<parcore::ColumnChunkDecoderConfig>();
	auto page_config = global_config.get_config<parcore::PageDecoderConfig>();

	// TODO: obm is outside function scope, probably no good.

#ifdef ENABLE_SIMULATION
	obm = std::make_shared<libstf::OutputBufferManager>(gstate->cthread, mem_config, gstate->pool, gstate->tlb, 2,
	                                                    1 << 21 /* 2MiB */);
#else
	obm = std::make_shared<libstf::OutputBufferManager>(gstate->cthread, mem_config, gstate->pool, gstate->tlb, 40,
	                                                    1 << 24 /* 16MiB */);
#endif

	obm->flush_buffers();

	gstate->decoder = std::make_shared<parcore::ColumnChunkDecoder>(gstate->cthread, gstate->tlb, obm,
	                                                                column_chunk_config, page_config, 0);

	auto maybe_file = arrow::io::ReadableFile::Open(bind_data.filename);
	if (!maybe_file.ok()) {
		throw IOException(maybe_file.status().ToString());
	}
	gstate->file = *maybe_file;

	gstate->reader =
	    std::make_unique<parcore::FileReader>(gstate->decoder, gstate->pool, bind_data.metadata, gstate->file);

	gstate->total_groups = bind_data.metadata.groups.size();

	return std::move(gstate);
}

struct ParcoreLocalState : public LocalTableFunctionState {};

unique_ptr<LocalTableFunctionState> ParcoreInitLocal(ExecutionContext &context, TableFunctionInitInput &input,
                                                     GlobalTableFunctionState *global_state_p) {
	return make_uniq<ParcoreLocalState>();
}

// Crude zero-copy demo: assumes a single INT32 column (column 0). Other
// columns in the bind's schema will be left uninitialised — feed an INT32
// single-column parquet until we generalise.
static void ParcoreFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &gstate = data_p.global_state->Cast<ParcoreGlobalState>();
	auto &bind = data_p.bind_data->Cast<ParcoreBindData>();

	const size_t kElemSize = bind.elem_sizes[0];

	// If we've finished draining the current chunk's buffers, pull the next
	// row group (or signal EOF). Reassigning current_buffers drops our refs
	// to the previous chunk's buffers — any that are still aux-referenced by
	// downstream operators stay alive via those refs; the rest get freed back
	// to the pool. We don't need to know or care which is which.
	if (gstate.current_buf_idx >= gstate.current_buffers.size()) {
		if (gstate.next_group >= gstate.total_groups) {
			output.SetCardinality(0);
			return;
		}
		gstate.reader->enqueue_column_chunk(gstate.next_group, /*column=*/0);
		gstate.current_buffers = gstate.reader->next_column_chunk(); // blocks on FPGA
		gstate.current_buf_idx = 0;
		gstate.current_buf_byte_offset = 0;
		gstate.next_group++;
	}

	auto &buf = gstate.current_buffers[gstate.current_buf_idx];
	size_t remaining_bytes = buf->size - gstate.current_buf_byte_offset;
	size_t emit = std::min<size_t>(remaining_bytes / kElemSize, STANDARD_VECTOR_SIZE);

	// The actual zero-copy handoff. Two things happen here:
	//
	//  1. FlatVector::SetData points the vector's raw data pointer directly
	//     into the FPGA-written libstf buffer (+ byte offset for the
	//     STANDARD_VECTOR_SIZE slice we're emitting this call). No memcpy,
	//     no arrow intermediary.
	//
	//  2. SetAuxiliary hands the buffer's shared_ptr to DuckDB's Vector
	//     lifetime slot (wrapped in LibstfBufferVectorBuffer, because
	//     DuckDB's slot is typed to shared_ptr<VectorBuffer>, not our
	//     shared_ptr<libstf::Buffer>). DuckDB copies this shared_ptr whenever
	//     it copies the vector, so the underlying memory stays alive as long
	//     as any downstream consumer references it.
	//
	// Two refcount holders protect the memory while it's in flight:
	//   - gstate.current_buffers keeps it alive across scan calls while we
	//     slice one FPGA chunk into multiple STANDARD_VECTOR_SIZE emissions
	//     (auxiliary gets cleared on each output.Reset()).
	//   - vector auxiliary (set here) keeps it alive for any downstream
	//     consumer that holds onto the vector past our next scan call.
	auto &vec = output.data[0];
	vec.SetVectorType(VectorType::FLAT_VECTOR);
	FlatVector::SetData(vec, reinterpret_cast<data_ptr_t>(buf->ptr) + gstate.current_buf_byte_offset);
	vec.SetAuxiliary(make_buffer<LibstfBufferVectorBuffer>(buf));

	// Advance the cursor. If we hit the end of this buffer, step to the next
	// one so the next scan call's `if` branch either keeps emitting or pulls
	// a fresh chunk.
	gstate.current_buf_byte_offset += emit * kElemSize;
	if (gstate.current_buf_byte_offset >= buf->size) {
		gstate.current_buf_idx++;
		gstate.current_buf_byte_offset = 0;
	}

	output.SetCardinality(emit);
}

static void LoadInternal(ExtensionLoader &loader) {
	TableFunction table_function("parcore",              // function name
	                             {LogicalType::VARCHAR}, // function arguments: parquet file path
	                             ParcoreFunction,        // table function
	                             ParcoreBind,            // bind function
	                             ParcoreInitGlobal,      // init global function
	                             ParcoreInitLocal        // init local function
	);

	loader.RegisterFunction(table_function);
}

void MaximusExtension::Load(ExtensionLoader &loader) {
	LoadInternal(loader);
}

std::string MaximusExtension::Name() {
	return "maximus";
}

std::string MaximusExtension::Version() const {
#ifdef EXT_VERSION_MAXIMUS
	return EXT_VERSION_MAXIMUS;
#else
	return "";
#endif
}

} // namespace duckdb

extern "C" {
DUCKDB_CPP_EXTENSION_ENTRY(maximus, loader) {
	duckdb::LoadInternal(loader);
}
}
