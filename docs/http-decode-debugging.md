# HTTP → ColumnChunkDecoder → host: debugging notes

Findings from bringing up `read_oasis('httpfpga://...')` on **build-87** (`ENABLE_HTTP=ON`,
`N_DECODERS=1`), tested on `alveo-u55c-04` against MinIO at `10.253.74.74:9000`.

Status: **the FPGA fetches, receives and decodes correctly. The decoded data never reaches the
host.** Everything up to and including the ColumnChunkDecoder is verified working. One break
remains, in output delivery.

## Verified working

Each of these is backed by a measurement, not inspection.

| Layer | Evidence |
|---|---|
| Bitstream config | synthesized `lynx_pkg.sv` has `` `define EN_TCP ``, `N_STRM_AXI = 2`, `EN_STRM = 1` → `NUM_STREAMS=2`, `NUM_DECODERS=1`, `BYPASS_ID=1`. No index collision with `axi_out[0]`. |
| Decoder present | 84k LUTs / 123k FFs of `inst_http_column_chunk_decoder` in the utilization report |
| Request build | echo CSRs read back `path_len=31`, `range=[4,492587]`, correct IP/port — parameters latch, and the read-before-START barrier holds |
| Path guard | throws at 33 characters instead of silently truncating |
| TCP + GET | Wireshark: correct ranged GET from the FPGA's own IP, 698-byte response |
| Body integrity | the small file's 57 bytes decode as a valid Thrift page header: `DATA_PAGE`, `uncompressed=46`, `compressed=40`, `num_values=4`, `PLAIN` — 17-byte header + 40 Snappy = 57, exactly `total_compressed_size` |
| Handler | returns to `IDLE`, `busy=0`, `sid` increments, zero error bits |
| `strip_http` + `DataNormalizer` | `decoder in.hs = 7697` × 64 B = 492,608 ≈ the 492,584-byte chunk (7696 full beats + 40-byte tail). **The body arrives intact.** |
| ColumnChunkDecoder | `decoder out.hs = 15360` × 64 B = 983,040 B = **122,880 int64** = exactly one DuckDB row group. `stalled=0`. **Decodes correctly.** |

## The remaining break

`OutputWriter` never issues a host DMA:

```
Sent local writes:      0
Notifications received: 0
Page faults received:   0
```

It accepts all 15360 beats without ever back-pressuring (`out.stalled=0`) and discards them.
Zero writes *and* zero page faults means it never attempted a transfer at all — so stream 0 has no
destination buffer programmed. The scan then parks forever, because nothing on this path has a
timeout.

### Leading hypothesis

The raw-bypass flow that used to deliver data (build-85) wrote to **stream 1, unmanaged**, via
`acquire_output_handle(stream, size)` with the transfer size known up front. `read_oasis` writes to
**stream 0, managed**, via the mask overload `acquire_output_handle(mask)`, where
`OutputBufferManager` pre-allocates speculatively. Those are different code paths, and the managed
one may never have run on an `EN_TCP` bitstream.

See `computeManagedStreams()` in `software/oasis/oasis_context.cpp` and the two overloads in
`parcore/libstf/software/libstf/output_buffer_manager.{hpp,cpp}`.

### Open question that halves the search

Has `read_oasis` ever returned data on **any** bitstream (RDMA or local file)? If no, this is not an
HTTP bug — it is the managed-stream output path in general. `hardware/build-67` is the only non-HTTP
build with a bitstream (`EN_TCP=0 EN_RDMA=1`) and can answer this by reading a local file.

## Ruled out — do not re-investigate

- **`strip_http` timing.** Build-87 does not meet timing (WNS `-0.876 ns`, 686 failing paths in
  `inst_tcp_read/inst_strip_http`), but the input byte count matches the chunk size exactly, so the
  data path is currently intact. Real, but not this bug.
- Network / proxy / ARP — `arp=0x4a4afd0a` is correct for `.74`
- HTTP protocol, including 206-vs-200: `strip_http` does no status-code matching, it hunts `\r\n\r\n`
- Decoder configuration and decode logic
- Partial / sub-databeat transfers — 15360 full beats is the opposite case
- Degenerate metadata — `INT64 / SNAPPY / num_values=4 / total_compressed_size=57` are all sane
- `EN_TCP` / `N_STRM_AXI` / `EN_STRM` misconfiguration
- Host DMA — unused on this path, and absent from the bitstream by design

**No resynthesis is required to fix the remaining bug.**

## Traps that cost time

- **`CMakeCache.txt` lies.** It showed `EN_TCP=0`, `N_STRM_AXI=1`; the build actually used `1` and
  `2`. `hardware/CMakeLists.txt` sets them with plain `set()`, which shadows the cache. Trust
  `build-NN/export.cmake` and the synthesized `lynx_pkg.sv` instead.
- **The progress bar SIGFPEs** while a query is parked, which looks like a crash in extension code.
  Always `SET enable_progress_bar=false` when debugging a hang.
- **`read_oasis` on a local file cannot work on an `ENABLE_HTTP` bitstream.** `axis_host_recv` is
  tied off and `gen_decoders` is compiled out (`vfpga_top.svh`), so there is no host→decoder path.
  It used to hang with no diagnostic; it now throws.
- **Bare `count(*)` never touches hardware** — `emit_cardinality_only` answers from the footer.
- **`ptrace_scope=2`** on the alveo nodes, so `gdb` cannot attach. Use a core dump
  (`ulimit -c unlimited`, then `Ctrl-\` — SIGINT does *not* dump core).
- **Profiler counters reset per column chunk.** Mid-transfer samples are partial and must be summed.
- `LD_LIBRARY_PATH` must include `.local/lib` before `$PREFIX/lib`, or a stale `liblibstf.so`
  produces `undefined symbol ...userMapEPvji`.

## Instrumentation added

All gated on `OASIS_HTTP_DEBUG=1`, since `read_oasis` fires requests from a scheduler thread with no
DuckDB logging in reach — a request that never left was previously indistinguishable from a response
that never came back.

- `HTTPReadConfig::read()` — post-START trace: request, echoed-back parameters, decoded FSM status
- `HTTPReadConfig::describe_status()` — unpacks the `totalWord` CSR into per-sub-FSM fields
- `HTTPSourceOperator::apply()` — re-samples handler state *and* decoder in/out stream counters at
  200 ms / 1 s / 5 s, then dumps Coyote's shell statistics (`Sent local writes`,
  `Notifications received`, `Page faults`)

## Known limits (not bugs)

- **GET path ≤ 32 characters** (`HTTP_FILE_WORDS=8`). Throws rather than truncating. The real
  ceiling is lower: `http_req_builder` assembles into a fixed 128-byte buffer with **no overflow
  detection**, of which 65 bytes are fixed header, leaving 63 for path + IP + range. Widening
  `fileWord0..N` past that needs the buffer widened too, or you get silent aliasing.
- `HttpConfig` is a single-session FSM, so `pipeline_depth` is pinned to 1 for HTTP
  (`default_pipeline_depth()` in `software/oasis/scheduler.cpp`).
- `HTTPFileSystem` issues one `HEAD` per open because `known_file_size` is cached on the handle, not
  the path — ~6 per query. Wasteful, harmless, unrelated to any of the above.
