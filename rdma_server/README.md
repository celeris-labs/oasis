# Oasis RDMA Server

The RDMA server hosts a set of Parquet files in a Coyote RDMA memory region so they can be
accessed by the Oasis DuckDB extension via the `rdma://` filesystem.

## Build

```bash
mkdir build
cmake -S . -B build
cmake --build build -j
```

The resulting binary is `build/oasis_rdma_server`.

## Run

```bash
./build/oasis_rdma_server [OPTIONS] FILE [FILE ...]
```

The server prints a summary of the hosted files and their offsets within the region, then
waits until it receives `SIGINT` (Ctrl+C) or `SIGTERM`.
