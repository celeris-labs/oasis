# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Scope: the regex offload path**, which is the active work (branch `feature/regex`). The
Parquet-scan path (`read_oasis`, `extension/src/oasis_scan.cpp`,
`extension/src/coalesced_fetcher.cpp`, `extension/src/rdma_file_system.cpp`) is earlier work
that still builds and still has tests; `README.md` and `extension/CLAUDE.md` cover it and the
general FPGA workflow.

**The RTL and the celeris host library have their own guide at
`/scratch/vifranz/celeris/CLAUDE.md`** — read that for the NFA array, the wire format, the
simulation loop, and synthesis. This file covers the DuckDB side and the benchmark harness.

**The array is now 128 engines**, tiled 8 × 16 so it can span SLRs (`rem_engine_tile.sv`,
`rem_pipe.sv`). That RTL lives, uncommitted, in the `/local/home/vifranz/celeris` checkout, and
the flashed bitstream is `build_hw_engine` (WNS −0.003 ns, on a tile-local reset path). The
host side must agree: `kRegexEngineCount = 128` in `celeris/.../regex_stream.hpp` and
`kRegexMaxSubmissionsInFlight = 64` (the RTL arm-queue depth) in `regex_fpga_batch.hpp`. A host
built for 64 engines against this card wedges it.

## Build and run

The extension requires the oasis software library installed first (see `README.md`; it
installs to `~/opt` by default). Then, from `extension/`:

```bash
make -j                 # release -> extension/build/release/duckdb, statically linked
make debug              # -> extension/build/debug/duckdb
make test               # release test suite
make format             # DuckDB's formatter
make tidy-check
```

**The release build links a jemalloc that is not on the default loader path.** Every
invocation of the built `duckdb`, `unittest` or `benchmark_runner` needs:

```bash
export LD_LIBRARY_PATH=$HOME/opt/lib:$LD_LIBRARY_PATH
```

Forgetting this is the most common "it doesn't start" failure. The benchmark scripts set it
themselves; interactive shells do not.

One SQLLogicTest file (`extension/test/sql/`, syntax `statement ok` / `query I`,
`require oasis`), run from `extension/`:

```bash
./build/release/test/unittest "test/sql/regex_fpga_scan.test"
```

`oasis.test`, `regex_fpga_scan.test`.

## Hardware prerequisites — non-obvious and silent when wrong

- **1 GiB huge pages must be provisioned**: `sudo hdev set hugepages --num-1g 12`, from a
  real terminal (sudo here refuses a tty-less caller, so not from a tool call or `!`).
  The pool **leaks**, so reset it between runs. Three traps, all silent:
  the old `-p 16 -s 1G` flags are gone; the 25%-of-RAM-per-NUMA-domain cap counts the
  2 MiB pool too, so a populated 2 MiB pool rejects any 1 GiB request on this box; and
  hdev writes the 1 GiB count *before* the 2 MiB one, so clearing 2 MiB and requesting
  1 GiB in one invocation allocates zero gigabyte pages. Do it in two calls,
  `--num-2m 0` then `--num-1g 12`, and check
  **`free_hugepages`, not `nr_hugepages`** --
  `/sys/kernel/mm/hugepages/hugepages-1048576kB/free_hugepages`. Fragmentation can hand
  back fewer pages than asked (10 of 12 here), which is fine: the regex path needs
  ~128 MiB.

  `nr_hugepages` is the trap. It reports the pool size, which stays at 12 whether or not
  the pages are usable, so a leaked pool looks identical to a healthy one. Only
  `free_hugepages` distinguishes them, and the extension's own preflight reads that.

  **A wedged run leaks the pages irrecoverably.** `--num-1g 12` is a no-op when the pool
  is already 12, so the documented reset does nothing after a hang; `--num-1g 0` reports
  success but does not shrink the pool either, because the pages are pinned below the
  allocator (no process maps them, and `coyote_driver` is loaded with refcount 0).
  Measured 2026-09-07: only a **reboot** clears it. Budget for that -- there is no
  userspace way back.

  The driver itself does *not* claim the pool: after a reboot and a reprogram, with
  `coyote_driver` loaded and no run started, all 12 pages are free. So "the pool leaks"
  means "a wedged run leaks it", not "loading the driver eats it".

  `hdev set hugepages --help` on this box documents `-p/--pages` and `-s/--size`, but the
  binary rejects `-p` outright. The help is stale; `--num-2m` / `--num-1g` are the real
  flags.
- **An exhausted pool produces wrong results *and* meaningless timings, without an error.**
  If counts look off, check the pool before debugging the matcher.
- **Only one process can hold the card and the pages at a time.** A stray `benchmark_runner`
  or `duckdb` from an abandoned run wedges every subsequent FPGA query. `scripts/regex_report.py`
  has a `preflight()` that checks both; copy that check rather than rediscovering it.
  `scripts/regex_card_health.sh` is the full check (module state, D-state tasks, holders,
  free pages). It can report a transient "REBOOT REQUIRED" while a process is still tearing
  down, so re-run it before believing that. `scripts/regex_fsst_stress.sh` looks for holders
  with `pgrep -f 'release/duckdb|benchmark_runner|unittest'`, which matches its *caller* when
  the calling command line contains those strings. Launch it from a clean command.
- **Stopping a run:** SIGTERM by PID, never `pkill -f` (it matches its own shell). `pgrep -x
  benchmark_runner` finds nothing, because the kernel truncates the name to 15 characters.

## The regex path

One entry point:

- **Table function** `regex_fpga_scan('tbl', regex_column := 'c', pattern := '...')` —
  `extension/src/regex_table.cpp`, ~1700 lines and the centre of gravity. It does its own
  storage scan with projection pushdown, so it replaces the table reference rather than sitting
  above it. Filter pushdown is deliberately **off**: a pushed filter makes DuckDB fetch the other
  columns through `FSSTStorage::Select`, which always decompresses, so filters run above the scan.

Pattern → config blob: `NFA(pattern, REGEX_MAX_STATES, REGEX_MAX_TOKENS).dump_binary()`,
zero-padded to `REGEX_CONFIG_BLOB_BYTES`. The NFA compiler is
`celeris/software/celeris/operators/regex/nfa.cpp`.

### The budgets are build-time constants that must match the flashed bitstream

`extension/CMakeLists.txt:82-83`:

```cmake
set(OASIS_REGEX_MAX_TOKENS 32)   # predicate slots per engine == bitstream CHAR_COUNT
set(OASIS_REGEX_MAX_STATES 28)   # NFA states per engine     == bitstream STATE_COUNT
```

These are propagated as `-DREGEX_MAX_*`. A mismatch
against the bitstream shifts every field after `state_pred`, so the card decodes a
valid-looking but **wrong** pattern — no error, just bad answers. This has already happened
once, which is why `extension/src/regex_table.cpp` `#error`s rather than restating the
values. When the bitstream changes, change them here and nowhere else.

Cost model: a literal costs **one slot per character**, a character-class range costs **two**
(lo/hi pair), and identical literals/ranges deduplicate. Character classes are cheap and
reusable; literal text is what actually exhausts the budget.

### Two failure modes at the frontier, and one is a bug

```
.*[acegikmoqsuwy09BDFHJLNPRTVXZ!#].{26}     binds (28 states, exactly at the cap)
.*[acegikmoqsuwy09BDFHJLNPRTVXZ!#].{26}     + trailing space -> 29 states
    -> "Invalid Error: NFA has 29 states but hardware supports at most 28"   (clean)
.*[acegikmoqsuwy09BDFHJLNPRTVXZ!#]x.*       one distinct character too many
    -> "Invalid Error: bitset::set: __position (which is 32) >= _Nb"         (NOT clean)
```

The state budget validates properly (`nfa.cpp:533`). The **token/slot budget does not**: it
overruns `std::bitset<REGEX_MAX_TOKENS>` at `nfa.cpp:682` and surfaces a raw libstdc++
message instead of a "pattern exceeds N predicate slots" rejection. Fix belongs in `nfa.cpp`,
next to the existing state check.

### Scan loop

`TryRefillScanChunk` → `AccumulateRows` → `SubmitStagedBatch` → collect → `AppendMatchedRows`.
Things worth knowing before editing it:

- **`StagedRowRef` is a 12-byte RUN, not a row**: `Count()` consecutive rows of one chunk
  decided by as many consecutive slots (count in 15 bits, CPU verdict in bit 15).
  `PushSlotRun` merges contiguous rows. A plain FSST chunk is one ref instead of 2048; one
  ref per row was ~190 MB written and re-read per query.
- **Chunk-level staging fast path** (top of the row loop in `AccumulateRows`). On chunks with no
  dictionary, identity selection and no NULLs, a tight loop stages rows until one might close
  the batch or needs the general loop, which then decides that row exactly as before. Batch
  boundaries are therefore unchanged. Staging went 30.4 → 17.5 ns/row.
- **Straddle side batch.** Under the FSST passthrough, rows DuckDB hands back decompressed
  (segment straddles, ~10%) ride an identity symbol table in their own batch
  (`ParkedStagedBatch`, `SwapStagedBatch`). Without it every segment/straddle alternation
  closed the batch. A parked batch holds staging refs on its chunks until it submits.
- **Chunk recycling + decoder pin.** Scanned `DataChunk`s go back to a per-thread pool. When
  nothing is projected (`count(*)`) a chunk is recycled as soon as it is staged, and collect
  counts bits instead of building selections. A batch's table identity is its FSST decoder's
  *address*, so an open batch pins the vector buffer that owns the decoder
  (`batch_decoder_owner`). Without that, a recycled address could admit another segment's rows
  into a batch carrying the wrong symbols — wrong answers, no error.
- **Compressed padding uses the table's shortest symbol** (`ShortestSymbolCode`). The engines
  walk padding *decoded*, and code 1 is often an 8 B symbol.
- **Dictionary fast path**: rows sharing a dictionary entry share one transfer slot. This is
  also why benchmark data must stay high-cardinality — otherwise you measure dedup, not the
  engine.
- **Outliers** (`>= oasis_regex_outlier_bytes`, default 2 KiB) never reach the card; they are
  matched on the host with RE2 and carry their verdict in the ref (`CpuMatch()`). A table
  whose strings are *all* that long puts nothing on the FPGA and silently compares RE2
  against RE2.
- **`InFlightTransfer` must be drained, not dropped.** Destroying one uncollected strands its
  handle at the head of the `OutputBufferManager`'s positional queue. See
  `~RegexFpgaScanLocalState`.
- **`RetainedChunk::staging_ref`** exists because one scanned chunk can span several submits;
  releasing it per-submit double-frees a chunk an outstanding transfer still reads from.
- **Projected columns are pinned, not copied** (`RetainOutputColumns`). A retained chunk's
  string columns keep pointing into storage; the chunk holds `BufferHandle` pins on the segment
  the scan started in and the one it ended in, and an FSST vector stays compressed, so
  `output_cache.Append` decompresses only matched rows. The pins prove nothing when the scan
  crossed more than one segment boundary, or moved to another row group or to transaction-local
  rows, so those chunks fall back to copying every string.
- **Output chunks carry the row group's batch index** (`get_partition_data`). Without it any
  order-preserving plan -- every `SELECT` that returns rows -- ran single-threaded. Batch
  indices are not consecutive per thread, so `output_batch_marks` cut the cache wherever the
  index changes and no emitted chunk mixes two.

Batch geometry lives in `extension/src/include/regex_fpga_batch.hpp`: 16384 rows per batch
(`REGEX_FPGA_MAX_ACCUM_COUNT`, lowered from 65536 once streaming cut the round trip from
~134 us to ~7.6 us). Each thread's wire buffers are 4 MiB out of the huge-page pool: one per
in-flight transfer plus the active and parked batches, so 16 threads × 6 = 384 MiB at the
defaults. Under the FSST passthrough a batch also closes at every symbol-table change, so
compressed transfers are at most one DuckDB segment: ~1 MB of text at 72 B strings, ~0.65 MB at
24 B. *(Note: the `oasis_regex_batch_rows` description string in
`extension/src/oasis_extension.cpp:62` still says "default 65536" and is stale.)*

### Threads × window: the defaults are 16 × 4

Every outstanding transfer holds one of 64 arm credits, so the scan caps its threads at
64 / `oasis_regex_max_in_flight`. The default window is **4** (`REGEX_FPGA_DEFAULT_IN_FLIGHT`),
giving 16 threads. Sweep on the 128-engine card, FSST 72 B (GB/s): 16×4 26.5, 16×2 25.7-26.2,
20×2 25.7, 32×2 24.6, 16×3 25.0, 24×2 24.5, 12×5 22.3, 8×8 17.2, window 1 20.4-23.0. Pinning
to the 16 physical cores (0-15) is worse, because the interrupt thread then competes with scan
threads. Only FSST 72 B was swept; plaintext is PCIe-bound anyway.

### Session settings, env switches and profiling

Settings: `oasis_regex_dry_run` (run the whole host pipeline, skip the device — isolates
scan+pack cost; results are wrong by construction), `oasis_regex_batch_rows`,
`oasis_regex_wire_buffer_bytes`, `oasis_regex_outlier_bytes`, `oasis_regex_max_in_flight`,
`oasis_regex_max_threads`, `oasis_regex_fsst_passthrough` (**on** by default; compression needs
`SET GLOBAL enable_fsst_vectors = true`; projecting the regex column keeps it compressed until the
card has matched). The card has no plaintext path: every transfer carries a symbol table, and rows
not shipped compressed -- straddles, `enable_fsst_vectors` off, or the passthrough off -- ride an
identity table. Turning the setting off never sends plaintext.

Env switches, all read once per scan:

| Variable | Default | Effect |
|---|---|---|
| `OASIS_REGEX_TABLE_SLOTS` | `0` | `1` restores the one-FSST-table-on-card gate. It serialised every compressed transfer: 1.9 vs 18.2 GB/s |
| `OASIS_REGEX_SIDE_BATCH` | on | `0`: straddle rows close the segment batch again |
| `OASIS_REGEX_FAST_STAGE` | on | `0`: per-row staging loop only |
| `OASIS_REGEX_CHUNK_RECYCLE` | on | `0`: no chunk pool or early release |
| `OASIS_REGEX_LATE_MAT` | on | `0`: projected string columns are decompressed and copied for every scanned row again, instead of pinned and decompressed only where the card matched |
| `OASIS_REGEX_DUMP_WIRE=<dir>` | off | dump each transfer as armed (`OASIS_REGEX_DUMP_WIRE_MAX`, default 4000), for celeris `06_regex --bench-replay DIR N W [PATTERN] [PLAIN_LEN]` |

`regex_fpga_batch_phases()` / `regex_fpga_reset_phases()` accumulate per-phase time summed over
threads (scan, stage, emit, drain, mutex_wait, config, handle, ...). `regex_fpga_stream_profile()`
reads the RTL's stream counters for the *last* batch only. Everything under `fpga_mutex` is
serialized, so above one thread read the phases as shares of thread time. Divide by
`strings` for ns/row, by `batches` for µs/transfer, and **always compare against the same run
with `oasis_regex_dry_run`**: the gap is what the device interaction costs. Profile CPU with
`perf record` (perf_event_paranoid is 1).

**Where the time goes now** (p_substring_72_10_15728k, FSST, defaults): host alone (dry run)
~39 GB/s; the card path replaying DuckDB's own dumped transfers, with no host work, 28.0 GB/s;
end to end 26.2-26.5. CPU is staging ~37%, DuckDB's `FSSTStorage::StringScanPartial` ~22%,
`duckdb_fsst_decompress` for straddle rows ~8%. Under the submission lock, libstf's
`acquire_output_handle` costs 7-15 µs per transfer — **do not modify libstf or coyote**; work
around their costs from the extension.

## Benchmark harness — `scripts/`

`regex_report.py` produces the canonical numbers: four suites (`patterns`, `selectivity`,
`length`, `threads`), each timed with DuckDB's `benchmark_runner` (warm-up plus N
timed runs, median), software and FPGA. Results land in `scripts/results/*.csv`. Run from the
repo root:

```bash
python3 scripts/regex_report.py                    # everything
python3 scripts/regex_report.py -s patterns --repeat 2
python3 scripts/regex_report.py --list
```

**To add a pattern, edit `scripts/regex_patterns.py` and nothing else** — `regex_gen.py`
generates a matching table at the right geometry automatically on the next run.

`regex_bench.py` compares one `SIMILAR TO` query against its `regex_fpga_scan` rewrite;
`regex_sweep.py` drives the parameter sweeps in `regex_cases.py`.

`regex_mat_bench.py` is the materialisation question specifically: what the operator pays to
*emit* rows rather than count them. One table (`m` in `/local/home/vifranz/regex_mat_fsst.duckdb`:
the 72 B FSST substring data plus an id, a 28 B second string and precomputed match flags), six
select lists from `count(*)` to whole rows, four selectivities set by pattern so the rows never
change. Its `oracle` variant filters on the precomputed flag instead of matching, which is what
DuckDB pays to produce that output once the answer is known, so
`fpga count(*) + (oracle shape - oracle count)` is an upper bound for the accelerated query.
(Do not write the 0% oracle as `WHERE false`: the optimiser folds it away and never scans.)

### Benchmark data: uncompressed by default, one local FSST twin

Compression is paid back as CPU on every scan and it favours software unevenly (RE2 gains
30%+ where it reduces to a `memchr`, ~0% where it genuinely matches), so the canonical
databases stay `*_uncompressed.duckdb` on `/scratch` (NFS, slow cold reads).

But plaintext caps the FPGA at the PCIe limit (~11.7 GB/s at any engine count), so measuring the
128-engine card needs the FSST passthrough. That uses the local FSST twin of the pattern tables:

```bash
REGEX_GEN_DB=/local/home/vifranz/regex_gen_fsst.duckdb REGEX_GEN_COMPRESSION=fsst \
  python3 scripts/regex_report.py -s patterns --fsst --exclude 'State explosion'
```

`REGEX_GEN_COMPRESSION=fsst` is required: without it the script would regenerate the twin as
plaintext, and it refuses rather than doing that. `--variant fpga` measures one side only, so
its cases read "skipped: one variant measured" rather than being verified against software.
`--exclude 'State explosion'` is there because that case's *software* side takes several
minutes per run; FPGA-only (`--variant fpga`) is fast. The script does not record `OASIS_*`
env vars in its CSV, so note them in the file name.

**`--fsst` is verified twice, and the second check is the one that matters.**
`check_fsst_storage()` reads `pragma_storage_info` *before* the run and aborts on a table that
is not FSST. That only proves the passthrough *could* fire. Whether it *did* is a property of
the run, so the verification pass — which already executes the FPGA query once — wraps it in
`regex_fpga_reset_phases()` / `regex_fpga_batch_phases()` and records each case's row
dispositions as the `fsst_*` CSV columns, ending with a summary line:

```
FSST passthrough: 6/6 case(s) shipped compressed rows to the card, 86.4-89.9% of rows compressed
```

The remainder of a healthy case is `rows_not_fsst`: the segment straddles DuckDB decompresses
for us (~10%). A case that shipped **nothing** compressed is only an error when it could have —
the column is FSST *and* its segments hold at least 2048 rows, since
`ColumnData::GetVectorScanType` hands over an FSST vector only when a whole vector lies inside
one segment. So the length sweep's tail is reported, not failed: par_1024 at 1188 rows/segment
can never compress, and par_2048 is all outliers. A real failure names the disposition
(`mode0` = the passthrough was off, `not_fsst` = the scan was handed flat vectors), prints
"this row's FPGA number is a plaintext measurement", and exits non-zero.

Because that check lives in the verification pass, `--fsst --no-verify` cannot tell a
compressed run from a plaintext one and says so on stderr. Don't quote numbers from one.

### Row-group count is a real experimental variable — do not change row counts casually

DuckDB hands out scan work **one whole row group per task**
(`extension/duckdb/src/storage/table/row_group_collection.cpp`, `NextParallelScan`), and
tasks are equal-sized. So with G row groups on T threads the makespan is `ceil(G/T)` waves and
utilisation is `G / (ceil(G/T) * T)` — a sawtooth, not a curve. On 32 threads: 25 groups is
0.78, **37 groups is 0.58** (32 in the first wave, 5 in the second, 27 threads idle
throughout), 32 groups is 1.00. Measured at constant volume, 25 → 37 groups cost software
20% and the FPGA path 5-9%, while the extra bytes themselves cost nothing.

`Pattern.rows` is therefore pinned to **3,932,160 = 32 x 122,880**, exactly 32 full row
groups. Keep it a multiple of `122880 * threads`. `regex_report.py`'s `check_parallelism()`
prints waves and utilisation before a run and warns below 90%.

`customer` from TPC-H sf30 is fixed at 4.5 M rows = 37 row groups and cannot be brought to
32, so any suite that scans it warns. That is expected, not a regression — but it does mean
such a case is not directly comparable to the synthetic suites at 32 threads. The `queries`
and `projection` suites are the remaining ones that do, since they read sf30 verbatim.

**The `states` suite was removed on 2026-09-12.** `.*a.{n}` over `customer.c_comment` at
n = 10/14/18/22/26 was supposed to show the FPGA staying flat while software's DFA blew up,
but all five points sat at 16-17 GB/s on the host ceiling of that column (see "Why a case
runs below ~25 GB/s"): c_comment compresses only 2.0x and straddles 17% of its rows, so it
dry-runs at 18.4 GB/s and the array never got to be the variable. The patterns suite's
"State explosion" case makes the same point at the state cap, on data that is not
host-bound.

### Rough expectations on this box (32 logical cores, 16 physical, U55C)

128 engines, FSST passthrough, defaults: FPGA **25.5-26.5 GB/s on all six patterns**, state
explosion included. Software on the same FSST tables runs 5.2-16.7 GB/s, so the speed-up is
1.5-4.7×. Plaintext FPGA is ~11.7 GB/s, PCIe-capped. (The 64-engine plaintext card was ~10.5
GB/s.) The FPGA is essentially **invariant to pattern complexity** — a 30-member class at
the state cap costs the same as `.*a.{22}`. Software spans three orders of magnitude
over the same patterns (16 GB/s where the optimiser rewrites `LIKE` to `contains()`, down to
0.017 GB/s on a wide class with a long fixed tail). The interesting cases are where software
has a specialised path and wins; the accelerator's case is the variance, not the peak.

**Emitting rows costs more than counting them, and it is the output that costs, not the match.**
On `m` (72 B FSST, 15.7 M rows, `scripts/regex_mat_bench.py`) `count(*)` is 43 ms / 26 GB/s at
every selectivity, while projecting columns costs (ms, 10% / 100%): an 8 B key 55 / 53, the regex
column itself 54 / 83, a second 28 B string 66 / 94, all three 77 / 145, whole rows to the client
93 / 534. Software is 200-284 ms for all of those and 471 at 100% emit, so the speed-up runs
2.8-4.3x at 10% and 1.5-1.8x at 100%, against 5x on `count(*)`. Two costs are structural: the
projected column is scanned for every row (verdicts arrive after the scan, so DuckDB's own
late materialisation is unavailable -- 15 ms of the 0% cost for one 28 B column), and the straddle
side batch is off whenever a column is projected, worth ~8%.

The `selectivity` suite says the same thing on its own data (`--fsst`, FPGA GB/s and speed-up at
0 / 10 / 50 / 100%): count 26.1 (4.9x) / 25.9 (4.7x) / 22.9 (4.4x) / 25.7 (5.8x), `sum(strlen(c))`
20.9 (4.0x) / 21.2 (4.0x) / 15.9 (3.1x) / 12.8 (2.6x), whole rows 21.6 (3.9x) / 19.2 (3.8x) /
8.7 (2.1x) / 4.2 (1.27x); anchored count 26.0 / 25.6 / 25.1 / 25.5. `count(*)` is flat in
selectivity, as it must be -- only the shapes that *emit* pay for it.

**Those last two columns used to read 9.8 and 3.6, and that was the generator, not the
operator.** `regex_gen.build` gives whichever side is the *majority* the 65536-string pool,
so above 50% selectivity the bulk of the column switched from `make_nonmatch` filler (word
text, FSST 3.2x) to `make_match` (regex expansion, so `.*` came out as random printable
characters, FSST ~1.2x). sel_75/sel_100 therefore stored 5652 and 4726 rows per FSST segment
against sel_0's 17515 -- and DuckDB hands the scan an FSST vector only when a whole 2048-row
vector lies inside one segment, so 35-42% of the rows went through `duckdb_fsst_decompress`
and onto the wire uncompressed. `splice_match`/`match_pool` (2026-09-12) build the match out
of filler with a minimal match spliced in at a random position, which keeps one text shape at
every selectivity; sel_75/sel_100/asel_75/asel_100 were regenerated in both the FSST twin and
the canonical uncompressed set. Count at 75/100% went 11.4/9.8 -> 25.4/25.7, anchored
11.6/9.5 -> 25.5/25.5. A residual asymmetry is left on purpose: the *minority* side is still
one repeated string, so sel_25/sel_50 compress slightly better than sel_0 (20088 vs 17515
rows/segment) and dip to ~23-24 GB/s.

On the plaintext wire the same suite isolates the partition-data fix, before -> after: count
11.92 -> 11.94 GB/s at 0% and 10.09 -> 9.97 at 100% (flat, as it must be), `sum(strlen(c))`
7.87 -> 11.53 and 5.33 -> 6.97, whole rows 0.90 -> 11.53 and 0.32 -> 3.66.

### Why a case runs below ~25 GB/s

Measured 2026-09-12 with `regex_fpga_batch_phases()`, each case paired against its own
`oasis_regex_dry_run`. Every deficit on the FSST wire is one of four things, and only the
first was a bug:

- **Segment straddle.** DuckDB hands the scan an FSST vector only when the whole 2048-row
  vector lies inside one segment (`ColumnData::GetVectorScanType`); otherwise it decompresses
  into a flat vector, which then travels uncompressed. So the compressed fraction is roughly
  `1 - 2048/rows_per_segment`, and `rows_per_segment` is set by the 256 KB block -- DuckDB
  refuses a larger one, so there is no knob. Read it with
  `pragma_storage_info(tbl)` grouped on `compression`. sel_0 17515, customer c_comment 11084,
  orders o_comment 15358, par_256 4632, par_512 2089, par_1024 1035. At par_512 and beyond a
  2048-row vector's *compressed* form already exceeds the block, so no alignment exists and
  the passthrough is off entirely (5% and 0% compressed): those two sit at the PCIe ceiling,
  11.97 and 12.12 GB/s of *wire*, and are not improvable from the host.
- **Host, not device.** Scan+stage costs ~33-35 ns/row nearly independent of string length,
  so throughput falls with bytes/row. par_16 dry-runs at 5.4 GB/s against 5.0 end to end and
  par_32 at 11.3 against 10.1 -- the card is free there and nothing device-side will help.
  Real TPC-H comment columns land here too: orders o_comment averages 48.5 B/row and dry-runs
  at 22.6 GB/s; customer c_comment is 72.5 B/row but compresses only 2.0x (against the
  synthetic column's 3.2x) and straddles 17% of its rows, and dry-runs at 18.4 GB/s. The
  That was the (now removed) `states` suite's 16-17 GB/s: the ceiling, not the array.
  Sweeping the thread count on it (13/16/19/20/21/24/32 against windows 2-5) moves it by less
  than run-to-run noise, so the 37-row-group wave story is *not* what capped it.
- **Per-transfer cost.** A batch closes at every symbol-table change, i.e. at every segment
  boundary, so `REGEX_FPGA_TARGET_WIRE_BYTES` is not the binding constraint on any real table:
  measured wire per transfer is 159 KB (par_16) to 709 KB (par_1024) and sweeping the target
  over 320 KB - 2560 KB changes the transfer count but not the wall (par_64 15.9 vs 15.0 ms,
  par_128 22.2 vs 22.7). Do not retune it.
- **Emitting rows.** The `materialise` and `emit` shapes, and the `projection` suite. See above.

`par_2048` (4.8 GB/s) is none of these: at `oasis_regex_outlier_bytes` = 2048 every row is an
outlier, so the whole table is matched on the host with RE2 and nothing reaches the card. That
is the intended behaviour of the outlier path, not a deficit.

## TPC-H data

`tcph_regex/generate_data.py` builds the TPC-H side (DuckDB's `dbgen` plus synthetic
regex-friendly columns — emails, SKUs, promotions, formatted addresses — at pinned
selectivities). It is *not* what generates the `p_*` / `sel_*` benchmark tables; those come
from `scripts/regex_gen.py`.

## Submodules

`extension/duckdb/` (pinned to a tagged release; `extension/docs/UPDATING.md` when bumping),
`extension/extension-ci-tools/` (branch matching the DuckDB release), `celeris/`, and
`parcore/`. `git submodule update --init --recursive` after cloning. Local modifications
showing as `M celeris` are normal on this branch.
