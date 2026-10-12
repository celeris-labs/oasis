# Oasis Bloom filter benchmarks

Runner, data generator and sweeps for the hardware Bloom filter join of the extension, modelled on
`celeris/examples/06_bloomfilter` (`bench.py`, `sweep_*.py`, `plot_utils.py` are reused/mirrored).

    source ~/plotting/bin/activate
    ./bench.py --folder results/one --ssize 65536 --rsize 16777216 --columns 2 --zipffactor 0
    ./sweep_probe_size.py        # Bloom on and off; also: sweep_build_size.py, sweep_columns.py, sweep_egress.py, sweep_threads.py
    python test_bench.py         # no FPGA needed (fake CLI)

## What a point is

`bench.py` generates (and caches in `bench/data/`) two Parquet files with `gen_data.py`: a build file `S` (one INT64
column `key`, sequential) and a probe file `R` (`key` and `c1..cN`, INT64). Every column is `OPTIONAL` with no NULLs
(what the ParCore decoder needs). The parameters have the names and defaults of the celeris binary
(`ssize rsize matchratio zipffactor columns batchsize numbatches`); a batch is a row group. Parquet-specific:
`compression` (uncompressed | snappy), `encoding`, `file_columns`. Extension-specific: `runtime_bloom`,
`egress_gbps` (`oasis_emulated_egress_gbps`), `threads`, and `--set NAME=VALUE` for any other setting.
Not applicable to files: `hugepages`, `device`, `lockstep`, `preenqueue`.

It then runs, in **one DuckDB CLI process** (`build/release/duckdb`), warm-ups followed by measured runs of

    SELECT count(*), sum(p.key), sum(p.c1), ... FROM read_oasis(S) b JOIN read_oasis(R) p ON p.key = b.key

and checks every result against the sums computed while generating the data. Folder contents: `run.sql`,
`stdout.log` (raw output, everything is parsed from here), `stderr.log`, `meta.yaml`, `bench.yaml`.

## Measures (`bench.yaml`, per measured run)

| Measure | Where | Definition |
|---|---|---|
| total query time `host.query_ms` | host | `OasisQueryStats.total_query_ms`: wall clock of the query, planning included |
| total scan time `host.scan_ms` | host | `scan_only_ms + scan_celeris_bloom_ms`: wall clock of the `read_oasis` scans (the Bloom one includes submitting its build side and ending it) |
| join time `host.join_ms` | host | total - scan. (`join_operator_cpu_ms` is DuckDB's own operator timing, CPU time summed over threads; not used) |
| decoder IN / OUT `decoder.in_gbps`, `out_gbps` | hardware | **probe only.** The extension reads the decoder's StreamProfiler when the last-starting `read_oasis` scan (the probe side; DuckDB's build pipeline has finished) starts, and again when the query ends (`OasisDecoderProfile` log record, label `final`). handshakes x 64 B over (handshake + starved + stalled + idle cycles) x 4 ns: the window runs from the first probe beat to the last handshake, idle cycles between flows included. `*_excl_idle` leaves those out. `scope` says what was measured (`probe`; `run` only for a log of an extension without the record) |
| decoder, whole run `decoder_run.*` | hardware | the segments of the query added up. Segment boundaries inside a flow lose some output beats on the OUT side (the profiler restarts independently at input and output), so with the Bloom filter on its bytes are about 1.5 % short; `checks.decoder_out_bytes_ratio` says |
| Bloom IN `bloom.in_gbps` | hardware | probe keys + columns to materialize read by the filter (`keys_in + values_in - build key beats`) x 64 B over the probe window: first probe key beat (`probe_start_cycles`) to the later of the probe phase's END and the last output, x 4 ns |
| Bloom OUT `bloom.out_gbps` | hardware | `out_bytes` (kept keys + materialized columns + mask) over the same window |

The extension has the DuckDB hash table of S built between the Bloom filter's build and the first probe key (tens of ms
at 2^20 rows, in which the decoder idles), so celeris's window (from the end of the build) would include that gap:
those rates are kept as `bloom.in_gbps_from_build_end` / `out_gbps_from_build_end`.

Also in `bloom`: `build_in_gbps` (build keys over the build phase), `run_in_gbps` / `run_out_gbps` (over the
whole run, first build beat to last handshake, which includes the gap between build and probe), the raw
counters, and `checks`: `decoder_probe_out_bytes_ratio` (the probe segment's output bytes over `rsize x (1 + columns) x 8`;
the run fails outside 0.99 .. 1.01) and `decoder_out_bytes_ratio`.

The profiler is read (and thereby re-armed) before every run and at the boundaries above. A read that returns exactly the
values of the previous read saw no beat (the profiler holds its counters until the next beat) and is reported as zero.
Throughputs count 64 B per handshake; the clock is 250 MHz.

## Rules for the FPGA

* The device is shared. A point refuses to start while another process has `/dev/coyote_fpga_0_v0` open or no 1 GiB
  hugepage is free (`--wait-device SECONDS` waits; the sweeps wait up to 15 min between points).
* Every point is under `--timeout` (default 600 s per DuckDB process). A run that has to be stopped is a failure:
  SIGINT, then SIGTERM, then SIGKILL. A killed hung run can leave the card unusable: check
  `/sys/kernel/coyote_sysfs_0/cyt_attr_hstats` (request == completion counts) before going on.
* Sweeps stop at the first failure and resume where they stopped (complete points are skipped).
* `--generate-only` (bench.py and the sweeps) writes the Parquet files without touching the card.

## Sweeps

| Script | Varies | Fixed (defaults) |
|---|---|---|
| `sweep_probe_size.py` | `rsize` 2^17 ... 2^26 | `ssize` 2^16, 2 columns |
| `sweep_build_size.py` | `ssize` 2^10 ... 2^24 | `rsize` 2^25, 2 columns |
| `sweep_columns.py` | `columns` 0 ... 16 (one probe file with 16) | `ssize` 2^20, `rsize` 2^24 |
| `sweep_egress.py` | `oasis_emulated_egress_gbps` 1 2 3 4 6 8 10, then no cap (plotted at 12.5 GB/s, `--link-gbps`) | `ssize` 2^20, `rsize` 2^24, 2 columns |
| `sweep_threads.py` | DuckDB `threads` 1 2 4 8 16 32 | `ssize` 2^20, `rsize` 2^24, 2 columns |

All use uniform probe keys (`zipffactor 0`; 1 is one hot bank), `matchratio 1` and uncompressed files unless
overridden on the command line. R has to be strictly larger than S: the extension's optimizer takes the relation with
fewer rows as the build side (verified on hardware: on a tie it filters S, not R); the runner rejects `rsize <= ssize`
and fails if the Bloom filter did not filter R.

### Bloom on, off, or both

Every sweep takes `--bloom {on,off,both}` (default `both`): the value of `oasis_runtime_bloom_filter` of its points
(off is a plain join of two `read_oasis` scans, so the comparison is what the filter buys). With `both`, the two
variants of a point run back to back (on, then off, point by point, so drift of the machine affects both alike).
Every variant has folders of its own:

    <folder>/bench_results/bloom_on/<point>/    as written by bench.py (the point's name depends on the sweep)
    <folder>/bench_results/bloom_off/<point>/
    <folder>/plots/bloom_on/<measure>.png       one plot per measure and variant
    <folder>/plots/bloom_off/<measure>.png      (no bloom_in / bloom_out: there is no filter)
    <folder>/plots/both/<measure>.png           both variants as two lines (blue circles / solid: on; vermillion
                                                squares / dashed: off); not for bloom_in / bloom_out (one line)
    <folder>/plots/both/query_breakdown.png     per point and variant a stacked bar: scan time (bottom) and
                                                join time (top, hatched), so total = scan + join is visible
    <folder>/summary.csv                        one row per point; columns query_ms[bloom_on], query_ms[bloom_off], ...

The measures are `query_ms`, `scan_ms`, `join_ms` (host) and `decoder_in`, `decoder_out` (the decoder during the
probe), `bloom_in`, `bloom_out` (the filter during the probe); times are in ms, throughputs in GB/s. The printed
table has one row per point and variant (second column). The y axis of every plot starts at zero.

Resuming: points that are complete in the folder (with the same parameters, `oasis_runtime_bloom_filter` included) are
skipped; the sweep stops at the first failure and keeps the failed point's folder for its logs: remove it to run that
point again. `--bloom` also selects what `--plots-only` plots (`both/` needs results of both variants). A folder from
before `--bloom` (the points directly in `bench_results/`, all run with the filter on) plots as Bloom on with
`--plots-only`; it is not continued (move the points into `bench_results/bloom_on/` or start a new folder).
`python test_sweeps.py` tests all of this with a fake CLI.
