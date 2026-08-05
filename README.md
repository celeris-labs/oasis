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

The HTTP client additionally has standalone `xsim` benches under `hardware/unit-tests/`, each with
its own `run.sh` and no dependency on the Coyote build:

| | |
|---|---|
| `http_pipeline/` | the whole client — handler + session table + init/send/read — against a TOE model serving several concurrent sessions. Checks bodies byte-exact and in order, one `tlast` each, and that request k+1's GET goes out before body k finishes. Runs at 4 slots and at 1 |
| `tcp_read/` | receive path against realistic MinIO responses: multi-segment, back-pressured, unaligned. `case_burst_notifications` announces every segment (and the FIN) before a single `readPkg` is served, which is what pins the one-readPkg-per-announcement contract |
| `http_req_builder/` | the assembled GET, byte for byte, including 64-character paths and multi-beat sends |
| `strip_http/` | header strip in isolation. **4 of its 6 cases currently fail** — the bench drives `strip_http` directly, without the `tcp_read` concatenator that masks per-`readPkg` `tlast`, so its expectations no longer match how the module is used. `tcp_read/` is the authoritative coverage for this module |

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

### Request pipelining (experimental — disabled in software, see below)

> **The host caps itself at one request in flight, and on the TOE we ship it must.** With
> `TCP_STACK_RX_DDR_BYPASS_EN=1` the receive path does not demultiplex sessions *at all*: there is
> one shared packet fifo for the whole stack (`axis_data_fifo_512_d1024 rx_buffer_fifo` in
> `tcp_stack.sv`), `rx_app_stream_if` answers a `readPkg` by echoing back the session id **the
> application asked for** plus a bare one-bit token, and `rxAppMemDataRead` pops one packet from the
> **head** of that fifo without ever looking at the session. The stack's real contract is therefore
> *"readPkg must be issued in the global arrival order of segments across all sessions"* — the head
> is whatever arrived first on the wire and it goes to whoever asks next, wearing that asker's id.
>
> `handler.sv` drains slots in **request** order. With two GETs open to the same server the responses
> interleave, so a slot receives another slot's bytes labelled as its own, the read FSM's accounting
> breaks, it stops issuing `readPkg`, nothing drains the shared fifo, and once occupancy passes 649
> of 1024 beats (~41.5 KB) `rx_engine` answers every further segment on *every* session with
> `ACK_NODELAY` instead of `ACK` — a duplicate ack, so the peer retransmits forever. Builds 90, 91
> and 92 all died this way; the duplicate-ack storm on the wire *is* the wedge, not a separate fault.
>
> So `HTTP_DEFAULT_MAX_INFLIGHT` in `software/oasis/configuration.cpp` is **1**, and
> `HTTPReadConfig::max_inflight()` — not `num_slots()` — is what anything sizing a queue must use.
> Depth > 1 needs a TOE rebuilt with `TCP_STACK_RX_DDR_BYPASS_EN=0`, which gives each session its own
> circular buffer in DDR. `OASIS_HTTP_MAX_INFLIGHT` exists to run exactly that experiment.
>
> The hardware below is correct and stays in the bitstream; only the depth the host uses is pinned.
> The way to recover the per-request dead time on this stack is **fewer, larger requests** (row-group
> coalescing) or **keep-alive**, not concurrency.

The unit of work is one `(row group, column)` column chunk, so a query fetches hundreds of them —
TPC-H Q6 over `lineitem` at sf1 is 4 columns x 49 row groups = 196 ranged GETs to move 48 MB. When
each of those was a full connect / GET / body / teardown cycle with nothing overlapping it, the
per-request round trips dominated: the decoder consumes 64 B/cycle at 250 MHz (16 GB/s, more than
the 100 GbE link can deliver) and spent the overwhelming majority of a query idle between requests.

`handler.sv` is now three concurrent stages over a ring of `HTTP_NUM_SLOTS` (4) request slots:

```
fill_ptr   host START write lands in a free slot          (one cycle, no handshake)
conn_ptr   CONNECT: tcp_init -> session id -> bind slot
send_ptr   SEND:    tcp_send_http builds and transmits the GET
read_ptr   READ:    tcp_read streams the body out, then closes the session
```

Slots advance strictly in order, so the ring needs no free list and the bodies necessarily arrive in
the order the host enqueued them — which matters, because they are concatenated into one decoder
stream. The connect and GET for request k+1 now happen while request k's body is streaming, so the
server's time-to-first-byte overlaps the previous transfer rather than following it.

Two things this depends on:

- **`tcp_session_table.sv` owns the notification stream.** `tcp_read` used to pop notifications and
  discard any whose session did not match the one it was reading. With a second connection open that
  silently loses the announcement for it, and the reader then waits forever for news that already
  came and went. The table queues the announced segment lengths and the FIN per slot instead.
- **One `readPkg` per announcement, naming exactly that announcement's length.** Coyote builds the
  TOE with `TCP_STACK_RX_DDR_BYPASS_EN=1`, so the receive buffer is a shared on-chip *packet* fifo
  rather than a per-session circular buffer in DDR. On that path `rx_app_stream_if` turns a readPkg
  into a bare one-bit token and `rxAppMemDataRead` forwards exactly one queued packet, whatever
  length was asked for; the length is used only to advance the app read pointer the advertised
  window is computed from. Build-90 and build-91 got this wrong — the table kept a running byte
  balance and the reader asked for `min(balance, 32 KB)` — so a single readPkg drained one ~4 KB
  segment while telling the TOE that 32 KB had been consumed. The window ran ahead of reality, the
  shared fifo backed up until `rx_engine` started dropping segments with `ACK_NODELAY`, and the
  decoder sat ~100% starved behind a duplicate-ACK storm. **Do not reintroduce coalescing here.**
- **The host must respect the ring depth.** `ConfigWriteReadyRegister` does not back-pressure: a
  `START` write arriving while the previous one is unconsumed overwrites it and that request is gone
  without a trace. `HttpConfig` read register 10 (`INFLIGHT`) reports occupancy, the scheduler sets
  its HTTP pipeline depth from `max_inflight()`, and `HTTPReadConfig::read` blocks until occupancy
  is below that cap before every request. Both use the cap, not the raw slot count — see the note at
  the top of this section.

Pre-pipelining bitstreams have no `INFLIGHT` register and read it back as zero; the software treats
that as "one request at a time" and keeps the old busy-bit guard, so `build-87` still works
unchanged. Setting `HTTP_NUM_SLOTS` to 1 restores sequential behaviour in hardware if it ever has to
be ruled out — that configuration is covered by the simulation.

**Keep-alive is *not* implemented.** Every request still opens its own connection. The response is
delimited by the server's FIN — `strip_http` finds `\r\n\r\n` and then streams until `tlast`, with no
`Content-Length` parsing and no way to resynchronise mid-beat on a following response's header.
Sharing one connection means byte-exact reframing inside the module that is already the worst timing
path in the design. Pipelining hides the connection cost instead of removing it, for much less risk.

### Row group size

Because one decoded column chunk must fit a single output buffer, the buffer size is a hard cap on
row group size — and therefore on how few requests a query needs. `OBM_BUFFER_CAPACITY`
(`extension/src/include/oasis_context_cache_entry.hpp`) is 8 MiB, which allows roughly 1M rows of an
8-byte type. DuckDB's default 122,880-row groups decode to 960 KiB, so files written with

```sql
COPY tbl TO 'x.parquet' (FORMAT parquet, ROW_GROUP_SIZE 1000000);
```

need ~8x fewer requests for the same bytes. That is the cheapest available reduction in dead time and
needs no resynthesis.

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
| Decoded column chunk | must fit one output buffer (8 MiB), i.e. ~1M rows of an 8-byte type |
| Compression | SNAPPY and uncompressed only — other codecs throw `codec N not supported by ParCore` |
| Requests in flight | **1.** The bitstream advertises `HTTP_NUM_SLOTS` (4), but the shared-fifo receive path in the `RX_DDR_BYPASS` TOE cannot demultiplex sessions, so the host pins itself to one. Connections are not reused |
| NULLs | **not supported.** The decoder is configured from `num_values`, which counts NULLs, but the page only holds the non-null values, so the read hangs waiting for values that do not exist. TPC-H is unaffected (no NULLs) |
| Trailing page bytes | a data page carrying padding past the last declared value hangs the decoder. `fastparquet` emits exactly 8 such bytes per page; DuckDB-written files are fine |

### Ephemeral port exhaustion (unfixed, and it will bite a benchmark run)

Every column chunk is a separate connection, and the TOE has **512 ephemeral ports** — ports
32768–33279, `pt_cursor` wrapping at `TCP_STACK_MAX_SESSIONS`
(`toe/port_table/port_table.cpp`, `toe/CMakeLists.txt:16`). It releases each one the instant the
connection closes, with no quiet time. Because the request says `Connection: close`, the **server**
closes first and therefore holds the 4-tuple in `TIME_WAIT` for 60 s.

Any run that exceeds 512 connections in under a minute reuses a port the server still owns. The
TOE's ISN is random and uncorrelated with that port's previous sequence space
(`tx_engine.cpp:541`), so Linux usually refuses to recycle the `TIME_WAIT` socket and answers with a
challenge ACK. That ACK reaches `rx_engine.cpp:1078`, which writes `clearRetransmitTimer` **one line
above** the state check that excludes `SYN_SENT`, and the timer update zeroes the retry counter
unconditionally (`retransmit_timer.cpp:102`). The retry count never reaches its limit of 4, the SYN
is re-sent at ~1.25 s forever, and `openStatus` is never emitted — so `tcp_init` does not even
report an error, it simply never completes.

Symptoms: the CONNECT stage stalls with no `init_error`. `HttpConfig` read register 11 reports
exactly that, and the host's credit timeout names it. **The port cursor lives in the bitstream, so
the count is cumulative since programming** — restarting DuckDB does not reset it.

No single hand-typed query reaches 512 (49 row groups × ≤8 columns), which is why interactive use
looks fine; a full `scripts/throughput.sh` run needs ~2,500 and crosses the threshold partway
through. The script now estimates the count up front and warns.

What actually helps, in order:

1. **Fewer, larger row groups.** `ROW_GROUP_SIZE 1000000` takes a full benchmark run from ~2,500
   connections to ~350 — under the pool — with no hardware change. This is the only mitigation
   available today.
2. **Keep-alive**, which removes the reuse window rather than delaying it. See above for why it is
   not done yet.
3. **A monotonic ISN** (`tx_engine.cpp:541`) makes a collision survivable rather than fatal, and
   **moving the `clearRetransmitTimer` write inside the state check** turns an infinite SYN retry
   into a reported failure after ~31 s. Both are HLS changes needing a TOE re-run.

Raising `TCP_STACK_MAX_SESSIONS` is *not* a fix: covering a 60 s peer `TIME_WAIT` at ~1 ms per
request needs ~60,000 ports and only 32,768 exist above 32768. A connection-per-request model cannot
outrun that at any pool size.

### When a read hangs

On a pipelined bitstream, `HTTPReadConfig::read` waits for a free request slot and throws after 30 s
with the ring occupancy and the decoded FSM state. A full ring means the pipeline stopped draining:
a response that never arrived, or a connection that never opened. Neither is retried — error
handling in the handler is still minimal, and one stuck request stalls everything behind it. There
is no reset CSR, so reprogramming is the only way out.

On a pre-pipelining bitstream the failure is different: the handler sampled its start trigger only
in `ST_IDLE` as a one-cycle pulse, so a request issued mid-transfer was dropped and never retried,
and the wedge **outlived the process** — every later run inherited it, which reads as "it worked a
minute ago and now nothing does". The busy-bit guard still catches that case.

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