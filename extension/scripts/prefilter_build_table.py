#!/usr/bin/env python3
"""Write a pre-filtered copy of a build-side table, to measure what the runtime Bloom filter could gain.

The hardware Bloom filter is built from the build file's whole key column, so a build-side predicate
(e.g. Q17's p_brand / p_container on part) never narrows it. Running the same join against a file that
already holds only the qualifying rows, with no predicate left, makes the current code build the filter
from exactly the filtered keys. That is the best case any scheme that sends filtered keys to the
hardware can reach.

The copy is written with DuckDB and checked like the files of tpch_optional.py: every leaf column
OPTIONAL, no NULLs, null_count statistics present, the same physical/logical types as the input, and
exactly the rows the predicate selects. (The pinned ParCore strips a definition-level section from every
page, and pyarrow's page-header statistics break its parser, so do not write these files any other way.)

Usage:
  prefilter_build_table.py tpch_parquet/1/part.parquet --preset q17
  prefilter_build_table.py tpch_parquet/10/part.parquet --preset q17 --verify
  prefilter_build_table.py tpch_parquet/1/orders.parquet --where "o_orderdate < DATE '1995-03-15'" \\
      --out /data/orders_pre.parquet

With --preset q17 it also prints the two Q17 variants to run on read_oasis: the baseline (full part,
predicates in the WHERE clause) and the pre-filtered one (filtered part, no predicate). --verify runs
both on plain read_parquet (CPU only, no hardware) and checks that the answers are identical; it scans
lineitem twice, so it is slow at large scale factors.

Needs the `duckdb` Python package.
"""
import argparse
import math
import pathlib
import sys

import duckdb

PRESETS = {
    # TPC-H Q17, the build side (part) predicate.
    "q17": "p_brand = 'Brand#23' AND p_container = 'MED BOX'",
}

# One filter array holds 16 banks * 2^18 bits (HASH_WIDTH = 18 as synthesized, see
# celeris/hardware/src/hdl/bloomfilter/bloomfilter_operator.sv); a key sets one bit in each of two
# arrays, and a probe key is kept only if both bits are set.
FILTER_BITS_PER_ARRAY = 16 * (1 << 18)


def q(s) -> str:
    """A SQL string literal."""
    return "'" + str(s).replace("'", "''") + "'"


def fp_estimate(n_keys: int) -> float:
    """Expected false-positive rate of the hardware filter holding n_keys distinct keys."""
    return (1.0 - math.exp(-n_keys / FILTER_BITS_PER_ARRAY)) ** 2


def leaf_schema(con, path):
    return con.execute(
        """SELECT name, type, converted_type, logical_type FROM parquet_schema(?)
           WHERE num_children IS NULL""",
        [str(path)],
    ).fetchall()


def check_output(con, src, dst, where, expected_rows):
    """Exit non-zero unless dst is a ParCore-readable copy of the rows of src that match `where`."""
    not_optional = con.execute(
        """SELECT name, repetition_type FROM parquet_schema(?)
           WHERE num_children IS NULL AND repetition_type != 'OPTIONAL'""",
        [str(dst)],
    ).fetchall()
    nulls, missing = con.execute(
        """SELECT coalesce(sum(stats_null_count), 0), count(*) FILTER (WHERE stats_null_count IS NULL)
           FROM parquet_metadata(?)""",
        [str(dst)],
    ).fetchone()
    rows = con.execute("SELECT num_rows FROM parquet_file_metadata(?)", [str(dst)]).fetchone()[0]
    row_groups = con.execute(
        "SELECT count(DISTINCT row_group_id) FROM parquet_metadata(?)", [str(dst)]
    ).fetchone()[0]

    if not_optional:
        sys.exit(f"{dst}: columns not OPTIONAL: {not_optional}")
    if nulls or missing:
        sys.exit(f"{dst}: {nulls} NULLs, {missing} column chunks without null_count statistics")
    if leaf_schema(con, src) != leaf_schema(con, dst):
        sys.exit(f"{dst}: schema differs from {src}:\n  {leaf_schema(con, src)}\n  {leaf_schema(con, dst)}")
    if rows != expected_rows:
        sys.exit(f"{dst}: {rows} rows, the predicate selects {expected_rows}")

    # Both directions: the copy holds exactly the selected rows, as a multiset.
    diff = con.execute(
        f"""SELECT
              (SELECT count(*) FROM (SELECT * FROM read_parquet({q(src)}) WHERE ({where})
                                     EXCEPT ALL SELECT * FROM read_parquet({q(dst)}))) +
              (SELECT count(*) FROM (SELECT * FROM read_parquet({q(dst)})
                                     EXCEPT ALL SELECT * FROM read_parquet({q(src)}) WHERE ({where})))"""
    ).fetchone()[0]
    if diff:
        sys.exit(f"{dst}: {diff} rows differ from the selected rows of {src}")
    return rows, row_groups


def q17_sql(lineitem, part, predicate, reader):
    """TPC-H Q17 over `reader`(lineitem) and `reader`(part). `predicate` is None for the pre-filtered part.

    The tables are inlined (no CTE) so that DuckDB does not materialize the lineitem scan shared by the
    query and its subquery, which would hide it from the join rewrite.
    """
    pred = f"\n  AND {predicate}" if predicate else ""
    return f"""SELECT sum(l_extendedprice) / 7.0 AS avg_yearly
FROM {reader}({q(lineitem)}) AS lineitem, {reader}({q(part)}) AS part
WHERE p_partkey = l_partkey{pred}
  AND l_quantity < (
    SELECT 0.2 * avg(l_quantity)
    FROM {reader}({q(lineitem)}) AS l2
    WHERE l2.l_partkey = p_partkey
  );"""


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("input", type=pathlib.Path, help="the build-side table, e.g. tpch_parquet/1/part.parquet")
    which = ap.add_mutually_exclusive_group(required=True)
    which.add_argument("--where", help="SQL predicate over the table's columns")
    which.add_argument("--preset", choices=sorted(PRESETS), help="a TPC-H query's build-side predicate")
    ap.add_argument("--out", type=pathlib.Path,
                    help="output file (default: <input stem>_<preset|filtered>.parquet next to the input)")
    ap.add_argument("--lineitem", type=pathlib.Path,
                    help="probe table, for the printed queries and --verify (default: lineitem.parquet "
                         "next to the input)")
    ap.add_argument("--verify", action="store_true",
                    help="--preset q17 only: run both Q17 variants on read_parquet and compare the answers")
    args = ap.parse_args()

    src = args.input.resolve()
    if not src.is_file():
        ap.error(f"{src}: no such file")
    where = PRESETS[args.preset] if args.preset else args.where
    dst = (args.out or src.with_name(f"{src.stem}_{args.preset or 'filtered'}.parquet")).resolve()
    if dst == src:
        ap.error("--out must not be the input file")
    if args.verify and args.preset != "q17":
        ap.error("--verify is only defined for --preset q17")
    lineitem = (args.lineitem or src.with_name("lineitem.parquet")).resolve()

    con = duckdb.connect()
    total, selected = con.execute(
        f"SELECT count(*), count(*) FILTER (WHERE ({where})) FROM read_parquet({q(src)})"
    ).fetchone()
    if selected == 0:
        sys.exit(f"the predicate selects none of the {total:,d} rows of {src.name}; "
                 "ParCore cannot read an empty Parquet file")

    dst.parent.mkdir(parents=True, exist_ok=True)
    con.execute(
        f"COPY (SELECT * FROM read_parquet({q(src)}) WHERE ({where})) TO {q(dst)} (FORMAT parquet)"
    )
    rows, row_groups = check_output(con, src, dst, where, selected)

    print(f"{src.name}: {total:,d} rows -> {rows:,d} rows ({100.0 * rows / total:.4f} %), "
          f"{row_groups} row group(s)")
    print(f"written and checked: {dst}")
    print(f"hardware filter, estimated false-positive rate if keys are unique (HASH_WIDTH=18): "
          f"whole table {100 * fp_estimate(total):.3g} %, filtered {100 * fp_estimate(rows):.3g} %")

    if args.preset != "q17":
        return

    print("\n-- baseline: full part, the predicate in the WHERE clause")
    print(q17_sql(lineitem, src, where, "read_oasis"))
    print("\n-- pre-filtered: the filtered part, no predicate")
    print(q17_sql(lineitem, dst, None, "read_oasis"))

    if args.verify:
        if not lineitem.is_file():
            sys.exit(f"{lineitem}: no such file, pass --lineitem")
        base = con.execute(q17_sql(lineitem, src, where, "read_parquet")).fetchall()
        pre = con.execute(q17_sql(lineitem, dst, None, "read_parquet")).fetchall()
        print(f"\nverify (read_parquet): baseline {base}, pre-filtered {pre}")
        if base != pre:
            sys.exit("the two variants disagree")
        print("identical")


if __name__ == "__main__":
    main()
