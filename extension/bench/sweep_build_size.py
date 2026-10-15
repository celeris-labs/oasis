#!/usr/bin/env python3
"""Query time and Bloom filter / decoder throughput over the size of the build relation S.

    ./sweep_build_size.py                                  # a new folder results/build_size_<date>_<time>
    ./sweep_build_size.py --resume results/build_size_20261013_101530   # continue that experiment

runs the benchmark (bench.py) for a build size of 2^MIN_EXP ... 2^MAX_EXP rows (default 2^10 ... 2^20), one after the
other, with the probe side fixed (--rsize, default 2^25 rows), uniform probe keys (zipf 0), 1% of the keys matching and 2
payload columns to materialize, everything else at the defaults of bench.py. Then it plots the results
(plot_utils.py). The experiment folder gets this structure (results and plots are separate folders):

    results/build_size_<date>_<time>/
        results/bloom_on/2pow10/ ... 2pow21/              one folder per point, as written by bench.py
        results/bloom_off/2pow10/ ...                     the same points with the Bloom filter off
        results/summary.csv                               one row per point, both variants side by side
        plots/bloom_on/, plots/bloom_off/                 one plot per measure and variant
        plots/both/                                       both variants in one picture per measure,
                                                          decoder_in_out.pdf (input and output in one
                                                          plot) and query_breakdown.pdf

The probe keys are drawn from the build side's key range, so a larger build side means more distinct keys on the
probe side and a fuller Bloom filter. Every point is the median over the measured runs (--agg changes that). The
build relation has to stay smaller than the probe side: the extension takes the relation with fewer rows as the
build side.

--bloom {on,off,both} (default: both) chooses the variants: the hardware Bloom filter on, off (then DuckDB's own join
Bloom filter filters the scans: oasis_duckdb_bloom_filter), or both, which runs the two variants of a point back to back and plots them side by side
(plots/both/). Bloom off has no Bloom filter throughput (bloom_in, bloom_out), so those are only plotted for on.

The Parquet files are generated into a temporary directory (--tmp-dir, default /dev/shm: RAM) when the sweep starts and removed when it
ends; nothing is kept between sweeps.

The sweep stops at the first failure. Run it again with `--resume <experiment folder>` to continue: complete points
are skipped, and the folder of a failed point (kept for its logs) has to be removed first. `--resume FOLDER
--plots-only` plots what is there without running.
"""

import sys

import sweep_lib

SWEEP = sweep_lib.Sweep(
    script="sweep_build_size.py",
    description=__doc__.split("\n\n")[0],
    experiment="build_size",
    swept="ssize",
    x_header="build rows",
    x_label="Rows of the build relation S",
    xscale="log",
    x_pow2=True,
    folder_of=lambda size: f"2pow{int(size).bit_length() - 1}",
    fixed={"rsize": 1 << 25},
    doc=__doc__,
)


def add_args(parser):
    parser.add_argument("--min-exp", type=int, default=10, help="smallest build size is 2^MIN_EXP rows (default: 10)")
    parser.add_argument("--max-exp", type=int, default=18,
                        help="largest build size is 2^MAX_EXP rows (default: 18; with a selective match ratio DuckDB "
                             "narrows the key to INTEGER from 2^20 rows on and the extension skips the rewrite)")


def points_of(args, parser):
    if not 0 <= args.min_exp <= args.max_exp <= 32:
        parser.error("need 0 <= MIN_EXP <= MAX_EXP <= 32")
    xs = [1 << e for e in range(args.min_exp, args.max_exp + 1)]
    if xs[-1] >= args.rsize:
        parser.error(f"the largest build size ({xs[-1]}) has to be below the probe size --rsize ({args.rsize})")
    return xs


if __name__ == "__main__":
    sys.exit(sweep_lib.main(SWEEP, add_args, points_of))
