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

### Keep-alive and request pipelining

> **One TCP connection carries every request.** It is opened lazily on the first ranged GET and then
> held open across every request and every query; `strip_http` delimits each response by
> `Content-Length` instead of by the server's FIN, which is what makes that possible.
>
> This is not a latency optimisation, it is what makes the client usable at all. The TOE hands out
> ephemeral ports from a pool of exactly 512, by a linear cursor, released with no quiet time and
> **cumulative since the bitstream was programmed** — and `Connection: close` meant the *server*
> closed first, so Linux held each 4-tuple in `TIME_WAIT` for 60 s. A full benchmark run needed
> thousands of connections and wedged partway through. It now needs one.
>
> It also makes pipelining safe again. Depth > 1 used to wedge the receive path, and the reason was
> never the depth — it was concurrent **sessions**. With `TCP_STACK_RX_DDR_BYPASS_EN=1` there is one
> shared packet fifo for the whole stack (`axis_data_fifo_512_d16384 rx_buffer_fifo` in
> `tcp_stack.sv`), `rx_app_stream_if` answers a `readPkg` by echoing back the session id **the
> application asked for** plus a bare one-bit token, and `rxAppMemDataRead` pops one packet from the
> **head** of that fifo without ever looking at the session. The real contract is *"readPkg must be
> issued in the global arrival order of segments across all sessions"*, which a handler draining
> slots in **request** order cannot honour with several connections open. Builds 90, 91 and 92 all
> died that way, and the duplicate-ACK storm on the wire *was* the wedge, not a separate fault.
> **With a single session, arrival order and request order are the same thing**, so the contract
> holds by construction and HTTP/1.1 pipelining over that connection is both legal and safe.

The unit of work is one `(row group, column)` column chunk, so a query fetches hundreds of them —
TPC-H Q6 over `lineitem` at sf1 is 4 columns x 49 row groups = 196 ranged GETs to move 48 MB. When
each of those was a full connect / GET / body / teardown cycle with nothing overlapping it, the
per-request round trips dominated: the decoder consumes 64 B/cycle at 250 MHz (16 GB/s, more than
the 100 GbE link can deliver) and spent the overwhelming majority of a query idle between requests.

**`handler_stream.sv` is what is built today, and it is not a descriptor ring.** `handler.sv` (a
ring of `HTTP_NUM_SLOTS` = 4 slots, each holding a full 1160-bit `http_config_t`) still exists in the
tree and in bitstreams up to build-95, but the depth was an amount of FPGA registers rather than a
design choice: measured on a scale-30 `lineitem` scan that ring was full for 1462 of 1465 requests,
so the host spent essentially the whole query blocked on a slot.

Every byte range is known once the Parquet footer is parsed, so the host now builds all of the GET
text up front and DMAs it in. A request is only text; nothing about it has to be stored on the FPGA.
What still needs a queue is the *column-chunk boundary*, because the host may split one chunk across
several ranged GETs and the `DataNormalizer` resets its byte offset on `tlast`. That is a byte count
per column chunk, so `HTTP_QUEUE_DEPTH` (64, `vfpga_top.svh:139`) scales with columns per row group
rather than with requests.

The host drives it in three steps (`HTTPReadConfig::submit_batch`):

```
1.  one cfg beat per column chunk, req_total_bytes == 0   -> pushes a queue entry
2.  one cfg beat with req_total_bytes != 0                -> latches the server, ARMS the transfer
                                                             (this is what opens the connection)
3.  the request text itself, DMA'd over s_axis_req (Coyote LOCAL_READ)
```

The order is part of the protocol and is not optional — see the comment on `await_cfg_ready`.

There is no `conn_ptr` any more — the connection is a property of the client, not of a request, and
a small FSM beside the ring opens it, holds it, and reopens it if it dies. Slots advance strictly in
order, so the ring needs no free list and the bodies necessarily arrive in the order the host
enqueued them, which matters because they are concatenated into one decoder stream. HTTP/1.1
guarantees responses in request order on one connection, so that ordering costs nothing on the
receive side: `tcp_session_table` is instantiated with a single slot and simply queues the
announcements for that session in arrival order.

The GET for request k+1 goes out while request k's body is streaming, so the server's
time-to-first-byte overlaps the previous transfer rather than following it.

**Reconnect and replay.** A persistent connection still dies — MinIO closes an idle one on its own
timeout. `tcp_read` reports that as an error and the recovery is in the ring: roll `send_ptr` back to
`read_ptr` and every request that was sent but not answered goes out again on the new connection.
The descriptors are still in their slots, so that is the whole fix.

That is only safe while the failure is **clean**, i.e. no body byte of the response being read has
reached the decoder yet. `strip_http` reports `resp_dirty` when it has, and the handler latches a
fatal flag and stalls visibly instead of replaying — replaying would duplicate those bytes in the
column. The host sees it as a stalled read plus the dirty bit in the `STALL` CSR.

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

### Response framing

`strip_http` parses the status line and header block byte by byte, extracts `Content-Length`, counts
the body down and raises `tlast` on the beat carrying its last byte — then keeps the leftover bytes
of that beat and resumes header parsing at the exact byte after the body. On a persistent connection
that is mandatory: body *k* is followed immediately by the status line of response *k+1*, frequently
inside the same 64-byte beat.

One input beat is held in a residue register and consumed through a byte cursor, and everything
reads it through **one** 512-bit barrel shift — the low byte is the next header character, the whole
word is the already-bottom-justified body beat. The 64-wide 32-bit comparator tree that used to
search for `\r\n\r\n` across a 67-byte window is gone, replaced by an 8-bit compare against a
14-byte ROM, so the module that owned the worst timing cluster on the device now has a shorter cone
than before. Header parsing costs ~1 cycle per byte (~200 cycles per response, 0.8 µs); bodies still
move a full beat per cycle.

Two consequences worth knowing:

- **A header block with no `Content-Length` is a hard error.** It cannot be framed, so `resp_error`
  latches and the framer stops rather than guessing. That covers `Transfer-Encoding: chunked`
  without parsing it — a ranged GET of a static object must never produce either.
- **The status code is captured.** A 404 or 416 used to flow into the decoder as if its XML body
  were column data. `HttpConfig` read register 12 now carries the three status digits.

### Splitting a column chunk across several GETs — off by default

**`HTTP_DEFAULT_CHUNK_BYTES` is now `0`: one GET per column chunk, no split.** The split still
exists as a knob (`OASIS_HTTP_CHUNK_BYTES=<bytes>`, no rebuild needed) and 192 KiB is the
known-good fallback, but it is not the default any more.

When splitting is on, `HTTPReadConfig::read` cuts a byte range into GETs of at most that size and
marks only the last one `body_last`, so the whole chunk still arrives as **one** decoder stream with
exactly one `tlast` — the `DataNormalizer` resets its running byte offset on `tlast`, so an extra one
mid-chunk would desynchronise everything after it. The flag rides in `REQ_FLAGS` (register 25,
formerly a dead `num_sessions` field, so the address map did not move). On the streamed path the
boundary is a byte count rather than a flag, so the split is invisible to the hardware either way.

**Why it was turned off.** The split was never a throughput optimisation — it was a host-side cap
against a receive fifo four times smaller than the advertised window, and that mismatch is fixed in
hardware (see *Receive window* below). What remains is cost: a ranged GET takes the object store
roughly the same time whatever its size, and HTTP/1.1 serialises that time — ADR-3 measured per-GET
cost falling only 1020 → 848 → 822 µs across pipeline depth 1 → 2 → 4, because MinIO answers request
1 fully before reading request 2. Splitting a 2 MB column chunk eleven ways pays that fixed cost
eleven times for the same bytes.

**What this has not been measured against yet.** The published size curve (192 KiB → 148 MB/s,
256 KiB → 179, 512 KiB → 294, 1 MiB → 423) is `one_conn_ceiling.sh` — a host raw socket measuring
what MinIO delivers on one keep-alive connection. It is the right shape and the right ceiling, but
it is *not* the FPGA path, which sits at ~0.33 GB/s. The equivalent sweep through the FPGA has not
been run at these sizes, and unsplit column chunks at scale 30 exceed every size on that curve.
Re-run `scripts/sweep.sh` and `scripts/throughput.sh` before quoting a speedup.

**What reports trouble.** `rx_fifo_stall` (the drain stopping, `stallWord` bit 25) with the reconnect
count beside it. There is also a Coyote-side hazard that larger responses make more likely:
`rx_engine` accepts a segment only with >375 beats (24000 B) free while `rx_sar_table` advertises
`(appd − recvd) − 1` and knows nothing about that floor, so an advertised window landing in 1..24000
deadlocks rather than back-pressures. The clamp shipped in build-105 and lives in the `parcore`
submodule — it does **not** survive a `git submodule update`.

### Receive window (fixed in hardware since build-95 — the old text here was wrong for months)

`rx_sar_table.cpp:71` still computes the advertised window from the application read pointer alone
and still has no knowledge of the fifo behind it — grep `rx_sar_table` for `data_count` and you get
nothing. **That stopped mattering when the two numbers were made equal.**

| | value | where |
|---|---|---|
| `WINDOW_SCALE_BITS` | 4 | `toe/toe_config.hpp.in` |
| `WINDOW_BITS` | `16 + 4` = 20 → **1 MiB** advertised | same file, scaling is enabled |
| `rx_buffer_fifo` | `axis_data_fifo_512_d16384` = 16384 × 64 B = **1 MiB** | `tcp_stack.sv:681` |
| `axis_max_data_count` | `16'd16384` | `tcp_stack.sv:544`, `:671` |

So the stack advertises exactly what it can hold. **Anything in this repo still quoting "256 KB
against a 64 KB fifo", `WINDOW_BITS = 18`, `d1024`, or a "~41.5 KB drop threshold" is describing
hardware that has not been built since build-94** — that arithmetic came from `WINDOW_SCALE_BITS = 2`
and a 1024-deep fifo, and both moved.

Raising the window is why chunk size buys throughput at all: 256 KiB → 179 MB/s, 512 KiB → 294,
1 MiB → 423, measured against MinIO. If the window is ever raised again, `rx_buffer_fifo` and both
`axis_max_data_count` literals **must** move with it; the stack advertises `BUFFER_SIZE` regardless
of real free space, so a window larger than the fifo invites exactly the drops it used to cause, and
recovery is go-back-N with out-of-order buffering disabled.

### Row group size

Because one decoded column chunk must fit a single output buffer, the buffer size is a hard cap on
row group size — and therefore on how few requests a query needs. `OBM_BUFFER_CAPACITY`
(`extension/src/include/oasis_context_cache_entry.hpp`) is 8 MiB, which allows roughly 1M rows of an
8-byte type. DuckDB's default 122,880-row groups decode to 960 KiB, so files written with

```sql
COPY tbl TO 'x.parquet' (FORMAT parquet, ROW_GROUP_SIZE 1000000);
```

need ~8x fewer requests for the same bytes.

**This no longer buys what it used to, and it was never free.** Larger row groups were the mitigation
for port exhaustion, which keep-alive removes outright — a whole query now costs one connection
whatever the row group size.

The "bigger row groups are slower" measurement (build-92: 49 → 7 row groups took the `latency`
workload from 3.068 s to 6.0–9.1 s) **was taken under the drop cliff and should not be relied on
now.** It was caused by 1.3 MB chunks living permanently in go-back-N against a 64 KB fifo, and that
fifo is now 1 MiB. Re-measure before quoting it. In either case the GET size is decoupled from the
row group size by the range split above, so pick row groups for decode efficiency and leave the wire
to `OASIS_HTTP_CHUNK_BYTES`.

**The real cap on row groups in flight is host-side and is a deadlock, not a slowdown** — see
*The dispatcher deadlock* below.

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
| Requests in flight | bounded by `HTTP_QUEUE_DEPTH` = **64** column-chunk entries (`handler_stream.sv`), pipelined over one persistent connection. Safe because there is only ever one TCP session. The old 4-slot `handler.sv` ring and the `max_inflight() × OASIS_HTTP_CHUNK_BYTES` bytes-in-flight cap are both gone |
| Receive window | 1 MiB advertised against a 1 MiB fifo — matched, see *Receive window* above. Raising one without the other reintroduces the drops |
| Column chunks in flight | **the binding limit in practice.** 64 hardware queue entries against a scheduler that dispatches 64 flows, and only 2 FPGA output buffers. See *The dispatcher deadlock* |
| Response framing | `Content-Length` only. A response without one (e.g. `Transfer-Encoding: chunked`) latches `resp_error` and stalls rather than misparsing |
| NULLs | **not supported.** The decoder is configured from `num_values`, which counts NULLs, but the page only holds the non-null values, so the read hangs waiting for values that do not exist. TPC-H is unaffected (no NULLs) |
| Trailing page bytes | a data page carrying padding past the last declared value hangs the decoder. `fastparquet` emits exactly 8 such bytes per page; DuckDB-written files are fine |

### The dispatcher deadlock (HYPOTHESIS — not yet confirmed on hardware)

**Status 2026-08-18: this is a candidate explanation for "`tpch_demo` dies half way through",
derived by reading the code plus one wedged-board reading. It has NOT been reproduced or confirmed,
and at least two other mechanisms produce the same symptom** — see *Competing explanations* at the
end of this section. Do not treat it as diagnosed.

What is directly observed, from `scripts/util/http_state.sh` on a board left wedged by a failed run:
`conn=up`, `reconnects=0`, no `dirty_abort`, no `read_timeout`, no `notify_overflow`. What you see is:

```
Invalid Error: FPGA HTTP config port has refused a chunk-length entry for 30s
  [inflight=64/64 conn=up pending; stalled: CONNECT READ(slot 0) rx_fifo_stall]
```

Read `inflight=64/64` as *the 64-entry column-chunk queue is full*, and remember the stall bits are
**sticky** — `CONNECT` latching does not mean the connection is stalled now, it means it stalled once
during the run. The two live readings are the queue occupancy and `rx_fifo_stall`.

Three resources are involved, and they are badly matched:

| resource | depth | set in |
|---|---|---|
| scheduler flows in flight | `min(max_inflight(), maximum_num_enqueued_configs())` = `min(64, 64)` = **64** | `scheduler.cpp`, `default_pipeline_depth` |
| HTTP column-chunk queue | **64** entries | `HTTP_QUEUE_DEPTH`, `vfpga_top.svh:139` |
| FPGA output buffers | **2** | `NUM_BUFFERS_TO_ENQUEUE`, passed as `2` in `oasis_context.cpp:62` |

The `min()` in `default_pipeline_depth` was added to stop the scheduler over-committing the decoder,
but on this hardware `MAX_NUM_ENQUEUED_BUFFERS` is also 64 (`column_chunk_decoder_config.sv:38`), so
**the `min()` is a no-op** and the scheduler still dispatches 64 flows. A flow is one *batch* of
column chunks, not one chunk, so 64 flows routinely need far more than 64 queue entries.

The deadlock is a circular wait on a single thread:

```
dispatch_loop (ONE thread)
  └─ dispatch_to
       ├─ sink->apply()      -> acquire_output_handle() -> ensure_stream_has_buffers()
       │                        ...the ONLY code path that tops FPGA output buffers back up to 2
       └─ source->apply()    -> submit_batch() -> await_cfg_ready()   <-- BLOCKS up to 30 s
```

1. The queue fills, so `await_cfg_ready` blocks the dispatcher.
2. Blocked, the dispatcher cannot acquire another output handle, so **no output buffers are added**.
   `ensure_stream_has_buffers` is called from exactly one site — inside `acquire_output_handle`
   (`output_buffer_manager.cpp:135`). The completion path pops a buffer (`:238`) and never replaces it.
3. The decoder drains its remaining ≤ 2 buffers and then has nowhere to write.
4. It stops consuming → `strip_http` back-pressures → the rx fifo fills (**`rx_fifo_stall`**) → the
   TOE back-pressures → responses stop arriving.
5. Responses are what free queue entries, so step 1 never clears. 30 s later the host throws.

That is why it "fails at a different query each run": what matters is how many column chunks have
accumulated, not which query asked for them. It is also why `--groups` helps — fewer row groups in
flight means fewer chunks, so the queue is less likely to fill while the dispatcher is the only thing
holding the buffer supply open. **`--groups` is a workaround for this bug, not a tuning knob.**

Fixes, in order of how much they address the actual cause:

1. **Replenish output buffers off the dispatcher.** Call `ensure_stream_has_buffers` when a buffer is
   popped in `move_current_buffer_to_handle`, so the FPGA's buffer supply no longer depends on a
   thread that can block on FPGA credit. This breaks the cycle outright and is the fix worth making.
2. **Raise `NUM_BUFFERS_TO_ENQUEUE` above 2.** Widens the window but does not remove the cycle; at
   8 MiB per buffer it also costs real memory. Mitigation, not a fix.
3. **Make the two depths genuinely different.** Bound the scheduler to something well under
   `HTTP_QUEUE_DEPTH` so the dispatcher never blocks in `submit_batch` in the normal case.

### Competing explanations for the same symptom

Every hypothesis below ends in *the decoder stops consuming*, and from there the downstream signature
(`rx_fifo_stall`, back-pressure to the TOE, queue never drains, `64/64`) is **identical**. The stall
bits cannot tell them apart. Do not close this out on the signature alone.

1. **The dispatcher deadlock above.** Predicts: the hung process has its `dispatch_loop` thread
   parked inside `await_cfg_ready`, and the failure tracks the number of column chunks in flight
   (so `--groups` moves it) rather than the query text.
2. **build-103 does not close timing.** WNS **-0.949 ns** on the 250 MHz user clock, 30,719 failing
   endpoints, and 689 of the 1000 worst paths are inside `inst_http_column_chunk_decoder`
   (524 `hybrid_page_decoder`, 113 Snappy `vhsnunzip`). build-102 was -0.436 ns with 200. A decoder
   that violates setup can hang or corrupt data-dependently. Predicts: build-102 survives runs that
   build-103 fails.
3. **A decoder input it cannot handle.** The NULL and trailing-page-bytes limits in *Limits and known
   gaps* both hang the decoder by construction. Predicts: deterministic — the *same* query fails
   every time on the same data.

**Discriminating test, cheapest first:** run the failing suite under `gdb` and look at the thread
backtraces at the hang (1 is confirmed or refuted outright); then repeat the same run on build-102
(separates 2); then check whether the failure is query-deterministic (separates 3). Note
`ptrace_scope` is 2 on `alveo-u55c-04`, so `gdb` must **launch** duckdb rather than attach to it.

Until this is settled, `--groups 4` is a mitigation of unknown mechanism, not a fix.

### Ephemeral port exhaustion (fixed by keep-alive; the mechanism is worth keeping in mind)

The TOE has **512 ephemeral ports** — 32768–33279, `pt_cursor` wrapping at `TCP_STACK_MAX_SESSIONS`
(`toe/port_table/port_table.cpp`, `toe/CMakeLists.txt:16`) — and releases each one the instant the
connection closes, with no quiet time. When every column chunk was its own connection and the
request said `Connection: close`, the **server** closed first and therefore held the 4-tuple in
`TIME_WAIT` for 60 s.

Any run exceeding 512 connections in under a minute reused a port the server still owned. The TOE's
ISN is random and uncorrelated with that port's previous sequence space (`tx_engine.cpp:541`), so
Linux usually refuses to recycle the `TIME_WAIT` socket and answers with a challenge ACK. That ACK
reaches `rx_engine.cpp:1078`, which writes `clearRetransmitTimer` **one line above** the state check
that excludes `SYN_SENT`, and the timer update zeroes the retry counter unconditionally
(`retransmit_timer.cpp:102`). The retry count never reaches its limit of 4, the SYN is re-sent at
~1.25 s forever, and `openStatus` is never emitted — so `tcp_init` does not even report an error, it
simply never completes. A full `scripts/throughput.sh` run needed ~2,500 connections and died
partway through; **the port cursor lives in the bitstream, so the count was cumulative since
programming** and restarting DuckDB did not reset it.

A query now costs one connection, so the pool is no longer reachable in normal use. Two things
survive from this:

- The symptom is still worth recognising: a CONNECT stage stalled with **no** `init_error` means
  `openStatus` never arrived at all, which is this. `HttpConfig` read register 11 reports it and the
  host's credit timeout names it. If it appears now, look at the reconnect count next to it —
  something is dropping the connection repeatedly.
- The two TOE bugs are still there. **A monotonic ISN** (`tx_engine.cpp:541`) would make a collision
  survivable rather than fatal, and **moving the `clearRetransmitTimer` write inside the state
  check** would turn an infinite SYN retry into a reported failure after ~31 s. Both are HLS changes
  needing a TOE re-run, and neither is done.

Raising `TCP_STACK_MAX_SESSIONS` was never the answer: covering a 60 s peer `TIME_WAIT` at ~1 ms per
request needs ~60,000 ports and only 32,768 exist above 32768. A connection-per-request model cannot
outrun that at any pool size — which is why the fix had to be to stop opening connections.

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