# Throwaway S3-over-RDMA client

A DuckDB extension to exercise `oasis_s3_server` in software. **Delete this directory once Oasis
integrates with the server.**

It serves `s3://` by having the server RDMA-WRITE the requested bytes directly into DuckDB's read
buffers, and DuckDB's own Parquet reader decodes them on the CPU. It is read-only and sends unsigned
requests, since the server does not check signatures yet. It fails instead of falling back to HTTP, so
a query that succeeds used RDMA.

```bash
git submodule update --init --depth 1 ../extension/duckdb ../extension/extension-ci-tools
GEN=ninja make release
cmake -S ../rdma_server -B ../rdma_server/build -G Ninja && cmake --build ../rdma_server/build

./run_tests.sh    # starts a server on the Parquet fixtures, then runs test/sql
```

```sql
SET oasis_sw_endpoint = '127.0.0.1:9000';
SELECT count(*) FROM read_parquet('s3://tpch/lineitem.parquet');
```
