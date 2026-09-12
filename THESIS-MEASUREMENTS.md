# Thesis measurements — open questions, and the ledger of what is already known

Working document. Three questions were open (M1 network ceiling, M2 decoder utilisation,
M3 end-to-end throughput) plus M4, multi-decoder scaling. **M4 is now answered — see M8**, not by
build-110 (which never finished routing) but by build-119. M1 and M2 are answered in the negative:
neither the network nor the decoder is the binding constraint (M8.3). M3's absolute numbers are
superseded by M8.1.

**Each experiment states its decision rule BEFORE the run**, so the result is falsifiable rather
than reassuring. Paste raw output under "Result" and we read it against the rule.

State as of **2026-09-12**. Every build the older sections refer to is listed here too, so a number
found in §0 or M1–M7 can be traced to the shape it was measured on:

| | bitstream | lanes | sessions | note |
|---|---|---|---|---|
| **citable** | **build-119** | **4 decoders** | 4 TCP | **775.3 MB/s = 3.76x one lane**, order-cancelled; 22/22 at sf30. See **M8** |
| equal to it | build-118 | 4 decoders | 4 TCP | 118 vs 119 differ by 0.8 %, inside noise — the `axis_skid` slice bought nothing (M8.5) |
| in flight | build-120 | 4 decoders + TODO 1 | 4 TCP | launched 13:10, **still in bitgen at 19:32 — no bitstream, no hardware number** |
| earlier | build-117 | 3 decoders | 3 TCP | WNS -0.849 ns, the last build that met timing comfortably |
| superseded | build-105 | 1 decoder | 1 TCP | the reference every number in §0 and M1–M7 was taken against |
| never completed | build-110 | 4 decoders | 4 TCP | M4's subject; abandoned in routing. **M4 was never answered by 110** — it is answered by M8 |

---

## 0. The ledger — every measurement so far that bears on these three questions

> ### ⚠️ CORRECTIONS from the session of 2026-09-12 — these supersede the 08-27 block below
>
> | claim | status | superseded by |
> |---|---|---|
> | **"chunk size buys +33 %"** (579 → 642 → 732 → 770 MB/s across 0 / 256K / 512K / 1M) | **CONFOUNDED — strike it.** The sweep ran in a single increasing-chunk order, so throughput tracked *run order*, i.e. MinIO cache warmth. The tell: the last setting issued 18x more and 17x smaller GETs and was still "fastest". An order-cancelling A/B reverses the sign. | **M8.4** |
> | **the per-GET cost model** (`451 µs fixed + 4.4 ns/byte`) | **RETRACTED.** Fitted to three collinear, time-ordered points, and `dead_us_per_get` is not additive — GETs pipeline, so per-GET dead time never sums to wall time. The fit predicted 707 ms of overhead against a 115 ms actual window. | — |
> | **the `lane_depth × chunk_bytes ≤ 256 KiB` budget rule** (2026-09-06) | **LIFTED.** The readPkg reservation is now hardware-verified with correct sums at depth 4 × 256 KiB = 1 MiB per lane. | **M8.4** |
> | §0.4 rule 2, **"run every configuration twice and report the second"** | **NOT SUFFICIENT** for anything compared across settings. Two runs in a fixed order still ride the cache ramp. Any A/B or sweep must alternate or palindrome its arms. | **§0.4 rule 9** |
>
> **Read M8 before quoting any throughput number in this document.** Everything in §0 and M1–M7 was
> measured on **build-105, one decoder**. The design is now four decoders and the absolute numbers moved.

> ### ⚠️ CORRECTIONS from the session of 2026-08-27 — read before using anything below
>
> Four entries in this ledger are now known to be wrong or misleading. They are struck here and
> superseded in the M-sections named.
>
> | ledger claim | status | superseded by |
> |---|---|---|
> | **"FPGA on one session: 0.33 GB/s = 72 % of the 0.463 the session can deliver … everything inside the FPGA competes for a 1.4x gap"** (§0.1, called "the single most important number here") | **WRONG — strike it.** The FPGA is at **97–99 %** of what one connection delivers *at its own request size*. The 1.4x gap was an artefact of comparing against a ceiling measured at 768 KiB while the design issues 187–279 KiB requests. There is no in-FPGA headroom. | **M3.1** |
> | **"16 connections → 4.60 GB/s"** (§0.1, 08-19) | **Cold-contaminated.** Warm, the same script gives **9.07 GB/s**. Server-side page cache is a 40x variable at 16 streams. | **M1.2** |
> | **"in-chunk ingest ~1.0 GB/s"** (§0.2, 08-19) | Column-dependent, not one number: **0.469 / 0.797 / 1.141 GB/s** input for copy-heavy / high-encoding-ratio / literal-heavy columns. | **M2.1** |
> | **"chunk size is a software constant, so a knee at 2–4 MiB is free throughput"** (M1.3 premise) | **Not free — unreachable.** Total receive buffering is 1.5 MiB and a single response above that deadlocks. Usable ceiling stays 0.43–0.48 GB/s on one session. | **M1.3, M7** |
>
> **One rule is added to §0.4:** *the server's page cache dominates every network number.* Cold vs
> warm is 0.16 → 0.78 GB/s on one stream and 0.23 → 9.07 GB/s on sixteen. Warm the object
> explicitly before any run; the existing rule 2 covered DuckDB's cache, not MinIO's.

### 0.1 What the network gives (this is the constraint everything else is measured against)

| date | what was measured | result | method |
|---|---|---|---|
| 08-19 | **one TCP session, FPGA request shape** (768 KiB ranged GETs, keep-alive) | depth 1 **0.287** GB/s, 2 **0.431**, 4 0.435, 8 0.444, 16 0.446, 32 **0.463** | `scripts/util/one_conn_ceiling.sh`, raw socket, on alveo-u55c-04 |
| 08-19 | one session, one huge 256 MiB read | **0.58 GB/s** | easiest possible case for the server — an upper bound on "one request" |
| 08-19 | **16 connections** | **4.60 GB/s** | `scripts/util/minio_ceiling.sh` (256 MiB curl reads) |
| 08-11 | connection scaling, 256 MiB reads | 1→0.789, 2→1.024, 4→1.989, 8→3.250, 16→3.555 GB/s | same from the build node and from alveo — "saturates at 8" |
| 08-12 | **chunk size vs throughput**, one connection, fixed bytes in flight | 32K×8 42.9 MB/s · 64K×4 68.1 · 128K×2 137.3 · 192K×1 148.2 · 256K×1 179.3 · 512K×1 293.6 · 512K×2 384.1 · **1024K×1 423.1** | throughput is ~linear in chunk size; depth is **harmful** |
| 08-10 | request SIZE vs COUNT at constant bytes in flight | 1×192 KiB beats 4×64 KiB by **1.21x** (30.05 s vs 36.51 s) | valid A/B — the CPU column moved 0.02 s |
| 08-12 | fixed cost of one GET | **~1.4 ms** at sf30 (~730–800 µs in the sf1 era) | independent of size ⇒ pure time-to-first-byte |
| 08-12 | same request pattern from a plain Linux host | **1.55 ms/req** | the TOE is not losing anything; we pay MinIO's price like everyone else |
| 08-10 | ceiling as an equation | `window / latency` = 256 KiB / 730 µs = 359 MB/s | window is 1 MiB since build-97 |
| — | link | 12.5 GB/s (100 GbE); MinIO tops out at ~4.6 | the server, not the wire, is the limit |
| 09-12 | **RTT host → MinIO**, first time measured | **0.092 / 0.135 / 0.292 ms** (min/avg/max) | `ping -c 200` from the deploy node |
| 09-12 | **BDP bound `W/RTT`** | **7.77 GB/s** with W = 1 MiB (the TOE's `rx_buffer_fifo`), or **1.94 GB/s** per lane | derived; `TCP_STACK_RX_DDR_BYPASS_EN=1` gives ONE buffer shared across all lanes |
| 09-12 | what MinIO actually is | a **single-process dev deployment** — `serve_tpch.sh:95` runs `minio server /local/home/jkreissl/minio-data`: one process, one directory, one node, no erasure sets | its 4.60 GB/s over 16 streams is unremarkable for that shape, and is probably page-cache-served (4 GiB read out of a ~6.2 GB object), so it measures MinIO's Go HTTP path, not storage |

**FPGA on one session: 0.33 GB/s = 72 % of the 0.463 the session can deliver.** Everything inside
the FPGA therefore competes for a **1.4x** gap. That is the single most important number here.

### 0.2 What the decoder does

| date | what | result |
|---|---|---|
| — | raw ceiling of the input port | 64 B × 250 MHz = **16.0 GB/s**; measured once at exactly that (93.1 MB in 5.82 ms) at 0.25 % duty |
| 08-19 | **in-chunk ingest rate, real query** | **~1.0 GB/s**, `in_stalled` **79.8 %**, and **idle 68 % of wall clock** |
| 08-19 | **Snappy bypassed** (uncompressed copy of `l_quantity`, same bytes on the wire) | `in_stalled` 79.8 → **82.3 %**, rate 1.01 → **1.02 GB/s** ⇒ **the decompressor is exonerated** |
| 08-11 | profiler split at 192 KiB chunk | latency: idle 73 % starved 5 % stalled 21 % · q6/q1: idle 49 / starved 45 / stalled 5 · wide: 44 / 48 / 7. Decoder duty **0.6 %** |
| 08-12 | effective decode throughput per query, sf30 | q8 **185** MiB/s, q9 136, q21 130, q6 126 … q3 47, q1 29, q2 29 — a **6x spread**, and the slow three are exactly the three the CPU wins |
| 08-23 | 2-lane A/B | **never completed a 2-lane arm.** 1-lane arm: q01 sf30 = 62.07 s, 1462.8 MiB through lane 0 (`OASIS_HTTP_BATCH=0`, which is why it is slow) |
| 09-12 | **decoder occupancy at 4 lanes** | `stalled` **10–14 %** — the decoder is not the constraint at four lanes either | build-119, `scale_pal` runs (M8) |
| 09-12 | **TOE → decoder datapath capacity** | **~13.9 GB/s per lane** in RTL — 18x the 0.775 GB/s the whole design achieves | the datapath, the normalizer and `readPkg` are all cleared as suspects |
| 09-12 | **a 5th decoder does not fit** | `inst_dynamic` = **409,908 LUTs** against a U55C SLR's **434,560** (~94 %); one decoder + glue measured at ~95k (117 → 118) | **area is the honest reason to stop at four — not diminishing returns**, since scaling is still linear at 4 |

**Arithmetic worth staring at:** 1.02 GB/s ÷ 250 MHz = **4.08 bytes per cycle**, against a port that
can carry 64. For an 8-byte column that is **one value every two cycles**. That is a specific,
testable shape — see M2.

### 0.3 What the system delivers end to end

| date | build | harness | FPGA | CPU (1 thread) | ratio |
|---|---|---|---|---|---|
| 08-12 | 97 | sf30, process per query, `--phases` | 437.77 s | 801.30 s | FPGA 1.83x |
| 08-19 | 104 | sf30, process per query | 282.32 s | 857.66 s | FPGA 3.04x |
| 08-19 | 105 | sf30, process per query | **273.18 s** | — | best recorded |
| 08-19 | 105 | sf30, **one session per side** | 354.9 s | **249.2 s** | **CPU 1.42x** |
| 08-19 | 105 | sf30, CPU on all 80 cores | — | **43.15 s** | CPU 8.2x |
| 08-10 | 95 | sf1, process per query | 31.63 s | 34.62 s | FPGA, 18/22 queries |
| 09-12 | **119** | **sf30, one session per side, cache off both sides, 4 decoders** | **26.98 s** | **14.45 s** | CPU 1.87x — **but see M8.2**: four queries carry 74 % of the FPGA total, and on the other 18 the FPGA is **1.65x faster** |

Throughput, as opposed to time: the 7-column lineitem scan moved **2938 MB in 14.31 s = 205 MB/s**
wall clock, against a server that can do 4600. The FPGA's own counters say 0.33 GB/s in-chunk.
Those two numbers differ because of idle between chunks — which is the whole point of M3.

### 0.4 Methodology rules these numbers were bought with — violate one and the run is worthless

1. **The profiler's `in_stalled` / `starved` / `handshake` count only cycles while a column chunk is
   streaming.** Between chunks the profiler is in IDLE and counts nothing. A decoder 80 % stalled
   *in-chunk* can be idle most of the wall clock. Four wrong "bottleneck found" conclusions came
   from that denominator. **Always cross-check bytes-on-the-wire ÷ query seconds first.**
2. **MinIO's page cache drifts across a day** (build-104: 403 s in the morning, 282 s in the
   afternoon, identical settings). Run every configuration **twice and report the second**, and
   interleave arms of any A/B.
3. Whichever side runs second reads a warm cache. `--phases` warms the CPU side by a whole phase.
4. **Never `OASIS_HTTP_DEBUG=1` while measuring** — its tracing thread reads the profile three times
   per request and each read resets the counters.
5. A profile read on a query that moved no data returns the **previous** query's numbers. Check the
   value changed.
6. Reprogram after any Ctrl-C, crash or wedge; check `free_hugepages` (needs 16 × 1 GiB).
7. Rebuild **and reinstall `software/`** after any branch switch — `make` in `extension/` does not,
   and a stale `liboasis.so` drives the board with a mismatched CSR map, silently.
8. Bitstream identity is readable on the wire: `Win=1048560` = 1 MiB window = build-97 and later.
9. **Never sweep a parameter in one monotone order.** MinIO's cache warms as the sweep proceeds, so
   the result encodes run order, not the parameter. Use an order-cancelling harness — `chunks_ab`
   (alternating A/B/A/B/A/B) or `scale_pal` (a prewarm pass, then forward 1→4 *and* reverse 4→1).
   The forward and reverse curves agreeing is the evidence that drift cancelled; if they disagree,
   the run is worthless. This rule cost a full retraction (the "+33 % chunk size" result).
10. **The profile counters are NOT reset between runs.** A decoder that is idle in the current run
    reports whatever it last did. After a 4-lane prewarm those leftovers are ~180 MB/s *each*, which
    once turned a 1-lane measurement into 737 MB/s. Exclude any decoder whose `(rate, hs)` pair does
    not **change** across repeats, and cross-check that the active decoders' `mib_in` sums to the
    workload.
11. **The shell's `BUILD` variable does not tell you which bitstream is loaded** — it only selects
    `$BIT` for `reprogram`. On 2026-09-12 every run from 12:11 on was build-119 while the shell said
    118, because only `sudo insmod` had been run. **Ground truth is the `.bit` file's atime:**
    `stat -c '%n atime=%x' hardware/build-*/bitstreams/cyt_top.bit`.
12. With `OASIS_HTTP_CHUNK_BYTES=0`, `gets` reads 392 for every decoder at every lane count.
    `kib_per_get` and `dead_us_per_get` are therefore meaningless in that configuration;
    `mib_in` and `in_mbytes_s` remain genuine.

---

## M0 — The fairness protocol every timing run must satisfy

A number is only comparable if both sides did the same work. Three things have to be true, stated
in the run's own output so a pasted result carries its own conditions.

### M0.1 — No TLS anywhere, on either side ✅ verified 2026-08-26

| side | transport | evidence |
|---|---|---|
| FPGA | plain HTTP/1.1 over TCP, built in hardware | no `https`, `ssl` or `TLS` token exists anywhere in `hardware/src`, `software/` or `extension/src`. There is no TLS block in the datapath — the FPGA could not speak it if asked |
| CPU baseline | plain HTTP/1.1 | `views_cpu()` emits `read_parquet('http://SERVER:PORT/...')` (`scripts/tpch_demo.sh:190`). No `s3://` URL, so `s3_use_ssl` never applies |
| both | no proxy | the script unsets `http_proxy/https_proxy/ALL_PROXY` and sets `NO_PROXY`, so there is no `CONNECT` tunnel and no proxy TLS |
| server | MinIO on `:9000`, plaintext | it answers the FPGA's header-less GET at all, which a TLS listener could not |

`tpch_demo.sh` now prints this in the banner of every run, so no result can be quoted without it.
**Nothing to fix — but nothing was previously asserted either, and now it is.**

### M0.2 — Same caching on both sides ⚠️ this was NOT true, and it is now a flag

The hole, found today by reading DuckDB v1.5.2's source:

| cache | default | CPU baseline | FPGA path |
|---|---|---|---|
| `enable_external_file_cache` — in-memory cache of file **data** | **TRUE** (`settings.hpp:710`) | caches **footers and column bytes** — in `--single-session` the second query over lineitem can be served entirely from RAM | caches **footers only**: `ParquetReader` opens through `CachingFileSystem` (`parquet_reader.cpp:862`), but column bytes are streamed by the scheduler into the decoder and never pass through it |
| `enable_http_metadata_cache` — HTTP HEAD results | FALSE | was hardcoded **true** in `tpch_demo.sh` | not consulted; the extension keeps its own one-HEAD-per-path size cache (`http_file_system.cpp:374`) |
| MinIO page cache | — | shared, and warms across a day | shared |

So the CPU side had a RAM cache of the actual data that the FPGA path structurally cannot use.
That is very likely a large part of why `--single-session` reads **CPU 1.42x** (354.9 s vs 249.2 s)
while process-per-query reads **FPGA 3.04x** — at scale 30 the whole dataset fits in the node's
~350 GB of free RAM.

**Fixed today:** `tpch_demo.sh --cache off|metadata|full`, default **off**.
- `off` — both DuckDB caches off **on both sides**. Every query re-fetches from MinIO. Parity.
- `metadata` — HEAD results cached CPU-side, no file data cached anywhere.
- `full` — DuckDB's defaults: the CPU baseline at its best, with a warm RAM cache against an FPGA
  without one.
The mode is printed in the banner **and** next to the totals, because it changes what the ratio
means rather than only its value.

**Protocol for the thesis: run `--cache off` and `--cache full`, and report both.** The first is the
parity claim; the second pre-empts "you handicapped DuckDB". Never quote one without saying which.

### M0.3 — Absolute numbers, not scaled ones
Every table reports measured seconds and measured bytes with the run's conditions attached
(scale, threads, cache mode, chunk size, bitstream, run order, which arm ran second). Ratios are
derived in the text from those two columns and never stand alone. Anything estimated or modelled is
labelled as such — the M4 prediction below is a prediction and is marked as one.

### M0.4 — Connection posture, so "single persistent connection" means something
At `--threads 1` stock httpfs issues its range reads nearly serially over pooled keep-alive
connections, which is the closest match to the FPGA's one persistent session; at all cores it opens
many. build-105 holds exactly one TCP session for the whole process; build-110 holds one per lane.
State the thread count with every number — it is a connection-count knob on the CPU side, not only
a decode-parallelism one.

---

## M1 — What can MinIO actually give one request, and how does it scale with connections?

**Why this decides the thesis:** if one session tops out near 0.5 GB/s, no amount of decoder or
datapath work matters and the whole remaining budget belongs to multi-session TCP. The 08-19
numbers already say exactly that, so M1 is **confirmation on today's server plus the scaling curve
we have never measured in the FPGA's request shape**.

### M1.0 — Sanity: is the dataset even there?
The HACC reservation moves nodes and MinIO's data directory is node-local (the binaries live in NFS
and follow you, the objects do not). `scripts/util/serve_tpch.sh` rebuilds from the NFS copy.

```bash
curl -s --noproxy '*' -o /dev/null -w '%{http_code} %{size_download}\n' \
     -H 'Range: bytes=0-1023' http://10.253.74.74:9000/throughput/tpch-30/lineitem.parquet
```
Expect `206 1024`.

**Checked 2026-08-26 from hacc-build-01: `Connection refused` on both `10.253.74.74:9000` and
`10.253.74.70:9000`.** A refusal (not a timeout) means a host answered with RST and nothing is
listening — consistent with the reservation having moved, which is exactly what
`scripts/util/serve_tpch.sh` was written for. Re-check from alveo-u55c-04 before concluding
anything; if it is refused there too, `./scripts/util/serve_tpch.sh` re-exports scale 30 from
`/scratch/jkreissl/tpch-sf30.db` on NFS and serves it, then `export OASIS_SERVER=<IP it prints>`.
**No M1/M2/M3 run can start until this answers 206.**

### M1.1 — Re-confirm the single-session ceiling on today's server
```bash
cd /scratch/jkreissl/oasis && ./scripts/util/one_conn_ceiling.sh          # run twice, report the 2nd
```
**Decision rule:** depth-32 within ~10 % of 0.463 GB/s ⇒ the 08-19 model holds and stands as the
thesis number. Materially higher ⇒ the server changed and every ratio below needs re-basing.

- Result: **HOLDS — measured 2026-08-27 on BOTH nodes.** `scripts/util/one_tcp.py depth`,
  768 KiB GETs, 2 GiB per point, inside a pre-warmed 2 GiB prefix.

  | depth | 1 | 2 | 4 | 8 | 16 | 32 |
  |---|---|---|---|---|---|---|
  | hacc-build-01 | 0.359 | 0.446 | 0.445 | 0.441 | 0.434 | 0.451 |
  | alveo-u55c-04 | 0.370 | 0.443 | 0.432 | 0.439 | 0.432 | 0.436 |

  Depth-32 = 0.436 GB/s, within 6 % of the 08-19 figure of 0.463 → the model stands. All of the
  pipelining gain is collected by depth 2; `ms/GET` is pinned at ~1.78 ms from depth 2 onward
  (2.13 ms at depth 1).

  **New, and stronger than the old claim.** With **1 KiB** GETs — body time negligible, so only the
  fixed cost remains — the floor is **0.707 ms/GET (1414 GETs/s) and does not move between depth 2
  and depth 64**. MinIO finishes request *n* before starting *n+1*: pipelining hides the RTT, never
  the service time. Independently corroborates ADR-3's 1020 → 848 → 822 µs across depth 1 → 2 → 4.
  The whole curve is fit by **~0.7 ms fixed per GET + ~0.85 GB/s streaming**.

### M1.2 — Connection scaling **in the FPGA's request shape** (new — this is the gap)
`minio_ceiling.sh` uses one 256 MiB read per stream, which is not what the FPGA does.
`scripts/util/conn_scaling.sh` (added today) runs N keep-alive sessions of back-to-back 768 KiB
ranged GETs at depth 2 — exactly the multi-session bitstream's shape.

```bash
cd /scratch/jkreissl/oasis && MODE=conn ./scripts/util/conn_scaling.sh     # 1,2,4,8,16 sessions
```
**Decision rule:** the *per-connection* column is the answer.
- flat to N=4 ⇒ build-110's four lanes are worth **4 × 0.46 = 1.84 GB/s** of headroom, and at the
  same 72 % efficiency the design should reach **~1.3 GB/s** — a 4x jump. Write that prediction down
  before the bitstream lands.
- falling before N=4 ⇒ MinIO saturates earlier in this shape than in the 256 MiB shape, and the
  useful lane count is wherever it flattens. That is a thesis result in itself.

- Result: **Measured — and the first attempt was INVALID. Cache state, not connection count.**

  `one_tcp.py conns` on alveo-u55c-04 (16 MiB GETs, depth 2) appeared to collapse: 1 → 0.889,
  2 → 1.695, 4 → 1.546, 8 → 0.910 GB/s. Total throughput going *backwards* is the signature of a
  disk-bound server, not a saturating one. Confirmed by running `minio_ceiling.sh` twice
  back-to-back on the same node:

  | streams | 1 | 2 | 4 | 8 | 16 |
  |---|---|---|---|---|---|
  | **cold** (first run) | 0.17 | 0.37 | 0.32 | 0.34 | 0.23 |
  | **warm** (immediate repeat) | 0.76 | 1.80 | 3.32 | 5.73 | **9.07** |

  A **40x swing at 16 streams between two consecutive runs of the identical command.** Warm, the
  per-stream column is flat out to 8 and MinIO scales cleanly. The cold single-stream number (0.17)
  matches hacc-build-01's cold read (0.164) and the warm one (0.76) matches its warm read (0.779) —
  so the server behaves identically from both nodes and the node was never the variable.

  **⇒ §0.1's `16 connections → 4.60 GB/s` (08-19) is cold-contaminated; read it as ≥ 9.07 GB/s
  warm.** The headroom above the FPGA is roughly twice what the ledger claims. Rule 2 applies to
  the **server's** page cache, not just DuckDB's — and `minio_ceiling.sh`'s own printed decision
  rule ("about 1 GB/s ⇒ the server is the limit, rethink the argument") is actively dangerous
  without a warm precondition: the cold run prints 0.23.

### M1.3 — Where is the chunk-size knee? (never measured above 1 MiB)
Throughput was linear in chunk size to 1 MiB and the sweep stopped there. The chunk size is a
software constant (`HTTP_DEFAULT_CHUNK_BYTES`), so a knee at 2–4 MiB is free throughput.
```bash
cd /scratch/jkreissl/oasis && MODE=chunk ./scripts/util/conn_scaling.sh
```
**Decision rule:** ms-per-GET flat across sizes ⇒ still latency-bound, raise the chunk to the last
flat point. Rising linearly ⇒ that size is bandwidth-bound and the knee is there.
Caveat before changing anything: chunk × depth must stay inside the 1 MiB receive window, and the
in-flight budget is bounded in **bytes**, not requests.

- Result: **Knee found — and it is unreachable. That is the finding.**

  `one_tcp.py chunk`, one connection, depth 2, alveo-u55c-04, warm, 1 GiB per point:

  | chunk | 64K | 128K | 256K | 512K | 768K | 1M | 2M | 4M | 8M | 16M | 64M |
  |---|---|---|---|---|---|---|---|---|---|---|---|
  | GB/s | 0.066 | 0.133 | 0.237 | 0.344 | 0.432 | 0.482 | 0.673 | 0.719 | 0.864 | **0.887** | 0.897 |

  Near-linear in chunk size to ~2 MiB, flattening at **~0.89 GB/s around 8–16 MiB**. Confirms the
  08-12 sweep and extends it past 1 MiB for the first time.

  **But the FPGA cannot use anything above ~1 MiB.** Total receive buffering is 1 MiB (TOE window)
  + 512 KiB (`RX_FIFO_DEPTH`) = **1.5 MiB**; a single response larger than that deadlocks — see
  **M7**, tested and reproduced today. So the usable single-session ceiling is the 768 KiB–1 MiB
  point, **0.43–0.48 GB/s**, which is where the design already sits.

  **⇒ raising `HTTP_DEFAULT_CHUNK_BYTES` is NOT free throughput**, contrary to this section's
  premise. The knee is real but sits on the far side of a hard buffering limit.

### M1.4 — The reference reader, for the thesis' comparison axis
What does stock DuckDB httpfs pull from the same object on the same host, at 1 thread and at all
cores? That is what "the CPU baseline's network throughput" means and we have never isolated it.
```bash
python3 - <<'PY'
import duckdb, time
c = duckdb.connect(); c.execute("INSTALL httpfs; LOAD httpfs")
for th in (1, 80):
    c.execute(f"SET threads={th}")
    t = time.time(); c.execute("SELECT sum(l_quantity) FROM read_parquet('http://10.253.74.74:9000/throughput/tpch-30/lineitem.parquet')").fetchall()
    print(th, "threads", round(time.time()-t, 2), "s")
PY
```
- Result: **Measured 2026-08-27 on alveo-u55c-04, warm, `sum(l_orderkey)` over sf30 lineitem
  (280.63 MB). This is the comparison axis the thesis should use.**

  | threads | 1 | 2 | 4 | 8 | 80 |
  |---|---|---|---|---|---|
  | MB/s | **247.6** | 489.9 | 910.4 | 1588.5 | 2814.9 |
  | vs 1 thread | 1.00 | 1.98 | 3.68 | 6.42 | 11.37 |

  **Scaling is linear to 8 threads** — i.e. linear in *connections*. Connection count sampled with
  `ss -tn dst 10.253.74.74` during the `threads=1` run: **2 connections for roughly a third of the
  time, 1 for the rest**, so ~1.3 on average.

  **⇒ per connection the FPGA matches stock DuckDB to within ~4 %:**

  | | connections | MB/s total | per connection |
  |---|---|---|---|
  | raw-socket ceiling @ 187 KiB | 1 | 181 | 181 |
  | **FPGA (build-105)** | 1 | 178.5 | **178.5** |
  | DuckDB `threads=1` | ~1.3 | 247.6 | **~186** |

  Predicted from connection count alone: 1.3 × 181 = 235 against 247.6 measured, within 5 %.
  **The CPU's entire advantage is sockets, not decoding.** Quote this per-connection, not per-query:
  a per-query ratio is a statement about DuckDB's thread count, not about either decoder.

---

## M2 — Is the decoder really stalled, and on what? (the supervisor's objection)

**The objection is right to be suspicious.** The port can carry 16 GB/s and we measure 1.0, with the
decoder itself refusing input 80 % of in-chunk cycles. Snappy is already exonerated. So either the
decoder is internally rate-limited (~4 bytes/cycle), or something downstream of it is, or the
counters do not mean what the derivation assumes. Each is cheap to separate, in this order.

### M2.0 — What the counters actually are (checked in RTL today, worth knowing before reading any)
- `StreamProfiler` counts a **handshake = `valid && ready`, with no `keep` weighting**
  (`libstf/hardware/src/hdl/util/stream_profiler.sv`). The software derivation then multiplies by a
  **flat 64 bytes** (`extension/src/oasis_profile.cpp:15`).
- The output interface `typed_ndata_i` is 64 lanes **with a per-byte `keep` mask**
  (`libstf/hardware/src/hdl/data_interfaces.sv:265`).
- ⇒ **a partially-filled output beat is counted as a full 64 bytes.** If the decoder emits sparse
  beats, the real output byte rate is far below what `out_throughput_*` prints, and the input stalls
  for a reason the counters actively hide. This alone could explain the whole anomaly.
- The IN profiler taps the decoder's **top-level** input (`column_chunk_decoder.sv:404`), i.e. it
  includes the PageHeaderParser, the decompressor and the value decoders behind it.

### M2.1 — Read the OUT counters (5 minutes, no rebuild, do this first)
Every conclusion so far was drawn from `in_*` alone. Run one clean, decoder-heavy query and dump the
whole row:
```bash
cd /scratch/jkreissl/oasis
./extension/build/release/duckdb -c "
  SET http_server='10.253.74.74'; SET http_port=9000;
  SELECT * FROM oasis_stream_profile();" > /dev/null   # arm: ends any stale window
./extension/build/release/duckdb -c "
  SET http_server='10.253.74.74'; SET http_port=9000;
  SELECT sum(l_quantity) FROM read_oasis('httpfpga:///throughput/tpch-30/lineitem.parquet');
  SELECT * FROM oasis_stream_profile();"
```
Compute three ratios and read them against the table:

| observation | conclusion |
|---|---|
| `out_stalled` large and growing | the **host/DMA output path** is the limit; `in_stalled` is just back-pressure arriving from downstream. Software fix, no bitstream. Check `OASIS_OBM_BUFFERS` (default 64 since the deadlock fix) |
| `out_handshakes / out_busy` ≈ 1.0 | the **output stream is saturated** — the decoder is output-beat-bound and `in_stalled` is arithmetically forced. Then the real question is beat *fill*: see M2.2 |
| `out_handshakes ≫ in_handshakes` for a column that should expand ~2–4x | beats are **sparsely filled** — the decoder is spending beats, not bytes. This is the hypothesis M2.0 predicts |
| both duties low, `out_stalled` ≈ 0 | the limit is **inside** the decoder (page-header walk, level decoding, dictionary lookup). Go to M2.3 |

- Result: **Run 2026-08-27, and it is decisive. `out_stalled = 0` on every column.**

  One column per Fig-11 class, sf30 lineitem, build-105, clean board:

  | column | class | `in_stalled` | % of in-chunk | **in GB/s** excl idle | **out GB/s** excl idle | `out_stalled` |
  |---|---|---|---|---|---|---|
  | `l_orderkey` | copy-heavy, low enc. ratio | 128.4 M | **85.9 %** | 0.469 | 2.398 | **0** |
  | `l_quantity` | high encoding ratio | 26.6 M | 62.3 % | 0.797 | 8.357 | **0** |
  | `l_shipdate` | literal-heavy | 13.3 M | **21.3 %** | 1.141 | 3.270 | **0** |

  **Three firm conclusions:**

  1. **The host / DMA / PCIe path is fully exonerated.** Zero stalled cycles on the output, on every
     column. The paper is PCIe-bound at ~12.5 GB/s; the HTTP path never gets close enough to engage
     it. This kills the "output path is the limit" branch of M2.1's own decision table.
  2. **`in_stalled` IS the decoder**, not back-pressure arriving from downstream. It varies **9.6x**
     across the three columns, tracking the Snappy copy fraction exactly as the paper's Fig 8
     predicts. (M2.0's hypothesis that sparse output beats hide the real rate is not needed.)
  3. **The paper's microbenchmarks reproduce on the HTTP path.** `l_quantity` at 8.36 GB/s sits
     inside Fig 10's dictionary band (8.2–11.4); `l_shipdate` at 3.27 just under Fig 8's
     literal-heavy 3.5 GiB/s; `l_orderkey` at 2.40 is the copy-heavy Snappy case. That is a
     validation result in its own right, not just a debugging step.

  Counters are self-consistent to the last beat: `out_handshakes` is identical for `l_orderkey` and
  `l_quantity` (22,499,797 × 64 B = 1440.0 MB = 179,998,372 rows × 8 B) and exactly half for
  `l_shipdate` (720 MB, 4 B/row).

  **The number the design needs is the INPUT rate**, because that is what the network feeds:
  **0.47–1.14 GB/s per lane**. One session at 16 MiB delivers 0.89 GB/s, so a lane and a session are
  the same order of magnitude — and on copy-heavy columns **one lane cannot absorb one session**.
  Lane:session is therefore ~2:1 for TPC-H key columns, ~1:1 for dates. `tcp_read.sv`'s own comment
  independently states ~615 MB/s for the vhsnunzip core, next to the 469 MB/s measured here.

### M2.2 — Value rate or byte rate? The one A/B that separates them
If the decoder is limited to ~0.5 **values** per cycle, then an INT32 column runs at half the
**bytes** per second of an INT64 one; if it is limited in bytes, both give ~1.0 GB/s. The testbench
corpus already has the pieces (bucket `testbench`, memory: `dk4` INT64, `t*`/`fp*`/`dict` INT32,
`unco`/`seam` uncompressed, `manyrg` 245 row groups).

Run the same-sized column as: INT32 vs INT64 · dictionary (`dict`) vs plain (`fp1024`) ·
SNAPPY vs UNCOMPRESSED (`unco`) · many small chunks (`manyrg`), reading `in_throughput_excl_idle`
for each.

**Decision rule:** bytes/s tracks the value width ⇒ **value-rate bound**, and the fix is inside the
value decoders (or more lanes). bytes/s constant across widths ⇒ **byte-rate bound**, and the
suspect is the header/decompress front end. Dictionary far below plain ⇒ the dictionary lookup
serialises.

- Result:

### M2.3 — Cycle-accurate decoder ceiling, with no network at all (runs on the build server)
`parcore/hardware/unit-tests/column_chunk_decoder_test.py` already drives a **real parquet column
chunk** through `ColumnChunkDecoder` in xsim. Feeding it at full rate and counting cycles gives the
decoder's true ceiling per encoding, independent of MinIO, the TOE and the host — the number the
supervisor is really asking about, and the one to put in the thesis as "the decoder can do X".

Extend it to log, per run: input beats, output beats, output beats' `keep` popcount, and total
cycles ⇒ GB/s in, GB/s out, and average beat fill. Sweep: PLAIN vs dictionary vs RLE, INT32 vs
INT64, compressed vs uncompressed, one big page vs many small ones.

**Decision rule:** sim says ~16 GB/s ⇒ the RTL is fine and the loss is in the *system* (feed path,
per-chunk setup, output writer). Sim says ~1 GB/s ⇒ the decoder genuinely runs at ~4 B/cycle, the
supervisor's assumption is wrong, and a per-stage probe (PageHeaderParser out, Decompressor out,
decoder out) names the stage in one more run.
*Gotcha from the harness notes: default sim time is 4 µs and longer streams are silently truncated
to zeros — set `overwrite_simulation_time` to the beat count.*

- Result:

### M2.4 — Per-chunk fixed cost, which is what actually caps the design today
`idle` is 68 % of the wall clock and is invisible to the in-chunk numbers. Divide
`in_idle_cycles × 4 ns` by the request count for dead time per chunk, and compare against the ~1.4 ms
MinIO time-to-first-byte. If they match, idle is simply the network and only more sessions help; if
idle ≫ 1.4 ms × requests, there is host round-trip time to reclaim.

- Result: **ANSWERED 2026-08-27 — idle IS the network, and only more sessions help.**

  From M3.1's latency run (sf30, 1465 GETs):

  | | |
  |---|---|
  | `in_idle_cycles × 4 ns / requests` | **633.8 µs** |
  | `(starved + idle) × 4 ns / requests` (`dead_us_per_get`) | **710.8 µs** |
  | MinIO's per-GET floor, measured independently | **707 µs** |

  The FPGA's dead time per request and MinIO's service time are **the same number to within 0.5 %**.
  That floor was measured with 1 KiB GETs at pipeline depth 64 (M1.1) — body time negligible, and it
  does not improve with depth, so it is pure server-side service time.

  **⇒ there is no host round-trip time to reclaim.** Every microsecond of idle is MinIO answering
  the previous request. The only levers are fewer requests (bigger chunks, capped at ~1 MiB by M7)
  and more sessions (M4).

  Note this supersedes §0.1's "**~1.4 ms** fixed cost of one GET (08-12)". Today's figure is 707 µs,
  closer to the "730–800 µs in the sf1 era" also recorded there. The 1.4 ms was most likely measured
  against a cold server cache — see M1.2 for how large that effect is.

### M2.5 — Feed the decoder as fast as the system can, and see what it does
Same range, re-read repeatedly so MinIO serves from page cache, with the largest chunk the window
allows. `starved` should collapse; whatever the decoder then does is its practical ceiling in situ.
Compare against M2.3's sim ceiling.

- Result:

### M2.6 — Last resort: ILA on the decoder's `in.ready`
`scripts/util/ila_tcp.sh` exists for the TCP side; the same approach on `in.ready` would show
whether the stall is a steady duty cycle (a rate limit) or bursty (a buffer credit). Costs a
bitstream — only if M2.1–M2.3 disagree.

### Do we need two decoders per TCP connection? — answer it explicitly
The measured pair is **decoder ~1.0 GB/s in-chunk vs one session 0.46 GB/s**. One decoder is
already ~2.2x one connection, so **no** — a second lane behind a single session buys only the idle
gaps, not bandwidth. The reason build-110 has four lanes is that it also has **four sessions**:
lanes ≈ sessions is the ratio the two numbers support. If M2.1–M2.3 revise the 1.0 GB/s downward,
that ratio moves, and it is the number that decides the lane count.

---

## M3 — What throughput does the current design actually reach?

Everything so far is a *time* against DuckDB. The thesis needs a throughput, and the metric has to
be defined once and stated, because three different denominators are in circulation
(0.33 GB/s in-chunk, 205 MB/s wall clock, 29–185 MiB/s per query).

**Definition to use:** `bytes fetched from MinIO ÷ query wall-clock seconds`, per query and
aggregated. Wall clock, because it is the only denominator that cannot flatter us (rule 0.4.1).
Report alongside it: decoded output bytes/s and rows/s, plus `% of one-session ceiling` from M1.

### M3.1 — The run
```bash
cd /scratch/jkreissl/oasis
./scripts/tpch_demo.sh --phases --threads 1 --scale 30 | tee /tmp/run-$(date +%H%M).txt   # twice; use the 2nd
```
`hw_MiB` and `fpga_s` are already in the table, so the throughput column is arithmetic on it:
```bash
awk '/^q[0-9]/ && $5 != "-" { mb=$5*1.048576; s=$3; if (s>0) { printf "%-5s %8.1f MB %7.2f s %8.1f MB/s\n", $1, mb, s, mb/s; t+=mb; T+=s } }
     END { printf "----- aggregate %.1f MB / %.1f s = %.1f MB/s\n", t, T, t/T }' /tmp/run-XXXX.txt
```
- Result: **Measured 2026-08-27, build-105, freshly programmed board, sf30, three repeats each
  (report the 2nd, rule 2).**

  | workload | cols | GETs | KiB/GET | `in_mbytes_s` | idle % | starved % | stalled % | dead µs/GET |
  |---|---|---|---|---|---|---|---|---|
  | latency | 1 | 1465 | 187.1 | 178.5 | 59.1 | 7.2 | 32.7 | 710.8 |
  | q6 | 4 | 5860 | 240.5 | 217.1 | 70.7 | 16.7 | 11.2 | 991.7 |
  | q1 | 4 | 5860 | 240.5 | 207.5 | 69.7 | 18.2 | 10.7 | 1043.9 |
  | wide | 8 | 11720 | 279.1 | 241.5 | 65.1 | 16.4 | 17.0 | 964.3 |

  All results matched the CPU baseline exactly; `mib_in` byte-identical across all three repeats of
  every workload.

  **Cross-checked against the M1.3 curve at each workload's own request size:**

  | workload | KiB/GET | FPGA MB/s | one-connection curve | ratio |
  |---|---|---|---|---|
  | latency | 187.1 | 178.5 | ~181 | **99 %** |
  | q6 | 240.5 | 217.1 | ~224 | **97 %** |
  | wide | 279.1 | 241.5 | ~247 | **98 %** |

  And `dead_us_per_get` = 710.8 against MinIO's independently measured 707 µs floor — **within
  0.5 %**, from two entirely separate measurement paths (a Python socket client and the decoder's
  own hardware counters).

  **⇒ §0.1's "FPGA at 72 % of the ceiling, so in-FPGA work is worth 1.4x" is WRONG — strike it.**
  The FPGA is at **97–99 %** of what one TCP connection delivers at its request size. There is no
  in-FPGA headroom to recover. The 1.4x gap was an artefact of comparing against a ceiling measured
  at 768 KiB while the design actually issues 187–279 KiB requests.

### M3.2 — Cross-check against the wire, so the claim is not counter-derived
```bash
cat /sys/kernel/coyote_sysfs_0/cyt_attr_nstats     # before and after the run
```
TCP RX bytes ÷ wall seconds must agree with M3.1 within a few percent. If it does not, `hw_MiB`
is not counting what we think it counts and every per-query throughput above is suspect.

- Result: **NOT DONE as specified — `cyt_attr_nstats` was never read.** The claim was
  cross-checked a different way instead, which is arguably stronger but does not replace this:
  `in_mbytes_s` was compared against the **independently measured single-connection curve** (M1.3)
  at each workload's own request size, and agrees to 97–99 % (M3.1). Two separate measurement
  paths — a Python socket client on the host and the decoder's own hardware counters — landing
  within 3 % is good evidence that `hw_MiB` counts what we think it counts.

  **Still worth doing**, because it is the only check that closes the loop through Coyote's own TCP
  byte counter rather than through a model of the server.

### M3.3 — The three numbers to put in the thesis
| metric | source | today |
|---|---|---|
| wire throughput, wall clock | M3.1 | ~205 MB/s measured once, on a 7-column scan |
| fraction of what one session could deliver | M3.1 ÷ M1.1 | 0.33/0.463 = **72 %** in-chunk; the wall-clock fraction is much lower and is the honest one |
| fraction of what the server could deliver | M3.1 ÷ 4.6 GB/s | ~4 % |
The gap between the second and third rows **is** the thesis argument for multi-session.

---

## M4 — build-110: does 4 lanes × 4 sessions deliver? (prediction on record, before the run)

Predicted from M1: ceiling **4 × 0.46 = 1.84 GB/s**; at today's 72 % efficiency, **~1.3 GB/s**, i.e.
**~4x** build-105 on wall clock for scan-heavy queries. q1/q2/q3 will improve **less**, because they
are DuckDB-bound and request-count-bound respectively, not bandwidth-bound.

Falsifiers, stated now:
- wall time flat and per-lane MiB unbalanced ⇒ the dispatcher is not spreading flows across lanes.
- wall time flat and per-lane MiB balanced ⇒ the sessions share a bottleneck we have not modelled
  (tx arbiter, rx dispatch, or MinIO in this shape — M1.2 is what rules the last one out).
- throughput scales but < 2x ⇒ per-chunk idle dominates; M2.4 is then the next lever, not lanes.

Run it as an A/B on the **same** bitstream (`oasis_scheduler_num_streams` = 1 then 4, interleaved),
never build-105 vs build-110 across a day — `scripts/util/decoder_ab.sh` exists for exactly this and
has never completed a multi-lane arm. `OASIS_HTTP_BATCH=0` is mandatory with more than one lane.

- Result: **NOT RUN — build-110 has no bitstream.** Still in place-and-route as of 2026-08-27
  16:25 (started 08-26 18:20, ~22 h). Router in rip-up-and-reroute, overlaps converging
  (364,247 → 26,532 on the latest global iteration) but iterations have restarted several times.
  Config verified correct: `N_DECODERS=4`, `ENABLE_HTTP_MULTI=ON`, `N_STRM_AXI=5`, `EN_TCP_MULTI`
  defined in the generated header.

  **Prediction revised DOWN before the run, on today's numbers:** 4 sessions × 178.5 MB/s =
  **714 MB/s ≈ 2.9x a single CPU thread** — not the 4 × 0.46 = 1.84 GB/s this section originally
  assumed, because that figure needs a request size the receive buffering cannot support (M1.3, M7).
  And on copy-heavy columns the per-lane decode limit of 0.469 GB/s (M2.1) binds before the network
  does, so expect **~1.9 GB/s** on TPC-H key columns even with all four sessions fed.

  **Resource ceiling, from build-105 vs build-108 deltas measured today:** +90,358 LUTs, +15 BRAM,
  +81 URAM per decoder, plus 144 RAMB36 per lane for `handler_multi`'s decoupling FIFO. Against
  build-105's 416,477 LUT / 846 BRAM / 99 URAM baseline that caps the design at **~7 lanes (BRAM)**,
  ~9 (LUT), ~10 (URAM). **The receive window and the lane count compete for the same BRAM** — a
  4 MiB window costs ~1024 RAMB36 against 1170 spare, so it is 4 MiB on one session *or* ~7 lanes at
  1 MiB, not both. That trade-off is a thesis result and it is specific to HTTP: RDMA gives every
  stream its own queue pair and never pays it.

---

## M5 — Give the FPGA path a cache of its own, validated by HEAD (design note)

The right end state is both sides cached, not both sides cold, and the FPGA path already has the
pieces:

- it already issues a **HEAD per path** and caches the result for the process
  (`CachedContentLength`, `http_file_system.cpp:374`), so a conditional revalidation is one header
  away — MinIO returns `ETag` and `Last-Modified` on both HEAD and GET, and `If-None-Match` /
  `If-Modified-Since` gets a 304 when nothing changed.
- the objects are immutable in practice (`Last-Modified` 2026-03-31 on the whole TPC-H set), so a
  validated cache would hit essentially always.

Two tiers, in order of value per unit of work:

1. **Footer / metadata cache across queries in a process.** lineitem's footer alone is 2.37 MB and
   is re-fetched at every bind. Cheap, and it removes a fixed cost from every query — the same cost
   `enable_http_metadata_cache` removes for the CPU. Today `--cache full` gives the FPGA side this
   via DuckDB's external file cache; making it ours makes it survive `--cache off` honestly.
2. **Column-data cache.** Bigger, and it changes what the accelerator is for: the FPGA's value is
   decoding bytes as they arrive off the wire, so caching decoded output competes with its own
   premise. Worth stating in the thesis as the reason the comparison is run cold, rather than
   leaving it as an omission.

Until (1) exists, `--cache off` is the honest default, which is why it is the default.

---

## M6 — Is the receive fifo actually sized right, or only *not observably wrong*?

`RX_FIFO_DEPTH = 8192` is 512 KiB and **128 RAMB36 per lane** — at 4 lanes on build-110 that is 512
RAMB36 of 2016, a quarter of the device's block RAM spent on one design decision. The depth went
1024 → 4096 → 8192 across builds, and the justification each time was *"the sticky stall bit stopped
setting"*. That is a much weaker claim than an occupancy number, and it is the one number nobody has.

**What exists today, and what it cannot tell us.** `axis_fifo.overflow_stall` →
`tcp_read.rx_fifo_stall` → `stallWord` bit 25 → `HttpConfig` read register 11 →
`scripts/util/http_state.sh`. One bit, and three limits on it:

| | |
|---|---|
| it is not overflow | it sets on `s_axis_tvalid && !s_axis_tready`, i.e. the producer was *refused*. `tready` comes from `almost_full` (4 entries of slack). **No data is ever lost** — the fifo ran out of room and back-pressure reached the TOE, which is the thing we are avoiding, not a drop |
| sticky, and never cleared | cleared only on `!rst_n`, deliberately not on `clear`. So it says "at some point since programming", never when, how often, or how close it came |
| OR-reduced across lanes | `handler_multi.sv:680` packs `\|lane_fifo_stall`. On build-110 four lanes collapse into one bit and the guilty lane is unknowable |

And it is **ambiguous between two opposite diagnoses** — ADR-2's 2026-08-18 note: the bit now sets
routinely because the *decoder* stopped consuming, not because the fifo is small. Same bit, opposite
fixes. Disambiguating it today means reading `inflight` beside it and reasoning.

**The change this needs.** `axis_fifo` already computes `level` and both handlers throw it away
(`.rx_fifo_level()` unconnected — `handler_stream.sv:341`, `handler_multi.sv:413`). Add a per-lane
max-hold register and a CSR word. The counter exists; this is a flop and a register slot.

**Prediction on record, from ADR-2's own arithmetic.** The worst case is the header walk holding the
parser off the fifo for ~550 cycles while beats arrive back-to-back: 550 × 64 B = **35 KB**, which is
**~7 %** of 512 KiB.

**Decision rule:**

| high-water mark | conclusion |
|---|---|
| ≤ ~15 % | sizing is proven generous. Every `rx_fifo_stall` in the run is **downstream** (decoder starved) by elimination, and the depth can be cut. `handler_multi.sv`'s own header already argues this: the 8192 depth exists because a *single* lane had to absorb a whole response, but with `rx_dispatch` gating per lane on `conn_space_ok` a lane needs one MSS plus decoder jitter. Reclaiming most of 512 RAMB36 is also a **timing** lever, and build-103 closed at WNS −0.949 ns |
| 15–90 % | sized about right; leave it and say so with a number instead of a bit |
| pegged near 100 % **with the decoder still consuming** | genuinely undersized. Back-pressure is reaching the TOE, which breaks the arrival-order contract for **every other lane at once** — the ADR-1 failure reached from the other direction |

Note the qualifier in the last row: pegged *with the decoder stalled* says nothing about sizing, it
is the dispatcher-deadlock signature arriving several links downstream.

**For the thesis.** This converts "the fifo was sized by trial" into a sizing argument with a
measured bound behind it — §3.4's decoupling-fifo decision (ADR-2) currently rests on the cliff
disappearing, which shows the fifo is *sufficient* but never that it is not 10x oversized.

- Result: **Partially answered 2026-08-27 — the FIFO does NOT throttle throughput, but the
  high-water register still does not exist.**

  Measured instead of the missing counter, using the advertised TCP window as a proxy for the TOE
  buffer's free space (window = buffer − unread), captured on the MinIO host:

  | | |
  |---|---|
  | window during normal operation | oscillates 1,028,080 ↔ **1,048,560**, returning to full 1 MiB |
  | zero-window events during a working run | **0** |
  | `out_stalled` (output buffers / DMA) | **0**, every column, every run |

  **A buffer that repeatedly empties completely cannot be throttling anything.** The reason nothing
  fills is simply that the network supplies ~180 MB/s while the decoder eats 469–1141 MB/s (M2.1) —
  the design is **starved, not backed up**.

  **Still not measured:** `rx_fifo_stall` has never been read on a *healthy* board — only on wedged
  ones — so the tcp_read FIFO specifically is exonerated only by inference from the window. The
  per-lane `level` high-water register proposed above is still the right change and still unbuilt;
  the 35 KB / ~7 % prediction remains untested.


---

## M7 — The response-size cap: total receive buffering is 1.5 MiB ✅ tested 2026-08-27

**This section did not exist before today. It is the hard limit that bounds M1.3, M3 and M4.**

### What was tested

A copy of sf30 `lineitem` was written with `ROW_GROUP_SIZE 1000000` (vs DuckDB's default 122,880)
and uploaded to `throughput/tpch-30-big/`, to raise the request size and cash in the M1.3 knee.
Chunk sizes, read from the footers of both files:

| column | `tpch-30` (122,880 rows) | `tpch-30-big` (1,001,472 rows) |
|---|---|---|
| `l_orderkey` | 193,097 B (0.18 MiB) | **1,564,246 B (1.49 MiB)** |
| `l_shipdate` | 194,978 B (0.19 MiB) | **1,516,363 B (1.45 MiB)** |
| `l_extendedprice` | 635,290 B (0.61 MiB) | **5,175,343 B (4.94 MiB)** |

Reading it with splitting off (`OASIS_HTTP_CHUNK_BYTES=0`) **deadlocks the board immediately.**

### The mechanism, confirmed on the wire

| buffer | size |
|---|---|
| TOE rx buffer (its free space **is** the advertised window) | 1024 KiB |
| `tcp_read` `RX_FIFO_DEPTH` = 8192 × 64 B | 512 KiB |
| **total receive buffering** | **~1.5 MiB** |

A response larger than total buffering cannot be absorbed at any drain rate. In the capture the
window walks down in 8192 B steps to **28,656**, and the next step (20,464) is ≤ **28,096**
(= 24,000 + MSS 4,096), so `rx_sar_table`'s clamp collapses it to **0** — **firing exactly as
designed**. MinIO then probes with textbook exponential backoff (gaps of 0.21, 0.41, 0.84, 1.66,
3.26, 6.85, 13.31 s) and the FPGA answers `Win=0` forever. The FPGA also emits a **new GET while
advertising `Win=0`**, i.e. the handler moves on while the TOE still holds ~1 MiB of unread body.

`configuration.cpp` predicted this boundary in as many words — *"sweeps hang AT the window, not at
some fraction of it — is the thing to re-test if this default misbehaves."* It misbehaved.

### What this bounds

- **`OBM_BUFFER_CAPACITY` (8 MiB decoded) was never the binding constraint.** The 1.5 MiB
  *compressed* receive path is, and it is 5x tighter. Row groups must be sized against it.
- The usable single-session request size is **≤ ~1 MiB**, which pins single-session throughput at
  **0.43–0.48 GB/s** (M1.3). This is the ceiling build-110 multiplies, not 0.89 GB/s.
- `RX_FIFO_DEPTH` and `WINDOW_SCALE_BITS` are the only levers, and both cost BRAM that lanes also
  need (M4).

### Also established: the zero-window events are a deadlock, not throttling

Filtering the full capture on `tcp.analysis.zero_window && ip.src==10.253.74.80` returns **12
packets, all inside the final 27 s of a 326 s run**. During normal operation the window never
reaches zero. So the FIFO does not throttle throughput (M6) — it fails once, terminally, and only
when a single response exceeds total buffering.

**Not resolved:** *why* the deadlock never recovers. The clamp collapses the window cleanly to zero,
so ordinary TCP flow control should resume once the decoder drains. It does not, and the cause was
not found. This is the one open hardware question from today.

- Result: tested and reproduced; mechanism confirmed; recovery path unexplained.

---

## M8 — Multi-decoder scaling: the result the thesis is built on ✅ measured 2026-09-12

This section answers **M4** (which build-110 was supposed to answer and never did) and supersedes
every absolute throughput number in §0 and M1–M7, all of which were taken on build-105 with **one**
decoder.

### M8.0 — Why these runs are trustworthy, when the ones before them were not

The three results retracted in the corrections block above were all killed by the same mechanism:
**MinIO's page cache warms as a run proceeds, so anything swept in a fixed order measures run order.**
Rule 9 in §0.4 is the fix, and these runs obey it:

- a **prewarm pass** first, discarded;
- then the lane count is swept **forward 1→4 and reverse 4→1** (`scale_pal`);
- `wide` workload, `OASIS_HTTP_CHUNK_BYTES=0`, median of 3 repeats per point;
- decoders whose `(rate, hs)` pair does not change across repeats are **excluded as stale** (rule 10).

**The decision rule, stated before the run:** forward and reverse must agree at every lane count, or
the curve is discarded. They agree at all four points: the two directions differ by **1.8 % / 1.9 % /
0.2 % / 2.0 %** at 1 / 2 / 3 / 4 lanes — worst case **2.0 %**, best **0.2 %** at 3 lanes, and the
deviations are small enough that the 3.76x conclusion does not depend on them.

One honest caveat: the reverse pass is the higher of the two at **3 of the 4 points**, and reverse ran
second, which is the direction a small residual cache-warming effect would push. It is bounded by the
2.0 % spread, so it cannot manufacture the result — but the palindrome damps drift rather than
eliminating it, and a third pass in a randomised order would settle it.

### M8.1 — The scaling curve (build-119, `scale_pal`) — **the headline result**

| lanes | forward | reverse | **mean MB/s** | **vs 1 lane** |
|---|---|---|---|---|
| 1 | 204.1 | 207.9 | **206.0** | 1.00x |
| 2 | 398.7 | 391.3 | **395.0** | **1.92x** |
| 3 | 587.5 | 588.5 | **588.0** | **2.85x** |
| 4 | 767.4 | 783.2 | **775.3** | **3.76x** |

Increments **+189.0, +193.0, +187.3 MB/s** — uniform to within 3 %. **There is no sign of flattening
at four lanes**; the design stops at four because a fifth decoder does not fit in the SLR (§0.2), not
because scaling ran out.

Raw logs: `oasis-debug/b119_pal_{fwd,rev}_{1,2,3,4}.txt`, provenance in `oasis-debug/RUN-PROVENANCE.md`.

> **Do not confuse this with the ~570 MB/s 4-lane figure** that also appears in the 2026-09-12 record
> (`b11{8,9}_scale_*`, 569.7 and 574.4). Those come from the older `scale` harness, which sweeps in one
> direction and does not exclude stale counters. They are used **only** for the like-for-like 118-vs-119
> comparison in M8.5, where both arms share the bias. The citable absolute is **775.3**.

### M8.2 — TPC-H at sf30 on four decoders, and where the FPGA time actually goes

`./scripts/tpch_demo.sh --single-session --threads 1`, cache off on both sides, **22/22 PASS**.
Log: `oasis-debug/b119_tpch_fair.txt`.

| | FPGA | CPU (1 thread) |
|---|---|---|
| q1 / q10 / q12 / q19 | 5.15 / 5.01 / 5.10 / 4.74 = **20.00 s** | 2.95 s |
| the other 18 | **6.98 s** | 11.50 s → **FPGA 1.65x faster** |
| all 22 | 26.98 s | 14.45 s → CPU 1.87x |

Those four queries carry **74 % of total FPGA runtime** and each sits at a flat ~5 s, which is the
signature of the two ~2 s `READ_TIMEOUT_CYCLES` watchdogs, not of decode work. **The FPGA already wins
13 of the 22 outright** (q16 is a tie at 0.12 s). The CPU phase ran after the entire FPGA phase and so
read a warm server cache — by a whole phase, not by one query — so the 1.65x on the other 18 is if
anything understated.

**Prediction on record, before build-120's hardware run:** if TODO 1 (lazy open / no idle reconnect)
removes the watchdog penalty on those four, the total lands near **~11 s and beats the CPU outright**.
Build-120 was still in bitgen at 19:32 on 2026-09-12, so this is **unfalsified, not confirmed**.

### M8.3 — Where the limits are, and none of them is the FPGA

| candidate bottleneck | what it permits | what we achieve | verdict |
|---|---|---|---|
| receive window (`W/RTT`) | **7.77 GB/s** | 0.463 one session = **6.0 %**; 0.775 at 4 lanes = **10.0 %** | **not binding.** Do not claim to have reached `W/RTT` |
| MinIO aggregate | **4.60 GB/s** over 16 streams | 0.775 = **17 %**, i.e. **5.9x headroom** | **not binding** |
| TOE → decoder datapath | ~13.9 GB/s per lane | 0.775 total | **not binding** |
| decoder itself | `stalled` 10–14 % | — | **not binding** |
| **per-connection service rate** | 0.463 GB/s = ~1.70 ms of serialized service per 768 KiB GET | — | **this is the one** |

**The defensible thesis paragraph:** the receive window is not binding (7.8 GB/s permitted, 0.46
achieved on one session); the object store's aggregate is not binding (4.60 available, 0.78
collected); the binding constraint is **per-connection service rate under HTTP/1.1's in-order
responses**, and therefore concurrency. What caps concurrency is the TOE's positional
`rxBufferReadCmd`, which forces a single arrival-ordered receive path across all lanes.

### M8.4 — Clean negatives (trustworthy precisely because drift produces false positives, not nulls)

- **Pipelining depth does nothing.** 4 / 8 / 16 outstanding GETs → **557.0 / 552.9 / 585.1 MB/s**, no
  trend. More outstanding requests on one socket cannot overlap under HTTP/1.1.
  Logs `b119_depth{4,8,16}.txt`.
- **Chunk size does nothing — the default is the best setting.** The order-cancelling A/B
  (`chunks_ab 0 1048576`) gives default **742.6 / 774.7 / 775.0** against 1 MiB **703.6 / 747.0 /
  720.4**: the default wins all three pairs, **+7.5 %**. Keep `HTTP_DEFAULT_CHUNK_BYTES = 0`.
  Logs `b119_ab_{A0,B1048576}_{1,2,3}.txt`. This is the run that reversed the retracted "+33 %".
- **The `lane_depth × chunk_bytes ≤ 256 KiB` budget rule is lifted.** The readPkg reservation is
  hardware-verified with correct sums at depth 4 × 256 KiB = 1 MiB per lane.

### M8.5 — build-118 vs build-119: the `axis_skid` register slice bought nothing

A like-for-like A/B on the same harness (`scale`, hence the lower absolutes — see the note in M8.1):

| | build-118 | build-119 (+ `axis_skid`) |
|---|---|---|
| WNS | **−1.344 ns** | **−1.474 ns** |
| failing endpoints | 2,464,261 | 2,472,435 |
| HTTP-logic violated paths | **59** | **59** |
| 4-lane MB/s | 569.7 | 574.4 (**+0.8 %, inside noise**) |

Timing slightly worse, throughput unchanged, the targeted violation count identical. At four decoders
the constraint is the decoder itself (`decoder:page/run` went 170 → 476 paths) and the HBM shell, not
the `skid_keep_q` cone the slice was aimed at. **Decision: do not commit `axis_skid.sv`.** It is
reverted from the tree and kept untracked; the pre-revert file is at
`oasis-debug/handler_multi.sv.slice119.bak`.

For context, WNS across the decoder counts: build-117 (3 decoders) **−0.849 ns**, build-118 (4)
**−1.344**, build-119 (4 + slice) **−1.474**. Timing degrades with decoder count, which is the second
reason — after area — that four is the stopping point.

### M8.6 — What is still unexplained: the ~190 MB/s per lane

Each lane delivers ~190 MB/s and we cannot yet say why that number and not a larger one. It is **not**
the decoder (`stalled` 10–14 %), **not** the datapath (~13.9 GB/s/lane), **not** the window (10 % of
BDP), **not** MinIO's aggregate (17 % of it). It is **~42 % of the 0.46 GB/s single-connection
ceiling**, so there is headroom even within one connection.

**Next probe:** `win_profile.sh` against a packet capture — a wide-open advertised window points
upstream (request issue / service rate), a window parked low points at the reader. This needs
`tshark`, which is **not installed on the deploy node**.

### M8.7 — Provenance of this section

Re-derived from the raw logs while writing this entry, not carried over on trust: **every value in the
M8.1 scaling table** (all eight forward/reverse figures reproduce as consecutive 4-decoder window sums
in `b119_pal_*`), **the entire M8.2 TPC-H table** (read directly from `b119_tpch_fair.txt`, including
the 13-of-22 count and the 20.00 s subtotal), and **all three WNS figures in M8.5** (read from
`hardware/build-1{17,18,19}/reports/shell_timing_summary.rpt`).

Carried from the 2026-09-12 run notes without independent re-derivation, because they depend on
`sumrate`'s median-with-stale-exclusion statistic: the depth medians and the chunk A/B medians in
M8.4, the RTT figures, the LUT counts, and the `stalled` percentages.

---

## What was NOT tested — an honest list, 2026-08-27

Nothing below has evidence behind it. Written down so no draft accidentally claims it.

### Correctness

- **`scripts/soak.sh` has never been run against build-105.** No record in this document, no commit
  mentions it. The 20-case decoder corpus — 4-row pages, plain (non-dictionary) pages, INT64, a
  100k-entry dictionary, the uncompressed path, the beat-boundary seam, the output-buffer boundary
  at 131,072 rows **and one over at 131,073**, 245 row groups, gzip/zstd **rejection**, a zero-row
  file — is entirely unexercised on this bitstream.
- What *is* proven: **22/22 TPC-H at sf30** cell-for-cell vs stock DuckDB (`tpch_demo.sh`), plus
  today's four workloads matching the CPU exactly with byte-identical `mib_in` across three repeats.
  That covers the workload; it does not cover the encoding edge cases.
- **Correctness has never been checked across request shapes** — the `OASIS_HTTP_CHUNK_BYTES` ×
  `OASIS_HTTP_MAX_INFLIGHT` matrix. A sweep of that would have caught M7's deadlock days earlier.
- `extension/test/sql/httpfpga_decode.test` is **stale** — points at `httpfpga://tb/...` and no `tb`
  bucket exists. It fails for the wrong reason.

### Hardware / measurement

- **`rx_fifo_stall` on a healthy board.** Only ever read on wedged ones. M6's FIFO exoneration rests
  on the advertised window as a proxy, not on the bit itself.
- **The per-lane FIFO high-water register** (M6) is still unbuilt; the 35 KB / ~7 % prediction is
  untested.
- **M2.2** (value rate vs byte rate), **M2.3** (cycle-accurate sim ceiling), **M2.5** (feed the
  decoder at full system rate) — none run.
- **M4 / build-110** — no bitstream; still routing after ~22 h.
- **The 512 KiB and 768 KiB points of the request-size sweep on the big file.** Only 262,144 ran,
  and with `OASIS_HTTP_MAX_INFLIGHT=1`, which removed pipelining and made the result
  non-comparable: `idle` fell 59.1 % → 17.8 % (the row-group change working) but `starved` rose
  7.2 % → 47.8 % and throughput did not move (178.5 → 180.6 MB/s). The split at 256 KiB also put the
  request count back to 1071 vs 1465, so it undid most of the row-group benefit. **This experiment
  needs re-running at 512 KiB / 768 KiB with depth ≥ 2.**
- **Whether the decoder is specifically the Snappy core.** `in_stalled` tracks the copy fraction
  across three columns (M2.1), which is strong, but it is not isolated.

### Comparison

- **DuckDB's connection count was sampled by eye**, not logged: "2 connections for about a third of
  the time, otherwise 1". The ~1.3 average behind M1.4's per-connection parity claim is that
  estimate. Worth a proper count before it goes in the thesis.

---

## Addendum to the honest list — 2026-09-12

Still no evidence behind any of this. The 08-27 list above stands except where M8 answered it.

- **build-120 has never run on hardware.** It was still in bitgen at 19:32 on 2026-09-12. M8.2's
  "~11 s and beats the CPU outright" is a **prediction on record, not a result**. Nothing in this
  document may cite a build-120 number.
- **The ~190 MB/s per lane is unexplained** (M8.6). Every candidate bottleneck has been excluded and
  none of them accounts for it. A thesis can state what it is *not*; it cannot yet state what it is.
- **`win_profile.sh` has never been run** — `tshark` is not installed on the deploy node. This is the
  one probe that would separate "upstream" from "reader" for M8.6.
- **`scripts/soak.sh` has still never been run**, now against *any* of builds 117–120. The 20-case
  decoder corpus remains entirely unexercised on the multi-decoder design; 22/22 TPC-H covers the
  workload, not the encoding edge cases.
- **Correctness has still never been checked across request shapes** (the `OASIS_HTTP_CHUNK_BYTES` ×
  `OASIS_HTTP_MAX_INFLIGHT` matrix) — and now there is a second axis, lane count, that has not been
  crossed with it either.
- **The chunk and depth medians in M8.4 were not independently re-derived** (M8.7). They rest on
  `sumrate`'s stale-exclusion statistic. The *conclusions* are robust — a null result cannot be
  manufactured by cache drift, which produces false positives — but the specific medians should be
  recomputed from the raw logs before any of them is printed as a figure.
- **The code under measurement was uncommitted working-tree state at the time.** Every M8 number was
  taken between 12:11 and 14:09; the readPkg reservation (`a9a99e8`) and the TODO 1 lazy-open change
  (`a08b100`) were only committed at 14:24–14:28, after the fact. They are in `feature/minio` now, so
  the tree is reproducible going forward — but no run in M8 was taken from a clean, tagged checkout,
  and the bitstreams remain the only exact record of what was on the board
  (`hardware/build-11{8,9}/`).
