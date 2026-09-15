-- The regex half of q29 on its own.  The thesis quotes this at 254 ms and compares the
-- sum of the two halves (399 ms) against the UNION ALL (382 ms) to argue that the CPU
-- the FPGA path leaves free cannot be sold to a second query.  That argument needs all
-- three numbers, and only the UNION ALL was reproducible before this file existed.
SELECT
    'flagged orders/' || o_orderpriority AS metric,
    count(*)::DOUBLE AS value
FROM
    regex_fpga_scan('orders', regex_column := 'o_comment',
                    pattern := '[ -~]*deposit[a-z][ -~]*')
GROUP BY
    o_orderpriority
ORDER BY
    metric;
