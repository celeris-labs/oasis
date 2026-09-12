# HTTP receive path — architecture decisions

A running record of the choices that shaped `hardware/src/hdl/http_read/`, why they were made, and
what evidence would overturn them. Written down because several of these were re-litigated three or
four times from memory, each time costing a day.

## How to read the numbers in this file

**Every measurement carries a date, the bitstream or commit it was taken on, and the method.** A
number without that stamp is not a measurement, and several such numbers survived in this file for
weeks after they had been superseded. When an old number is kept for the record it is marked
*(historical)* and the current value sits next to it.

Two traps produced most of the wrong conclusions recorded here. Both are cheap to avoid and neither
is obvious:

1. **The profiler's `starved` / `stalled` / `handshake` counters run only while a column chunk is
   streaming.** Between chunks the profiler is in IDLE and counts nothing. A decoder that is 80 %
   stalled *in-chunk* can be idle for most of the wall clock. Always cross-check against bytes on
   the wire ÷ query seconds before drawing any conclusion from a percentage.
2. **MinIO's page cache warms across a day.** The same build measured 403 s in the morning and 282 s
   in the afternoon on identical settings (build-104, 2026-08-19). Run every configuration twice,
   report the second, and interleave the arms of any A/B.

A third, found 2026-08-26 and relevant to every FPGA-vs-CPU ratio: DuckDB's
`enable_external_file_cache` defaults to **true**, so the CPU baseline could cache column data in
RAM that the FPGA path structurally cannot. Use `scripts/tpch_demo.sh --cache off` for the parity
number. See `THESIS-MEASUREMENTS.md` in the repo root.

## Status at a glance — 2026-08-26

| | decision | status |
|---|---|---|
| ADR-1 | one persistent connection per request | **superseded**; its *contract* (arrival order) stands and ADR-4 satisfies it |
| ADR-2 | keep the HTTP parser out of the TOE's back-pressure path | **accepted, shipped** in `b238c4e`, holds |
| ADR-3 | N connections serialised onto **one** decoder | **superseded by ADR-4, and several of its numbers were wrong** — see the corrections table |
| ADR-4 | **one TCP session per decode lane** | accepted, implemented in `3edff95`, first bitstream **build-110** (4 lanes, synthesizing 2026-08-26). **Verified in simulation only — no hardware measurement exists yet.** |

---

## ADR-1 — One persistent connection per request was wrong; the contract is arrival order

**Date:** 2026-08-06 · **Status:** conclusion superseded (ADR-4); the contract itself still holds

The Coyote TOE is built with `TCP_STACK_RX_DDR_BYPASS_EN=1`, so there is no per-session receive
buffer: every session shares one packet fifo (`rx_buffer_fifo` in `tcp_stack.sv:681`).
`rxAppMemDataRead()` pops the **head** of that fifo regardless of which session asked, so the real
contract is:

> `readPkg` must be issued in global **arrival** order across all sessions.

**Size note (verified 2026-08-26).** This ADR was written when that fifo was
`axis_data_fifo_512_d1024`, 1024 × 64 B = 64 KB. It is now `axis_data_fifo_512_d16384` = **1 MiB**
(`tcp_stack.sv:681`), matched to a 1 MiB advertised window (`WINDOW_SCALE_BITS = 4`, confirmed in
`rx_engine.cpp` and `tx_engine.cpp`). The contract above is unchanged — it is about ordering, not
capacity — but every capacity number in the original text was four to sixteen times too small.

Builds 90/91/92 violated it — `handler.sv`, the descriptor ring now retired to
`hardware/archive/http_read/`, drained slots in *request* order — and wedged. The fix
taken at the time was to allow only one connection (keep-alive, `00c1c09`), which made everything
correct and hid the actual cause for a week.

**What was wrong with the conclusion:** "readPkg must be in arrival order" does not imply "therefore
one connection". Coyote's own full-throughput receiver runs many sessions and satisfies the contract
trivially, by never buffering and never stalling
(`examples/13_perf_tcp/hw/src/hls/tcp_perf_server/tcp_perf_server.cpp`):

```cpp
if (!rx_notif.empty()) {
    rxNotification notification = rx_notif.read();
    if (notification.length != 0)
        rx_read_request.write(rxReadRequest(notification.session_id, notification.length));
}
```

Read the notification, issue the `readPkg` immediately, consume to `last` under
`#pragma HLS PIPELINE II=1`. No session table, no per-slot queues, no reordering.

`rx_dispatch.sv` (ADR-4) is this contract made explicit: it owns the notification and `readPkg`
handshake for all lanes and hands each lane pre-routed bytes in arrival order.

**Lesson recorded deliberately:** the reference implementation of the thing being built was in the
repository the whole time and nobody looked at it. Derivation from the HLS sources produced the
right contract and the wrong architecture.

---

## ADR-2 — The parser must not sit in the TOE's back-pressure path

**Date:** 2026-08-06 · **Status:** accepted, implemented in `b238c4e`, still holds

`strip_http` drove `s_axis_rx_data_TREADY` directly, so the TCP stack was told to stop whenever the
HTTP parser was busy. The parser walks header bytes one per cycle — ~550 cycles for a MinIO 206
header — and during that window ~35 KB accumulates in the shared 64 KB fifo at line rate.

**Evidence — `scripts/sweep.sh` on build-93 (2026-08-06), chunk size swept at fixed depth,
8 KiB-era defaults *(historical: this is the pre-fix design and the fifo was 64 KB then)*:**

| | 4K→8K | 8K→16K | 16K→32K | 32K→64K | 64K→128K |
|---|---|---|---|---|---|
| depth 1 | 1031 µs/GET | 1014 | 967 | **+10.4 ms/GET** | 339 |
| depth 2 | 907 | 780 | 711 | **+13.8 ms/GET** | **+16.6 ms** |
| depth 4 | 883 | 730 | 750 | **+9.8 ms/GET** | **+10.1 ms** |

The cliff is at the same *chunk size* at every depth — bytes in flight at the breaking point were
64 KiB, 128 KiB and 256 KiB, three different numbers. So it is the size of **one response**, not
bytes in flight, and it lands exactly where a response stops fitting alongside the parser's backlog.

**Decision.** `axis_fifo.sv` between the TOE and the parser. `TREADY` now comes from fifo space.
`rx_fifo_stall` is sticky and reaches the host as `stallWord` bit 25.

**Confirmed on build-94 (2026-08-07):** the 32K→64K cliff is gone at every depth (936 / 508 / 764 µs
per GET where build-93 paid an extra 10.4 / 13.8 / 9.8 ms) and `rx_fifo_stall` never set.

> **2026-08-18 — `rx_fifo_stall` now sets routinely, and the original reading of it is wrong.**
> The bit was documented as meaning "the fifo is undersized and this decision has been silently
> undone". It has a second and far more common cause: the fifo fills because the **decoder** stopped
> consuming, not because the fifo is too small. When the host deadlocks its own dispatcher the
> decoder runs out of output buffers, `strip_http` back-pressures, and this bit sets as a *symptom*
> several links down the chain. That deadlock was real and is fixed (2 output buffers against 64
> dispatched flows; `OASIS_OBM_BUFFERS` now defaults to 64) — see the top-level `README.md`.
>
> Read it as "the drain stopped" and then ask **why**. Only conclude the fifo is undersized after
> ruling out the host side — `inflight=64/64` alongside it points at the deadlock, not at RTL.

**Rejected:** a faster (parallel CRLF line-skipping) header parser. Measured at 0.3 % of per-request
cost — right measurement, wrong quantity. The parser's cost was never cycles, it was holding
`TREADY` low. Fixing the back-pressure is strictly better and needs no new parser.

---

## ADR-3 — N connections, serialised onto **one** decoder

**Date:** 2026-08-06 · **Status: SUPERSEDED by ADR-4.** Kept because its reasoning is still the
reasoning, and because three of its quantities were wrong in ways worth naming.

### What it got right, and this part has held up

Per-GET cost is dominated by MinIO's service time for a ranged GET, and HTTP/1.1 **serialises it**.
Pipelining guarantees the server answers in order; it does not make it work in parallel. Only more
*connections* buy real concurrency. Every measurement since has confirmed this:

- one session, 768 KiB ranged GETs, pipeline depth 1 → 32: **0.287 / 0.431 / 0.435 / 0.444 / 0.446 /
  0.463 GB/s** (`scripts/util/one_conn_ceiling.sh`, on alveo-u55c-04, 2026-08-19). All of the
  pipelining gain is collected by depth 2.
- a plain Linux host issuing the same pattern pays **1.55 ms per request** (2026-08-12). The FPGA's
  1.4–2.0 ms is the same number: the TOE is not losing anything, it is paying MinIO's price.

The wire itself is healthy, and this evidence still stands
(`/sys/kernel/coyote_sysfs_0/cyt_attr_nstats` over one `throughput.sh` run, build-93, 6,065 GETs):

```
TCP session cnt: 1          one connection, no reconnects, no port exhaustion
Retrans cnt:     unchanged
TCP TX pkgs:     36,168  /  6,065 GETs = 5.96   (1 GET + ~5 ACKs -- no duplicates)
TCP RX pkgs:     54,536  /  6,065 GETs = 8.99   (33,408 B / 4096 MSS = 8.16 -> 9)
```

Not a single packet more than expected in either direction. The Wireshark "retransmissions" were
capture artifacts of a mirror port dropping frames.

### Corrections — every number in the original text that is no longer true

| original claim | status | what is actually true |
|---|---|---|
| "per-GET cost is ~800 µs" | **stale, not wrong** | 799–822 µs was measured on build-93 at a **32 KiB** chunk (sweep fit 822 µs, profiler 799 µs q1 / 804 µs wide). At the sf30 working point (768 KiB chunks) the per-GET cost is **~1.4 ms** (2026-08-12). The cost is per *request*, nearly independent of size — which is why bigger chunks win |
| "**86 % `starved`, 12 % `idle`** ⇒ the FPGA waits on the wire, not the host" | **wrong as stated** | that split is *in-chunk only* (trap 1 above). Measured over the whole query at a 192 KiB chunk (2026-08-11): latency workload idle **73 %** / starved 5 % / stalled 21 %; q1 and q6 idle **49 %** / starved 45 % / stalled 5 %; a wide 7-column scan idle **44 %** / starved 48 % / stalled 7 %. Per-request setup is roughly **half** the time, not 12 % of it. Both halves are waiting, which is why concurrency attacks both |
| "the decoder ingests at 16.0 GB/s and sits at 0.25 % duty — not the bottleneck **by three orders of magnitude**" | **wrong** | 16.0 GB/s (93.1 MB in 5.82 ms = exactly 64 B × 250 MHz) is the input **port's line rate** on a burst, not a sustained decode rate. On a real query the decoder ingests **~1.0 GB/s in-chunk** and is **idle 68 % of the wall clock** (2026-08-19). Against one session at 0.46 GB/s that is a factor of **~2.2**, not 1000. The direction of the conclusion survives; the margin does not |
| "N × 32 KiB / 800 µs = **N × 40 MB/s**" | **dead** | it assumed a 32 KiB chunk. Measured on one connection: 192 KiB → 148 MB/s, 256 KiB → 179, 512 KiB → 294, 1 MiB → 423 (2026-08-12). Most of what this ADR wanted from N connections was bought first by a bigger window and a bigger chunk on **one** |
| "N decoders would only help if the decoder were the bottleneck" | **still the right test, new answer** | at one session it is not the bottleneck (1.0 vs 0.46 GB/s). At **three or more** sessions it would be. That is exactly why ADR-4 pairs one lane with one session instead of serialising N sessions onto one decoder |
| "689 of the 1000 worst paths sit inside the decoder" (2026-08-18 note, build-103) | **true of build-103 only** | build-103 closed at WNS −0.949 ns. build-105 is **−0.383 ns** and its largest failing cluster is `inst_handler/inst_tbl` (106 paths), followed by shell network-stack blocks; build-108 is −0.620 ns with the biggest cluster in the shell's HBM width converter. See *Timing* below |

### What is still worth keeping from it

- **Ordering.** Responses must reach a `DataNormalizer` as one continuous stream with exactly one
  `tlast`; with `ENABLE_COMPACTOR=0` it accumulates a running byte offset and resets it on `tlast`.
  This is why bytes may not be interleaved *into a lane* — ADR-4 satisfies it per lane rather than
  by serialising every lane onto one decoder.
- **One `strip_http` per connection, never a shared parser with saved context.** The residue at a
  response boundary is mid-beat, so switching contexts would have to save and restore
  `res_data_q`/`res_cur_q`/`res_len_q`/`hs_q`/`body_left_q`, and framing bugs in that module are
  silent and permanent. It costs area (a 512-bit 64-way barrel shifter each) that the U55C has.
  ADR-4 does exactly this.
- **The side effect is real:** connection *k+1* parses its header while *k* streams its body, so the
  550-cycle header walk is hidden rather than merely moved.
- The **1.14x arithmetic of 2026-08-07** (at sf1, fixed per-process cost was 88 % of a lineitem
  scan, so driving GET cost to zero was worth 1.14x) was correct *at sf1* and is why this ADR was
  not built then. At sf30 the GET count is ~100x larger and the fixed cost is irrelevant — which is
  the condition it named for revisiting, and it has been met.

---

## ADR-4 — One TCP session per decode lane

**Date:** 2026-08-26 · **Status:** accepted; implemented in `3edff95`; first bitstream **build-110**
(`N_DECODERS=4`, `ENABLE_HTTP_MULTI=ON`). **Simulation-verified only — no hardware run yet.**

### The measurement that forces it

| | GB/s | source |
|---|---|---|
| one TCP session, any pipeline depth | **0.463** | `one_conn_ceiling.sh`, 768 KiB GETs, alveo-u55c-04, 2026-08-19 |
| 16 connections | **4.60** | `minio_ceiling.sh`, same day, same host |
| the FPGA, on its one session | **0.33** | decoder counters, build-105 |
| the link | 12.5 | 100 GbE |

The FPGA is at **72 % of what one session can ever deliver**, so everything inside the FPGA competes
for a 1.4x gap while the session count is worth up to 10x. Session count is the only large lever
left.

**Why lanes and sessions in equal number.** The decoder ingests ~1.0 GB/s in-chunk against a session
that delivers 0.46, so one lane covers about two sessions on paper — but it is also idle 68 % of the
wall clock, and the second lane exists to cover *those gaps*, not to add bandwidth. Pairing them 1:1
is the arrangement that needs no arbitration and no reordering: **each lane owns a session, a
decoupling fifo, a framer and a decoder, end to end.** If the decoder's real sustained rate turns
out to be well above 1.0 GB/s, fewer lanes than sessions becomes the better ratio and this decision
should be revisited — that is what M2 in `THESIS-MEASUREMENTS.md` measures.

### What is shared, and how

The TOE has exactly one transmit path and one receive path, so those two are shared and nothing else
is:

- **Transmit — `tx_arbiter.sv`.** `meta → status → data` cannot interleave: `tx_status` is a single
  ordered response stream, so a second announcement made before the first lane's data is pushed
  takes the other lane's reservation. The grant therefore covers a **whole transfer**. Request text
  is a few hundred bytes against a ~1 ms round trip, so serialising it costs nothing measurable.
- **Receive — `rx_dispatch.sv`.** `tcp_read` gains `EXTERNAL_DISPATCH`, where the dispatcher owns the
  notification and `readPkg` handshake and hands each lane **pre-routed bytes in arrival order** —
  ADR-1's contract, enforced in one place. The framer, the decoupling fifo and the response state
  machine are untouched: each lane still sees one ordered single-session byte stream, which is why a
  per-lane `strip_http` needed no new logic.
  `rx_space_ok` reports room for a **whole MSS**, not one beat, because once the dispatcher issues a
  `readPkg` every beat is accepted unconditionally, and a lane short of a full segment would stall
  every other lane.

**The single-session path is unchanged.** Tie `bus_grant` high and leave `EXTERNAL_DISPATCH` at 0
and both modules behave exactly as before, which is what `EN_TCP_MULTI` selects between
(`vfpga_top.svh:32`, `:340`).

**Why the demux moved upstream.** The single-session design demuxes *after* the framer, on one
shared body stream, so a lane busy on a large chunk back-pressures every other lane — its own
comment conceded "the same head-of-line behaviour the single-lane design had". Moving the demux into
the receive path is only worth doing if that goes away, and `http_multilane_tb` test 2 fails the
build if it has not.

### Evidence — simulation, run 2026-08-23

| bench | result | what it covers |
|---|---|---|
| `rx_dispatch` | **10 passed, 0 failed** | arrival-order dispatch, per-lane space gating |
| `tx_arbiter` | **6 passed, 0 failed** | round-robin grant across N claimants of one TOE tx interface |
| `handler_multi` | **15 passed, 0 failed** | N sessions end to end through the handler |
| `http_multilane` | **16 passed, 0 failed** | N responses interleaved **at packet granularity** on one shared rx stream come out correctly framed on their own lanes, and a stalled lane does not stall the others |
| `strip_http` | 20 passed, 0 failed | framer, unchanged by this work |
| `tcp_read` | 11 passed, 0 failed | resume mid-`readPkg`, clean vs dirty abort |
| `http_pipeline` | PASS | single-session path, unchanged |

Read back from each bench's `xsim.log`; re-run with `hardware/unit-tests/<name>/run.sh`.

### Cost, as built

Per lane: one `strip_http`, one session slot, and a **2048 × 64 B = 128 KiB** decoupling fifo
(36 RAMB36). Four lanes cost the 144 RAMB36 that the single-lane 8192-deep fifo used on its own,
because `rx_dispatch` gates each lane on room for one MSS and the fifo no longer has to hold a whole
response. build-105 (one lane) sits at 44.5 % BRAM and 31.9 % LUT on the U55C.

### The host side

The lane count is read **off the bitstream**, not compiled in: `oasis_stream_profile()` emits one row
per decoder and the scheduler's default stream count is `num_decoders()`
(`software/oasis/scheduler.cpp:21`). Synthesize with `scripts/synthesize.sh --multi`.

**`OASIS_HTTP_BATCH=0` is mandatory with more than one lane.** A row-group batch carries one lane for
all its chunks, and those chunks may belong to flows the scheduler placed on different streams;
`emit_batch` throws rather than route a column's bytes into a decoder configured for another column.

**A trap that has already cost a run:** `stream` means two unrelated things — a decode lane
(`req_chunk_dest`, in the CSR) and a host-DMA sink (`localSg::dest`). Under `EN_TCP_MULTI` the
streams *below* the lane count carry request text and only those above it are tied off
(`vfpga_top.svh:32`). Sending a lane's text to a tied-off stream is silent data loss: `tready` stays
high, the bytes are discarded, the DMA reports success, and the armed handler waits forever.

### The CSR read map — revision 2

Registers 0–15 are revision 1 and have not moved; **the write map is frozen** and revision 2 does not
touch it. The full field tables live in `http_config.sv`'s header, which is the normative copy; this
is the shape and the reason for it.

Read `INFLIGHT[31:24]` **first**. It was a literal zero through revision 1 and reads `2` here, and
that byte is the entire compatibility scheme: registers 16–20 do not exist on an earlier bitstream
and reading them there comes back as `resp_error`, not as zeros, while a library that predates the
byte ignores it. Neither side has to be upgraded in step with the other — which is the failure mode
this project keeps paying for, because a bitstream and a host library that disagree about a map fail
*silently*, in both directions.

| id | name | what it carries |
|---|---|---|
| 16 | `LANE_OCC` | chunk entries queued and not yet retired, **one byte per lane** at `[8L+7:8L]`, saturating at 255 |
| 17 | `LANE_READY` | the admission window, **one nibble per lane** at `[4L+3:4L]`: `+0` ARM_READY, `+1` ENTRY_READY, `+2` CONN_UP, `+3` FATAL |
| 18 | `LANE_STATE` | `tcp_read` state at `[4L+3:4L]`, `http_req_stream` state at `[32+4L+3:32+4L]` |
| 19 | `LANE_ERR` | sticky causes, **one byte per lane** at `[8L+7:8L]`: `+0` LANE_DEAD, `+1` DIRTY, `+2` INIT_ERR, `+3` RESP_ERR, `+4` STATUS_BAD, `+5` TX_REFUSED, `+6` READ_TIMEOUT, `+7` RX_FIFO_STALL |
| 20 | `LANE_POLICY` | `[7:0]` revision, `[15:8]` `NUM_CONNS`, `[31:16]` `QUEUE_DEPTH`, `[55:32]` `LANE_STALL_CYCLES`, `[61:56]` its log2 |

Three decisions in that table are load-bearing.

**The stride is fixed at eight lanes, not `NUM_CONNS`.** A host compiled against one bitstream reads
another; a stride that moved with the lane count would reinterpret every field the moment a two-lane
bitstream was swapped for a four-lane one, and reinterpret it *plausibly*. Lanes the bitstream does
not have read zero, and `INFLIGHT[23:20]` says how many are real.

**Both admission bits sit in one register.** They are monotone in the host's favour — only a config
beat the host itself writes can clear either — so a value read is still true when the write lands,
and poll-then-write needs no retry and no lock. Splitting them across two registers would not break
that (monotonicity is per bit) but would cost a second round trip on a path taken once per column
chunk. Note `ARM_READY` stays **low** on a fatal lane that was armed and never sent: check `FATAL`
first, or wait forever.

**`LANE_DEAD` cannot be inferred from anything else.** `rx_dispatch`'s own `dead_q` is cleared when a
session is bound or released — and releasing the session is exactly what `handler_multi` does to a
lane it has just declared fatal. By the time the host polls, `dbg_lane_dead` is back to zero and
`FATAL` is set, so "the head-of-line watchdog discarded bytes out of the middle of this lane's
response" and "this lane failed a read it could not replay" are the same reading. They ask for
different things from the host, so the cause is latched in `handler_multi` at the moment it is true.
`lane_drain`'s `s_e` asserts it on the killed lane and asserts it clear on the survivors.

### What would overturn ADR-4

- **MinIO does not scale in this request shape.** `scripts/util/conn_scaling.sh` measures GB/s *per
  connection* at N = 1…16 with the FPGA's own pattern. If per-connection throughput falls before
  N = 4, the useful lane count is wherever it flattens, and building more lanes is building nothing.
- **Wall time flat with the lanes balanced.** Then the sessions share a bottleneck not modelled here
  — the tx arbiter, the dispatcher, or the server.
- **Wall time flat with the lanes *unbalanced*.** Then it is the host scheduler not spreading flows,
  which is software and cheaper to fix.
- **The decoder turns out to be much slower than 1.0 GB/s.** Then lanes should outnumber sessions.
  Measured by M2 in `THESIS-MEASUREMENTS.md`; note that the counters over-report the output rate,
  since `StreamProfiler` counts a handshake with no `keep` weighting and the software bills every
  handshake at a flat 64 bytes.

Run the A/B on **one** bitstream (`oasis_scheduler_num_streams` 1 vs N, arms interleaved) — never
build-105 against build-110 across a day. `scripts/util/decoder_ab.sh` exists for this and has never
completed a multi-lane arm.

---

## Constraints that are not decisions

These are properties of the Coyote shell and the TOE. They bound every ADR above and none of them
is ours to choose.

### The shared receive fifo has no per-session demux
`RX_DDR_BYPASS` reads are **positional, not addressed**: `rxBufferReadCmd` is a bare `ap_uint<1>`
that pops the fifo head (`toe.cpp:317`). Hence ADR-1's arrival-order contract, and hence
`rx_dispatch` owning the handshake for every lane.

### Lanes are coupled head-of-line — the price of arrival order
**Documented 2026-09-11 · Decision: accepted as a constraint, no change.**

Because every `readPkg` pops the head of one shared fifo, `rx_dispatch` keeps all announcements in a
single arrival-ordered queue and may only ever serve its head. It issues the head's `readPkg` only
when the head's lane has room for a whole MSS, counting segments already requested (`issue_ok_w`,
`rx_dispatch.sv:273-279`; `rx_space_ok`, `tcp_read.sv:322-323`). **When that lane's fifo is full, no
lane is served**: packets for idle lanes queued behind it wait, and one slow decoder paces the whole
receive path.

**It cannot be designed away inside `rx_dispatch`.** Serving a later entry first would hand its lane
the head's bytes (the read is positional) — the failure that wedged builds 90–92. Taking the head with
nowhere to put it would discard bytes the TOE has already ACKed. Under `RX_DDR_BYPASS` the design only
chooses *where* the wait happens.

**Why it costs nothing today — measured 2026-09-11.** A lane's fifo fills only when its bytes arrive
faster than its decoder takes them. On build-117, per-lane delivery is ~150 MB/s (157 / 152 / 144 MB/s
at 1 / 2 / 3 lanes, bounded by MinIO's ~1.4 ms per GET). Decoder intake *with data waiting* —
`hs·64 / ((hs + stalled) · 4 ns)` from the profile counters — is:

| workload | decoder intake | cycles accepted |
|---|---|---|
| `latency` (`l_orderkey`) | 0.53 GB/s | 3.3% |
| `wide` (8 columns) | 1.28 GB/s | 8% |
| `q1` / `q6` (4 columns) | 1.7–1.8 GB/s | 11% |

It is identical at 1, 2 and 3 lanes and at 64 KiB and 256 KiB GETs, so it is the decoder's own rate:
**3.5x to 12x headroom** over delivery. (Compressed input bytes. These supersede the "~615 MB/s" in
`tcp_read.sv`'s `RX_FIFO_DEPTH` comment, which was one column.) A throughput bench of the real
`rx_dispatch` + `tcp_read` + `strip_http` against an ideal TOE puts the receive path at 1–2% occupancy
at those rates.

**Slow is not dead.** The head-of-line watchdog counts only while the head stays blocked on the *same*
connection, and resets the moment that lane regains an MSS of room (`rx_dispatch.sv:433-435`). A slow
decoder holds the head only as long as it takes to drain one segment — ~8 µs at the slowest intake
above, against the 262 µs of `HOL_STALL_CYCLES`. Only a decoder that *stops* for 262 µs has its lane
declared dead.

**When it would start to cost.** When a lane's delivery exceeds its decoder's intake for longer than
its 128 KiB fifo absorbs: a faster or lower-latency server, much larger GETs, or strongly uneven lanes
(one decompressing heavy pages while the others race). Measured on the same bench: with one lane's
sink throttled to 16 B/cycle and 2 lanes running, the other lane lost 20% (33.90 → 27.26 B/cycle) and
the rx bus fell to 80%; at 3 lanes, where 16 B/cycle is close to a fair share, the neighbours were
unaffected. On hardware it would show in the profile counters as `stalled` high on the slow lane while
`starved` rises on lanes whose decoders sit idle.

**Options, if it ever matters**, cheapest first:

- **Deeper lane fifos** — `RX_FIFO_DEPTH` (`vfpga_top.svh:388`). Postpones the stall, does not remove
  it. 2048 → 4096 doubles the absorbable burst and the `readPkg` latency cover (30 → 61 segments in
  flight, 7.7 → 15.6 µs at line rate), for ~32 RAMB36 more per lane (build-117: 96 RAMB36 for three
  lanes at 2048).
- **Host-side pacing** — never have more bytes outstanding on a lane than its fifo holds. Removes the
  coupling, but by Little's law caps a lane at ~128 KiB / 1.4 ms ≈ 94 MB/s, below the 157 MB/s it
  achieves today. Not worth it.
- **Per-session TOE buffering** — `RX_DDR_BYPASS_EN=0` (below). The only change that removes the
  coupling, at the price of every received byte going through HBM.

Bench: `hardware/unit-tests/rx_perf/` (`./run.sh` full sweep; `./run.sh lanes N SLOW=1 SLOWDIV=4` for the
slow-lane coupling case; `TOE_GAP=1` for the board's one-idle-cycle-per-packet TOE shape).

### The `rx_engine` window cliff — a Coyote bug, worked around in our checkout
`rx_engine.cpp:1295` (the `RX_DDR_BYPASS` branch) accepts a segment only when
`(rxbuffer_max_data_count - rxbuffer_data_count) > 375` beats — **24,000 bytes** — while
`rx_sar_table.cpp` advertises `(appd - recvd) - 1`, which knows nothing about that floor. Any
advertised window between 1 and 24,000 bytes therefore invites the peer to send bytes the receiver
will drop: dup-ACK storm, go-back-N, up to ~13 s of dead air per event. The signature is
unmistakable — `Ack` climbs by exactly the bytes acked while `Win` falls by the same amount.

Confirmed by four captures each bracketing the threshold: (20144, 24240), (22528, 30720),
(20896, 24992), (22240, 26336); the intersection contains 24000.

**Fix, written 2026-08-19 and shipped in build-105:** clamp the advertised window to **zero** below
`375 × 64 + MSS` (`rx_sar_table.cpp:87`, verified present 2026-08-26). Zero is a state TCP handles
correctly — persist-timer probes every ~200 ms and resumes; a small non-zero window is fatal.
**The Coyote submodule is dirty because of this** and the change will not survive
`git submodule update`. Upstream Coyote should hear about it.

Its effect is **not isolated**: build-104 already passed 22/22 without it, so it is a
throughput/robustness change, not the correctness fix. The correctness fix was two host-side bugs
(the dispatcher deadlock).

### `RX_DDR_BYPASS_EN=0` is wired on the U55C — this was recorded as an open question and it is not
Traced 2026-08-10: `tcp_stack` → `m_tcp_mem_wr_cmd[ddrPortNetworkRx]` → `network_stack` →
`network_top` → `net_mem_intf #(.ENABLE(1))` → `m_axi_tcp_ddr` → `axi_stripe` → `axi_mem[0]` (HBM),
generated under `{% elif cnfg.en_tcp %}` in `hw/templates/common/shell_top_tmplt.txt:888` — our exact
config. Two changes would flip it: `TCP_STACK_RX_DDR_BYPASS_EN 0` in `toe/CMakeLists.txt`, and the
`RX_DDR_BYPASS_EN` parameter on `tcp_stack` (defaults 1, no instantiation overrides it).

Not doing it: ADR-4 obtains per-lane buffering without touching the shell, and this would put every
received byte through HBM. What ADR-4 does *not* obtain is lane independence — the lanes stay coupled
head-of-line through the shared fifo (see above), and this is the only change that would remove that.

### Window scaling stays on
`WINDOW_SCALE_BITS` is 4, so the stack advertises 1 MiB, and `rx_buffer_fifo` is `d16384` = 1 MiB to
match. **These two move together or not at all.** Turning scaling off would make `BUFFER_SIZE`
65,536 and cost throughput for nothing — measured, one connection: 256 KiB → 179 MB/s versus
1 MiB → 423 MB/s. The flag still exists as `scripts/synthesize.sh --no-window-scaling`.

### Deeper pipelining on one connection is not a lever
Depth beyond 2 is worth nothing (0.431 → 0.463 GB/s from depth 2 to 32) and at constant bytes in
flight **smaller-and-deeper is strictly worse**: 1 × 192 KiB beat 4 × 64 KiB by 1.21x (30.05 s vs
36.51 s, 2026-08-10), and 64K × 4 is 2.2x slower than 192K × 1. Bound in-flight **bytes**, never
in-flight requests.

---

## Timing

Recorded from each build's `analysis.txt`. **None of these bitstreams closes timing**, which matters
because a design that does not close can fail data-dependently: reproduce any intermittent,
query-dependent fault on the cleanest available bitstream before blaming the network or the host.

| build | WNS | largest cluster of failing paths |
|---|---|---|
| build-103 | −0.949 ns | `inst_http_column_chunk_decoder` (524 in `hybrid_page_decoder`, 113 in Snappy `vhsnunzip`) |
| **build-105** | **−0.383 ns** | `inst_handler/inst_tbl` (106 paths), then shell network-stack blocks (`mac_ip_encode`, `arp_server`, `rx_buffer_fifo`) |
| build-108 | −0.620 ns | shell HBM width converter (`inst_int_hbm/.../axi_downsizer_inst`) |

build-105 utilisation, for scale: LUT 31.9 %, FF 25.8 %, BRAM 44.5 %, URAM 10.3 %, DSP 0 %.

---

## Status as built

| piece | state |
|---|---|
| `axis_fifo.sv` + decoupling in `tcp_read.sv` | shipped `b238c4e` (ADR-2) |
| `rx_dispatch.sv` | **instantiated** via `handler_multi` under `EN_TCP_MULTI` (was dead code until `3edff95`) |
| `tx_arbiter.sv` | shipped `3edff95` |
| per-lane `strip_http` + per-lane decoupling fifo | shipped `3edff95` |
| `handler_multi.sv` (N persistent sessions) | shipped `3edff95`, and now the **only** HTTP client. The single-session `handler_stream.sv` and its `tcp_session_table.sv` followed the descriptor-ring `handler.sv` into `hardware/archive/http_read/`; `EN_TCP_MULTI` off is an elaboration error |
| concurrent-session testbench | `http_multilane_tb` — interleaves responses at packet granularity, 16/16 |
| host lane count | read from the bitstream (`num_decoders()`); `scripts/synthesize.sh --multi` |
| **hardware measurement of ADR-4** | **does not exist.** build-110 is the first bitstream; the A/B is M4 in `THESIS-MEASUREMENTS.md` |

**Not built, and deliberately:** the ADR-3 output mux that serialised N connections onto one decoder.
Step 3 of its plan was the one that could silently corrupt data; pairing lanes with sessions removes
the need for it entirely.
