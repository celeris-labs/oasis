-- Oasis TPC-H init file.
-- Run the binary from the `extension/` directory so the relative paths resolve.
--
--   ./build/release/duckdb -init tpch_init.sql
--
-- Single-threaded so concurrent oasis scans never interleave on FPGA stream 0.
SET threads TO 1;

-- Point the standard TPC-H table names at the parquet files via the oasis scan.
CREATE OR REPLACE VIEW region   AS SELECT * FROM read_oasis('data/tpch/region.parquet');
CREATE OR REPLACE VIEW nation   AS SELECT * FROM read_oasis('data/tpch/nation.parquet');
CREATE OR REPLACE VIEW supplier AS SELECT * FROM read_oasis('data/tpch/supplier.parquet');
CREATE OR REPLACE VIEW customer AS SELECT * FROM read_oasis('data/tpch/customer.parquet');
CREATE OR REPLACE VIEW part     AS SELECT * FROM read_oasis('data/tpch/part.parquet');
CREATE OR REPLACE VIEW partsupp AS SELECT * FROM read_oasis('data/tpch/partsupp.parquet');
CREATE OR REPLACE VIEW orders   AS SELECT * FROM read_oasis('data/tpch/orders.parquet');
CREATE OR REPLACE VIEW lineitem AS SELECT * FROM read_oasis('data/tpch/lineitem.parquet');
