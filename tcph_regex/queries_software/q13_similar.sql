-- Software twin of queries_software/q13.sql with the LIKE predicate expressed as
-- SIMILAR TO, so the two software variants can be timed against each other and against
-- queries_fpga/q13.sql.  The pattern mirrors the FPGA query (and the TPC-H spec):
-- 'requests', not the 'request' the LIKE variant in q13.sql uses.
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
    AND NOT o_comment SIMILAR TO '.*special.*requests.*'
GROUP BY
    c_custkey) AS c_orders (c_custkey,
        c_count)
GROUP BY
    c_count
ORDER BY
    custdist DESC,
    c_count DESC;
