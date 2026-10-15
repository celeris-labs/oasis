#!/usr/bin/env python3
"""Query time and Bloom filter / decoder throughput over the number of INT64 columns to materialize.

    ./sweep_columns.py                                  # a new folder results/columns_<date>_<time>
    ./sweep_columns.py --resume results/columns_20261013_101530   # continue that experiment

runs the benchmark (bench.py) for MIN_COLUMNS ... MAX_COLUMNS payload columns of the probe side that the query
reads and the hardware materializes besides the key (default 0 ... 16), one after the other, with build size 2^16
and probe size 2^24 rows, uniform probe keys (zipf 0) and 1% of the keys matching. Then it plots the results
(plot_utils.py). The experiment folder gets this structure (results and plots are separate folders):

    results/columns_<date>_<time>/
        results/bloom_on/columns_00/ ... columns_16/      one folder per point, as written by bench.py
        results/bloom_off/columns_00/ ...                 the same points with the Bloom filter off
        results/summary.csv                               one row per point, both variants side by side
        plots/bloom_on/, plots/bloom_off/                 one plot per measure and variant
        plots/both/                                       both variants in one picture per measure,
                                                          decoder_in_out.pdf (input and output in one
                                                          plot) and query_breakdown.pdf

All points use one probe file with MAX_COLUMNS payload columns (columns the query does not reference are not read),
so the data is generated once. Every column is 8 bytes per probe row in and, for the kept rows, out. Every point is
the median over the measured runs (--agg changes that).

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
    script="sweep_columns.py",
    description=__doc__.split("\n\n")[0],
    experiment="columns",
    swept="columns",
    x_header="columns",
    x_label="Materialized INT64 columns (besides the key)",
    xscale="linear",
    folder_of=lambda columns: f"columns_{int(columns):02d}",
    extra_params_of=lambda xs: {"file_columns": max(xs)},
    doc=__doc__,
)


def add_args(parser):
    parser.add_argument("--min-columns", type=int, default=0, help="fewest columns (default: 0)")
    parser.add_argument("--max-columns", type=int, default=16, help="most columns (default: 16)")


def points_of(args, parser):
    if not 0 <= args.min_columns <= args.max_columns:
        parser.error("need 0 <= MIN_COLUMNS <= MAX_COLUMNS")
    return list(range(args.min_columns, args.max_columns + 1))


if __name__ == "__main__":
    sys.exit(sweep_lib.main(SWEEP, add_args, points_of))
