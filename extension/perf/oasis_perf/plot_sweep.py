#!/usr/bin/env python3
import argparse
import csv
from collections import defaultdict
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np


def load_rows(path: Path):
    with path.open() as f:
        return list(csv.DictReader(f))


def mean(xs):
    xs = [float(x) for x in xs]
    return sum(xs) / len(xs) if xs else 0.0


def group_mean(rows, keys, value_key):
    grouped = defaultdict(list)
    for row in rows:
        grouped[tuple(row[k] for k in keys)].append(float(row[value_key]))
    return {k: mean(v) for k, v in grouped.items()}


def safe_name(s):
    return str(s).replace("/", "_").replace(".", "p").replace(" ", "_")


def plot_speedup_vs_match_rate(rows, outdir: Path):
    configs = sorted(set(
        (r["query_kind"], r["build_rows"], r["probe_rows"], r["payload_cols"])
        for r in rows
    ))

    for query_kind, build_rows, probe_rows, payload_cols in configs:
        sub = [
            r for r in rows
            if r["query_kind"] == query_kind
            and r["build_rows"] == build_rows
            and r["probe_rows"] == probe_rows
            and r["payload_cols"] == payload_cols
        ]

        fprs = sorted(set(float(r["simulated_fpr"]) for r in sub))
        match_rates = sorted(set(float(r["match_rate"]) for r in sub))

        plt.figure(figsize=(8, 5))

        for fpr in fprs:
            y = []
            for mr in match_rates:
                vals = [
                    float(r["speedup"]) for r in sub
                    if float(r["simulated_fpr"]) == fpr and float(r["match_rate"]) == mr
                ]
                y.append(mean(vals))
            plt.plot(match_rates, y, marker="o", label=f"FPR={fpr:g}")

        plt.xlabel("Match rate")
        plt.ylabel("Speedup [baseline / filtered]")
        plt.title(f"Speedup vs match rate ({query_kind}, build={build_rows}, probe={probe_rows}, payload={payload_cols})")
        plt.grid(True, alpha=0.3)
        plt.legend()
        plt.tight_layout()

        name = f"speedup_vs_match_{query_kind}_build{build_rows}_probe{probe_rows}_payload{payload_cols}.png"
        plt.savefig(outdir / name, dpi=150)
        plt.close()


def plot_filtered_rows_vs_fpr(rows, outdir: Path):
    configs = sorted(set(
        (r["build_rows"], r["probe_rows"], r["match_rate"], r["payload_cols"])
        for r in rows
    ))

    for build_rows, probe_rows, match_rate, payload_cols in configs:
        sub = [
            r for r in rows
            if r["build_rows"] == build_rows
            and r["probe_rows"] == probe_rows
            and r["match_rate"] == match_rate
            and r["payload_cols"] == payload_cols
            and r["query_kind"] == "count"
        ]

        if not sub:
            continue

        fprs = sorted(set(float(r["simulated_fpr"]) for r in sub))
        filtered = []
        for fpr in fprs:
            vals = [
                float(r["filtered_probe_rows"]) for r in sub
                if float(r["simulated_fpr"]) == fpr
            ]
            filtered.append(mean(vals))

        plt.figure(figsize=(8, 5))
        plt.plot(fprs, filtered, marker="o")
        plt.xlabel("Simulated false-positive rate")
        plt.ylabel("Filtered probe rows")
        plt.title(f"Rows passed vs FPR (build={build_rows}, probe={probe_rows}, match={match_rate}, payload={payload_cols})")
        plt.grid(True, alpha=0.3)
        plt.tight_layout()

        name = f"filtered_rows_vs_fpr_build{build_rows}_probe{probe_rows}_match{safe_name(match_rate)}_payload{payload_cols}.png"
        plt.savefig(outdir / name, dpi=150)
        plt.close()


def plot_runtime_vs_fpr(rows, outdir: Path):
    configs = sorted(set(
        (r["query_kind"], r["build_rows"], r["probe_rows"], r["match_rate"], r["payload_cols"])
        for r in rows
    ))

    for query_kind, build_rows, probe_rows, match_rate, payload_cols in configs:
        sub = [
            r for r in rows
            if r["query_kind"] == query_kind
            and r["build_rows"] == build_rows
            and r["probe_rows"] == probe_rows
            and r["match_rate"] == match_rate
            and r["payload_cols"] == payload_cols
        ]

        fprs = sorted(set(float(r["simulated_fpr"]) for r in sub))
        filtered_ms = []
        baseline_ms = []

        for fpr in fprs:
            filtered_ms.append(mean([
                r["filtered_ms"] for r in sub
                if float(r["simulated_fpr"]) == fpr
            ]))
            baseline_ms.append(mean([
                r["baseline_ms"] for r in sub
                if float(r["simulated_fpr"]) == fpr
            ]))

        plt.figure(figsize=(8, 5))
        plt.plot(fprs, filtered_ms, marker="o", label="filtered")
        plt.plot(fprs, baseline_ms, linestyle="--", label="baseline")
        plt.xlabel("Simulated false-positive rate")
        plt.ylabel("Runtime [ms]")
        plt.title(f"Runtime vs FPR ({query_kind}, build={build_rows}, probe={probe_rows}, match={match_rate}, payload={payload_cols})")
        plt.grid(True, alpha=0.3)
        plt.legend()
        plt.tight_layout()

        name = f"runtime_vs_fpr_{query_kind}_build{build_rows}_probe{probe_rows}_match{safe_name(match_rate)}_payload{payload_cols}.png"
        plt.savefig(outdir / name, dpi=150)
        plt.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", default="results/sweep_results.csv")
    parser.add_argument("--outdir", default="results/sweep_plots")
    args = parser.parse_args()

    rows = load_rows(Path(args.csv))
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    plot_speedup_vs_match_rate(rows, outdir)
    plot_filtered_rows_vs_fpr(rows, outdir)
    plot_runtime_vs_fpr(rows, outdir)

    print(f"Wrote plots to {outdir}")


if __name__ == "__main__":
    main()
