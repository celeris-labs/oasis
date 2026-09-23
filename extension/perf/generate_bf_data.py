#!/usr/bin/env python3
"""Generate build/probe Parquet files for OASIS Bloom filter testing.

Parameterized version of the snippet in extension/SIMULATION_GUIDE.md
(Step 4.1). Produces a fixed-width `build.parquet` and a `probe.parquet`
whose rows match the build table's keys at the requested rate.
"""
import argparse
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as parquet


def parse_match_rate(value: str) -> float:
    if value.endswith("%"):
        return float(value[:-1]) / 100.0
    return float(value)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="/tmp/oasis_bf_test", help="Output directory (default: %(default)s)")
    parser.add_argument("--build-rows", type=int, default=1_000, help="Number of build table rows (default: %(default)s)")
    parser.add_argument("--probe-rows", type=int, default=10_000, help="Number of probe table rows (default: %(default)s)")
    parser.add_argument(
        "--match-rate",
        type=parse_match_rate,
        default=0.1,
        help="Fraction of probe rows that match a build key, e.g. 0.1 or 10%% (default: %(default)s)",
    )
    args = parser.parse_args()

    if args.build_rows <= 0:
        raise ValueError("--build-rows must be positive")
    if args.probe_rows <= 0:
        raise ValueError("--probe-rows must be positive")
    if not (0.0 <= args.match_rate <= 1.0):
        raise ValueError("--match-rate must be between 0 and 1")

    output = Path(args.out)
    output.mkdir(parents=True, exist_ok=True)

    build_keys = list(range(args.build_rows))

    match_rows = round(args.probe_rows * args.match_rate)
    nonmatch_rows = args.probe_rows - match_rows

    # Cycle through build keys if we need more matches than there are build rows.
    matching_keys = [build_keys[i % args.build_rows] for i in range(match_rows)]
    # Non-matching keys start right after the build key range, so they can never collide with it.
    nonmatching_keys = list(range(args.build_rows, args.build_rows + nonmatch_rows))

    probe_keys = matching_keys + nonmatching_keys

    parquet.write_table(
        pa.table({"key": build_keys}),
        output / "build.parquet",
        compression="SNAPPY",
        use_dictionary=False,
    )
    parquet.write_table(
        pa.table({"key": probe_keys}),
        output / "probe.parquet",
        compression="SNAPPY",
        use_dictionary=False,
    )

    print(f"Wrote dataset: {output}")
    print(f"  build.parquet : {args.build_rows} rows")
    print(f"  probe.parquet : {args.probe_rows} rows ({match_rows} matching, {args.match_rate:.2%} match rate)")


if __name__ == "__main__":
    main()
