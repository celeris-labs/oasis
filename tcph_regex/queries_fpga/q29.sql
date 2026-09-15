-- Deposit-Comment Audit and Supplier Cost Exposure  (one dashboard, two panels)
--
-- Two report sections in one statement, with no dependency between them:
--
--   1. a regex over all 45M o_comment values (2.18 GB of text), and
--   2. supply-cost exposure per supplier over the 24M-row partsupp table.
--
-- This was built to test whether the CPU regex_fpga_scan does NOT use can be sold to the
-- rest of the query.  It caps its scan threads at kRegexMaxSubmissionsInFlight /
-- oasis_regex_max_in_flight = 16 and matches at 11.3 GB/s while burning 2.6 core-seconds;
-- SIMILAR TO over the same column needs 13.1 for the same answer.  Five times the CPU for
-- the same work looks like headroom worth selling.
--
-- It is not, and this query is the measurement that says so.  Measured (median of 15,
-- benchmark_runner): fpga 370 ms, software 621 ms, 1.68x -- against 1.76x for the regex
-- ALONE.  Adding the companion made the accelerator's position slightly worse, and every
-- companion size measured did the same (scripts/regex_overlap.py).  Three reasons, each
-- measured separately:
--
--   * DuckDB does not overlap the two sections.  Regex alone 254 ms + companion alone
--     145 ms = 399; together 382 (UNION ALL) or 372 (CROSS JOIN), at 20 of 32 effective
--     cores.  The sections run essentially back to back whatever shape they are given.
--   * The box absorbs extra work for BOTH engines anyway.  16 external threads of pure
--     compute or pure streaming cost either variant 0.99-1.01x and themselves run at
--     1.00x.  With 16 physical cores behind 32 logical, software's scan is memory-stalled
--     enough to leave the same slack the FPGA path leaves.
--   * Under real oversubscription the FPGA path degrades FASTER, because it is latency-
--     bound on the device round trip and its packing threads have to be scheduled
--     promptly to keep the card fed: with 4 competing analytics streams it slows 7.5x
--     against software's 3.75x.  It only wins again at 8 streams.
--
-- The operator's case is throughput and pattern-invariance, not spare threads.
SELECT
    'flagged orders/' || o_orderpriority AS metric,
    count(*)::DOUBLE AS value
FROM
    regex_fpga_scan('orders', regex_column := 'o_comment',
                    pattern := '.*deposit[a-z].*')
GROUP BY
    o_orderpriority
UNION ALL
SELECT
    'supply cost/' || (ps_suppkey % 8)::VARCHAR,
    sum(supply_cost)::DOUBLE
FROM (
    SELECT ps_suppkey, sum(ps_supplycost) AS supply_cost
    FROM partsupp
    GROUP BY ps_suppkey
) AS c
GROUP BY
    ps_suppkey % 8
ORDER BY
    metric;
