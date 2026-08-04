# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

WIP DuckDB extension ("oasis") for running table scans of Parquet files on FPGAs, part of the Oasis project. Built on the DuckDB extension template with CMake + Make, using DuckDB's `extension-ci-tools` submodule for build infrastructure.

## Current state

`read_oasis()` is implemented in `src/oasis_scan.cpp`. It builds one `QuerySplinter` per row group
(one flow per projected hardware column), submits it to the shared scheduler, and maps the decoded
buffers into DuckDB vectors. Bytes reach the decoder one of three ways, picked by the file handle:
`HTTPSourceOperator` (the FPGA issues its own ranged GET), `RDMASourceOperator`, or
`LocalSourceOperator` (host DMA). Columns the hardware cannot decode are marked `is_cpu` and parsed
normally.

**Building this extension does not rebuild `../software`.** A stale `liboasis.so` silently survives
a branch switch and then drives the FPGA with a register map that does not match the loaded
bitstream — the writes succeed and the hardware emits a corrupt request. Rebuild and re-install the
Oasis library first. See the top-level README for the full rule and the current HTTP-path limits.

## Original design sketch

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
./build/release/test/unittest "test/sql/oasis.test"
```

SQLLogicTest syntax: `statement ok`, `statement error`, `query I` (one column), `query II` (two columns), etc. Use `require oasis` to ensure the extension is loaded.

Two suites are **hardware-gated** and excluded from a default `make test` — they need a programmed
board and a reachable object server:

- `test/sql/httpfpga_decode.test` — `read_oasis()`, the only one that exercises the FPGA decoder
- `test/sql/httpfpga.test` — `read_parquet('httpfpga://…')`, which on a decoder bitstream is served
  over a host socket and so only covers the object server and the Parquet plumbing

Their expected values were computed from the objects actually stored on the server, not from TPC-H
reference tables, so a mismatch means the bytes delivered differ from the bytes the server holds.

## Architecture

- **Extension entry point**: `src/oasis_extension.cpp` — defines `OasisExtension::Load()` which registers functions via `LoadInternal()`. The C entry point `DUCKDB_CPP_EXTENSION_ENTRY` calls `LoadInternal` for the loadable extension variant.
- **Extension header**: `src/include/oasis_extension.hpp` — declares `OasisExtension` (inherits `duckdb::Extension`).
- **Extension config**: `extension_config.cmake` — tells DuckDB's build system to load this extension and its tests.
- **Dependencies**: OpenSSL linked via vcpkg (`vcpkg.json`). Add new vcpkg deps there and link in `CMakeLists.txt`.

### DuckDB Table Function Pattern

The extension implements a table function using DuckDB's standard pattern:
1. **Bind function** (`OasisBind`) — validates inputs, determines output schema (column names/types), returns bind data
2. **Init local** (`MyInitLocal`) — per-thread initialization (opens file handles, skips headers)
3. **Scan function** (`OasisScan`) — reads data into `DataChunk` up to `STANDARD_VECTOR_SIZE` rows per call; return 0 cardinality to signal EOF

All extension code lives in the `duckdb` namespace.

## Submodules

- `duckdb/` — full DuckDB source, pinned to the latest tagged release (see `docs/UPDATING.md` when bumping)
- `extension-ci-tools/` — shared build/CI infrastructure, makefiles, vcpkg overlays; pinned to the branch matching the DuckDB release (e.g. `v1.5-variegata` for `v1.5.x`)

Run `git submodule update --init --recursive` after cloning.
