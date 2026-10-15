#!/usr/bin/env python3
"""What the hardware Bloom filter saves, in percent, per experiment of a sweep (any sweep with both variants).

    ./plot_savings.py results/tpch_q17_20261015_163949 results/tpch_q19_20261015_170113 results/tpch_q20_*
    ./plot_savings.py FOLDER... --measures query_ms scan_ms egress_mb --labels Q17 Q19 Q20 -o savings.pdf

Reads <folder>/results/summary.csv of every experiment folder (written by the sweeps, Bloom on and off side by side)
and plots, for each measure, 100 * (off - on) / off against the swept parameter (the first column of the summary:
the TPC-H scale factor, the probe size, ...): one line per experiment, one panel per measure. Positive is a saving
of the Bloom filter, negative a loss. Time measures (query_ms, scan_ms, rest_ms) and the data the host receives
(egress_mb) are the useful ones; any column that the summary has for both variants works.

The output is a PDF (--output, default savings.pdf next to the first folder's `plots`), and a table of the numbers
on stdout. It is drawn in the style of the sweeps' plots (plot_utils.py: the font of the title for the axis labels and
tick numbers, an x axis label, the legend at the bottom right). Needs matplotlib.
"""

import argparse
import csv
import re
import sys
from pathlib import Path

# The y axis label is short (the title says what is saved); what a measure is called comes from the sweeps' MEASURES
YLABELS = {m: "Time saved (%)" for m in ("query_ms", "scan_ms", "rest_ms")}
YLABELS["egress_mb"] = "Data saved (%)"
# Colorblind-safe (Okabe-Ito), one per experiment
COLORS = ["#0072B2", "#D55E00", "#009E73", "#CC79A7", "#E69F00", "#56B4E9", "#000000"]
MARKERS = ["o", "s", "^", "D", "v", "P", "X"]
PANEL_SIZE = (6.0, 4.0)  # inches, as the sweeps' plots (plot_utils.FIGURE_SIZE)


def read_summary(folder):
    path = Path(folder) / "results" / "summary.csv"
    if not path.exists():
        sys.exit(f"{folder}: no results/summary.csv (is it an experiment folder of a sweep?)")
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f))
    if not rows:
        sys.exit(f"{path}: no rows")
    return rows


def label_of(folder):
    """tpch_q17_20261015_163949 -> Q17; any other experiment keeps its type (probe_size_...)"""
    name = Path(str(folder).rstrip("/")).name
    m = re.match(r"tpch_(q\d+)_", name)
    if m:
        return m.group(1).upper()
    return re.sub(r"_\d{8}_\d{6}$", "", name)


def savings(rows, measure):
    """[(x, saving in percent)] of the points that have the measure for both variants"""
    on, off = f"{measure}[bloom_on]", f"{measure}[bloom_off]"
    if on not in rows[0] or off not in rows[0]:
        sys.exit(f"the summary has no {measure} for both variants (columns: {', '.join(rows[0])})")
    out = []
    key = next(iter(rows[0]))
    for r in rows:
        try:
            a, b = float(r[on]), float(r[off])
        except ValueError:
            continue
        if b > 0:
            out.append((float(r[key]), 100.0 * (b - a) / b))
    return key, sorted(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], epilog=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folders", nargs="+", metavar="FOLDER", help="experiment folders (with results/summary.csv)")
    ap.add_argument("--measures", nargs="+", default=["query_ms", "scan_ms", "egress_mb"], metavar="M",
                    help="summary columns to plot, one panel each (default: query_ms scan_ms egress_mb)")
    ap.add_argument("--labels", nargs="+", metavar="L", help="legend label per folder (default: from the folder name)")
    ap.add_argument("-o", "--output", help="output PDF (default: savings.pdf in the first folder)")
    ap.add_argument("--xlabel", help="x axis label (default: the summary's first column)")
    args = ap.parse_args(argv)
    if args.labels and len(args.labels) != len(args.folders):
        ap.error("--labels needs one label per folder")

    import sweep_lib  # the sweeps' measure titles; plot_utils is theirs too
    pu = sweep_lib._load_celeris_module("plot_utils")
    plt = pu.plt
    titles = {m[0]: m[3] for m in sweep_lib.MEASURES}

    labels = args.labels or [label_of(f) for f in args.folders]
    n = len(args.measures)
    fig, axes = plt.subplots(1, n, figsize=(PANEL_SIZE[0] * n, PANEL_SIZE[1]), squeeze=False, facecolor=pu.SURFACE)
    xkey = None
    print(f"{'experiment':10} {'measure':10} " + " ".join(f"{'x':>6} {'saved %':>8}" for _ in range(1)))
    for ax, measure in zip(axes[0], args.measures):
        all_x = []
        for i, (folder, label) in enumerate(zip(args.folders, labels)):
            xkey, pts = savings(read_summary(folder), measure)
            if not pts:
                continue
            xs, ys = zip(*pts)
            all_x += xs
            color = COLORS[i % len(COLORS)]
            ax.plot(xs, ys, marker=MARKERS[i % len(MARKERS)], color=color, markerfacecolor=color, markeredgewidth=0,
                    markersize=7, linewidth=1.8, label=label)
            for x, y in pts:
                print(f"{label:10} {measure:10} {x:6g} {y:8.1f}")
        if len(set(all_x)) <= pu.MAX_LABELLED_TICKS:  # Few points: label each of them
            ticks = sorted(set(all_x))
            ax.set_xticks(ticks, [pu._number_label(t) for t in ticks])
        else:
            pu._integer_ticks(ax, all_x, "linear")
        ax.axhline(0, color=pu.BASELINE, linewidth=0.8)  # Positive: the filter saves, negative: it costs
        pu._style_axes(ax, args.xlabel or (xkey or "").replace("_", " "), YLABELS.get(measure, "Saved (%)"),
                       f"{titles.get(measure, measure)}\nsaved by the HW Bloom filter")
        legend = ax.legend(loc="lower right", frameon=True, facecolor=pu.SURFACE, edgecolor=pu.GRID, fontsize=9)
        for text in legend.get_texts():
            text.set_color(pu.INK_PRIMARY)
        pu._finish(fig, ax)
    out = Path(args.output) if args.output else Path(args.folders[0]) / "savings.pdf"
    pu._save(fig, pu._check_path(out))
    print(f"plot: {out}")


if __name__ == "__main__":
    main()
