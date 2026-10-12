#!/usr/bin/env python3
"""Query time and Bloom filter / decoder throughput over the number of workers (DuckDB threads).

    ./sweep_threads.py                              # into a new folder results/threads_<date>_<time>
    ./sweep_threads.py --folder results/threads     # or into the folder you name

runs the benchmark (bench.py) with DuckDB's `threads` setting at each of --threads-list (default 1 2 4 8 16 32),
one after the other, with build size 2^20 and probe size 2^24 rows, uniform probe keys (zipf 0), all keys matching
and 2 payload columns. The read_oasis scan runs one worker per DuckDB thread; they share the one decoder stream of
the FPGA, so this shows where the host stops being the bottleneck. Then it plots the results (plot_utils.py). The
folder gets this structure:

    results/threads/
        bench_results/bloom_on/threads_01/ ... threads_32/      one folder per point, as written by bench.py
        bench_results/bloom_off/threads_01/ ...                 the same points with the Bloom filter off
        plots/bloom_on/, plots/bloom_off/                       one plot per measure and variant
        plots/both/                                             both variants in one picture per measure,
                                                                and query_breakdown.png
        summary.csv                                             one row per point, both variants side by side

Every point is the median over the measured runs (--agg changes that).

--bloom {on,off,both} (default: both) chooses the variants: the Bloom filter on, off (a plain join of two
read_oasis scans), or both, which runs the two variants of a point back to back and plots them side by side
(plots/both/). Bloom off has no Bloom filter throughput (bloom_in, bloom_out), so those are only plotted for on.

The sweep stops at the first failure. Run it again to continue: complete points are skipped, and the folder of a
failed point (kept for its logs) has to be removed first. `--plots-only` plots what is there without running (a
folder from before --bloom, with the points directly in bench_results/, is plotted as Bloom on); `--generate-only`
only writes the Parquet files.
"""

import sys

import sweep_lib

SWEEP = sweep_lib.Sweep(
    script="sweep_threads.py",
    description=__doc__.split("\n\n")[0],
    default_folder="threads",
    swept="threads",
    x_header="workers",
    x_label="Workers (DuckDB threads)",
    xscale="log",
    folder_of=lambda threads: f"threads_{int(threads):02d}",
    doc=__doc__,
)


def add_args(parser):
    parser.add_argument("--threads-list", type=int, nargs="+", default=[1, 2, 4, 8, 16, 32], metavar="N",
                        help="worker counts (default: 1 2 4 8 16 32)")


def points_of(args, parser):
    if any(t < 1 for t in args.threads_list):
        parser.error("worker counts have to be at least 1")
    return sorted(set(args.threads_list))


if __name__ == "__main__":
    sys.exit(sweep_lib.main(SWEEP, add_args, points_of))
