# Oasis -- Data Processing SmartNIC

Oasis is a data processing SmartNIC for cloud-native data lakes. It offloads Parquet decoding into
the network data path. The main components are a hardware design that embeds 
[ParCore](https://github.com/celeris-labs/parcore) into an RDMA-enabled 
[Coyote](https://github.com/fpgasystems/Coyote) vFPGA and a software abstraction for easy 
integration into query engines.

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

## Hardware
The functionality of the hardware component can be verified with unit tests that are built on top of 
the Coyote unit test framework. We also describe how to synthesize the hardware.

### Unit tests
To run the unit tests, the Vivado simulation project needs to be set up:

```bash
./scripts/setup_simulation.sh
```

After this is finished, VSCode shows the unit tests as a test flask on the left side. The simulation
project needs to be regenerated whenever new files are added (also for the dependencies).

### Synthesis
For synthesis, execute the following command:

```bash
./scripts/synthesize.sh [--http] [--no-rdma] [--decoders <number-of-decoders>]
```

`--http` builds the FPGA HTTP client (`ENABLE_HTTP=ON`, and implies `ENABLE_RDMA=OFF`) — see
[HTTP read path](#http-read-path) below.

The script spins off the synthesis in the background in a way that the user can disconnect from 
the server without the synthesis stopping. You can check the progress in `hardware/build-**/bitgen.log`. 
It is expected that the synthesis takes multiple hours to finish sometimes not printing anything new 
to the log for a while.

Each build archives the exact RTL it was synthesized from under
`hardware/build-NN/oasis_config_0/user_c0_0/hdl/`. That archive is the authority on what a given
bitstream actually contains — `CMakeCache.txt` is not, because `hardware/CMakeLists.txt` sets the
build options with plain `set()`, which shadows the cache. Check `build-NN/export.cmake` or the
synthesized `lynx_pkg.sv` instead.

Always read `hardware/build-NN/reports/shell_timing_summary.rpt` before programming a build.

## HTTP read path

With `--http`, the vFPGA issues its own ranged HTTP `GET` for each Parquet column chunk, strips the
response headers, normalizes the body and streams it straight into a `ColumnChunkDecoder` — the
compressed bytes never touch host memory. The host reads decoded, typed output back from stream 0,
exactly as the RDMA flow does.

Use `read_oasis('httpfpga://<path>')` to exercise this. `read_parquet('httpfpga://<path>')` treats
the URL purely as a byte source and parses on the CPU; on an `ENABLE_HTTP` bitstream the raw bypass
stream is tied off, so those reads are served over an ordinary host socket and the FPGA is not
involved at all.

### The CSR map must match the bitstream

`HttpConfig` is a flat register file, and the software map in `software/oasis/configuration.cpp`
must agree with the `HttpConfig` instantiation in `hardware/src/vfpga_top.svh` **register for
register**. There is no version handshake: a mismatched map writes every parameter to the wrong
address, the writes all succeed silently, and the FPGA emits a corrupt request — typically a
truncated `Range:` header containing NUL bytes and fragments of unrelated parameters.

Two consequences worth internalising:

- **Rebuild `software/` after switching branches.** `make` in `extension/` does *not* rebuild the
  Oasis library, so a stale `liboasis.so` silently outlives a branch switch. Run
  `cmake --build software/build -j` and re-install before blaming the hardware.
- **Program the new bitstream before installing a library built for it**, not the other way round.

Builds up to and including `build-88` instantiate `HttpConfig` with `START_ADDR=31` while the
software map places `START` at 39; `HTTP_LEGACY_START` in `configuration.cpp` documents the
write-ordering workaround that keeps both working. `http_config.sv` now carries
`ASSERT_ELAB(START_ADDR > LAST_PARAM_ADDR)`, so that class of mistake fails at elaboration rather
than six hours later on the wire.

### Limits and known gaps

| | |
|---|---|
| GET path budget | 64 characters (16 CSR words). Was 32 up to `build-88`; longer paths throw rather than truncate |
| Decoded column chunk | must fit one output buffer (1 MiB), i.e. a DuckDB-default 122,880-row group of an 8-byte type |
| Compression | SNAPPY and uncompressed only — other codecs throw `codec N not supported by ParCore` |
| Sessions | `HttpConfig` is a single-session FSM, so the scheduler pins HTTP pipeline depth to 1 |
| NULLs | **not supported.** The decoder is configured from `num_values`, which counts NULLs, but the page only holds the non-null values, so the read hangs waiting for values that do not exist. TPC-H is unaffected (no NULLs) |
| Trailing page bytes | a data page carrying padding past the last declared value hangs the decoder. `fastparquet` emits exactly 8 such bytes per page; DuckDB-written files are fine |

### When a read hangs

The handler samples its start trigger only in `ST_IDLE` and the trigger is a one-cycle pulse, so a
request issued while it is mid-transfer is dropped and never retried. There is no reset CSR, so the
wedge **outlives the process** — every later run inherits it and fails the same way, which reads as
"it worked a minute ago and now nothing does". `HTTPReadConfig::read` checks for this before
starting and throws with the decoded FSM state; the only way to clear it is to reprogram.

Set `OASIS_HTTP_DEBUG=1` for a per-stage trace. Read it as:

- `decoder in.hs == 0` — the body never arrived; look at the request and the network
- `in.hs > 0`, `out.hs == 0` — the decoder consumed the body and produced nothing; page-header or encoding problem
- `out.hs > 0` but no result — output was produced but not delivered

Note that `Sent local writes` in Coyote's statistics counts **host**-initiated transfers only. It
reads 0 on runs that deliver correct data; `Notifications received` is the signal that FPGA-initiated
DMA completed.

## Software
The software consists of the Oasis software library and a DuckDB extension.

### Oasis library
The Oasis software library has dependencies on the Coyote, libSTF, and ParCore software libraries to 
be installed or includes them from the submodules. In case they are not installed already, libSTF 
also has a dependency on jemalloc that can be installed with `./parcore/libstf/scripts/install_jemalloc.sh` 
and ParCore currently has a dependency on Arrow 21.0.0 which can be installed with `./parcore/scripts/install_arrow.sh`. 
The Oasis software library can be built as follows:

```bash
mkdir software/build
cmake -S software -B software/build
cmake --build software/build -j
```

If you want to install it to e.g., `~/opt`, you need to add `-DCMAKE_INSTALL_PREFIX=$HOME/opt` to 
the first `cmake` command and execute `cmake --install software/build` after the build.

### DuckDB extension
The DuckDB Oasis extension can be built as follows and requires the Oasis software library to be 
installed first:

```bash
cd extension
make -j
```

More detail can be found in the `extension/README.md`.

## License
The Oasis code is licensed under the terms in 
[LICENSE.md](https://github.com/fpgasystems/libstf/blob/master/LICENSE.md), which corresponds to the 
MIT Licence. Any contributions to libstf will be accepted under the terms of the same license.