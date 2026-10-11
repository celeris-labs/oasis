-- Generate TPC-H at an arbitrary scale factor as Parquet files whose columns are all OPTIONAL
-- (max_definition_level 1) but contain no NULLs.
--
-- dbgen declares every column NOT NULL. Depending on the DuckDB version the Parquet writer may turn
-- that into REQUIRED columns (no definition-level section), so each table is first copied into a
-- constraint-free table (CTAS drops NOT NULL) and that copy is what gets written out.
--
-- Parameters, set before running (both optional):
--   sf       TPC-H scale factor, any positive number          (default 1)
--   out_dir  existing directory that receives <table>.parquet (default '.')
--
-- Usage (needs the DuckDB CLI; the `duckdb` Python package works too, see generate_tpch_parquet.py):
--   mkdir -p data/sf10
--   { echo "SET VARIABLE sf = 10; SET VARIABLE out_dir = 'data/sf10';"; cat tpch_optional.sql; } | duckdb
--
--   for sf in 1 10 100; do
--     mkdir -p data/sf$sf
--     { echo "SET VARIABLE sf = $sf; SET VARIABLE out_dir = 'data/sf$sf';"; cat tpch_optional.sql; } | duckdb
--   done
--
-- Note: at sf < 0.001 dbgen collapses every table to one row; use sf >= 0.001.
-- Write the data with DuckDB, not pyarrow: pyarrow's page-header statistics break the ParCore decoder.

INSTALL tpch;
LOAD tpch;

SET VARIABLE sf      = COALESCE(getvariable('sf'), 1);
SET VARIABLE out_dir = COALESCE(getvariable('out_dir'), '.');

CALL dbgen(sf = getvariable('sf'));

-- One table at a time so peak memory is the original plus one copy of the largest table, not two
-- copies of everything. The constraint-free copy keeps the original row order.
CREATE TABLE region_opt AS SELECT * FROM region;
DROP TABLE region;
COPY region_opt TO (getvariable('out_dir') || '/region.parquet') (FORMAT parquet);
DROP TABLE region_opt;

CREATE TABLE nation_opt AS SELECT * FROM nation;
DROP TABLE nation;
COPY nation_opt TO (getvariable('out_dir') || '/nation.parquet') (FORMAT parquet);
DROP TABLE nation_opt;

CREATE TABLE supplier_opt AS SELECT * FROM supplier;
DROP TABLE supplier;
COPY supplier_opt TO (getvariable('out_dir') || '/supplier.parquet') (FORMAT parquet);
DROP TABLE supplier_opt;

CREATE TABLE customer_opt AS SELECT * FROM customer;
DROP TABLE customer;
COPY customer_opt TO (getvariable('out_dir') || '/customer.parquet') (FORMAT parquet);
DROP TABLE customer_opt;

CREATE TABLE part_opt AS SELECT * FROM part;
DROP TABLE part;
COPY part_opt TO (getvariable('out_dir') || '/part.parquet') (FORMAT parquet);
DROP TABLE part_opt;

CREATE TABLE partsupp_opt AS SELECT * FROM partsupp;
DROP TABLE partsupp;
COPY partsupp_opt TO (getvariable('out_dir') || '/partsupp.parquet') (FORMAT parquet);
DROP TABLE partsupp_opt;

CREATE TABLE orders_opt AS SELECT * FROM orders;
DROP TABLE orders;
COPY orders_opt TO (getvariable('out_dir') || '/orders.parquet') (FORMAT parquet);
DROP TABLE orders_opt;

CREATE TABLE lineitem_opt AS SELECT * FROM lineitem;
DROP TABLE lineitem;
COPY lineitem_opt TO (getvariable('out_dir') || '/lineitem.parquet') (FORMAT parquet);
DROP TABLE lineitem_opt;

-- Verify what was written: every leaf column OPTIONAL, zero NULLs. error() aborts the script (non-zero
-- exit status) if either fails; otherwise this prints one summary row per file.
WITH files AS (
    SELECT file AS file_name FROM glob(getvariable('out_dir') || '/*.parquet')
),
schema AS (
    SELECT file_name,
           count(*) FILTER (WHERE repetition_type = 'OPTIONAL') AS optional_cols,
           count(*) FILTER (WHERE repetition_type != 'OPTIONAL') AS other_cols
    FROM parquet_schema(getvariable('out_dir') || '/*.parquet')
    WHERE num_children IS NULL
    GROUP BY file_name
),
stats AS (
    SELECT file_name,
           sum(stats_null_count) AS nulls,
           count(*) FILTER (WHERE stats_null_count IS NULL) AS missing_stats
    FROM parquet_metadata(getvariable('out_dir') || '/*.parquet')
    GROUP BY file_name
),
rows AS (
    SELECT file_name, sum(num_rows) AS num_rows
    FROM (SELECT DISTINCT file_name, row_group_id, row_group_num_rows AS num_rows
          FROM parquet_metadata(getvariable('out_dir') || '/*.parquet'))
    GROUP BY file_name
)
SELECT regexp_extract(f.file_name, '[^/]+$') AS file,
       r.num_rows,
       s.optional_cols,
       CASE WHEN s.other_cols > 0 THEN error('not all columns OPTIONAL in ' || f.file_name) END AS _chk_optional,
       t.nulls,
       CASE WHEN t.nulls > 0 OR t.missing_stats > 0
            THEN error('NULLs (or missing null_count stats) in ' || f.file_name) END AS _chk_nulls
FROM files f
JOIN schema s USING (file_name)
JOIN stats  t USING (file_name)
JOIN rows   r USING (file_name)
ORDER BY file;
