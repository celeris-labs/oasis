#pragma once

#include "duckdb.hpp"
#include "duckdb/common/types/vector_buffer.hpp"
#include "libstf/buffer.hpp"

namespace duckdb {

// Type-system adapter that lets us hand a `shared_ptr<libstf::Buffer>` to DuckDB's Vector lifetime 
// machinery. DuckDB tracks foreign-owned backing memory through `AuxiliaryDataHolder` slots on the 
// Vector, so we wrap ours in a trivial holder. No logic, no copy: this exists purely so that when 
// DuckDB drops the holder, our shared_ptr<libstf::Buffer> refcount ticks down and, eventually, 
// libstf::BufferDeleter returns the memory to the pool.
class LibstfBufferVectorBuffer : public AuxiliaryDataHolder {
public:
	explicit LibstfBufferVectorBuffer(std::shared_ptr<libstf::Buffer> buf) : buffer(std::move(buf)) {
	}

private:
	std::shared_ptr<libstf::Buffer> buffer;
};

} // namespace duckdb
