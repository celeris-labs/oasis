#!/usr/bin/env python3
"""TPC-H Q20: query time and Bloom filter / decoder throughput over the scale factor.

    ./sweep_tpch_q20.py                                    # a new folder results/tpch_q20_<date>_<time>
    ./sweep_tpch_q20.py --resume results/tpch_q20_20261014_101530   # continue that experiment

runs TPC-H Q20 (bench.py's statistics, tpch_bench.py's data) at the scale factors 1 ... 8 (--scale-factors),
one after the other, with everything else at the defaults of bench.py. Then it plots the results (plot_utils.py).
The experiment folder has the structure of the other sweeps, with the scale factor as the points:

    results/tpch_q20_<date>_<time>/
        results/bloom_on/sf1/ ... sf8/                    one folder per point, as written by bench.py
        results/bloom_off/sf1/ ...                        the same points with the Bloom filter off
        results/summary.csv                               one row per point, both variants side by side
        plots/bloom_on/, plots/bloom_off/                 one plot per measure and variant
        plots/both/                                       both variants in one picture per measure,
                                                          and query_breakdown.pdf

The measures are the ones of every sweep (sweep_lib.py): query, scan and rest time (the host's wall clock),
the decoder's input and output throughput, its starved / stalled cycles and waiting share, and the Bloom filter's
input and output throughput. Every point is the median over the measured runs (--agg changes that).

The query is Q20 with the build side's filter removed and its correlated subquery written as the join below an
aggregate that DuckDB's decorrelation produces anyway:

    SELECT count(*) AS n_suppliers, sum(md5_number_lower(s_name || '|' || s_address)) AS name_checksum
    FROM (SELECT s_name, s_address
          FROM supplier, nation
          WHERE s_suppkey IN (
              SELECT ps_suppkey
              FROM (SELECT ps_partkey, ps_suppkey, ps_availqty, sum(l_quantity) AS sum_qty
                    FROM lineitem, partsupp
                    WHERE l_partkey = ps_partkey AND l_suppkey = ps_suppkey
                      AND l_shipdate >= DATE '1994-01-01' AND l_shipdate < DATE '1995-01-01'
                    GROUP BY ps_partkey, ps_suppkey, ps_availqty)
              WHERE ps_availqty > 0.5 * sum_qty)
            AND s_nationkey = n_nationkey AND n_name = 'CANADA')

where `partsupp` is a file that holds only the rows of partsupp whose part is one of the parts of the original
query's `ps_partkey IN (SELECT p_partkey FROM part WHERE p_name LIKE 'forest%')` (about 1.1 % of the rows). The
hardware Bloom filter is built from the whole key column of the build file, so it holds exactly the keys of the
forest parts, and the probe side, lineitem, is pruned to the rows of those parts, before the aggregate. The answer of every run is checked against the original query on the tables dbgen
generated (the original TPC-H text with ORDER BY s_name dropped, and the same count / checksum around it).

Which join the Bloom filter can go into, and why the query is written this way (EXPLAIN and the extension's debug
log, `CALL enable_logging(level = 'debug', storage = 'memory')`):

* The extension rewrites an INNER join of two read_oasis scans (nothing but filters between a join and its scan).
  The original Q20 has none: `ps_partkey IN (SELECT p_partkey FROM part ...)` is a SEMI join ("only inner joins are
  rewritten"), and the correlated subquery over lineitem is decorrelated into a join of lineitem with a DELIM_SCAN
  ("could not find single LogicalGet on both sides"), under the aggregate. The one join that would be rewritten is
  supplier-nation (25 build rows), which prunes nothing that matters.
* The semi join with part is therefore evaluated while generating the file: partsupp_q20.parquet is the build side,
  the rows of partsupp of the forest parts, with every column. (A file of the forest parts alone would make the
  plan join part with partsupp first and lineitem with that result, a join the extension cannot take: lineitem
  does not join part, the subquery's key is (ps_partkey, ps_suppkey).) The IN of the original is a filter of
  partsupp, like Q17's predicate is one of part, and leaves the query the same way.
* The correlated subquery becomes a join of lineitem and the filtered partsupp on both keys, then the aggregate by
  (ps_partkey, ps_suppkey, ps_availqty), then the comparison. That is the same answer: a partsupp row with no
  lineitem row in 1994 has sum() NULL in the original, so `ps_availqty > 0.5 * NULL` is NULL and the row is dropped,
  as the inner join drops it. ps_partkey, ps_suppkey is unique, so grouping by it is one group per partsupp row.
* The extension builds the filter from the first equality of the join: ps_partkey (l_partkey is first in the
  query), not both columns. The log line says which key ("Runtime Bloom filter rewrite: ... key 'ps_partkey'").
* supplier and nation are read with DuckDB's read_parquet, not read_oasis (they are tiny): the join of two
  read_oasis scans would have been rewritten as well, a second Bloom filter run in every query. Both variants read
  them the same way.
* The filter keeps the lineitem rows of the forest parts (about 1.1 % of them). The year range (1994, the
  pushed-down l_shipdate filter) stays in the query: it is the probe side's own predicate. l_shipdate is read by
  the filter only, it is still a column the decoder outputs (4 B per row).
* The result is one row (the number of suppliers and a sum of md5 digests of their names and addresses), not the list:
  a run's result has to be comparable with the generated answer, and the list of suppliers is small.

No DuckDB optimizer has to be disabled: the plan has the lineitem-partsupp join below the aggregate for Bloom on
and off alike (so the plans of the two variants are the same).

Lineitem is scanned once. The decoder's output is l_partkey, l_suppkey, l_quantity (8 B each) and l_shipdate (4 B)
of every row, whole columns: the pushed-down filter is applied after the decoder.

--bloom {on,off,both} (default: both) chooses the variants: the hardware Bloom filter on, off (then DuckDB's own join Bloom filter filters the scans), or both,
which runs the two variants of a point back to back and plots them side by side (plots/both/). Bloom off has no
Bloom filter throughput (bloom_in, bloom_out), so those are only plotted for on.

The TPC-H data is generated by DuckDB's dbgen (the duckdb package with the tpch extension) into a temporary
directory (--tmp-dir) when a point needs it, for both variants, and removed when the point is done. Every column
is OPTIONAL without NULLs, as ParCore needs it (about 0.4 GB per scale factor uncompressed, with 16 columns of
lineitem). --compression snappy writes Snappy compressed files.

The sweep stops at the first failure. Run it again with `--resume <experiment folder>` to continue: complete points
are skipped, and the folder of a failed point (kept for its logs) has to be removed first. `--resume FOLDER
--plots-only` plots what is there without running.
"""

import sys

import sweep_lib
import tpch_bench

SWEEP, add_args, points_of = tpch_bench.scale_factor_sweep(tpch_bench.Q20, "sweep_tpch_q20.py", __doc__)


if __name__ == "__main__":
    sys.exit(sweep_lib.main(SWEEP, add_args, points_of))
