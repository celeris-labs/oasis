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
  storage scan with projection and filter pushdown, so it replaces the table reference rather
  than sitting above it.

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
`oasis_regex_max_threads`, `oasis_regex_fsst_passthrough` (needs `SET GLOBAL
enable_fsst_vectors = true`, refuses to project the regex column, and is switched off by any
pushed-down filter).

Env switches, all read once per scan:

| Variable | Default | Effect |
|---|---|---|
| `OASIS_REGEX_TABLE_SLOTS` | `0` | `1` restores the one-FSST-table-on-card gate. It serialised every compressed transfer: 1.9 vs 18.2 GB/s |
| `OASIS_REGEX_SIDE_BATCH` | on | `0`: straddle rows close the segment batch again |
| `OASIS_REGEX_FAST_STAGE` | on | `0`: per-row staging loop only |
| `OASIS_REGEX_CHUNK_RECYCLE` | on | `0`: no chunk pool or early release |
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

`regex_report.py` produces the canonical numbers: five suites (`patterns`, `selectivity`,
`length`, `threads`, `states`), each timed with DuckDB's `benchmark_runner` (warm-up plus N
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
plaintext, and it refuses rather than doing that. Under `--fsst` it verifies counts only, so
"verification: 0/N agree, N not checked" is normal when every case says `ok (count only)`. A
`--variant fpga` run skips verification entirely. `--exclude 'State explosion'` is there because
that case's *software* side takes several minutes per run; FPGA-only (`--variant fpga`) is fast.
The script does not record `OASIS_*` env vars in its CSV, so note them in the file name.

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
32, so the `states` and `threads` suites will always warn. That is expected, not a
regression — but it does mean those two are not directly comparable to the synthetic suites
at 32 threads.

### Rough expectations on this box (32 logical cores, 16 physical, U55C)

128 engines, FSST passthrough, defaults: FPGA **25.5-26.5 GB/s on all six patterns**, state
explosion included. Software on the same FSST tables runs 5.2-16.7 GB/s, so the speed-up is
1.5-4.7×. Plaintext FPGA is ~11.7 GB/s, PCIe-capped. (The 64-engine plaintext card was ~10.5
GB/s.) The FPGA is essentially **invariant to pattern complexity** — a 30-member class at
the state cap costs the same as `.*a.{22}`. Software spans three orders of magnitude
over the same patterns (16 GB/s where the optimiser rewrites `LIKE` to `contains()`, down to
0.017 GB/s on a wide class with a long fixed tail). The interesting cases are where software
has a specialised path and wins; the accelerator's case is the variance, not the peak.

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
