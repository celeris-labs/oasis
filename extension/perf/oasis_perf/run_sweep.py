#!/usr/bin/env python3
import argparse
import csv
import time
from collections import defaultdict
from pathlib import Path

import duckdb
import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq


def parse_list_int(s):
    return [int(x) for x in s.split(",") if x.strip()]


def parse_list_float(s):
    return [float(x) for x in s.split(",") if x.strip()]


def parse_list_str(s):
    return [x.strip() for x in s.split(",") if x.strip()]


def fpr_tag(fpr):
    return str(fpr).replace(".", "p")


def write_parquet(path: Path, table: pa.Table, compression: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    pq.write_table(table, path, compression=compression)


def generate_dataset(
    out_dir: Path,
    build_rows: int,
    probe_rows: int,
    match_rate: float,
    payload_cols: int,
    fprs,
    seed: int,
    compression: str,
):
    out_dir.mkdir(parents=True, exist_ok=True)

    rng = np.random.default_rng(seed)

    build_keys = np.arange(build_rows, dtype=np.int64)
    build_cols = {"key": pa.array(build_keys, type=pa.int64())}

    for c in range(payload_cols):
        payload = ((build_keys * np.int64(1315423911)) + np.int64(c * 2654435761)) & np.int64(0x7FFFFFFFFFFFFFFF)
        build_cols[f"payload_{c}"] = pa.array(payload, type=pa.int64())

    build_table = pa.table(build_cols)

    match_rows = int(round(probe_rows * match_rate))
    nonmatch_rows = probe_rows - match_rows

    if match_rows > 0:
        matching_keys = build_keys[np.arange(match_rows, dtype=np.int64) % build_rows]
    else:
        matching_keys = np.empty(0, dtype=np.int64)

    nonmatch_base = build_rows + 1_000_000_000
    nonmatching_keys = np.arange(nonmatch_base, nonmatch_base + nonmatch_rows, dtype=np.int64)

    probe_keys = np.concatenate([matching_keys, nonmatching_keys])
    rng.shuffle(probe_keys)

    match_mask = probe_keys < build_rows
    exact_filtered = probe_keys[match_mask]
    nonmatches = probe_keys[~match_mask]

    write_parquet(out_dir / "build.parquet", build_table, compression)
    write_parquet(out_dir / "probe.parquet", pa.table({"key": pa.array(probe_keys, type=pa.int64())}), compression)
    write_parquet(
        out_dir / "probe_filtered_fpr_0p0.parquet",
        pa.table({"key": pa.array(exact_filtered, type=pa.int64())}),
        compression,
    )

    fpr_rows = {0.0: int(len(exact_filtered))}

    for fpr in fprs:
        if fpr == 0.0:
            continue

        if fpr >= 1.0:
            sampled_nonmatches = nonmatches
        else:
            keep = rng.random(len(nonmatches)) < fpr
            sampled_nonmatches = nonmatches[keep]

        filtered = np.concatenate([exact_filtered, sampled_nonmatches])
        rng.shuffle(filtered)

        write_parquet(
            out_dir / f"probe_filtered_fpr_{fpr_tag(fpr)}.parquet",
            pa.table({"key": pa.array(filtered, type=pa.int64())}),
            compression,
        )
        fpr_rows[fpr] = int(len(filtered))

    with (out_dir / "meta.txt").open("w") as f:
        f.write(f"build_rows={build_rows}\n")
        f.write(f"probe_rows={probe_rows}\n")
        f.write(f"match_rate={match_rate}\n")
        f.write(f"payload_cols={payload_cols}\n")
        f.write(f"true_match_rows={int(len(exact_filtered))}\n")
        f.write(f"nonmatch_rows={int(len(nonmatches))}\n")
        f.write(f"compression={compression}\n")
        f.write(f"seed={seed}\n")
        for fpr, rows in sorted(fpr_rows.items()):
            f.write(f"filtered_rows_fpr_{fpr_tag(fpr)}={rows}\n")

    return {
        "true_match_rows": int(len(exact_filtered)),
        "nonmatch_rows": int(len(nonmatches)),
        "fpr_rows": fpr_rows,
    }


def make_query(build_path: Path, probe_path: Path, query_kind: str, payload_sums: int, payload_cols: int):
    if query_kind == "count":
        select = "COUNT(*)"
    elif query_kind == "payload":
        use_sums = min(payload_sums, payload_cols)
        sums = [f"SUM(b.payload_{i})" for i in range(use_sums)]
        select = "COUNT(*)" if not sums else "COUNT(*), " + ", ".join(sums)
    else:
        raise ValueError(query_kind)

    return f"""
SELECT {select}
FROM read_parquet('{probe_path}') p
JOIN read_parquet('{build_path}') b
ON p.key = b.key
"""


def timed_query(con, sql):
    start = time.perf_counter()
    con.execute(sql).fetchall()
    end = time.perf_counter()
    return (end - start) * 1000.0


def append_rows(csv_path: Path, rows):
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    write_header = not csv_path.exists()
    with csv_path.open("a", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        if write_header:
            writer.writeheader()
        writer.writerows(rows)


def write_report(report_path: Path, csv_rows):
    grouped = defaultdict(list)

    for row in csv_rows:
        key = (
            row["query_kind"],
            row["build_rows"],
            row["probe_rows"],
            row["match_rate"],
            row["payload_cols"],
            row["simulated_fpr"],
        )
        grouped[key].append(row)

    lines = []
    lines.append("# Upper-bound and simulated-FPR Bloom filtering benchmark")
    lines.append("")
    lines.append("This benchmark measures the downstream DuckDB join benefit of reducing the probe-side input before the join.")
    lines.append("")
    lines.append("The simulated false-positive rate is implemented as:")
    lines.append("")
    lines.append("```text")
    lines.append("filtered_probe = all true matching probe rows + random sample of non-matching probe rows with probability FPR")
    lines.append("```")
    lines.append("")
    lines.append("Therefore `FPR=0.0` is a perfect filter upper bound, and `FPR=1.0` approximates no filtering.")
    lines.append("")
    lines.append("## Summary")
    lines.append("")
    lines.append("| query | build | probe | match_rate | payload_cols | FPR | filtered_rows | baseline_ms | filtered_ms | speedup |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")

    for key, rows in sorted(grouped.items()):
        query_kind, build_rows, probe_rows, match_rate, payload_cols, fpr = key
        baseline = np.mean([float(r["baseline_ms"]) for r in rows])
        filtered = np.mean([float(r["filtered_ms"]) for r in rows])
        speedup = np.mean([float(r["speedup"]) for r in rows])
        filtered_rows = int(rows[0]["filtered_probe_rows"])

        lines.append(
            f"| {query_kind} | {build_rows} | {probe_rows} | {match_rate} | {payload_cols} | {fpr} | "
            f"{filtered_rows} | {baseline:.3f} | {filtered:.3f} | {speedup:.3f} |"
        )

    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-rows", default="100000")
    parser.add_argument("--probe-rows", default="100000")
    parser.add_argument("--paired-sizes", action="store_true",
                        help="Pair build/probe sizes by index instead of taking the Cartesian product.")
    parser.add_argument("--match-rates", default="0.01,0.10,0.50,1.00")
    parser.add_argument("--payload-cols", default="0,8")
    parser.add_argument("--fprs", default="0.0,0.01,0.05,0.10,1.0")
    parser.add_argument("--query-kinds", default="count,payload")
    parser.add_argument("--payload-sums", type=int, default=4)
    parser.add_argument("--threads", type=int, default=1)
    parser.add_argument("--warmup", type=int, default=1)
    parser.add_argument("--repetitions", type=int, default=5)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--compression", default="snappy")
    parser.add_argument("--data-root", default="data/sweep")
    parser.add_argument("--out-csv", default="results/sweep_results.csv")
    parser.add_argument("--report", default="results/sweep_report.md")
    args = parser.parse_args()

    build_rows_list = parse_list_int(args.build_rows)
    probe_rows_list = parse_list_int(args.probe_rows)
    match_rates = parse_list_float(args.match_rates)
    payload_cols_list = parse_list_int(args.payload_cols)
    fprs = parse_list_float(args.fprs)
    query_kinds = parse_list_str(args.query_kinds)

    if 0.0 not in fprs:
        fprs = [0.0] + fprs
    fprs = sorted(set(fprs))

    data_root = Path(args.data_root)
    out_csv = Path(args.out_csv)
    report_path = Path(args.report)

    con = duckdb.connect(database=":memory:")
    con.execute(f"PRAGMA threads={args.threads}")

    all_rows = []

    if args.paired_sizes:
        if len(build_rows_list) != len(probe_rows_list):
            raise SystemExit("--paired-sizes requires same number of --build-rows and --probe-rows entries")
        size_pairs = list(zip(build_rows_list, probe_rows_list))
    else:
        size_pairs = [(b, p) for b in build_rows_list for p in probe_rows_list]

    for build_rows, probe_rows in size_pairs:
        for match_rate in match_rates:
            for payload_cols in payload_cols_list:
                dataset_name = (
                    f"build{build_rows}_probe{probe_rows}_"
                    f"match{str(match_rate).replace('.', 'p')}_payload{payload_cols}"
                )
                data_dir = data_root / dataset_name

                print(f"\n== Dataset {dataset_name} ==")
                info = generate_dataset(
                        out_dir=data_dir,
                        build_rows=build_rows,
                        probe_rows=probe_rows,
                        match_rate=match_rate,
                        payload_cols=payload_cols,
                        fprs=fprs,
                        seed=args.seed,
                        compression=args.compression,
                    )

                build_path = data_dir / "build.parquet"
                baseline_probe = data_dir / "probe.parquet"

                for query_kind in query_kinds:
                        baseline_sql = make_query(
                            build_path,
                            baseline_probe,
                            query_kind=query_kind,
                            payload_sums=args.payload_sums,
                            payload_cols=payload_cols,
                        )

                        for _ in range(args.warmup):
                            timed_query(con, baseline_sql)

                        baseline_times = []
                        for rep in range(args.repetitions):
                            baseline_times.append(timed_query(con, baseline_sql))

                        for fpr in fprs:
                            filtered_probe = data_dir / f"probe_filtered_fpr_{fpr_tag(fpr)}.parquet"
                            filtered_sql = make_query(
                                build_path,
                                filtered_probe,
                                query_kind=query_kind,
                                payload_sums=args.payload_sums,
                                payload_cols=payload_cols,
                            )

                            for _ in range(args.warmup):
                                timed_query(con, filtered_sql)

                            for rep in range(args.repetitions):
                                filtered_ms = timed_query(con, filtered_sql)
                                baseline_ms = baseline_times[rep]
                                speedup = baseline_ms / filtered_ms if filtered_ms > 0 else 0.0

                                row = {
                                    "dataset": dataset_name,
                                    "query_kind": query_kind,
                                    "threads": args.threads,
                                    "rep": rep,
                                    "build_rows": build_rows,
                                    "probe_rows": probe_rows,
                                    "match_rate": match_rate,
                                    "payload_cols": payload_cols,
                                    "payload_sums": min(args.payload_sums, payload_cols),
                                    "simulated_fpr": fpr,
                                    "true_match_rows": info["true_match_rows"],
                                    "nonmatch_rows": info["nonmatch_rows"],
                                    "filtered_probe_rows": info["fpr_rows"][fpr],
                                    "filter_selectivity": info["fpr_rows"][fpr] / probe_rows if probe_rows else 0.0,
                                    "baseline_ms": f"{baseline_ms:.3f}",
                                    "filtered_ms": f"{filtered_ms:.3f}",
                                    "speedup": f"{speedup:.4f}",
                                }
                                all_rows.append(row)

                            print(
                                f"{query_kind:7s} fpr={fpr:<5g} "
                                f"filtered_rows={info['fpr_rows'][fpr]:<8d} "
                                f"baseline_mean={np.mean(baseline_times):.3f}ms"
                            )

    append_rows(out_csv, all_rows)
    write_report(report_path, all_rows)

    print(f"\nWrote CSV:    {out_csv}")
    print(f"Wrote report: {report_path}")


if __name__ == "__main__":
    main()
