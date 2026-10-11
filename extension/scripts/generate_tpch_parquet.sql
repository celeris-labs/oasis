-- Generate TPC-H as Parquet files for any scale factor, ready for read_oasis(...).
--
-- One file per table, <out_dir>/<table>.parquet. Every leaf column is OPTIONAL
-- (max_definition_level 1, max_repetition_level 0) but no value is NULL. DuckDB's dbgen declares its
-- columns NOT NULL, which some DuckDB versions turn into REQUIRED Parquet columns without a
-- definition-level section; each table is therefore copied into a constraint-free table before it
-- is written.
--
-- The files stay within what read_oasis accepts: SNAPPY-compressed (pinned explicitly below, since
-- the extension rejects every codec but UNCOMPRESSED and SNAPPY), and only BOOLEAN/INT32/INT64/
-- FLOAT/DOUBLE/BYTE_ARRAY physical types. TPC-H's DECIMAL(15,2) is stored as INT64 and DATE as INT32.
-- The script ends with a check of all of this that fails loudly on a violation.
--
-- Parameters (DuckDB session variables, both optional):
--   sf        TPC-H scale factor                          default 0.01
--   out_dir   existing output directory                   default tpch_sf<sf>
--
-- Usage:
--   mkdir -p tpch_sf1
--   duckdb -cmd "SET VARIABLE sf = 1;" < generate_tpch_parquet.sql
--
--   # several scale factors
--   for sf in 0.01 0.1 1 10; do
--       mkdir -p tpch_sf$sf
--       duckdb -cmd "SET VARIABLE sf = $sf;" < generate_tpch_parquet.sql
--   done
--
-- Then, from the DuckDB with the oasis extension loaded:
--   SELECT count(*) FROM read_oasis('tpch_sf1/lineitem.parquet');
--   SELECT ... FROM read_oasis('tpch_sf1/lineitem.parquet') l
--                JOIN read_oasis('tpch_sf1/orders.parquet') o ON l.l_orderkey = o.o_orderkey;
-- The last query of this script prints the read_oasis(...) expression of every table.
--
-- Needs the DuckDB `tpch` extension (INSTALL needs network access once). dbgen holds the whole
-- data set in memory: roughly 1 GiB per scale factor, plus one table's worth for the copy.
-- Use the DuckDB writer, not pyarrow: pyarrow's page-header statistics break the ParCore decoder.

INSTALL tpch;
LOAD tpch;

SET VARIABLE sf = coalesce(getvariable('sf'), 0.01);
SET VARIABLE out_dir = coalesce(getvariable('out_dir'), 'tpch_sf' || getvariable('sf'));

CALL dbgen(sf = getvariable('sf'));

-- region
CREATE TABLE region_nullable AS SELECT * FROM region;
COPY region_nullable TO (getvariable('out_dir') || '/region.parquet') (FORMAT parquet, COMPRESSION snappy);
DROP TABLE region_nullable;

-- nation
CREATE TABLE nation_nullable AS SELECT * FROM nation;
COPY nation_nullable TO (getvariable('out_dir') || '/nation.parquet') (FORMAT parquet, COMPRESSION snappy);
DROP TABLE nation_nullable;

-- supplier
CREATE TABLE supplier_nullable AS SELECT * FROM supplier;
COPY supplier_nullable TO (getvariable('out_dir') || '/supplier.parquet') (FORMAT parquet, COMPRESSION snappy);
DROP TABLE supplier_nullable;

-- customer
CREATE TABLE customer_nullable AS SELECT * FROM customer;
COPY customer_nullable TO (getvariable('out_dir') || '/customer.parquet') (FORMAT parquet, COMPRESSION snappy);
DROP TABLE customer_nullable;

-- part
CREATE TABLE part_nullable AS SELECT * FROM part;
COPY part_nullable TO (getvariable('out_dir') || '/part.parquet') (FORMAT parquet, COMPRESSION snappy);
DROP TABLE part_nullable;

-- partsupp
CREATE TABLE partsupp_nullable AS SELECT * FROM partsupp;
COPY partsupp_nullable TO (getvariable('out_dir') || '/partsupp.parquet') (FORMAT parquet, COMPRESSION snappy);
DROP TABLE partsupp_nullable;

-- orders
CREATE TABLE orders_nullable AS SELECT * FROM orders;
COPY orders_nullable TO (getvariable('out_dir') || '/orders.parquet') (FORMAT parquet, COMPRESSION snappy);
DROP TABLE orders_nullable;

-- lineitem
CREATE TABLE lineitem_nullable AS SELECT * FROM lineitem;
COPY lineitem_nullable TO (getvariable('out_dir') || '/lineitem.parquet') (FORMAT parquet, COMPRESSION snappy);
DROP TABLE lineitem_nullable;

-- Checks, from the Parquet metadata alone (no data scan). error() aborts the script with a
-- non-zero exit status on a violation.

-- All leaves OPTIONAL.
SELECT CASE
         WHEN count(*) FILTER (WHERE repetition_type IS DISTINCT FROM 'OPTIONAL') > 0
           THEN error('non-OPTIONAL Parquet column in ' || getvariable('out_dir'))
         ELSE count(*)
       END AS optional_columns
FROM parquet_schema(getvariable('out_dir') || '/*.parquet')
WHERE num_children IS NULL;

-- No NULLs.
SELECT CASE
         WHEN bool_or(stats_null_count IS NULL OR stats_null_count > 0)
           THEN error('NULL values (or missing null_count) in ' || getvariable('out_dir'))
         ELSE sum(stats_null_count)::BIGINT
       END AS null_values
FROM parquet_metadata(getvariable('out_dir') || '/*.parquet');

-- Physical types and codecs read_oasis (ParCore) can decode.
SELECT CASE
         WHEN count(*) FILTER (
                WHERE type NOT IN ('BOOLEAN', 'INT32', 'INT64', 'FLOAT', 'DOUBLE', 'BYTE_ARRAY')
                   OR compression NOT IN ('UNCOMPRESSED', 'SNAPPY')) > 0
           THEN error('column chunk read_oasis cannot decode in ' || getvariable('out_dir'))
         ELSE count(*)
       END AS read_oasis_column_chunks
FROM parquet_metadata(getvariable('out_dir') || '/*.parquet');

-- Row counts, row groups and the path to hand to read_oasis, per table.
SELECT regexp_extract(file_name, '([a-z]+)\.parquet$', 1) AS "table",
       num_rows,
       num_row_groups,
       'read_oasis(''' || file_name || ''')' AS scan
FROM parquet_file_metadata(getvariable('out_dir') || '/*.parquet')
ORDER BY 1;
