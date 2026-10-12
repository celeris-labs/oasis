#!/usr/bin/env python3
"""Query time and Bloom filter / decoder throughput over the size of the build relation S.

    ./sweep_build_size.py                              # into a new folder results/build_size_<date>_<time>
    ./sweep_build_size.py --folder results/build_size  # or into the folder you name

runs the benchmark (bench.py) for a build size of 2^MIN_EXP ... 2^MAX_EXP rows (default 2^10 ... 2^24), one after the
other, with the probe side fixed (--rsize, default 2^25 rows), uniform probe keys (zipf 0), all keys matching and 2
payload columns to materialize, everything else at the defaults of bench.py. Then it plots the results
(plot_utils.py). The folder gets this structure:

    results/build_size/
        bench_results/bloom_on/2pow10/ ... 2pow24/              one folder per point, as written by bench.py
        bench_results/bloom_off/2pow10/ ...                     the same points with the Bloom filter off
        plots/bloom_on/, plots/bloom_off/                       one plot per measure and variant
        plots/both/                                             both variants in one picture per measure,
                                                                and query_breakdown.png
        summary.csv                                             one row per point, both variants side by side

The probe keys are drawn from the build side's key range, so a larger build side means more distinct keys on the
probe side and a fuller Bloom filter. Every point is the median over the measured runs (--agg changes that). The
build relation has to stay smaller than the probe side: the extension takes the relation with fewer rows as the
build side.

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
    script="sweep_build_size.py",
    description=__doc__.split("\n\n")[0],
    default_folder="build_size",
    swept="ssize",
    x_header="build rows",
    x_label="Rows of the build relation S",
    xscale="log",
    folder_of=lambda size: f"2pow{int(size).bit_length() - 1}",
    fixed={"rsize": 1 << 25},
    doc=__doc__,
)


def add_args(parser):
    parser.add_argument("--min-exp", type=int, default=10, help="smallest build size is 2^MIN_EXP rows (default: 10)")
    parser.add_argument("--max-exp", type=int, default=24, help="largest build size is 2^MAX_EXP rows (default: 24)")


def points_of(args, parser):
    if not 0 <= args.min_exp <= args.max_exp <= 32:
        parser.error("need 0 <= MIN_EXP <= MAX_EXP <= 32")
    xs = [1 << e for e in range(args.min_exp, args.max_exp + 1)]
    if xs[-1] >= args.rsize:
        parser.error(f"the largest build size ({xs[-1]}) has to be below the probe size --rsize ({args.rsize})")
    return xs


if __name__ == "__main__":
    sys.exit(sweep_lib.main(SWEEP, add_args, points_of))
