#!/usr/bin/env python3
"""Generate TPC-H Parquet files at one or more scale factors; all columns OPTIONAL, no NULLs.

dbgen declares every column NOT NULL, and depending on the DuckDB version the Parquet writer turns
that into REQUIRED columns (no definition-level section). Each table is therefore copied into a
constraint-free table (CREATE TABLE ... AS drops NOT NULL) and that copy is what gets written. The
written files are read back and the script exits non-zero if any leaf column is not OPTIONAL or any
null_count is non-zero.

Output layout: <out>/<scale>/<table>.parquet, with <out> defaulting to ./tpch_parquet, e.g.
tpch_parquet/10/lineitem.parquet for scale factor 10. In a fractional scale the '.' becomes '_'
(scale 0.01 -> tpch_parquet/0_01/).

Usage:
  tpch_optional.py 1 10 100
  tpch_optional.py 100 --memory-limit 64GB --temp-dir /scratch/duckdb_tmp
  tpch_optional.py 0.01 --out /data/tpch

Needs the `duckdb` Python package (pip install duckdb); it fetches the tpch extension on first use.
Use DuckDB, not pyarrow, to write: pyarrow's page-header statistics break the ParCore decoder.
sf below 0.001 is rejected: dbgen collapses every table to a single row there.
"""
import argparse
import pathlib
import sys

import duckdb

# Smallest tables first; each is copied, written and released before the next, so peak memory is the
# generated data set plus one copy of the largest table.
TABLES = ["region", "nation", "supplier", "customer", "part", "partsupp", "orders", "lineitem"]


def generate(sf: float, out_dir: pathlib.Path, memory_limit: str | None, temp_dir: str | None) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)

    con = duckdb.connect()
    if memory_limit:
        con.execute(f"SET memory_limit = '{memory_limit}'")
    if temp_dir:
        con.execute(f"SET temp_directory = '{temp_dir}'")  # where an over-limit data set spills to
    con.execute("INSTALL tpch; LOAD tpch")
    con.execute(f"CALL dbgen(sf = {sf!r})")

    for t in TABLES:
        path = out_dir / f"{t}.parquet"
        con.execute(f"CREATE TABLE {t}_opt AS SELECT * FROM {t}")  # row order preserved, NOT NULL dropped
        con.execute(f"DROP TABLE {t}")
        con.execute(f"COPY {t}_opt TO '{path}' (FORMAT parquet)")
        con.execute(f"DROP TABLE {t}_opt")

        # Read the file back. A flat schema of OPTIONAL leaves means max_definition_level 1 and
        # max_repetition_level 0.
        not_optional = con.execute(
            """SELECT name, repetition_type FROM parquet_schema(?)
               WHERE num_children IS NULL AND repetition_type != 'OPTIONAL'""",
            [str(path)],
        ).fetchall()
        n_cols = con.execute(
            "SELECT count(*) FROM parquet_schema(?) WHERE num_children IS NULL", [str(path)]
        ).fetchone()[0]
        nulls, missing = con.execute(
            """SELECT coalesce(sum(stats_null_count), 0), count(*) FILTER (WHERE stats_null_count IS NULL)
               FROM parquet_metadata(?)""",
            [str(path)],
        ).fetchone()
        rows = con.execute("SELECT num_rows FROM parquet_file_metadata(?)", [str(path)]).fetchone()[0]

        if not_optional:
            sys.exit(f"{path}: columns not OPTIONAL: {not_optional}")
        if nulls or missing:
            sys.exit(f"{path}: {nulls} NULLs, {missing} column chunks without null_count statistics")
        print(f"{sf:g}  {t:9s} {rows:>12,d} rows  {n_cols:2d} OPTIONAL cols  0 NULLs  {path}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("scale", type=float, nargs="+", help="TPC-H scale factor(s), e.g. 1 10 100")
    ap.add_argument("--out", type=pathlib.Path, default=pathlib.Path("tpch_parquet"),
                    help="base directory; files go to <out>/<scale>/, '.' in the scale written as '_' "
                         "(default: ./tpch_parquet)")
    ap.add_argument("--memory-limit", help="DuckDB memory_limit, e.g. 64GB (default: 80%% of RAM)")
    ap.add_argument("--temp-dir", help="DuckDB spill directory for data sets larger than the memory limit")
    args = ap.parse_args()

    for sf in args.scale:
        if sf < 0.001:
            ap.error(f"sf {sf:g} is below 0.001, where dbgen collapses every table to one row")
    for sf in args.scale:
        generate(sf, args.out / f"{sf:g}".replace(".", "_"), args.memory_limit, args.temp_dir)


if __name__ == "__main__":
    main()
