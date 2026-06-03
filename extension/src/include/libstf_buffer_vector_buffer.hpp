#pragma once

#include "duckdb.hpp"
#include "duckdb/common/types/vector_buffer.hpp"
#include "libstf/buffer.hpp"

namespace duckdb {

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

} // namespace duckdb
