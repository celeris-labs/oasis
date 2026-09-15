-- The non-regex half of q29 on its own (the thesis quotes 145 ms).  Identical on both
-- paths: it touches no string column, so there is no FPGA variant to write.
SELECT
    'supply cost/' || (ps_suppkey % 8)::VARCHAR AS metric,
    sum(supply_cost)::DOUBLE AS value
FROM (
    SELECT ps_suppkey, sum(ps_supplycost) AS supply_cost
    FROM partsupp
    GROUP BY ps_suppkey
) AS c
GROUP BY
    ps_suppkey % 8
ORDER BY
    metric;
