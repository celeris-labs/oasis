#!/usr/bin/env python3
"""Query time and Bloom filter / decoder throughput over the size of the probe relation R.

    ./sweep_probe_size.py                                  # a new folder results/probe_size_<date>_<time>
    ./sweep_probe_size.py --resume results/probe_size_20261013_101530   # continue that experiment

runs the benchmark (bench.py) for a probe size of 2^MIN_EXP ... 2^MAX_EXP rows (default 2^17 ... 2^26), one after the
other, with the build side fixed (--ssize, default 2^16 rows), uniform probe keys (zipf 0), all keys matching and 2
payload columns to materialize, everything else at the defaults of bench.py. Then it plots the results
(plot_utils.py). The experiment folder gets this structure (results and plots are separate folders):

    results/probe_size_<date>_<time>/
        results/bloom_on/2pow17/ ... 2pow26/              one folder per point, as written by bench.py
        results/bloom_off/2pow17/ ...                     the same points with the Bloom filter off
        results/summary.csv                               one row per point, both variants side by side
        plots/bloom_on/, plots/bloom_off/                 one plot per measure and variant
        plots/both/                                       both variants in one picture per measure,
                                                          and query_breakdown.png

The measures are listed in sweep_lib.py (the same in every sweep). Every point is the median over the measured runs
(--agg changes that). The probe relation has to stay larger than the build side: the extension takes the relation
with fewer rows as the build side.

--bloom {on,off,both} (default: both) chooses the variants: the Bloom filter on, off (a plain join of two
read_oasis scans), or both, which runs the two variants of a point back to back and plots them side by side
(plots/both/). Bloom off has no Bloom filter throughput (bloom_in, bloom_out), so those are only plotted for on.

The Parquet files are generated into a temporary directory (--tmp-dir) when the sweep starts and removed when it
ends; nothing is kept between sweeps.

The sweep stops at the first failure. Run it again with `--resume <experiment folder>` to continue: complete points
are skipped, and the folder of a failed point (kept for its logs) has to be removed first. `--resume FOLDER
--plots-only` plots what is there without running.
"""

import sys

import sweep_lib

SWEEP = sweep_lib.Sweep(
    script="sweep_probe_size.py",
    description=__doc__.split("\n\n")[0],
    experiment="probe_size",
    swept="rsize",
    x_header="probe rows",
    x_label="Rows of the probe relation R",
    xscale="log",
    folder_of=lambda size: f"2pow{int(size).bit_length() - 1}",
    fixed={"ssize": 1 << 16},
    doc=__doc__,
)


def add_args(parser):
    parser.add_argument("--min-exp", type=int, default=17, help="smallest probe size is 2^MIN_EXP rows (default: 17)")
    parser.add_argument("--max-exp", type=int, default=26, help="largest probe size is 2^MAX_EXP rows (default: 26)")


def points_of(args, parser):
    if not 0 <= args.min_exp <= args.max_exp <= 32:
        parser.error("need 0 <= MIN_EXP <= MAX_EXP <= 32")
    xs = [1 << e for e in range(args.min_exp, args.max_exp + 1)]
    if xs[0] <= args.ssize:
        parser.error(f"the smallest probe size ({xs[0]}) has to be above the build size --ssize ({args.ssize})")
    return xs


if __name__ == "__main__":
    sys.exit(sweep_lib.main(SWEEP, add_args, points_of))
