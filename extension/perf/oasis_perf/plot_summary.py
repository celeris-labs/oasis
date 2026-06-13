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
    if not xs:
        return float("nan")
    return statistics.fmean(xs)


def size_label(n: int) -> str:
    if n >= 1_000_000:
        return f"{n/1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n/1_000:.0f}k"
    return str(n)


def pick_representative(values, max_items=5):
    values = sorted(set(values))
    if len(values) <= max_items:
        return values
    idxs = []
    for i in range(max_items):
        pos = round(i * (len(values) - 1) / (max_items - 1))
        idxs.append(pos)
    return [values[i] for i in sorted(set(idxs))]


def load_rows(csv_path: Path):
    rows = []
    with csv_path.open() as f:
        reader = csv.DictReader(f)
        for r in reader:
            row = dict(r)
            row["build_rows"] = int(float(row["build_rows"]))
            row["probe_rows"] = int(float(row["probe_rows"]))
            row["match_rate"] = float(row["match_rate"])
            row["payload_cols"] = int(float(row["payload_cols"]))
            row["simulated_fpr"] = float(row["simulated_fpr"])
            row["baseline_ms"] = float(row["baseline_ms"])
            row["filtered_ms"] = float(row["filtered_ms"])
            row["speedup"] = float(row["speedup"])

            row["_size"] = row["build_rows"] + row["probe_rows"]
            row["_payload_group"] = "no_payload" if row["payload_cols"] == 0 else "with_payload"
            rows.append(row)
    return rows


def agg_speedup(rows, key_fields):
    acc = defaultdict(list)
    for r in rows:
        key = tuple(r[k] for k in key_fields)
        acc[key].append(r["speedup"])
    return {k: mean(v) for k, v in acc.items()}


def plot_speedup_vs_size(rows, outdir: Path):
    payload_groups = [g for g in ["no_payload", "with_payload"] if any(r["_payload_group"] == g for r in rows)]
    fprs = sorted(set(r["simulated_fpr"] for r in rows))
    sizes = sorted(set(r["_size"] for r in rows))

    agg = agg_speedup(rows, ["_payload_group", "simulated_fpr", "_size"])

    fig, axes = plt.subplots(1, len(payload_groups), figsize=(7 * len(payload_groups), 5), squeeze=False)
    axes = axes[0]

    for ax, group in zip(axes, payload_groups):
        for fpr in fprs:
            xs = []
            ys = []
            for s in sizes:
                val = agg.get((group, fpr, s))
                if val is not None and not math.isnan(val):
                    xs.append(s)
                    ys.append(val)
            if xs:
                ax.plot(xs, ys, marker="o", label=f"FPR={fpr:g}")
        ax.set_xscale("log")
        ax.set_title("ohne Payload" if group == "no_payload" else "mit Payload")
        ax.set_xlabel("Gesamtgröße (build_rows + probe_rows)")
        ax.set_ylabel("Mean speedup [baseline / filtered]")
        ax.grid(True, alpha=0.3)
        ax.legend()

    fig.suptitle("Speedup vs Datenmenge")
    fig.tight_layout()
    fig.savefig(outdir / "speedup_vs_size.png", dpi=160)
    plt.close(fig)


def plot_speedup_vs_fpr(rows, outdir: Path):
    payload_groups = [g for g in ["no_payload", "with_payload"] if any(r["_payload_group"] == g for r in rows)]
    all_sizes = sorted(set(r["_size"] for r in rows))
    sizes = pick_representative(all_sizes, max_items=5)
    fprs = sorted(set(r["simulated_fpr"] for r in rows))

    agg = agg_speedup(rows, ["_payload_group", "_size", "simulated_fpr"])

    fig, axes = plt.subplots(1, len(payload_groups), figsize=(7 * len(payload_groups), 5), squeeze=False)
    axes = axes[0]

    for ax, group in zip(axes, payload_groups):
        for s in sizes:
            xs = []
            ys = []
            for fpr in fprs:
                val = agg.get((group, s, fpr))
                if val is not None and not math.isnan(val):
                    xs.append(fpr)
                    ys.append(val)
            if xs:
                ax.plot(xs, ys, marker="o", label=f"size={size_label(s)}")
        ax.set_title("ohne Payload" if group == "no_payload" else "mit Payload")
        ax.set_xlabel("Simulierte False-Positive-Rate")
        ax.set_ylabel("Mean speedup [baseline / filtered]")
        ax.grid(True, alpha=0.3)
        ax.legend()

    fig.suptitle("Speedup vs FPR")
    fig.tight_layout()
    fig.savefig(outdir / "speedup_vs_fpr.png", dpi=160)
    plt.close(fig)


def plot_payload_effect(rows, outdir: Path):
    sizes = sorted(set(r["_size"] for r in rows))
    agg = agg_speedup(rows, ["_payload_group", "_size"])

    no_payload = [agg.get(("no_payload", s), float("nan")) for s in sizes]
    with_payload = [agg.get(("with_payload", s), float("nan")) for s in sizes]

    x = list(range(len(sizes)))
    width = 0.38

    fig = plt.figure(figsize=(10, 5.5))
    ax = fig.add_subplot(111)
    ax.bar([i - width / 2 for i in x], no_payload, width=width, label="ohne Payload")
    ax.bar([i + width / 2 for i in x], with_payload, width=width, label="mit Payload")

    ax.set_xticks(x)
    ax.set_xticklabels([size_label(s) for s in sizes])
    ax.set_xlabel("Gesamtgröße (build_rows + probe_rows)")
    ax.set_ylabel("Mean speedup [baseline / filtered]")
    ax.set_title("Payload-Effekt auf den Speedup")
    ax.grid(True, axis="y", alpha=0.3)
    ax.legend()

    fig.tight_layout()
    fig.savefig(outdir / "payload_effect.png", dpi=160)
    plt.close(fig)


def write_report(rows, outdir: Path):
    sizes = sorted(set(r["_size"] for r in rows))
    fprs = sorted(set(r["simulated_fpr"] for r in rows))
    match_rates = sorted(set(r["match_rate"] for r in rows))
    payload_cols = sorted(set(r["payload_cols"] for r in rows))

    speedups = [r["speedup"] for r in rows]
    baselines = [r["baseline_ms"] for r in rows]
    filtered = [r["filtered_ms"] for r in rows]

    lines = []
    lines.append("# Benchmark Summary")
    lines.append("")
    lines.append(f"- Anzahl Messpunkte: {len(rows)}")
    lines.append(f"- Datengrößen (build+probe): {', '.join(size_label(s) for s in sizes)}")
    lines.append(f"- FPRs: {', '.join(str(x) for x in fprs)}")
    lines.append(f"- Match-Rates: {', '.join(str(x) for x in match_rates)}")
    lines.append(f"- Payload-Spalten: {', '.join(str(x) for x in payload_cols)}")
    lines.append("")
    lines.append("## Globale Mittelwerte")
    lines.append("")
    lines.append(f"- Mean baseline runtime: {mean(baselines):.4f} ms")
    lines.append(f"- Mean filtered runtime: {mean(filtered):.4f} ms")
    lines.append(f"- Mean speedup: {mean(speedups):.4f}x")
    lines.append("")
    lines.append("## Was zeigen die 3 Plots?")
    lines.append("")
    lines.append("1. **speedup_vs_size.png**")
    lines.append("   - Aggregiert über Match-Rate und Wiederholungen.")
    lines.append("   - Zeigt, wie der Speedup mit wachsender Datenmenge skaliert.")
    lines.append("   - Jeweils getrennt für ohne/mit Payload.")
    lines.append("")
    lines.append("2. **speedup_vs_fpr.png**")
    lines.append("   - Aggregiert über Match-Rate und Wiederholungen.")
    lines.append("   - Zeigt, wie empfindlich der Speedup auf bessere/schlechtere FPR reagiert.")
    lines.append("   - Jeweils getrennt für ohne/mit Payload.")
    lines.append("")
    lines.append("3. **payload_effect.png**")
    lines.append("   - Aggregiert über FPR, Match-Rate und Wiederholungen.")
    lines.append("   - Zeigt den direkten Effekt zusätzlicher Payload-Spalten auf den beobachteten Speedup.")
    lines.append("")
    lines.append("## Hinweis")
    lines.append("")
    lines.append("Die Aggregation ist absichtlich kompakt gehalten, damit nicht wieder zu viele Einzelplots entstehen.")
    lines.append("Wenn später ein bestimmter Ausreißer interessant ist, kann man dafür gezielt wieder Detailplots erzeugen.")

    (outdir / "summary_report.md").write_text("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", default="results/sweep_results.csv")
    parser.add_argument("--outdir", default="results/summary_plots")
    args = parser.parse_args()

    csv_path = Path(args.csv)
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    rows = load_rows(csv_path)

    plot_speedup_vs_size(rows, outdir)
    plot_speedup_vs_fpr(rows, outdir)
    plot_payload_effect(rows, outdir)
    write_report(rows, outdir)

    print(f"Wrote summary outputs to {outdir}")
    for p in sorted(outdir.iterdir()):
        print(p)


if __name__ == "__main__":
    main()
