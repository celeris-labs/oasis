# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

WIP DuckDB extension ("maximus") for running table scans of Parquet files on FPGAs, part of the maximus project. Built on the DuckDB extension template with CMake + Make, using DuckDB's `extension-ci-tools` submodule for build infrastructure.

## Planned Flow

1. Open file
2. Instantiate parcore `FileReader` (or appropriate reader) with all required infra (cthread, pool, tlb, obm, column_chunk_decoder)
3. Enqueue column chunks with the reader
4. Receive decoded output as `vector<shared_ptr<libstf::Buffer>>` from `next_column_chunk()` (blocks until accelerator is done)
5. Map parcore output buffers **directly and zero-copy** into DuckDB `Vector` data — no Arrow intermediary

The zero-copy pipeline is owned entirely by this extension: parcore buffers are wired directly into DuckDB's `DataChunk` columns. This keeps the full pipeline under our control and allows us to extend zero-copy to strings and other types as parcore support grows — something that would not be possible via Arrow.

Parcore includes an example on how to read a file (parcore/examples/readfile/main.cpp) that is useful reference for setup and the enqueue/dequeue loop.

## Build Commands

```bash
make                # Build release (output: ./build/release/duckdb)
make debug          # Build debug (output: ./build/debug/duckdb)
make test           # Run tests (release)
make test_debug     # Run tests (debug)
make format         # Format code with DuckDB's formatter
make tidy-check     # Run clang-tidy
make clean          # Clean build artifacts
```

The built DuckDB shell at `./build/release/duckdb` has the extension statically linked — no need to `LOAD` it manually.

## Testing

Tests use DuckDB's **SQLLogicTest** format in `test/sql/`. Run a specific test:
```bash
./build/release/test/unittest "test/sql/maximus.test"
```

SQLLogicTest syntax: `statement ok`, `statement error`, `query I` (one column), `query II` (two columns), etc. Use `require maximus` to ensure the extension is loaded.

## Architecture

- **Extension entry point**: `src/maximus_extension.cpp` — defines `MaximusExtension::Load()` which registers functions via `LoadInternal()`. The C entry point `DUCKDB_CPP_EXTENSION_ENTRY` calls `LoadInternal` for the loadable extension variant.
- **Extension header**: `src/include/maximus_extension.hpp` — declares `MaximusExtension` (inherits `duckdb::Extension`).
- **Extension config**: `extension_config.cmake` — tells DuckDB's build system to load this extension and its tests.
- **Dependencies**: OpenSSL linked via vcpkg (`vcpkg.json`). Add new vcpkg deps there and link in `CMakeLists.txt`.

### DuckDB Table Function Pattern

The extension implements a table function using DuckDB's standard pattern:
1. **Bind function** (`MaximusBind`) — validates inputs, determines output schema (column names/types), returns bind data
2. **Init local** (`MyInitLocal`) — per-thread initialization (opens file handles, skips headers)
3. **Scan function** (`MaximusScan`) — reads data into `DataChunk` up to `STANDARD_VECTOR_SIZE` rows per call; return 0 cardinality to signal EOF

All extension code lives in the `duckdb` namespace.

## Submodules

- `duckdb/` — full DuckDB source (tracks main branch)
- `extension-ci-tools/` — shared build/CI infrastructure, makefiles, vcpkg overlays

Run `git submodule update --init --recursive` after cloning.
