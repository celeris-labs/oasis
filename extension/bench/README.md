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
| rest `host.rest_ms` | host | the rest of the query (join operators, aggregation, planning...) = total - scan. (`join_operator_cpu_ms` is DuckDB's own operator timing, CPU time summed over threads; not used) |
| decoder IN / OUT `decoder.in_gbps`, `out_gbps` | hardware | **probe only.** The extension reads the decoder's StreamProfiler when the last-starting `read_oasis` scan (the probe side; DuckDB's build pipeline has finished) starts, and again when the query ends (`OasisDecoderProfile` log record, label `final`). handshakes x 64 B over (handshake + starved + stalled + idle cycles) x 4 ns: the window runs from the first probe beat to the last handshake, idle cycles between flows included. `*_excl_idle` leaves those out. `scope` says what was measured (`probe`; `run` only for a log of an extension without the record) |
| decoder, whole run `decoder_run.*` | hardware | the segments of the query added up. Segment boundaries inside a flow lose some output beats on the OUT side (the profiler restarts independently at input and output), so with the Bloom filter on its bytes are about 1.5 % short; `checks.decoder_out_bytes_ratio` says |
| Bloom IN `bloom.in_gbps` | hardware | probe keys + columns to materialize read by the filter (`keys_in + values_in - build key beats`) x 64 B over the probe window: first probe key beat (`probe_start_cycles`) to the last output handshake (`out_cycles - probe_start_cycles`), x 4 ns. The probe phase's own cycle count is not used: it runs until the host's END command, which comes after the last key beat |
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
| `sweep_build_size.py` | `ssize` 2^10 ... 2^18 | `rsize` 2^25, 2 columns |
| `sweep_columns.py` | `columns` 0 ... 16 (one probe file with 16) | `ssize` 2^16, `rsize` 2^24 |
| `sweep_egress.py` | `oasis_emulated_egress_gbps` 1 2 3 4 6 8 10, then no cap (plotted at 12.5 GB/s, `--link-gbps`) | `ssize` 2^16, `rsize` 2^24, 2 columns |
| `sweep_threads.py` | DuckDB `threads` 1 2 4 8 16 32 | `ssize` 2^16, `rsize` 2^24, 2 columns |

All use uniform probe keys (`zipffactor 0`; 1 is one hot bank), `matchratio 0.01` and uncompressed files unless
overridden on the command line. The generated Parquet files go to a temporary directory in `/dev/shm` (a tmpfs, so RAM;
`--tmp-dir` changes it) and `meta.yaml` records it (`data_dir`, `data_filesystem`). R has to be strictly larger than S: the extension's optimizer takes the relation with
fewer rows as the build side (verified on hardware: on a tie it filters S, not R); the runner rejects `rsize <= ssize`
and fails if the Bloom filter did not filter R.

### Bloom on, off, or both

Every sweep takes `--bloom {on,off,both}` (default `both`): the value of `oasis_runtime_bloom_filter` of its points
(off: DuckDB's own join Bloom filter filters the `read_oasis` scans instead, `oasis_duckdb_bloom_filter` is set to the opposite of `oasis_runtime_bloom_filter`, so the comparison is hardware against software Bloom filter). With `both`, the two
variants of a point run back to back (on, then off, point by point, so drift of the machine affects both alike).
Every variant has folders of its own:

    <folder>/bench_results/bloom_on/<point>/    as written by bench.py (the point's name depends on the sweep)
    <folder>/bench_results/bloom_off/<point>/
    <folder>/plots/bloom_on/<measure>.pdf       one plot per measure and variant
    <folder>/plots/bloom_off/<measure>.pdf      (no bloom_in / bloom_out: there is no filter)
    <folder>/plots/both/<measure>.pdf           both variants as two lines (blue circles / solid: on; vermillion
                                                squares / dashed: off); not for bloom_in / bloom_out (one line)
    <folder>/plots/<variant>/decoder_in_out.pdf the decoder's input and output throughput in one plot (and
                                                bloom_in_out.pdf for the filter, Bloom on only); legend at the
                                                bottom right. plots/both/decoder_in_out.pdf has four lines
                                                (colors: in / out; solid / dashed: on / off)
    <folder>/plots/both/query_breakdown.pdf     per point and variant a stacked bar: scan time (bottom) and
                                                the rest (top, lighter), so total = scan + rest is visible
    <folder>/summary.csv                        one row per point; columns query_ms[bloom_on], query_ms[bloom_off], ...

The measures are `query_ms`, `scan_ms`, `rest_ms` (host) and `decoder_in`, `decoder_out` (the decoder during the
probe), `bloom_in`, `bloom_out` (the filter during the probe); times are in ms, throughputs in GB/s. The printed
table has one row per point and variant (second column). Every plot is a PDF; the y axis starts at zero, both axes
have a label, and labels and tick numbers are set in the font of the title.

Resuming: points that are complete in the folder (with the same parameters, `oasis_runtime_bloom_filter` included) are
skipped; the sweep stops at the first failure and keeps the failed point's folder for its logs: remove it to run that
point again. `--bloom` also selects what `--plots-only` plots (`both/` needs results of both variants). A folder from
before `--bloom` (the points directly in `bench_results/`, all run with the filter on) plots as Bloom on with
`--plots-only`; it is not continued (move the points into `bench_results/bloom_on/` or start a new folder).
`python test_sweeps.py` tests all of this with a fake CLI.

## TPC-H queries

`sweep_tpch_q17.py`, `sweep_tpch_q19.py` and `sweep_tpch_q20.py` run TPC-H Q17, Q19 and Q20 over the scale factor
(`--scale-factors`, default 1 ... 8; `--timeout` default 1800 s per point) with the same measures, folders, plots and
`--bloom {on,off,both}` / `--resume` / `--plots-only` as the other sweeps (the points are `sf1` ... `sf8`; the
experiment is `tpch_q17_<date>_<time>`, `tpch_q19_...`, `tpch_q20_...`). `tpch_bench.py` has the data, the queries
(`Query`: `Q17`, `Q19`, `Q20`) and the checks, `test_tpch.py` the tests (no FPGA; generates SF 0.1 for real). What
follows is common to the three; Q17 is the one described in detail, the sections after it have what differs.

    source ~/plotting/bin/activate
    ./sweep_tpch_q17.py                                   # SF 1 ... 8, Bloom on and off
    ./sweep_tpch_q17.py --scale-factors 1 5 --bloom on --compression snappy

* **Data.** DuckDB's dbgen (python `duckdb` with the tpch extension) per scale factor, into the temporary directory,
  dropped when the point (both variants) is done. Only the two tables of the query are written: `lineitem.parquet`
  (whole, all 16 columns) and `part_q17.parquet`. Every column is OPTIONAL without NULLs, row groups of 122880 rows.
  About 0.4 GB per scale factor uncompressed.
* **The build side is pre-filtered.** Q17's predicate (`p_brand = 'Brand#23' AND p_container = 'MED BOX'`, 0.1 % of
  `part`) is not in the measured query: `part_q17.parquet` holds only the parts that satisfy it, with every column
  of `part`, and the query joins it with no predicate. The hardware filter is built from the build file's whole key
  column, so this is what makes it hold exactly the qualifying keys. The reference answer is computed while
  generating, from the original query (predicate in the WHERE clause) on dbgen's tables, and every run's result is
  checked against it.
* **Plan.** `SET disabled_optimizers = 'deliminator'` for both variants: with no predicate left DuckDB's
  deliminator pass otherwise reshapes Q17 so that the extension finds no lineitem-part join to rewrite.
* **Decoder measures.** Q17 reads lineitem twice: the join's scan (l_partkey, l_quantity, l_extendedprice; the one
  the Bloom filter prunes) and the subquery's aggregate scan (l_partkey, l_quantity; every row is needed). The
  extension's decoder profile has one segment per scan, and which scan the Bloom filtered one is depends on the plan, so
  `decoder_*` is the decoder over **all scans of lineitem together** (first lineitem scan's start to the end of the
  query; the part scans and the filter's build pass are not in it). The run fails if those scans are not consecutive in the
  profile, or if their output bytes differ from `5 columns x 8 B x rows` by more than 3 % (`checks` in bench.yaml).
  `bloom_in`/`bloom_out` are the filter's, as in the other sweeps.

### Q19

`sweep_tpch_q19.py` (docstring of the script has the details). lineitem JOIN part with one OR of three groups, each
group mixing part predicates (`p_brand`, `p_container IN (...)`, `p_size BETWEEN`) and lineitem predicates
(`l_quantity` range, `l_shipmode`, `l_shipinstruct`).

* **Build side.** `part_q19.parquet`: the parts that satisfy one of the three groups' part predicates (about 0.24 % of
  `part`), with every column. Any other part cannot be in the result.
* **What leaves the query.** `p_container` and `p_size`: the three brands differ, so a part of the file is in exactly
  one group, which `p_brand` names, and that group's container and size predicates hold for it by construction.
  `p_brand` stays, because it couples a part to its group's `l_quantity` range (columns of both sides: it cannot be a
  filter of one file). The lineitem predicates stay; `l_shipmode` and `l_shipinstruct`, which every group has, are
  written once outside the OR (DuckDB's plan has them there as well).
* **Plan.** The extension rewrites the lineitem-part join as it is (build `part_q19.parquet` `p_partkey`, probe
  `lineitem` `l_partkey`); no optimizer is disabled. The OR is a condition of the hash join over the kept rows.
* **Decoder.** One scan of lineitem; the decoder outputs `l_partkey`, `l_quantity`, `l_extendedprice`, `l_discount`
  (4 x 8 B per row). `l_shipmode` and `l_shipinstruct` are strings, decoded on the CPU, so they are not counted: the run
  fails if the decoder's output bytes are not `4 x 8 B x rows` within 3 %.
* **Answer.** The original Q19 (the three groups, `p_container IN`, `p_size BETWEEN`, every lineitem predicate) on
  dbgen's tables; `sum(l_extendedprice * (1 - l_discount))` is a DECIMAL and is compared exactly.

### Q20

`sweep_tpch_q20.py`. Nested IN / correlated subquery over supplier, nation, partsupp, part (`LIKE 'forest%'`) and
lineitem (a year of `l_shipdate`, `sum(l_quantity)` by `(ps_partkey, ps_suppkey)`).

* **Which join the filter can go into.** The extension rewrites an INNER join of two `read_oasis` scans with nothing
  but filters between a join and its scan. The original Q20 has none: `ps_partkey IN (SELECT p_partkey ...)` is a
  SEMI join (log: "only inner joins are rewritten"), the correlated subquery over lineitem is a join with a
  DELIM_SCAN under the aggregate ("could not find single LogicalGet on both sides"), and the only rewritten join is
  supplier-nation (25 build rows). (Checked with `CALL enable_logging(level = 'debug', storage = 'memory')` and EXPLAIN
  on the extension's CLI at SF 1.)
* **Build side.** `partsupp_q20.parquet`: the rows of partsupp whose part is a `forest%` part (about 1.1 % of
  partsupp), every column, with `part` itself not in the measured query (it is read at generation time only). The
  IN's semi join is evaluated into the file, as Q17's predicate is.
* **The query.** The correlated subquery is written as the join and aggregate DuckDB's decorrelation produces:
  `lineitem JOIN partsupp_q20 ON l_partkey = ps_partkey AND l_suppkey = ps_suppkey`, the year's `l_shipdate`
  filter, `GROUP BY ps_partkey, ps_suppkey, ps_availqty`, then `ps_availqty > 0.5 * sum_qty`, then the IN and
  supplier-nation (`'CANADA'`). The answers are equal: a partsupp row without a lineitem row in the year has a NULL
  sum in the original and the comparison drops it, as the inner join does. The Bloom filter is built from the first key
  of the join, `ps_partkey` (l_partkey is written first), and prunes lineitem to the forest parts' rows (about 1 %);
  the filter on the pair is not possible, the extension has one key column.
* **Small tables.** `supplier` and `nation` are read with DuckDB's `read_parquet`, not `read_oasis` (written as
  `supplier.parquet`, `nation.parquet` next to the others): two `read_oasis` scans would be rewritten too, a second
  filter run in every query, and `check_run` expects exactly one.
* **Result.** One row: `count(*)` and `sum(md5_number_lower(s_name || '|' || s_address))` of the suppliers the
  original returns (ordered by name), both compared exactly.
* **Plan.** No optimizer is disabled; the plan is the same with the Bloom filter on and off.
* **Decoder.** One scan of lineitem; `l_partkey`, `l_suppkey`, `l_quantity` (8 B each) and `l_shipdate` (4 B, read by the
  filter only but a decoder column) = 28 B per row, within 3 %.
