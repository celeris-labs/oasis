# Oasis -- Data Processing SmartNIC

Oasis is a data processing SmartNIC for cloud-native data lakes. It offloads Parquet decoding into
the network data path. The main components are a hardware design that embeds
[ParCore](https://github.com/celeris-labs/parcore) into an RDMA-enabled
[Coyote](https://github.com/fpgasystems/Coyote) vFPGA and a software abstraction for easy
integration into query engines.

This repository adds an HTTP mode for the AMD Alveo U55C: the vFPGA fetches the Parquet column
chunks itself, with ranged HTTP `GET`s over the TCP/IP stack in the Coyote shell, from an
S3-compatible object store such as MinIO, and streams the bodies into four ParCore column-chunk
decoders (one TCP session per decoder); those bytes never touch host memory. The host
library (`software/`) plans the requests and collects the decoded columns; the DuckDB extension
(`extension/`) exposes it as the table function `read_oasis()`.

## Repository layout

| path | contents |
| --- | --- |
| `hardware/` | vFPGA design (`src/`), decoder floorplans (`constraints/`), patches to the submodules (`patches/`), RTL benches (`unit-tests/`), `CMakeLists.txt` for the Coyote build |
| `software/` | the Oasis host library (`oasis/`) and a board-free check (`tests/csr_decode_check.cpp`) |
| `extension/` | the DuckDB extension (`src/`, SQL tests in `test/sql/`); submodules `duckdb` and `extension-ci-tools` |
| `rdma_server/` | the file server for the RDMA mode |
| `scripts/` | hardware build (`synthesize.sh`), TPC-H run (`tpch_demo.sh`, queries in `tpch/`), throughput harness (`throughput.sh`), simulation setup, Arrow install |
| `parcore/` | submodule: ParCore, with libstf and Coyote nested in it (`parcore/libstf/coyote`) |
| `celeris/` | submodule from the upstream project; no build below uses it |

## Requirements

- Vivado and Vitis HLS 2024.2, and `tmux` (the hardware build runs in a detached session).
- CMake 3.16 or newer and a C++17 compiler; jemalloc (`./parcore/libstf/scripts/install_jemalloc.sh`)
  and Apache Arrow 24.0.0 (`./scripts/install_arrow.sh`). Both scripts install into `~/opt` by
  default (`INSTALL_PATH` changes it).
- An Alveo U55C with the Coyote driver, and 1 GiB huge pages on its host: the library maps 4 of them
  by default (`LIBSTF_HUGE_PAGES=N` changes the count).
- For the HTTP mode, an object store the FPGA's network port can reach that serves anonymous
  ranged `GET`s with `Content-Length` (MinIO does).

## Getting the sources

The hardware component requires the ParCore submodule and its dependencies to be loaded by either
cloning this repo with submodules directly:

```bash
git clone --recurse-submodules git@github.com:celeris-labs/oasis.git
```

Or initializing the submodule as a step after cloning:

```bash
git submodule update --init extension/duckdb
git submodule update --init extension/extension-ci-tools
git submodule update --init --recursive parcore
git submodule update --init celeris
```

The TCP stack (`parcore/libstf/coyote/hw/services/network`) is pinned to a commit that is not
upstream; it ships as `hardware/patches/oasis-cmake-defined-guard.bundle`. If the recursive update
cannot find commit `e9edcc4` there, restore it from the bundle. Then, and after every later
submodule update, apply the patches; every hardware build needs them:

```bash
SM=parcore/libstf/coyote/hw/services/network
git -C $SM fetch "$PWD/hardware/patches/oasis-cmake-defined-guard.bundle" \
      'oasis/cmake-defined-guard:oasis/cmake-defined-guard'
git -C $SM checkout oasis/cmake-defined-guard
bash hardware/patches/apply.sh
```

`apply.sh` can be run any number of times. [hardware/patches/README.md](hardware/patches/README.md)
lists what each patch changes.

## Hardware

### Synthesis

From the repository root:

```bash
./scripts/synthesize.sh --http --decoders 4                 # the HTTP design
./scripts/synthesize.sh --http --decoders 4 --toe-buffer    # ... with the TCP receive buffer in card memory
```

| option | meaning |
| --- | --- |
| `--http` | the FPGA HTTP client feeding the decoders (`ENABLE_HTTP=ON`, RDMA off). Without it the build is the RDMA design |
| `--decoders N` | number of decoders, one HTTP lane each (default 1) |
| `--toe-buffer` | the TCP offload engine keeps a 1 MiB receive ring per session in card memory instead of one shared receive FIFO; the handler becomes `handler_toe`. Needs `--http` and patches 0007 and 0008 (CMake refuses otherwise) |
| `--cores N` | parallel Vivado jobs (default 64, about 170 GB of memory; use 16 when two builds share a host) |
| `--build-num N` | build into `hardware/build-N` instead of the next free number |
| `--no-rdma` | leave out the RDMA stack (`--http` already does) |

With `--http` and four decoders, the decoders are pinned to SLRs by the floorplan in
`hardware/constraints/` that matches the variant; the build hooks it in automatically
(`ENABLE_DECODER_PBLOCKS`, on by default).

The script spins off the synthesis in the background in a way that the user can disconnect from
the server without the synthesis stopping (tmux session `bitgen-<build directory>`). You can check
the progress in `hardware/build-N/bitgen.log`. It is expected that the synthesis takes multiple
hours to finish, sometimes not printing anything new to the log for a while. The script refuses to
build into an existing directory and records its configuration in `hardware/build-N/PROVENANCE.txt`.

The result is `hardware/build-N/bitstreams/cyt_top.bit`. Read
`hardware/build-N/reports/shell_timing_summary.rpt` before programming a build. Afterwards the
script writes `timing_report.txt`, `utilization_report.txt` and `analysis.txt` into the build
directory and, if `BOT_GMAIL_USER`, `BOT_GMAIL_PASSWORD` and `BOT_RECIPIENT_EMAIL` are set, mails
the analysis.

### Programming the board

Build the Coyote driver once (`make` in `parcore/libstf/coyote/driver`, which writes
`build/coyote_driver.ko` there). On the ETH Zurich HACC cluster, program the FPGA and insert the
driver from the host with the board, using Coyote's script (it needs Vivado on `PATH`):

```bash
cd parcore/libstf/coyote/util
./program_hacc_local.sh <repo>/hardware/build-N/bitstreams/cyt_top.bit \
                        <repo>/parcore/libstf/coyote/driver/build/coyote_driver.ko
```

The extension opens the FPGA when it loads, so program the board before starting DuckDB. The host
library drives the HTTP handlers of both variants (CSR revisions 2 and 6) and refuses an HTTP
bitstream with any other revision at startup.

### Unit tests

To run the unit tests, the Vivado simulation project needs to be set up:

```bash
./scripts/setup_simulation.sh
```

After this is finished, VSCode shows the unit tests as a test flask on the left side. The simulation
project needs to be regenerated whenever new files are added (also for the dependencies).

The HTTP client has standalone benches under `hardware/unit-tests/`, each with its own `run.sh`:
`strip_http` (response framing), `tcp_read` (the receive side of one session), `http_req_stream`
(request text to the TCP transmit path), `handler_multi` (N sessions end to end), `toe_rx` (the
receive side with per-session rings), `lane_drain` (liveness and recovery of both handlers),
`tcp_mem_mux` (the shell's TCP memory multiplexer from patch 0008) and `toe_csim` (C simulation of
the patched TCP offload engine with its receive ring in card memory). Run all of them with:

```bash
hardware/unit-tests/run_all.sh            # or: hardware/unit-tests/run_all.sh tcp_read toe_rx
```

The RTL benches need Vivado's `xsim` (their `run.sh` sources
`/tools/Xilinx/Vivado/2024.2/settings64.sh` if it is not on `PATH`). `tcp_mem_mux` and `toe_csim`
need the patches applied, and `toe_csim` runs Vitis HLS (`VITIS_HLS`, default
`/tools/Xilinx/Vitis_HLS/2024.2/bin/vitis_hls`).

## Software

The software consists of the Oasis software library and a DuckDB extension.

### Oasis library

The Oasis software library has dependencies on the Coyote, libSTF, and ParCore software libraries to
be installed or includes them from the submodules. In case they are not installed already, libSTF
also has a dependency on jemalloc and ParCore on Arrow (see Requirements). The Oasis software
library can be built and installed as follows:

```bash
cmake -S software -B software/build -DCMAKE_INSTALL_PREFIX=$HOME/opt
cmake --build software/build -j
cmake --install software/build
```

Add `-DOASIS_BUILD_TESTS=ON` to the first command to also build `csr_decode_check`, a board-free
check of how the library decodes the HTTP handler's registers: `./software/build/csr_decode_check`.

### DuckDB extension

The DuckDB Oasis extension can be built as follows and requires the Oasis software library to be
installed first:

```bash
export CMAKE_PREFIX_PATH=$HOME/opt
cd extension
make -j
```

This builds `extension/build/release/duckdb`, a DuckDB shell with the extension (and `httpfs`, for
the CPU baselines) built in. It finds the installed libraries at run time through
`LD_LIBRARY_PATH=$HOME/opt/lib`. Building the extension does not rebuild the library: after a
change in `software/`, rebuild and re-install it first. More detail can be found in the
`extension/README.md`.

## Reading Parquet with read_oasis()

The scripts expect the eight TPC-H tables as `/throughput/tpch-<scale>/<table>.parquet`, i.e. in a
bucket `throughput` that allows anonymous reads. Any DuckDB (e.g. the stock CLI) writes them:

```sql
INSTALL tpch; LOAD tpch; CALL dbgen(sf = 1);
COPY lineitem TO 'lineitem.parquet' (FORMAT PARQUET, COMPRESSION SNAPPY, ROW_GROUP_SIZE 122880);
-- ... the same for orders, customer, part, partsupp, supplier, nation, region
```

With MinIO's client: `mc mb <alias>/throughput`, `mc cp *.parquet <alias>/throughput/tpch-1/` and
`mc anonymous set download <alias>/throughput` (the FPGA's requests carry no credentials).

Then, on the host with the programmed board:

```sql
SET http_server = '<object store IP>';
SET http_port = 9000;
SELECT sum(l_extendedprice * l_discount) FROM read_oasis('httpfpga:///throughput/tpch-1/lineitem.parquet');
```

| setting | meaning |
| --- | --- |
| `http_server`, `http_port` | the object store (defaults `127.0.0.1` and 18488). Fixed after the first `httpfpga://` access of a session |
| `httpfpga_debug` | print the HTTP client's state with every request batch to stderr (same as `OASIS_HTTP_DEBUG=1`) |
| `oasis_scheduler_num_streams` | decoders the scheduler uses (0 = all) |
| `oasis_scheduler_queue_depth` | work the scheduler keeps in flight per decoder (0 = the depth of the bitstream's config FIFO) |
| `oasis_scan_groups_in_flight` | row groups a scan keeps submitted (default 16) |
| `oasis_logging_level` | libSTF/ParCore log level (default `ERROR`) |
| `oasis_rdma_server`, `oasis_rdma_port` | the RDMA file server (RDMA mode) |

Environment variables of the library: `OASIS_HTTP_LANE_DEPTH` (column chunks one lane may owe,
default 4), `OASIS_HTTP_MAX_INFLIGHT` (requests per stream, default the bitstream's queue depth),
`OASIS_HTTP_CHUNK_BYTES` (largest GET in bytes, default 0 = one GET per column chunk; the
`--toe-buffer` design also caps every GET at its receive-ring budget), `OASIS_HTTP_BATCH` (one
request batch per row group; the default on single-decoder bitstreams, refused on more),
`OASIS_OBM_BUFFERS` (output buffers per stream, default 64), `OASIS_STALL_DUMP_S` (print a state
dump after that many seconds without progress; 30 by default on `--toe-buffer` bitstreams),
`OASIS_DUMP_DIR` (also write that dump to a file there), `OASIS_EXIT_DUMP=1` (print it at exit).

What runs where:

- Fixed-width columns (BOOLEAN, INT32, INT64, FLOAT, DOUBLE) are fetched and decoded by the FPGA.
  String (BYTE_ARRAY) columns are decoded on the host from bytes fetched over a host socket. Other
  physical types are refused.
- Only SNAPPY and uncompressed files are supported. A decoded column chunk must fit one 8 MiB
  output buffer (about one million 8-byte values per row group).
- `read_parquet('httpfpga://...')` reads over a host socket; the FPGA is not involved.
- A bare `count(*)` is answered from the Parquet footer with the FPGA idle.

## Benchmarks

Both scripts take the object store from `OASIS_SERVER` and `OASIS_PORT` (or `--server`, `--port`;
the default address is the server they were developed against) and use
`extension/build/release/duckdb` (`DUCKDB` overrides it). `-h` prints every option.

- `./scripts/tpch_demo.sh` runs the 22 TPC-H queries on `read_oasis()` views and again on stock
  DuckDB (httpfs and its parquet reader, same objects), compares the answers cell for cell and sums
  the wall clock of both sides. For example
  `./scripts/tpch_demo.sh --scale 30 --single-session --cache metadata --threads 1 --cpu-threads 0`.
- `./scripts/throughput.sh` runs four `lineitem` scans (`--workload latency|q6|q1|wide`), reads the
  decoders' cycle counters around each run, and reports the wall-clock rate, a completeness verdict
  per run and a stock-DuckDB baseline.

## RDMA mode

Without `--http`, the build is the RDMA design: the vFPGA reads the Parquet files over RDMA from
`rdma_server`, which hosts them in a Coyote RDMA memory region (see
[rdma_server/README.md](rdma_server/README.md)). Set `oasis_rdma_server` (and `oasis_rdma_port`)
and read them with `read_oasis('rdma://<file>')`.

## License

The Oasis code is licensed under the terms in
[LICENSE.md](https://github.com/fpgasystems/libstf/blob/master/LICENSE.md), which corresponds to the
MIT Licence. Any contributions to libstf will be accepted under the terms of the same license.
