#!/usr/bin/env python3
import argparse
import csv
import statistics
from collections import defaultdict
from pathlib import Path

import matplotlib.pyplot as plt


def mean(xs):
    xs = list(xs)
    return statistics.fmean(xs) if xs else float("nan")


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


def pick_rows(rows, fpr=None, query_kind=None):
    out = []
    for r in rows:
        if fpr is not None and abs(r["simulated_fpr"] - fpr) > 1e-12:
            continue
        if query_kind is not None and r.get("query_kind") != query_kind:
            continue
        out.append(r)
    return out


def plot_ratio_effect(ax, rows, fpr):
    rows = pick_rows(rows, fpr=fpr)

    # Nur build < probe, wie gewünscht.
    rows = [r for r in rows if r["build_rows"] < r["probe_rows"]]

    ratios = sorted(set(r["ratio"] for r in rows))
    payload_groups = ["ohne Payload", "mit Payload"]

    agg = grouped_mean(rows, ["payload_group", "ratio"])

    for group in payload_groups:
        xs = []
        ys = []
        for ratio in ratios:
            val = agg.get((group, ratio))
            if val is not None:
                xs.append(ratio)
                ys.append(val)
        if xs:
            ax.plot(xs, ys, marker="o", label=group)

    ax.set_xscale("log")
    ax.set_xticks(ratios)
    ax.set_xticklabels([f"1:{int(r)}" if abs(r - int(r)) < 1e-9 else f"1:{r:g}" for r in ratios])
    ax.set_xlabel("Build/Probe-Verhältnis")
    ax.set_ylabel("Mean speedup [baseline / filtered]")
    ax.set_title(f"Einfluss des Build/Probe-Verhältnisses, FPR={fpr:g}")
    ax.grid(True, alpha=0.3)
    ax.legend()


def plot_payload_columns_effect(ax, rows, fpr):
    rows = pick_rows(rows, fpr=fpr, query_kind="payload")

    # Für diesen Plot geht es um breite Build-Seite.
    # Wir aggregieren über die getesteten Größen und Match-Rates.
    payload_cols = sorted(set(r["payload_cols"] for r in rows))
    agg = grouped_mean(rows, ["payload_cols"])

    xs = []
    ys = []
    for p in payload_cols:
        val = agg.get((p,))
        if val is not None:
            xs.append(p)
            ys.append(val)

    ax.plot(xs, ys, marker="o")
    ax.set_xscale("log", base=2)
    ax.set_xticks(xs)
    ax.set_xticklabels([str(x) for x in xs])
    ax.set_xlabel("Payload-Spalten auf Build-Seite")
    ax.set_ylabel("Mean speedup [baseline / filtered]")
    ax.set_title(f"Einfluss der Build-Payload-Breite, FPR={fpr:g}")
    ax.grid(True, alpha=0.3)


def write_report(outdir, ratio_rows, payload_rows, fpr):
    ratio_filtered = [r for r in ratio_rows if abs(r["simulated_fpr"] - fpr) < 1e-12 and r["build_rows"] < r["probe_rows"]]
    payload_filtered = [r for r in payload_rows if abs(r["simulated_fpr"] - fpr) < 1e-12 and r.get("query_kind") == "payload"]

    ratios = sorted(set(r["ratio"] for r in ratio_filtered))
    payload_cols = sorted(set(r["payload_cols"] for r in payload_filtered))

    lines = []
    lines.append("# Timeline Benchmark Additions")
    lines.append("")
    lines.append(f"Representative FPR used for presentation plots: `{fpr:g}`")
    lines.append("")
    lines.append("## Abgedeckte Zusatzfragen")
    lines.append("")
    lines.append("- Einfluss des Build/Probe-Größenverhältnisses, nur `build < probe`.")
    lines.append("- Einfluss der Anzahl Payload-Spalten auf der Build-Seite.")
    lines.append("")
    lines.append("## Ratio-Test")
    lines.append("")
    lines.append(f"- getestete Probe/Build-Ratios: {', '.join(f'1:{int(r)}' if abs(r-int(r)) < 1e-9 else f'1:{r:g}' for r in ratios)}")
    lines.append("- aggregiert über absolute Größen, Match-Rates und Wiederholungen.")
    lines.append("")
    lines.append("## Payload-Column-Test")
    lines.append("")
    lines.append(f"- getestete Payload-Spalten: {', '.join(str(x) for x in payload_cols)}")
    lines.append("- aggregiert über absolute Größen, Match-Rates und Wiederholungen.")
    lines.append("")
    lines.append("## Interpretation")
    lines.append("")
    lines.append("Diese Plots ergänzen die bereits vorhandenen Plots zu absoluter Datenmenge, FPR und Payload ja/nein.")
    lines.append("Damit ist der Timeline-Punkt abgedeckt, ohne dieselben Messungen erneut zu visualisieren.")

    (outdir / "timeline_additions_report.md").write_text("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ratio-csv", default="results/ratio_results.csv")
    parser.add_argument("--payload-csv", default="results/payload_columns_results.csv")
    parser.add_argument("--outdir", default="results/timeline_plots")
    parser.add_argument("--fpr", type=float, default=0.05)
    args = parser.parse_args()

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    ratio_rows = read_csv(args.ratio_csv)
    payload_rows = read_csv(args.payload_csv)

    fig, axes = plt.subplots(1, 2, figsize=(15, 5.5))

    plot_ratio_effect(axes[0], ratio_rows, args.fpr)
    plot_payload_columns_effect(axes[1], payload_rows, args.fpr)

    fig.suptitle("Zusatzbenchmarks: Größenverhältnis und Build-Payload-Breite")
    fig.tight_layout()
    fig.savefig(outdir / "timeline_additions_summary.png", dpi=180)
    plt.close(fig)

    write_report(outdir, ratio_rows, payload_rows, args.fpr)

    print(f"Wrote {outdir / 'timeline_additions_summary.png'}")
    print(f"Wrote {outdir / 'timeline_additions_report.md'}")


if __name__ == "__main__":
    main()