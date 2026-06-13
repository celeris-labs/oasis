#!/usr/bin/env python3
import argparse
from pathlib import Path

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq


def parse_match_rate(value: str) -> float:
    if value.endswith("%"):
        return float(value[:-1]) / 100.0
    return float(value)


def write_parquet(path: Path, table: pa.Table, compression: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    pq.write_table(table, path, compression=compression)


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate upper-bound Bloom filter benchmark data.")
    parser.add_argument("--out", required=True, help="Output dataset directory")
    parser.add_argument("--build-rows", type=int, required=True)
    parser.add_argument("--probe-rows", type=int, required=True)
    parser.add_argument("--match-rate", type=parse_match_rate, required=True)
    parser.add_argument("--payload-cols", type=int, default=0)
    parser.add_argument("--payload-sums", type=int, default=0)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--compression", default="snappy")
    args = parser.parse_args()

    if not (0.0 <= args.match_rate <= 1.0):
        raise ValueError("--match-rate must be between 0 and 1")

    if args.payload_sums > args.payload_cols:
        raise ValueError("--payload-sums cannot be larger than --payload-cols")

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    rng = np.random.default_rng(args.seed)

    build_keys = np.arange(args.build_rows, dtype=np.int64)

    build_cols = {"key": pa.array(build_keys, type=pa.int64())}
    for c in range(args.payload_cols):
        payload = ((build_keys * np.int64(1315423911)) + np.int64(c * 2654435761)) & np.int64(0x7FFFFFFFFFFFFFFF)
        build_cols[f"payload_{c}"] = pa.array(payload, type=pa.int64())

    build_table = pa.table(build_cols)

    match_rows = int(round(args.probe_rows * args.match_rate))
    nonmatch_rows = args.probe_rows - match_rows

    if args.build_rows <= 0 and match_rows > 0:
        raise ValueError("cannot create matching probe rows with build_rows=0")

    if match_rows > 0:
        matching_keys = build_keys[np.arange(match_rows, dtype=np.int64) % args.build_rows]
    else:
        matching_keys = np.empty(0, dtype=np.int64)

    nonmatching_keys = np.arange(
        args.build_rows + 1_000_000_000,
        args.build_rows + 1_000_000_000 + nonmatch_rows,
        dtype=np.int64,
    )

    probe_keys = np.concatenate([matching_keys, nonmatching_keys])
    rng.shuffle(probe_keys)

    build_key_set = set(int(x) for x in build_keys)
    mask = np.fromiter((int(k) in build_key_set for k in probe_keys), dtype=np.bool_, count=len(probe_keys))
    filtered_keys = probe_keys[mask]

    probe_table = pa.table({"key": pa.array(probe_keys, type=pa.int64())})
    filtered_table = pa.table({"key": pa.array(filtered_keys, type=pa.int64())})

    write_parquet(out / "build.parquet", build_table, args.compression)
    write_parquet(out / "probe.parquet", probe_table, args.compression)
    write_parquet(out / "probe_filtered_exact.parquet", filtered_table, args.compression)

    meta = {
        "build_rows": args.build_rows,
        "probe_rows": args.probe_rows,
        "match_rate": args.match_rate,
        "payload_cols": args.payload_cols,
        "payload_sums": args.payload_sums,
        "matched_probe_rows": int(len(filtered_keys)),
        "filter_selectivity": float(len(filtered_keys) / args.probe_rows if args.probe_rows else 0.0),
        "compression": args.compression,
        "seed": args.seed,
    }

    with (out / "meta.txt").open("w") as f:
        for key, value in meta.items():
            f.write(f"{key}={value}\n")

    print(f"Wrote dataset: {out}")
    print(f"  build rows          : {args.build_rows}")
    print(f"  probe rows          : {args.probe_rows}")
    print(f"  exact filtered rows : {len(filtered_keys)}")
    print(f"  selectivity         : {meta['filter_selectivity']:.6f}")
    print(f"  payload cols        : {args.payload_cols}")


if __name__ == "__main__":
    main()
