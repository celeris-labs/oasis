#!/usr/bin/env python3
"""Generate TPC-H benchmark data with regex-friendly synthetic columns.

Uses DuckDB's built-in TPC-H generator as a baseline, then fills in the
extension schema fields (emails, SKUs, promotions, and formatted addresses)
while keeping per-regex selectivity constant across scale factors.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import duckdb

from generate_addresses import AddressKind, generate_address

SCRIPT_DIR = Path(__file__).resolve().parent

# Fraction of eligible rows that should match each benchmark regex.
SELECTIVITY = {
    "german_address_8xxx": 0.15,
    "freemail_customer": 0.25,
    "corporate_supplier_email": 0.40,
    "premium_sku": 0.20,
    "promo_part_type": 0.10,
    "seasonal_promotion": 0.02,
}

GERMANY_NATIONKEY = 7
BPS = 10_000
CHUNKED_DBGEN_THRESHOLD = 30
CHUNKED_DBGEN_CHILDREN = 10


def selectivity_bps(fraction: float) -> int:
    return int(fraction * BPS)


def load_schema_extensions(con: duckdb.DuckDBPyConnection) -> None:
    con.execute(
        """
        ALTER TABLE customer ADD COLUMN IF NOT EXISTS c_email VARCHAR(64);
        ALTER TABLE supplier ADD COLUMN IF NOT EXISTS s_email VARCHAR(64);
        ALTER TABLE part ADD COLUMN IF NOT EXISTS p_sku VARCHAR(20);
        """
    )
    con.execute(
        """
        CREATE TABLE IF NOT EXISTS promotion (
            pr_promokey   BIGINT NOT NULL,
            pr_partkey    BIGINT NOT NULL,
            pr_code       VARCHAR(25) NOT NULL,
            pr_channel    CHAR(10) NOT NULL,
            pr_startdate  DATE NOT NULL,
            pr_enddate    DATE NOT NULL,
            pr_comment    VARCHAR(152) NOT NULL
        );
        """
    )


def populate_customer_emails(con: duckdb.DuckDBPyConnection) -> None:
    bps = selectivity_bps(SELECTIVITY["freemail_customer"])
    con.execute(
      f"""
      UPDATE customer
      SET c_email = CASE
          WHEN c_mktsegment IN ('BUILDING', 'AUTOMOBILE')
               AND (hash(c_custkey::BIGINT + 23000) % {BPS}) < {bps} THEN
              'cust' || c_custkey::VARCHAR
              || '@'
              || (ARRAY['gmail.com', 'yahoo.com', 'hotmail.com', 'outlook.com'])[
                  (1 + (hash(c_custkey + 1) % 4))::BIGINT
              ]
          ELSE
              'cust' || c_custkey::VARCHAR
              || '@corp-'
              || (ARRAY['parts', 'supply', 'trade', 'industry'])[(1 + (hash(c_custkey + 2) % 4))::BIGINT]
              || '.'
              || (ARRAY['com', 'de', 'eu', 'fr'])[(1 + (hash(c_custkey + 3) % 4))::BIGINT]
      END;
      """
    )


def populate_supplier_emails(con: duckdb.DuckDBPyConnection) -> None:
    bps = selectivity_bps(SELECTIVITY["corporate_supplier_email"])
    con.execute(
        f"""
        UPDATE supplier
        SET s_email = CASE
            WHEN s_nationkey IN (
                SELECT n.n_nationkey
                FROM nation n
                JOIN region r ON n.n_regionkey = r.r_regionkey
                WHERE r.r_name = 'EUROPE'
            )
            AND (hash(s_suppkey::BIGINT + 26000) % {BPS}) < {bps} THEN
                'sales' || s_suppkey::VARCHAR
                || '@'
                || (ARRAY['acme-parts', 'supply-co', 'industrial', 'metals'])[
                    (1 + (hash(s_suppkey + 1) % 4))::BIGINT
                ]
                || '.'
                || (ARRAY['com', 'eu', 'de', 'fr', 'co.uk'])[(1 + (hash(s_suppkey + 2) % 5))::BIGINT]
            WHEN s_nationkey IN (
                SELECT n.n_nationkey
                FROM nation n
                JOIN region r ON n.n_regionkey = r.r_regionkey
                WHERE r.r_name = 'EUROPE'
            ) THEN
                'sales' || s_suppkey::VARCHAR
                || '@'
                || (ARRAY['gmail', 'yahoo', 'hotmail', 'outlook'])[(1 + (hash(s_suppkey + 3) % 4))::BIGINT]
                || '.com'
            ELSE
                'sales' || s_suppkey::VARCHAR
                || '@supplier-'
                || (ARRAY['local', 'internal', 'ops'])[(1 + (hash(s_suppkey + 4) % 3))::BIGINT]
                || '.net'
        END;
        """
    )


def populate_part_skus_and_types(con: duckdb.DuckDBPyConnection) -> None:
    sku_bps = selectivity_bps(SELECTIVITY["premium_sku"])
    promo_bps = selectivity_bps(SELECTIVITY["promo_part_type"])
    con.execute(
        f"""
        UPDATE part
        SET
            p_sku = CASE
                WHEN (hash(p_partkey::BIGINT + 24000) % {BPS}) < {sku_bps} THEN
                    chr(65 + (p_partkey % 26)::INTEGER)
                    || chr(65 + ((p_partkey / 26) % 26)::INTEGER)
                    || chr(65 + ((p_partkey / 676) % 26)::INTEGER)
                    || '-'
                    || lpad((p_partkey % 100000)::VARCHAR, 5, '0')
                    || '-'
                    || (ARRAY['EU', 'US', 'AS'])[(1 + (hash(p_partkey + 5) % 3))::BIGINT]
                ELSE
                    'cat-'
                    || lpad((p_partkey % 1000000)::VARCHAR, 6, '0')
                    || '-'
                    || (ARRAY['std', 'eco', 'base'])[(1 + (hash(p_partkey + 6) % 3))::BIGINT]
            END,
            p_type = CASE
                WHEN (hash(p_partkey::BIGINT + 14000) % {BPS}) < {promo_bps} THEN
                    'PROMO '
                    || (ARRAY['BRUSHED', 'BURNISHED', 'PLATED', 'POLISHED', 'ANODIZED'])[
                        (1 + (hash(p_partkey + 11) % 5))::BIGINT
                    ]
                    || ' '
                    || (ARRAY['BRASS', 'STEEL', 'TIN', 'NICKEL', 'COPPER'])[
                        (1 + (hash(p_partkey + 12) % 5))::BIGINT
                    ]
                ELSE
                    (ARRAY['SMALL', 'MEDIUM', 'LARGE', 'STANDARD', 'ECONOMY'])[
                        (1 + (hash(p_partkey + 13) % 5))::BIGINT
                    ]
                    || ' '
                    || (ARRAY['BRUSHED', 'BURNISHED', 'PLATED', 'POLISHED', 'ANODIZED'])[
                        (1 + (hash(p_partkey + 14) % 5))::BIGINT
                    ]
                    || ' '
                    || (ARRAY['BRASS', 'STEEL', 'TIN', 'NICKEL', 'COPPER'])[
                        (1 + (hash(p_partkey + 15) % 5))::BIGINT
                    ]
            END;
        """
    )


def _address_kind_sql(key_col: str, nation_col: str, seed: int, bps: int) -> str:
    return f"""
        CASE
            WHEN {nation_col} = {GERMANY_NATIONKEY}
                 AND (hash({key_col}::BIGINT + {seed}) % {BPS}) < {bps} THEN '{AddressKind.MATCH.value}'
            WHEN {nation_col} = {GERMANY_NATIONKEY}
                 AND (hash({key_col}::BIGINT + {seed + 1}) % 3) = 0 THEN '{AddressKind.DE_STREET_FIRST.value}'
            WHEN {nation_col} = {GERMANY_NATIONKEY}
                 AND (hash({key_col}::BIGINT + {seed + 1}) % 3) = 1 THEN '{AddressKind.DE_WRONG_POSTCODE.value}'
            WHEN {nation_col} = {GERMANY_NATIONKEY} THEN '{AddressKind.DE_MULTIWORD.value}'
            ELSE '{AddressKind.FOREIGN.value}'
        END
    """


def populate_addresses(con: duckdb.DuckDBPyConnection) -> None:
    bps = selectivity_bps(SELECTIVITY["german_address_8xxx"])

    def gen_addr(kind: str, key: int, seed: int) -> str:
        return generate_address(AddressKind(kind), key, seed)

    con.create_function("gen_addr", gen_addr)

    for table, key_col, nation_col in (
        ("customer", "c_custkey", "c_nationkey"),
        ("supplier", "s_suppkey", "s_nationkey"),
    ):
        address_col = "c_address" if table == "customer" else "s_address"
        seed = 27000 if table == "customer" else 28000
        con.execute(
            f"""
            UPDATE {table}
            SET {address_col} = gen_addr(
                {_address_kind_sql(key_col, nation_col, seed, bps)},
                {key_col},
                {seed}
            )
            """
        )


def populate_customer_de(con: duckdb.DuckDBPyConnection) -> None:
    con.execute(
        """
        CREATE OR REPLACE TABLE customer_de AS
        SELECT c.*
        FROM customer c
        JOIN nation n ON c.c_nationkey = n.n_nationkey
        WHERE n.n_name = 'GERMANY';
        """
    )


def populate_promotions(con: duckdb.DuckDBPyConnection) -> None:
    promo_bps = selectivity_bps(SELECTIVITY["seasonal_promotion"])
    con.execute("DELETE FROM promotion")
    con.execute(
        f"""
        INSERT INTO promotion
        SELECT
            row_number() OVER () AS pr_promokey,
            p_partkey AS pr_partkey,
            (ARRAY['SUMMER', 'WINTER', 'SPRING', 'FALL'])[(1 + (hash(p_partkey + 7) % 4))::BIGINT]
                || '-2026-'
                || (ARRAY['WEB', 'EMAIL', 'PRINT', 'SOCIAL'])[(1 + (hash(p_partkey + 8) % 4))::BIGINT]
                || '-'
                || upper(lpad((p_partkey % 10000)::VARCHAR, 4, '0')) AS pr_code,
            (ARRAY['WEB', 'EMAIL', 'PRINT', 'SOCIAL'])[(1 + (hash(p_partkey + 9) % 4))::BIGINT] AS pr_channel,
            DATE '1995-01-01' + (hash(p_partkey + 10) % 300)::INTEGER AS pr_startdate,
            DATE '1995-01-01' + ((hash(p_partkey + 10) % 300) + 60)::INTEGER AS pr_enddate,
            'Seasonal promotion campaign for part ' || p_partkey::VARCHAR AS pr_comment
        FROM part
        WHERE (hash(p_partkey::BIGINT + 25000) % {BPS}) < {promo_bps};
        """
    )


def generate_baseline_tpch(con: duckdb.DuckDBPyConnection, sf: float) -> None:
    if sf > CHUNKED_DBGEN_THRESHOLD:
        for step in range(CHUNKED_DBGEN_CHILDREN):
            print(
                f"  dbgen step {step + 1}/{CHUNKED_DBGEN_CHILDREN} "
                f"(sf={sf}, children={CHUNKED_DBGEN_CHILDREN}, step={step})..."
            )
            con.execute(
                "CALL dbgen(sf = ?, children = ?, step = ?)",
                [sf, CHUNKED_DBGEN_CHILDREN, step],
            )
    else:
        con.execute("CALL dbgen(sf = ?)", [sf])


def report_selectivity(con: duckdb.DuckDBPyConnection, sf: float) -> None:
    print(f"\nSelectivity report (sf={sf}):")
    queries = {
        "q27 german 8xxx addresses": f"""
            SELECT round(100.0 * avg((c_address SIMILAR TO '\\d+ \\w+.? 8\\d\\d\\d \\w+')::INT), 2)
            FROM customer_de
        """,
        "q23 freemail customers": """
            SELECT round(100.0 * avg((
                c_mktsegment IN ('BUILDING', 'AUTOMOBILE')
                AND c_email SIMILAR TO '.*@(gmail|yahoo|hotmail|outlook)\\.com'
            )::INT) / nullif(avg((c_mktsegment IN ('BUILDING', 'AUTOMOBILE'))::INT), 0), 2)
            FROM customer
        """,
        "q24 premium SKU parts": """
            SELECT round(100.0 * avg((p_sku SIMILAR TO '[A-Z][A-Z][A-Z]-[0-9]+-(EU|US|AS)')::INT), 2)
            FROM part
        """,
        "q14 PROMO part types": """
            SELECT round(100.0 * avg((p_type SIMILAR TO 'PROMO.*')::INT), 2)
            FROM part
        """,
        "q26 corporate supplier emails": f"""
            SELECT round(100.0 * avg((
                s_nationkey IN (
                    SELECT n.n_nationkey
                    FROM nation n
                    JOIN region r ON n.n_regionkey = r.r_regionkey
                    WHERE r.r_name = 'EUROPE'
                )
                AND s_email SIMILAR TO '.*@.*\\.(com|eu|de|fr|co\\.uk)'
                AND NOT s_email SIMILAR TO '.*@(gmail|yahoo|hotmail|outlook)\\..*'
            )::INT) / nullif(avg((
                s_nationkey IN (
                    SELECT n.n_nationkey
                    FROM nation n
                    JOIN region r ON n.n_regionkey = r.r_regionkey
                    WHERE r.r_name = 'EUROPE'
                )
            )::INT), 0), 2)
            FROM supplier
        """,
        "q25 seasonal promotions": """
            SELECT round(100.0 * avg((pr_code SIMILAR TO '(SUMMER|WINTER|SPRING|FALL)-2026-.*')::INT), 2)
            FROM promotion
        """,
    }
    for label, sql in queries.items():
        value = con.execute(sql).fetchone()[0]
        print(f"  {label}: {value}%")


def generate_data(sf: float, output: Path, report: bool) -> None:
    if output.exists():
        output.unlink()

    con = duckdb.connect(str(output))
    try:
        print(f"Generating baseline TPC-H data (sf={sf})...")
        con.execute("INSTALL tpch; LOAD tpch;")
        generate_baseline_tpch(con, sf)

        print("Adding extension schema columns...")
        load_schema_extensions(con)

        print("Populating regex benchmark fields...")
        populate_customer_emails(con)
        populate_supplier_emails(con)
        populate_part_skus_and_types(con)
        populate_addresses(con)
        populate_customer_de(con)
        populate_promotions(con)

        if report:
            report_selectivity(con, sf)
    finally:
        con.close()

    print(f"Wrote {output}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--sf",
        type=float,
        default=1.0,
        help="TPC-H scale factor passed to dbgen (default: 1.0)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=SCRIPT_DIR / "tpch_regex.duckdb",
        help="Output DuckDB database path",
    )
    parser.add_argument(
        "--report",
        action="store_true",
        help="Print achieved regex selectivity after generation",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    if args.sf <= 0:
        print("Scale factor must be positive.", file=sys.stderr)
        return 1

    generate_data(args.sf, args.output.resolve(), args.report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
