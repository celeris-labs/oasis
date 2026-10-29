# Oasis Extension

This repository is based on https://github.com/duckdb/extension-template, check it out if you want to build and ship your own DuckDB extension.

---

This extension, Oasis, scans Parquet files on an FPGA. It registers the `read_oasis()` table
function, which decodes column chunks in hardware and maps the decoded buffers into DuckDB vectors
zero-copy, plus the `httpfpga://` and `rdma://` file systems that supply the bytes.

See the [top-level README](../README.md) for the hardware side and the limits of the HTTP path.


## Building
Install the Oasis library first and point `CMAKE_PREFIX_PATH` at its prefix (see the top-level
README), then run in this directory:
```sh
CMAKE_BUILD_PARALLEL_LEVEL=8 make
```
The main binaries that will be built are:
```sh
./build/release/duckdb
./build/release/test/unittest
```
- `duckdb` is the binary for the duckdb shell with the extension code automatically loaded.
- `unittest` is the test runner of duckdb. Again, the extension is already linked into the binary.

## Running the extension
To run the extension code, simply start the shell with `./build/release/duckdb`.

Now we can use the features from the extension directly in DuckDB. `read_oasis()` scans a Parquet
file with the column chunks decoded on the FPGA:

```sql
SET http_server='<object server IP>';
SET http_port=9000;
SELECT sum(p_partkey) FROM read_oasis('httpfpga:///throughput/tpch-1/part.parquet');
```

Settings: `http_server` and `http_port` (the object server; they cannot change after the first
`httpfpga://` access of a session), `httpfpga_debug` (print the HTTP client's state to stderr, as
`OASIS_HTTP_DEBUG=1` does), `oasis_scheduler_num_streams`, `oasis_scheduler_queue_depth`,
`oasis_scan_groups_in_flight`, `oasis_logging_level`, and `oasis_rdma_server` / `oasis_rdma_port`
for the `rdma://` file system.

Two things that surprise people:

- `read_parquet('httpfpga://…')` only uses the URL as a byte source: the bytes come over an
  ordinary host socket and are parsed on the CPU, so the FPGA is not involved. Use `read_oasis()` to
  exercise the hardware.
- A bare `count(*)` projects no columns and is answered from the Parquet footer with the FPGA idle.
  Project a real fixed-width column if you mean to test the decoder.

Building this extension does **not** rebuild the Oasis library in `../software`. After a change
there, rebuild and re-install it first, or the extension keeps using the old `liboasis.so`.

## Running the tests
The SQL tests in `./test/sql` read objects from the object server: `httpfpga.test` over a host
socket with `read_parquet()`, `httpfpga_decode.test` through the FPGA with `read_oasis()`. Run them
on the board host with the board programmed: loading the extension maps 1 GiB huge pages and opens
the FPGA, and on any other host it stops with `Your system has 0 free 1GiB huge pages`. Set
`OASIS_SERVER` to the object server's IP address, without a port (the tests use port 9000); without
it both tests are skipped. From this directory:
```sh
OASIS_SERVER=<object server IP> ./build/release/test/unittest --test-dir "$PWD" "test/*"
OASIS_SERVER=<object server IP> ./build/release/test/unittest --test-dir "$PWD" test/sql/httpfpga_decode.test
```
`--test-dir` makes `test/*` select this extension's tests; without it the pattern can select
DuckDB's own tests instead.
