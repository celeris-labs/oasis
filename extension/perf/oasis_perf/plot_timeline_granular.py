#!/usr/bin/env python3
import argparse
import csv
import math
import statistics
from collections import defaultdict
from pathlib import Path

import matplotlib.pyplot as plt


def mean(xs):
    xs = list(xs)
    return statistics.fmean(xs) if xs else float("nan")


def size_label(n):
    if n >= 1_000_000:
        value = n / 1_000_000
        return f"{value:g}M"
    if n >= 1_000:
        value = n / 1_000
        return f"{value:g}k"
    return str(n)


def ratio_label(r):
    if abs(r - round(r)) < 1e-9:
        return f"1:{int(round(r))}"
    return f"1:{r:g}"


def read_csv(path):
    rows = []
    with Path(path).open() as f:
        reader = csv.DictReader(f)
        for r in reader:
            row = dict(r)
            row["build_rows"] = int(float(row["build_rows"]))
            row["probe_rows"] = int(float(row["probe_rows"]))
            row["match_rate"] = float(row["match_rate"])
            row["payload_cols"] = int(float(row["payload_cols"]))
            row["simulated_fpr"] = float(row["simulated_fpr"])
            row["speedup"] = float(row["speedup"])
            row["baseline_ms"] = float(row["baseline_ms"])
            row["filtered_ms"] = float(row["filtered_ms"])
            row["ratio"] = row["probe_rows"] / row["build_rows"]
            row["total_rows"] = row["build_rows"] + row["probe_rows"]
            row["payload_group"] = "ohne Payload" if row["payload_cols"] == 0 else "mit Payload"
            rows.append(row)
    return rows


def grouped_mean(rows, keys, value="speedup"):
    acc = defaultdict(list)
    for r in rows:
        key = tuple(r[k] for k in keys)
        acc[key].append(r[value])
    return {k: mean(v) for k, v in acc.items()}


def filter_rows(rows, **filters):
    out = []
    for r in rows:
        ok = True
        for k, v in filters.items():
            if v is None:
                continue
            if isinstance(v, float):
                if abs(r[k] - v) > 1e-12:
                    ok = False
                    break
            else:
                if r[k] != v:
                    ok = False
                    break
        if ok:
            out.append(r)
    return out


def set_common_grid(ax):
    ax.grid(True, alpha=0.3)


def plot_ratio_by_size_payload(rows, outdir, fpr=0.05, match_rate=0.10):
    rows = [r for r in rows if r["build_rows"] < r["probe_rows"]]
    rows = filter_rows(rows, simulated_fpr=fpr, match_rate=match_rate)

    payload_groups = ["ohne Payload", "mit Payload"]
    ratios = sorted(set(r["ratio"] for r in rows))
    sizes = sorted(set(r["total_rows"] for r in rows))

    agg = grouped_mean(rows, ["payload_group", "ratio", "total_rows"])

    fig, axes = plt.subplots(1, 2, figsize=(14, 5.2), squeeze=False, sharey=True)
    axes = axes[0]

    for ax, payload_group in zip(axes, payload_groups):
        for ratio in ratios:
            xs = []
            ys = []
            for size in sizes:
                val = agg.get((payload_group, ratio, size))
                if val is not None and not math.isnan(val):
                    xs.append(size)
                    ys.append(val)

            if xs:
                ax.plot(xs, ys, marker="o", linewidth=2, label=ratio_label(ratio))

        ax.set_xscale("log")
        ax.set_xlabel("Gesamtgröße build_rows + probe_rows, log scale")
        ax.set_title(payload_group)
        set_common_grid(ax)
        ax.legend(title="Build/Probe", fontsize=8)

    axes[0].set_ylabel("Mean speedup [baseline / filtered]")

    fig.suptitle(
        f"Build < Probe: Einfluss des Größenverhältnisses, match={match_rate:g}, FPR={fpr:g}"
    )
    fig.tight_layout()
    fig.savefig(outdir / "ratio_by_size_payload.png", dpi=180)
    plt.close(fig)


def plot_ratio_by_match_payload(rows, outdir):
    rows = [r for r in rows if r["build_rows"] < r["probe_rows"]]

    match_rates = sorted(set(r["match_rate"] for r in rows))
    payload_groups = ["ohne Payload", "mit Payload"]
    fprs = [f for f in [0.0, 0.01, 0.05, 0.10, 1.0] if any(abs(r["simulated_fpr"] - f) < 1e-12 for r in rows)]
    ratios = sorted(set(r["ratio"] for r in rows))

    agg = grouped_mean(rows, ["payload_group", "match_rate", "simulated_fpr", "ratio"])

    fig, axes = plt.subplots(
        len(payload_groups),
        len(match_rates),
        figsize=(5.0 * len(match_rates), 4.0 * len(payload_groups)),
        squeeze=False,
        sharey=True,
    )

    for row_idx, payload_group in enumerate(payload_groups):
        for col_idx, match_rate in enumerate(match_rates):
            ax = axes[row_idx][col_idx]

            for fpr in fprs:
                xs = []
                ys = []
                for ratio in ratios:
                    val = agg.get((payload_group, match_rate, fpr, ratio))
                    if val is not None and not math.isnan(val):
                        xs.append(ratio)
                        ys.append(val)

                if xs:
                    ax.plot(xs, ys, marker="o", linewidth=1.8, label=f"FPR={fpr:g}")

            ax.set_xscale("log")
            ax.set_xticks(ratios)
            ax.set_xticklabels([ratio_label(r) for r in ratios])
            ax.set_title(f"{payload_group}, match={match_rate:g}")
            ax.set_xlabel("Build/Probe")
            set_common_grid(ax)

            if col_idx == 0:
                ax.set_ylabel("Mean speedup")

            if row_idx == 0 and col_idx == len(match_rates) - 1:
                ax.legend(fontsize=8)

    fig.suptitle("Build < Probe: Ratio-Effekt nach Match-Rate und Payload")
    fig.tight_layout()
    fig.savefig(outdir / "ratio_by_match_payload_detail.png", dpi=180)
    plt.close(fig)


def pick_largest_sizes(sizes, n=2):
    sizes = sorted(set(sizes))
    return sizes[-n:] if len(sizes) > n else sizes


def plot_payload_columns_large_only(rows, outdir):
    rows = filter_rows(rows, query_kind="payload")

    sizes = pick_largest_sizes([r["total_rows"] for r in rows], n=2)
    payload_cols = sorted(set(r["payload_cols"] for r in rows))
    fprs = sorted(set(r["simulated_fpr"] for r in rows))

    agg = grouped_mean(rows, ["total_rows", "simulated_fpr", "payload_cols"])

    fig, axes = plt.subplots(1, len(sizes), figsize=(7 * len(sizes), 5.2), squeeze=False, sharey=True)
    axes = axes[0]

    for ax, size in zip(axes, sizes):
        for fpr in fprs:
            xs = []
            ys = []
            for p in payload_cols:
                val = agg.get((size, fpr, p))
                if val is not None and not math.isnan(val):
                    xs.append(p)
                    ys.append(val)

            if xs:
                ax.plot(xs, ys, marker="o", linewidth=2, label=f"FPR={fpr:g}")

        ax.set_xscale("log", base=2)
        ax.set_xticks(payload_cols)
        ax.set_xticklabels([str(p) for p in payload_cols])
        ax.set_xlabel("Payload-Spalten auf Build-Seite")
        ax.set_title(f"Gesamtgröße {size_label(size)}")
        set_common_grid(ax)
        ax.legend(fontsize=8)

    axes[0].set_ylabel("Mean speedup [baseline / filtered]")

    fig.suptitle("Einfluss der Build-Payload-Breite bei großen Datenmengen")
    fig.tight_layout()
    fig.savefig(outdir / "payload_columns_large_only.png", dpi=180)
    plt.close(fig)


def plot_payload_columns_all_sizes(rows, outdir):
    rows = filter_rows(rows, query_kind="payload")

    sizes = sorted(set(r["total_rows"] for r in rows))
    payload_cols = sorted(set(r["payload_cols"] for r in rows))
    fprs = sorted(set(r["simulated_fpr"] for r in rows))

    # Maximal vier Panels, sonst wird es wieder unübersichtlich.
    if len(sizes) > 4:
        idxs = [0, round((len(sizes) - 1) / 3), round(2 * (len(sizes) - 1) / 3), len(sizes) - 1]
        sizes = [sizes[i] for i in sorted(set(idxs))]

    agg = grouped_mean(rows, ["total_rows", "simulated_fpr", "payload_cols"])

    ncols = 2
    nrows = math.ceil(len(sizes) / ncols)
    fig, axes = plt.subplots(nrows, ncols, figsize=(12, 4.4 * nrows), squeeze=False, sharey=True)
    flat_axes = [ax for row in axes for ax in row]

    for ax, size in zip(flat_axes, sizes):
        for fpr in fprs:
            xs = []
            ys = []
            for p in payload_cols:
                val = agg.get((size, fpr, p))
                if val is not None and not math.isnan(val):
                    xs.append(p)
                    ys.append(val)

            if xs:
                ax.plot(xs, ys, marker="o", linewidth=1.8, label=f"FPR={fpr:g}")

        ax.set_xscale("log", base=2)
        ax.set_xticks(payload_cols)
        ax.set_xticklabels([str(p) for p in payload_cols])
        ax.set_title(f"Gesamtgröße {size_label(size)}")
        ax.set_xlabel("Payload-Spalten auf Build-Seite")
        set_common_grid(ax)
        ax.legend(fontsize=8)

    for ax in flat_axes[len(sizes):]:
        ax.axis("off")

    for row in axes:
        row[0].set_ylabel("Mean speedup")

    fig.suptitle("Payload-Spalten-Effekt nach Datenmenge")
    fig.tight_layout()
    fig.savefig(outdir / "payload_columns_by_size_detail.png", dpi=180)
    plt.close(fig)


def write_report(outdir):
    text = """# Final Timeline Plots

Diese Plots ergänzen die vorhandenen Hauptplots:

- `speedup_vs_size.png`
- `speedup_vs_fpr.png`
- `payload_effect.png`

## Neue Plots

### `ratio_by_size_payload.png`

Präsentationsplot für den Effekt des Build/Probe-Verhältnisses.
Es werden nur Fälle mit `build_rows < probe_rows` gezeigt.
Der Plot ist auf `match=0.1` und `FPR=0.05` fixiert, damit nicht Ratio, Match-Rate und FPR gleichzeitig vermischt werden.

### `payload_columns_large_only.png`

Präsentationsplot für den Effekt der Anzahl der Build-Payload-Spalten.
Es werden nur die zwei größten Datenmengen gezeigt, weil der Effekt dort sichtbar und relevant ist.

### `ratio_by_match_payload_detail.png`

Backup-/Detailplot.
Zeigt den Ratio-Effekt zusätzlich getrennt nach Match-Rate und Payload.

### `payload_columns_by_size_detail.png`

Backup-/Detailplot.
Zeigt den Payload-Column-Effekt für mehrere Größen.

## Empfohlene Präsentationsauswahl

Für die Präsentation:

1. `speedup_vs_size.png`
2. `speedup_vs_fpr.png`
3. `payload_effect.png`
4. `ratio_by_size_payload.png`
5. `payload_columns_large_only.png`

Die Detailplots nur als Backup verwenden.
"""
    (outdir / "final_timeline_plots_report.md").write_text(text)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ratio-csv", default="results/ratio_results.csv")
    parser.add_argument("--payload-csv", default="results/payload_columns_results.csv")
    parser.add_argument("--outdir", default="results/timeline_final_plots")
    parser.add_argument("--ratio-fpr", type=float, default=0.05)
    parser.add_argument("--ratio-match-rate", type=float, default=0.10)
    args = parser.parse_args()

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    ratio_rows = read_csv(args.ratio_csv)
    payload_rows = read_csv(args.payload_csv)

    plot_ratio_by_size_payload(
        ratio_rows,
        outdir,
        fpr=args.ratio_fpr,
        match_rate=args.ratio_match_rate,
    )
    plot_payload_columns_large_only(payload_rows, outdir)

    # Backup/detail plots
    plot_ratio_by_match_payload(ratio_rows, outdir)
    plot_payload_columns_all_sizes(payload_rows, outdir)

    write_report(outdir)

    print(f"Wrote plots to {outdir}")
    for p in sorted(outdir.iterdir()):
        print(p)


if __name__ == "__main__":
    main()