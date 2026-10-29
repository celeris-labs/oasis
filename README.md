# Oasis -- Data Processing SmartNIC

Oasis offloads Parquet decoding into the network data path. It embeds
[ParCore](https://github.com/celeris-labs/parcore) decoders into a
[Coyote](https://github.com/fpgasystems/Coyote) vFPGA on an AMD Alveo U55C: the FPGA fetches the
Parquet column chunks itself with ranged HTTP `GET`s over Coyote's TCP/IP stack from an
S3-compatible object store such as MinIO, and streams the bodies into four column-chunk decoders,
one TCP session each. The host library (`software/`) plans the requests and collects the decoded
columns, and the DuckDB extension (`extension/`) exposes them as the table function `read_oasis()`.

## Repository layout

| path | contents |
| --- | --- |
| `hardware/` | vFPGA design (`src/`), decoder floorplan (`constraints/`), patches to the submodules (`patches/`), RTL benches (`unit-tests/`), `CMakeLists.txt` for the Coyote build |
| `software/` | the Oasis host library (`oasis/`) and a board-free check (`tests/csr_decode_check.cpp`) |
| `extension/` | the DuckDB extension (`src/`, SQL tests in `test/sql/`); submodules `duckdb` and `extension-ci-tools` |
| `rdma_server/` | the file server for the RDMA design |
| `scripts/` | hardware build (`synthesize.sh`), TPC-H run (`tpch_demo.sh`, queries in `tpch/`), throughput harness (`throughput.sh`), simulation setup |
| `parcore/` | submodule: ParCore, with libstf and Coyote nested in it (`parcore/libstf/coyote`) |
| `celeris/` | submodule: a private repository of the group; builds without `--http` list its hardware sources, the HTTP design does not use it |

## Prerequisites

- Build host: Vivado and Vitis HLS 2024.2, `tmux`, CMake 3.16 or newer, a C++17 compiler, Boost
  headers, and the OpenSSL and libcurl development files. Configuring the extension downloads
  DuckDB's `httpfs` extension from GitHub, so it needs network access.
- Board host: an Alveo U55C on the ETH Zurich HACC cluster (Coyote's programming script uses
  `hdev`), `sudo`, and Vivado on `PATH`.
- Object store: reachable from the FPGA's network port, listening on port 9000, serving anonymous
  ranged `GET`s with `Content-Length` over keep-alive connections (MinIO does). To fill it: MinIO's
  client `mc` and a stock DuckDB CLI with the `tpch` extension.

## Setup

Clone the repository, initialise ParCore and the two submodules the extension build needs, and
apply the patches. Leave out `celeris`, a private repository of the group: the HTTP design does not
use it, and only builds without `--http` list its hardware sources.

```bash
git clone https://github.com/celeris-labs/oasis.git
cd oasis
git submodule update --init --recursive parcore
git submodule update --init extension/duckdb extension/extension-ci-tools
bash hardware/patches/apply.sh
```

libstf refers to its Coyote submodule by an SSH URL. Without an SSH key for GitHub, initialise
ParCore with this instead:

```bash
git -c url."https://github.com/".insteadOf=git@github.com: submodule update --init --recursive parcore
```

Every submodule is pinned to an upstream commit. `apply.sh` checks out Coyote's `dev/tcp` branch and
applies the changes the design needs to ParCore, libstf, Coyote and its TCP stack;
[hardware/patches/README.md](hardware/patches/README.md) lists them. Run it again after every
submodule update; running it twice is safe.

Build and install the host library. It builds Coyote's, libstf's and ParCore's host libraries from
the submodules unless they are already installed, and installs all four into the prefix:

```bash
./parcore/libstf/scripts/install_jemalloc.sh    # once; installs into ~/opt (INSTALL_PATH changes it)
export CMAKE_PREFIX_PATH=$HOME/opt
cmake -S software -B software/build -DCMAKE_INSTALL_PREFIX=$HOME/opt -DOASIS_BUILD_TESTS=ON
cmake --build software/build -j8
cmake --install software/build
./software/build/csr_decode_check               # csr_decode_check: 62 passed, 0 failed
```

`csr_decode_check` checks, without a board, how the library decodes the HTTP handler's registers.
If it stops with `undefined symbol`, an older `liboasis.so` on `LD_LIBRARY_PATH` was loaded first.

Build the DuckDB shell with the extension, in the same shell (`CMAKE_PREFIX_PATH` must point at the
prefix):

```bash
cd extension
CMAKE_BUILD_PARALLEL_LEVEL=8 make
cd ..
```

This builds `extension/build/release/duckdb`, a DuckDB shell with the Oasis extension and `httpfs`
(for the CPU baselines) built in. It finds the installed libraries through its RUNPATH, the
prefix's `lib/`; `LD_LIBRARY_PATH` is searched first, so keep older copies off it. Building the
extension does not rebuild the library: after a change in `software/`, rebuild and install it
first. [extension/README.md](extension/README.md) has the extension's details and tests.

## Object store and data sets

Start MinIO on an address the FPGA can reach, on port 9000, with a one-hour idle timeout:

```bash
MINIO_IDLE_TIMEOUT=1h MINIO_ROOT_USER=minioadmin MINIO_ROOT_PASSWORD=minioadmin \
    minio server <data directory> --address <store IP>:9000
```

The scripts read the eight TPC-H tables as `/throughput/tpch-<scale>/<table>.parquet`. Write them
with a stock DuckDB CLI and upload them (`S=1` here; `S=30` for `tpch-30`):

```bash
S=1; mkdir tpch-$S
{ echo "INSTALL tpch; LOAD tpch; CALL dbgen(sf = $S);"
  for t in lineitem orders customer part partsupp supplier nation region; do
    echo "COPY $t TO 'tpch-$S/$t.parquet' (FORMAT PARQUET, COMPRESSION SNAPPY, ROW_GROUP_SIZE 122880);"
  done; } | duckdb
mc alias set store http://<store IP>:9000 minioadmin minioadmin
mc mb --ignore-existing store/throughput
mc cp tpch-$S/*.parquet store/throughput/tpch-$S/
mc anonymous set download store/throughput
curl --noproxy '*' -s -o /dev/null -w '%{http_code}\n' -r 0-3 \
    http://<store IP>:9000/throughput/tpch-$S/region.parquet      # 206
```

The FPGA's requests carry no credentials, so the bucket must allow anonymous reads. The decoder
reads files written by DuckDB, SNAPPY-compressed or uncompressed, with PLAIN or dictionary
encoding.

## Hardware

### Bitstream

From the repository root:

```bash
./scripts/synthesize.sh --http --decoders 4 --cores 16
```

| option | meaning |
| --- | --- |
| `--http` | the FPGA HTTP client feeding the decoders (`ENABLE_HTTP=ON`, RDMA off). Without it the build is the RDMA design |
| `--decoders N` | number of decoders, one HTTP lane each (default 1) |
| `--cores N` | parallel Vivado jobs (default 64, about 170 GB of memory; use 16 when two builds share a host) |
| `--build-num N` | build into `hardware/build-N` instead of the next free number |
| `--no-rdma` | leave out the RDMA stack (`--http` already does) |

The script configures `hardware/build-N`, records the configuration in
`hardware/build-N/PROVENANCE.txt` and runs the build in a detached `tmux` session, so you can log
out. It refuses to build into an existing directory. The build takes several hours; follow it in
`hardware/build-N/bitgen.log`, which can stay silent for a long time. With `--http` and four
decoders, the floorplan `hardware/constraints/decoder_pblocks.xdc` places the decoders
(`ENABLE_DECODER_PBLOCKS`, on by default).

The bitstream is `hardware/build-N/bitstreams/cyt_top.bit`. Check
`hardware/build-N/reports/shell_timing_summary.rpt` before you program it. At the end the script
writes `timing_report.txt`, `utilization_report.txt` and `analysis.txt` into the build directory and
mails the analysis if `BOT_GMAIL_USER`, `BOT_GMAIL_PASSWORD` and `BOT_RECIPIENT_EMAIL` are set.

Without `--http` the build is the RDMA design: the FPGA reads the Parquet files over RDMA from
`rdma_server` ([rdma_server/README.md](rdma_server/README.md)). Set `oasis_rdma_server` (and
`oasis_rdma_port`) and read them with `read_oasis('rdma://<file>')`. Builds without `--http` also
list the hardware sources of `celeris`, so initialise it first with
`git submodule update --init celeris` (it needs access to the private repository).

### Programming the board

On the board host, from a terminal (the commands need `sudo`), in the repository root. Provide
1 GiB huge pages after every boot; drop the 2 MiB pool first, both count against one limit:

```bash
sudo hdev set hugepages --num-2m 0
sudo hdev set hugepages --num-1g 12
cat /sys/kernel/mm/hugepages/hugepages-1048576kB/free_hugepages   # 12
```

Build the Coyote driver on a host that runs the board host's kernel (the module is refused on any
other kernel), then program the FPGA and insert the driver with Coyote's script. It removes a
loaded driver first:

```bash
(cd parcore/libstf/coyote/driver && make)                          # build/coyote_driver.ko
REPO=$PWD
cd parcore/libstf/coyote/util
./program_hacc_local.sh $REPO/hardware/build-N/bitstreams/cyt_top.bit \
                        $REPO/parcore/libstf/coyote/driver/build/coyote_driver.ko
cd $REPO
```

Then restart the object store: it still holds the connections of the previous bitstream. The
extension opens the FPGA when it loads, so program the board before starting DuckDB.

## Running

On the board host, with the board programmed and the object store restarted:

```bash
export OASIS_SERVER=<store IP> OASIS_PORT=9000 LIBSTF_HUGE_PAGES=10
D=extension/build/release/duckdb
$D -noheader -list -c "SET http_server='$OASIS_SERVER'; SET http_port=9000;
  SELECT sum(r_regionkey) FROM read_oasis('httpfpga:///throughput/tpch-1/region.parquet');"   # 10
$D -noheader -list -c "SET http_server='$OASIS_SERVER'; SET http_port=9000;
  SELECT sum(l_orderkey) FROM read_oasis('httpfpga:///throughput/tpch-1/lineitem.parquet');"  # 18005322964949
```

`LIBSTF_HUGE_PAGES` is the number of free 1 GiB huge pages the library maps (default 4); the scale
30 `wide` workload needs 10.

`./scripts/tpch_demo.sh` runs the 22 TPC-H queries on `read_oasis()` views, then on stock DuckDB
(httpfs and its Parquet reader, same objects), compares the answers cell for cell and sums the wall
clock of both sides:

```bash
./scripts/tpch_demo.sh --scale 1  --single-session --cache metadata --threads 1 --cpu-threads 0
./scripts/tpch_demo.sh --scale 30 --single-session --cache metadata --threads 1 --cpu-threads 0
```

A good run prints `fpga session rc=0   cpu session rc=0` and ends its table with
` pass 22   fail 0   skip 0`.

`./scripts/throughput.sh` runs `lineitem` scans (`--workload latency|q6|q1|wide|all`), three times
on the FPGA and once on stock DuckDB, and reads the decoders' cycle counters around each FPGA run:

```bash
./scripts/throughput.sh --scale 30 --workload wide
```

Each FPGA run gets a verdict, and only `OK` runs count. `wall_MB/s` is the throughput; `intake_MB/s`
is the decoders' rate while they had data:

```
  run 1: hs_total=52334581  wall_MB/s=619.7    intake_MB/s=703.5    decoders=4/4   OK
```

Both scripts take the object store from `OASIS_SERVER` and `OASIS_PORT` (or `--server`, `--port`),
use `extension/build/release/duckdb` (`DUCKDB` overrides it) and print every option with `-h`.

### Settings

| setting | meaning |
| --- | --- |
| `http_server`, `http_port` | the object store (defaults `127.0.0.1` and 18488). Fixed after the first `httpfpga://` access of a session |
| `httpfpga_debug` | print the HTTP client's state with every request batch to stderr (same as `OASIS_HTTP_DEBUG=1`) |
| `oasis_scheduler_num_streams` | decoders the scheduler uses (0 = all) |
| `oasis_scheduler_queue_depth` | work the scheduler keeps in flight per decoder (0 = the depth of the bitstream's config FIFO) |
| `oasis_scan_groups_in_flight` | row groups a scan keeps submitted (default 16) |
| `oasis_logging_level` | libSTF/ParCore log level (default `ERROR`) |
| `oasis_rdma_server`, `oasis_rdma_port` | the RDMA file server (RDMA design) |

Environment variables of the library: `OASIS_HTTP_LANE_DEPTH` (column chunks one lane may owe,
default 4), `OASIS_HTTP_MAX_INFLIGHT` (requests per stream, default the bitstream's queue depth),
`OASIS_HTTP_CHUNK_BYTES` (largest GET in bytes, default 0 = one GET per column chunk),
`OASIS_HTTP_BATCH` (one request batch per row group; the default on single-decoder bitstreams,
refused on more), `OASIS_OBM_BUFFERS` (output buffers per stream, default 64), `OASIS_STALL_DUMP_S`
(print a state dump after that many seconds without progress; off by default), `OASIS_DUMP_DIR`
(also write that dump to a file there), `OASIS_EXIT_DUMP=1` (print it at exit).

## Simulation

From the repository root, with Vivado on `PATH`, create the Vivado simulation project of the
design in `hardware/build-sim` (create it again after adding source files):

```bash
./scripts/setup_simulation.sh
```

The HTTP client has standalone benches under `hardware/unit-tests/`, each with its own `run.sh`:
`strip_http` (response framing), `tcp_read` (the receive side of one session), `http_req_stream`
(request text to the TCP transmit path), `handler_multi` (N sessions end to end) and `lane_drain`
(liveness and recovery of the handler). They need Vivado's `xsim` (their `run.sh` sources
`/tools/Xilinx/Vivado/2024.2/settings64.sh` if it is not on `PATH`). Run all of them with:

```bash
hardware/unit-tests/run_all.sh            # or: hardware/unit-tests/run_all.sh tcp_read lane_drain
```

## Known issues and limits

- Run one DuckDB process at a time: every `duckdb` built here opens the FPGA when it starts, the
  CPU-baseline runs of the scripts included.
- Stop a running query with SIGINT, once (`pkill -INT -x duckdb`), and wait for the process to
  exit. Never `kill -9` a process that has the FPGA open: the driver can hang until the host
  reboots.
- After a failed query (an error, or a lane reported fatal or out of service), program the board
  and restart the object store before the next run. If the first query after programming fails,
  program the board again instead of retrying it.
- The object store must listen on port 9000; other ports did not connect.
- The FPGA keeps its four connections open between queries. MinIO's default idle timeout closes
  them after 30 s, and the reconnects can leave a lane down; hence `MINIO_IDLE_TIMEOUT=1h`.
- Restart the object store after every programming, before the first query: `ss -tan dst <FPGA IP>`
  on the store host must show no connection to the board.
- Fixed-width columns (BOOLEAN, INT32, INT64, FLOAT, DOUBLE) are fetched and decoded by the FPGA.
  String (BYTE_ARRAY) columns are decoded on the host from bytes fetched over a host socket. Other
  physical types are refused.
- Only SNAPPY and uncompressed files are supported. A decoded column chunk must fit one 8 MiB
  output buffer (about one million 8-byte values per row group).
- `read_parquet('httpfpga://...')` reads over a host socket; the FPGA is not involved. A bare
  `count(*)` is answered from the Parquet footer with the FPGA idle.
- The host library drives the HTTP handler's CSR revision 2 and refuses an HTTP bitstream with any
  other revision at startup.

## License

Oasis is licensed under the MIT License, see [LICENSE.md](LICENSE.md). The submodules are separate
projects under their own terms, and `extension/` keeps the DuckDB extension template's license
(`extension/LICENSE`).
