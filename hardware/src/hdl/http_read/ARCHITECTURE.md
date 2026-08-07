# HTTP receive path — architecture decisions

A running record of the choices that shaped `hardware/src/hdl/http_read/`, why they were made, and
what evidence would overturn them. Written down because several of these were re-litigated three or
four times from memory, each time costing a day.

---

## ADR-1 — One persistent connection per request was wrong; the contract is arrival order

**Date:** 2026-08-06 · **Status:** superseded by ADR-3

The Coyote TOE is built with `TCP_STACK_RX_DDR_BYPASS_EN=1`, so there is no per-session receive
buffer: every session shares one `axis_data_fifo_512_d1024` (`tcp_stack.sv:681`, 1024 × 64 B =
64 KB). `rxAppMemDataRead()` pops the **head** of that fifo regardless of which session asked, so
the real contract is:

> `readPkg` must be issued in global **arrival** order across all sessions.

Builds 90/91/92 violated it — `handler.sv` drained slots in *request* order — and wedged. The fix
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

**Lesson recorded deliberately:** the reference implementation of the thing being built was in the
repository the whole time and nobody looked at it. Derivation from the HLS sources produced the
right contract and the wrong architecture.

---

## ADR-2 — The parser must not sit in the TOE's back-pressure path

**Date:** 2026-08-06 · **Status:** accepted, implemented in `b238c4e`

`strip_http` drove `s_axis_rx_data_TREADY` directly, so the TCP stack was told to stop whenever the
HTTP parser was busy. The parser walks header bytes one per cycle — ~550 cycles for a MinIO 206
header — and during that window ~35 KB accumulates in the shared 64 KB fifo at line rate.

**Evidence.** `scripts/sweep.sh`, chunk size swept at fixed depth:

| | 4K→8K | 8K→16K | 16K→32K | 32K→64K | 64K→128K |
|---|---|---|---|---|---|
| depth 1 | 1031 µs/GET | 1014 | 967 | **+10.4 ms/GET** | 339 |
| depth 2 | 907 | 780 | 711 | **+13.8 ms/GET** | **+16.6 ms** |
| depth 4 | 883 | 730 | 750 | **+9.8 ms/GET** | **+10.1 ms** |

The cliff is at the same *chunk size* at every depth — bytes in flight at the breaking point were
64 KiB, 128 KiB and 256 KiB, three different numbers. So it is the size of **one response**, not
bytes in flight, and it lands exactly where a response stops fitting alongside the parser's backlog.

**Decision.** `axis_fifo.sv` between the TOE and the parser. `TREADY` now comes from fifo space.
`rx_fifo_stall` is sticky and reaches the host as `stallWord` bit 25 — if it ever sets, the fifo is
undersized and this decision has been silently undone.

**Rejected:** a faster (parallel CRLF line-skipping) header parser. Measured at 0.3 % of per-request
cost — right measurement, wrong quantity. The parser's cost was never cycles, it was holding
`TREADY` low. Fixing the back-pressure is strictly better and needs no new parser.

---

## ADR-3 — N connections, serialised onto **one** decoder

**Date:** 2026-08-06 · **Status:** accepted

### The measurement that forces it

Per-GET cost is ~800 µs and barely improves with pipeline depth (1020 → 848 → 822 µs for depth
1 → 2 → 4). Two independent methods agree: `scripts/sweep.sh` fits 822 µs, the hardware profiler
reports 799 µs (q1) and 804 µs (wide).

The profiler says *what* is being waited on: **86 % `starved`, 12 % `idle`.** `starved` means the
decoder is mid-column-chunk waiting for network bytes; `idle` is the host round trip between
chunks. So the FPGA is waiting on the wire, not on the host.

And the wire is healthy. `/sys/kernel/coyote_sysfs_0/cyt_attr_nstats` over one run:

```
TCP session cnt: 1          one connection, no reconnects, no port exhaustion
Retrans cnt:     unchanged
TCP TX pkgs:     36,168  /  6,065 GETs = 5.96   (1 GET + ~5 ACKs -- no duplicates)
TCP RX pkgs:     54,536  /  6,065 GETs = 8.99   (33,408 B / 4096 MSS = 8.16 -> 9)
```

Not a single packet more than expected in either direction. The Wireshark retransmissions were
capture artifacts.

**Conclusion:** the ~800 µs is MinIO's service time for a ranged GET, and HTTP/1.1 **serialises it**.
Pipelining guarantees the server answers in order; it does not make it work in parallel. MinIO reads
request 1, answers it fully, then reads request 2. Depth therefore only ever saves the network round
trip, which is what the 1020 → 822 µs measurement shows.

More connections is the only thing that buys real concurrency: N × 32 KiB / 800 µs = **N × 40 MB/s**.

### Why one decoder

Responses must reach the `DataNormalizer` as one continuous stream with exactly one `tlast` — with
`ENABLE_COMPACTOR=0` it accumulates a running byte offset and resets it on `tlast`. So the decoder
side consumes in **request order** regardless of how many connections fetch in parallel.

Given that, N decoders would only help if the decoder were the bottleneck. **It is not, by three
orders of magnitude:** it ingests at 16.0 GB/s (measured: 93.1 MB in 5.82 ms, exactly 64 B ×
250 MHz) and sits at **0.25 % duty** over a query. Adding decoders multiplies a resource that is
idle 99.75 % of the time.

**Decision:** N connections fetch concurrently, each with its own receive fifo and its own
`strip_http` context; an output mux hands completed responses to the single decoder in request
order.

A useful side effect: connection *k+1* parses its header while connection *k* streams its body, so
the 550-cycle header walk is hidden rather than merely moved.

**Cost:** one `strip_http` per connection. The 512-bit 64-way barrel shifter is the expensive part,
but the instances are independent, so this adds area without lengthening any path. Context
save/restore into a shared parser was considered and rejected: it saves area we are not short of, in
exchange for control complexity in the one module whose framing bugs are silent and permanent.

**Buffering:** N × one response. At 32 KiB that is 128 KiB for N=4 — a few URAMs of 960.

### 2026-08-07: build-94 measured, and the cost/benefit has moved sharply

ADR-2 shipped and worked -- the 32K->64K cliff is gone at every depth. That made a 128 KiB default
chunk legal (`29d065b`), and a stray `sleep(1)` in the host's ARP warm-up turned out to be 1.0 s of a
1.36 s fixed per-process cost (`db38b3a`). TPC-H sf1 went **147.1 s -> 40.6 s**, 22/22 still passing,
and effective decoder throughput is now **70-110 MB/s** against the 40 MB/s this ADR was written on.

**This weakens the case for N connections at small scale, and the arithmetic should be checked before
building them.** A lineitem scan at sf1, at the best measured point, now decomposes as:

    total 0.441 s  =  fixed 0.388 s (88 %)  +  all 72 GETs 0.053 s (12 %)

So driving the GET cost to *zero* -- which is the very best N connections could ever do -- is a
**1.14x** win here. Cutting the fixed cost to 0.1 s is **2.9x**. The bottleneck this ADR was written
to attack is no longer the bottleneck at sf1.

Two things must be settled before this ADR is worth implementing:

1. **How far does chunk size go?** For a latency-bound workload, N connections and N-times-bigger
   chunks buy the same thing, and chunk size is free. The floor is one GET per column chunk. If that
   floor is reachable, most of what ADR-3 offers is already available without touching RTL.
2. **Does it still bind at SF30?** There the GET count is ~100x larger and the fixed cost is
   irrelevant, so the answer is probably yes -- but "probably" is what this file exists to prevent.

Related: [[toe-rx-no-demux]] records "bigger row groups are slower". That was measured UNDER the
cliff, where a larger column chunk meant a larger response falling off it. With the cliff gone the
sign may well have flipped, and bigger row groups mean fewer GETs. Re-test before relying on it.

### What would overturn this

- **The decoder stops being idle.** If duty rises above ~50 % after the connection count goes up,
  the serialisation becomes the limit and N decoders start to matter. Watch `duty_pct` in
  `scripts/throughput.sh`.
- **MinIO turns out to serialise across connections too** (a global lock, or disk-bound). Then N
  connections buy nothing and the bottleneck is the server, not us. This is the cheapest thing to
  falsify: the throughput should scale close to linearly with N up to some N, and if it does not,
  stop building.
- **`rx_fifo_stall` sets.** Then the per-connection fifos are undersized and back-pressure is
  reaching the TOE again, which breaks the arrival-order contract for every other session at once.

### Explicitly not doing

- **`RX_DDR_BYPASS_EN=0`** (per-session buffers in memory). A documented FNS build flag, not a fork
  — but the non-bypass path in `tcp_stack.sv` drives a memory channel (`m_tcp_mem_wr_cmd[
  ddrPortNetworkRx]`) and the U55C has HBM, not DDR. Whether Coyote wires that channel on this card
  is an open question for the Coyote authors.
- **`WINDOW_SCALING_EN=0`.** Would make `BUFFER_SIZE` 65,536 — exactly the fifo — instead of the
  262,144 the stack currently advertises against 64 KB of real buffer. Prepared as
  `scripts/synthesize.sh --no-window-scaling`, deliberately not built: once the fifo is drained
  continuously the over-advertisement matters much less, and this would confound the measurement.
  (Note the CMake guard bug that made the flag a no-op was real and is fixed in the Coyote checkout.)
- **`NUM_SLOTS = 8`.** Deeper pipelining on *one* connection cannot help, for the reason above.

### Implementation plan

Done:

- `axis_fifo.sv` and the decoupling in `tcp_read.sv` (`b238c4e`) — ADR-2.
- `rx_dispatch.sv` and its testbench (`7f15616`) — written and verified 10/10, **not yet
  instantiated anywhere**. It is dead code in the build until the steps below land.

Remaining, in order:

1. **Per-connection receive fifos.** One `axis_fifo` per connection, fed from
   `rx_dispatch.conn_tvalid/tdata/tkeep/tlast`. `conn_space_ok[i]` must mean "room for a whole
   MSS" (4096 B = 64 beats), not "room for one beat" — the dispatcher gates `readPkg` issuance on
   it and a packet, once requested, is accepted unconditionally.
2. **N `strip_http` instances**, one per connection, each permanently owning its connection's byte
   stream. Not one shared parser with saved context: the residue at a response boundary is
   mid-beat, so switching parsers between connections would have to save and restore
   `res_data_q`/`res_cur_q`/`res_len_q`/`hs_q`/`body_left_q`, and framing bugs in that module are
   silent and permanent. Side benefit: connection *k+1* parses its header while *k* streams its
   body, so the 550-cycle header walk is hidden rather than moved.
3. **Output mux in request order.** Exactly one `strip_http` output feeds the `DataNormalizer` at a
   time, selected by the handler's `read_ptr`. Everything else buffers. This is what makes one
   decoder correct — see the top of ADR-3.
4. **`handler.sv`: N persistent connections.** Round-robin assignment of requests to connections, so
   response *k* always comes from connection *k mod N* and the mux selector is trivial. The existing
   `CS_DOWN/OPEN/UP/CLOSE` FSM becomes per-connection; reconnect and replay stay per-connection
   (`send_ptr_q <= read_ptr_q` must rewind only that connection's requests).
5. **`http_pipeline_tb`: genuinely concurrent sessions.** The current bench opens one connection at a
   time. Needs a server model that interleaves responses across sessions and announces them
   out of request order — otherwise the arrival-order property is never exercised end to end and the
   test passes on a design that reorders.
6. **Software.** Surface the connection count, `OASIS_HTTP_CONNECTIONS` override, and keep
   `max_inflight() x chunk_bytes()` bounded per connection rather than globally.

Sequencing note: step 3 is the one that can silently corrupt data (wrong stream to the decoder, one
`tlast` too many or too few), so it wants an assertion in the bench that the decoder stream is
byte-identical to the concatenation of the responses in request order — not merely the right length.
