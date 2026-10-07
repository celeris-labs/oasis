#!/usr/bin/env python3
"""Generate a tiny TPC-H data set as Parquet files the ParCore decoder can read.

The decoder strips exactly one definition-level section from every data page (and no repetition
levels), so every column must be OPTIONAL (max_definition_level 1, max_repetition_level 0). The
generated data has no NULLs. DuckDB's dbgen declares its columns NOT NULL, which the Parquet writer
would turn into REQUIRED columns with no level section; the tables are therefore copied into
constraint-free tables first.

dbgen cannot go below SF 0.001 (every table collapses to a single row), so smaller data sets are
cut from SF 0.001 with --shrink N: it keeps 1/N of the customers, only their orders and only those
orders' lineitems. All foreign keys stay valid; region, nation, supplier, part and partsupp are kept
whole (they are small, and lineitem references nearly all of them).

Usage: generate_tpch_parquet.py [--sf 0.001] [--shrink 1] [--out tpch_parquet]
Needs the `duckdb` Python package (not pyarrow: its page-header statistics break the decoder).
"""
import argparse
import pathlib

import duckdb

TABLES = ["region", "nation", "supplier", "customer", "part", "partsupp", "orders", "lineitem"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sf", type=float, default=0.001)
    ap.add_argument("--shrink", type=int, default=1, help="keep 1/N of customers, orders and lineitems")
    ap.add_argument("--out", type=pathlib.Path, default=pathlib.Path(__file__).parent.parent / "tpch_parquet")
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    con = duckdb.connect()
    con.execute("INSTALL tpch; LOAD tpch")
    con.execute(f"CALL dbgen(sf={args.sf})")

    # Source of each output table; row order is preserved.
    source = {t: f"SELECT * FROM {t}" for t in TABLES}
    if args.shrink > 1:
        n_cust = con.execute("SELECT count(*) FROM customer").fetchone()[0]
        max_cust = max(1, n_cust // args.shrink)
        source["customer"] = f"SELECT * FROM customer WHERE c_custkey <= {max_cust}"
        source["orders"] = f"SELECT * FROM orders WHERE o_custkey <= {max_cust}"
        source["lineitem"] = f"SELECT * FROM lineitem WHERE l_orderkey IN (SELECT o_orderkey FROM orders WHERE o_custkey <= {max_cust})"

    for t in TABLES:
        con.execute(f"CREATE TABLE {t}_nullable AS {source[t]}")
        path = args.out / f"{t}.parquet"
        con.execute(f"COPY {t}_nullable TO '{path}' (FORMAT parquet)")

        rows = con.execute(f"SELECT count(*) FROM '{path}'").fetchone()[0]
        # A flat schema of OPTIONAL leaves means max_definition_level 1, max_repetition_level 0.
        bad = con.execute(
            f"""SELECT name, repetition_type FROM parquet_schema('{path}')
                WHERE num_children IS NULL AND repetition_type != 'OPTIONAL'"""
        ).fetchall()
        nulls = sum(
            con.execute(f"SELECT count(*) FILTER (WHERE {c} IS NULL) FROM '{path}'").fetchone()[0]
            for (c,) in con.execute(f"SELECT name FROM parquet_schema('{path}') WHERE num_children IS NULL").fetchall()
        )
        assert not bad, f"{t}: columns not OPTIONAL: {bad}"
        assert nulls == 0, f"{t}: {nulls} NULL values"
        print(f"{t:10s} {rows:6d} rows  {path}")


if __name__ == "__main__":
    main()
