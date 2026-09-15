-- q13 with the same cheap predicate as queries_software/q13_cheap.sql, but in the plan
-- shape the FPGA rewrite forces: a subquery feeding a NOT IN anti-join over 45M rows,
-- rather than a filter pushed into the scan.  No regex on either side, so timing this
-- against its software twin isolates the cost of the plan shape from the cost of matching.
SELECT
    c_count,
    count(*) AS custdist
FROM (
    SELECT
        c_custkey,
        count(o_orderkey)
    FROM
        customer
    LEFT OUTER JOIN orders ON c_custkey = o_custkey
    AND o_orderkey NOT IN (
        SELECT
            o_orderkey
        FROM
            orders
        WHERE
            o_orderkey % 97 = 0)
GROUP BY
    c_custkey) AS c_orders (c_custkey,
        c_count)
GROUP BY
    c_count
ORDER BY
    custdist DESC,
    c_count DESC;
