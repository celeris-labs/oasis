-- Deposit-Comment Audit and Supplier Cost Exposure  (one dashboard, two panels)
-- Software twin of queries_fpga/q29.sql.  Same two independent sections, regex as
-- SIMILAR TO.  See the FPGA file's header: the pair exists to measure whether the
-- accelerator's unused CPU can be sold to a companion workload, and the answer measured
-- on this box is no -- 621 ms against the FPGA's 370, a 1.68x that is below the 1.76x the
-- regex gets on its own.
SELECT
    'flagged orders/' || o_orderpriority AS metric,
    count(*)::DOUBLE AS value
FROM
    orders
WHERE
    o_comment SIMILAR TO '[ -~]*deposit[a-z][ -~]*'
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
