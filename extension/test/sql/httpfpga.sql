-- httpfpga roadmap — run via:  ./build/release/duckdb < test/sql/httpfpga.sql
-- Unlike the .test file, the CLI PRINTS each query's result OR error inline and keeps going,
-- so you see exactly which files/query-shapes work and which fail. (SQLLogicTest silently
-- skips any error containing "HTTP", which hides httpfpga failures.)
.echo on
.bail off

INSTALL parquet; LOAD parquet;
SET http_server='10.253.74.74';
SET http_port=9000;
SET httpfpga_cpu_fallback=false;
SET httpfpga_debug=true;

-- 1. connectivity + scale-independent goldens (region=5, nation=25)
SELECT count(*) AS region_rows FROM read_parquet('httpfpga://testbench/tpch-30/region.parquet');
SELECT r_name FROM read_parquet('httpfpga://testbench/tpch-30/region.parquet') ORDER BY r_regionkey;
SELECT count(*) AS nation_rows FROM read_parquet('httpfpga://testbench/tpch-30/nation.parquet');

-- 2. per-file smoke: can the FPGA path read each object at all?
SELECT count(*) FROM read_parquet('httpfpga://testbench/tpch-30/supplier.parquet');
SELECT count(*), min(p_partkey), max(p_partkey) FROM read_parquet('httpfpga://testbench/tpch-30/part.parquet');
SELECT count(*), min(c_custkey), max(c_custkey) FROM read_parquet('httpfpga://testbench/tpch-30/customer.parquet');
SELECT count(*), min(o_orderkey), max(o_orderkey) FROM read_parquet('httpfpga://testbench/tpch-30/orders.parquet');
SELECT count(*) FROM read_parquet('httpfpga://testbench/tpch-30/partsupp.parquet');
SELECT count(*) FROM read_parquet('httpfpga://testbench/tpch-30/lineitem.parquet');

-- 3. column-type coverage (numeric / decimal / string / date)
SELECT sum(p_size), avg(p_retailprice), max(length(p_name)) FROM read_parquet('httpfpga://testbench/tpch-30/part.parquet');
SELECT sum(l_quantity), sum(l_extendedprice), avg(l_discount) FROM read_parquet('httpfpga://testbench/tpch-30/lineitem.parquet');
SELECT min(o_orderdate), max(o_orderdate), count(DISTINCT o_orderstatus) FROM read_parquet('httpfpga://testbench/tpch-30/orders.parquet');

-- 4. group by / filter / order
SELECT p_brand, count(*), avg(p_retailprice) FROM read_parquet('httpfpga://testbench/tpch-30/part.parquet') GROUP BY p_brand ORDER BY p_brand;
SELECT l_returnflag, l_linestatus, count(*), sum(l_quantity) FROM read_parquet('httpfpga://testbench/tpch-30/lineitem.parquet') GROUP BY 1,2 ORDER BY 1,2;

-- 5. cross-file joins
SELECT count(*) FROM read_parquet('httpfpga://testbench/tpch-30/part.parquet') p
  JOIN read_parquet('httpfpga://testbench/tpch-30/partsupp.parquet') ps ON p.p_partkey = ps.ps_partkey;
SELECT n_name, count(*) FROM read_parquet('httpfpga://testbench/tpch-30/customer.parquet') c
  JOIN read_parquet('httpfpga://testbench/tpch-30/nation.parquet') n ON c.c_nationkey = n.n_nationkey
  GROUP BY n_name ORDER BY n_name;

-- 6. TPC-H Q1 shape
SELECT l_returnflag, l_linestatus, sum(l_quantity) sum_qty, sum(l_extendedprice) sum_base,
       sum(l_extendedprice*(1-l_discount)) sum_disc, avg(l_quantity) avg_qty, count(*) cnt
FROM read_parquet('httpfpga://testbench/tpch-30/lineitem.parquet')
WHERE l_shipdate <= DATE '1998-09-02'
GROUP BY 1,2 ORDER BY 1,2;
