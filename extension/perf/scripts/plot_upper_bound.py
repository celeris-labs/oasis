#!/usr/bin/env python3
import csv
import math
import os
import argparse
import statistics
import matplotlib.pyplot as plt


def pick(row, *names):
    for n in names:
        if n in row:
            return row[n]
    raise KeyError(f"None of the columns {names} found in CSV. Found: {list(row.keys())}")


def load_rows(path):
    rows = []
    with open(path, "r", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rep = int(pick(row, "rep", "repetition", "run"))
            baseline = float(pick(row, "baseline_ms", "baseline"))
            filtered = float(pick(row, "filtered_ms", "filtered"))
            if "speedup" in row and row["speedup"] != "":
                speedup = float(row["speedup"])
            else:
                speedup = baseline / filtered
            rows.append({
                "rep": rep,
                "baseline_ms": baseline,
                "filtered_ms": filtered,
                "speedup": speedup,
            })
    rows.sort(key=lambda r: r["rep"])
    return rows


def mean_std(values):
    if len(values) == 1:
        return values[0], 0.0
    return statistics.mean(values), statistics.stdev(values)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", required=True, help="Path to upper_bound_results.csv")
    parser.add_argument("--outdir", required=True, help="Directory for plots")
    args = parser.parse_args()

    os.makedirs(args.outdir, exist_ok=True)

    rows = load_rows(args.csv)

    reps = [r["rep"] for r in rows]
    baseline = [r["baseline_ms"] for r in rows]
    filtered = [r["filtered_ms"] for r in rows]
    speedup = [r["speedup"] for r in rows]

    baseline_mean, baseline_std = mean_std(baseline)
    filtered_mean, filtered_std = mean_std(filtered)
    speedup_mean, speedup_std = mean_std(speedup)

    # Plot 1: baseline vs filtered per repetition
    plt.figure(figsize=(8, 5))
    plt.plot(reps, baseline, marker="o", label="baseline")
    plt.plot(reps, filtered, marker="o", label="filtered_exact")
    plt.xlabel("Repetition")
    plt.ylabel("Runtime [ms]")
    plt.title("Upper-bound benchmark: runtime per repetition")
    plt.legend()
    plt.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(os.path.join(args.outdir, "runtime_per_rep.png"), dpi=150)
    plt.close()

    # Plot 2: speedup per repetition
    plt.figure(figsize=(8, 5))
    plt.plot(reps, speedup, marker="o")
    plt.axhline(speedup_mean, linestyle="--", label=f"mean = {speedup_mean:.3f}x")
    plt.xlabel("Repetition")
    plt.ylabel("Speedup [baseline / filtered]")
    plt.title("Upper-bound benchmark: speedup per repetition")
    plt.legend()
    plt.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(os.path.join(args.outdir, "speedup_per_rep.png"), dpi=150)
    plt.close()

    # Plot 3: summary bar chart with std-dev
    plt.figure(figsize=(8, 5))
    labels = ["baseline", "filtered_exact", "speedup"]
    means = [baseline_mean, filtered_mean, speedup_mean]
    errs = [baseline_std, filtered_std, speedup_std]
    plt.bar(labels, means, yerr=errs, capsize=6)
    plt.ylabel("ms / x")
    plt.title("Upper-bound benchmark: summary")
    plt.tight_layout()
    plt.savefig(os.path.join(args.outdir, "summary.png"), dpi=150)
    plt.close()

    # Write small text summary too
    with open(os.path.join(args.outdir, "summary.txt"), "w") as f:
        f.write(f"baseline_mean_ms={baseline_mean:.6f}\n")
        f.write(f"baseline_std_ms={baseline_std:.6f}\n")
        f.write(f"filtered_mean_ms={filtered_mean:.6f}\n")
        f.write(f"filtered_std_ms={filtered_std:.6f}\n")
        f.write(f"speedup_mean={speedup_mean:.6f}\n")
        f.write(f"speedup_std={speedup_std:.6f}\n")

    print("Wrote:")
    print(os.path.join(args.outdir, "runtime_per_rep.png"))
    print(os.path.join(args.outdir, "speedup_per_rep.png"))
    print(os.path.join(args.outdir, "summary.png"))
    print(os.path.join(args.outdir, "summary.txt"))


if __name__ == "__main__":
    main()
