#!/usr/bin/env python3
"""Query time and Bloom filter / decoder throughput over the egress cap (the FPGA -> host link, emulated).

    ./sweep_egress.py                                  # a new folder results/egress_<date>_<time>
    ./sweep_egress.py --resume results/egress_20261013_101530   # continue that experiment

runs the benchmark (bench.py) with oasis_emulated_egress_gbps set to each of --caps GB/s (default 1 2 3 4 6 8 10),
then once without a cap, one after the other, with build size 2^16 and probe size 2^24 rows, uniform probe keys
(zipf 0), 1% of the keys matching (so the Bloom filter can remove most of the output) and 2 payload columns. Then it plots the results
(plot_utils.py) over the cap in GB/s; the point without a cap is the link's own speed and is plotted as the last
point at --link-gbps (default 12.5). The experiment folder gets this structure (results and plots are separate folders):

    results/egress_<date>_<time>/
        results/bloom_on/egress_1/ ... egress_off/        one folder per point, as written by bench.py
        results/bloom_off/egress_1/ ...                   the same points with the Bloom filter off
        results/summary.csv                               one row per point, both variants side by side
        plots/bloom_on/, plots/bloom_off/                 one plot per measure and variant
        plots/both/                                       both variants in one picture per measure,
                                                          decoder_in_out.pdf (input and output in one
                                                          plot) and query_breakdown.pdf

The cap is software-only: the scheduler holds back new flows so that the output the hardware writes averages at
most that many GB/s. Every point is the median over the measured runs (--agg changes that).

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

LINK_GBPS = 12.5  # Where the point without a cap is plotted; set from --link-gbps

SWEEP = sweep_lib.Sweep(
    script="sweep_egress.py",
    description=__doc__.split("\n\n")[0],
    experiment="egress",
    swept="egress_gbps",
    x_header="egress GB/s",
    x_label="Egress cap (GB/s)",  # the last point, "off", is the link speed (--link-gbps)
    xscale="linear",
    folder_of=lambda cap: "egress_off" if cap == 0 else f"egress_{cap:g}",
    x_text=lambda cap: "off" if cap == 0 else f"{cap:g}",
    plot_x=lambda cap: LINK_GBPS if cap == 0 else cap,
    sort_key=lambda cap: (cap == 0, cap),  # "off" last
    doc=__doc__,
)


def add_args(parser):
    parser.add_argument("--caps", type=float, nargs="+", default=[1, 2, 3, 4, 6, 8, 10],
                        metavar="GBPS", help="caps in GB/s (default: 1 2 3 4 6 8 10)")
    parser.add_argument("--link-gbps", type=float, default=LINK_GBPS,
                        help="where the point without a cap is plotted, the link's speed (default: %(default)s)")
    parser.add_argument("--no-off", action="store_true", help="do not add the point without a cap")


def points_of(args, parser):
    if any(c <= 0 for c in args.caps):
        parser.error("the caps have to be above 0 (the point without a cap is added unless --no-off)")
    caps = sorted(set(args.caps))
    if caps[-1] >= args.link_gbps:
        parser.error(f"the caps have to be below --link-gbps ({args.link_gbps:g}), where the uncapped point is plotted")
    global LINK_GBPS
    LINK_GBPS = args.link_gbps
    return caps if args.no_off else caps + [0.0]


if __name__ == "__main__":
    sys.exit(sweep_lib.main(SWEEP, add_args, points_of))
