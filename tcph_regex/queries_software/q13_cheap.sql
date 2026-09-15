-- q13 with a cheap predicate of similar selectivity, in the SOFTWARE plan shape: the
-- filter is pushed into the orders scan.  Pairs with queries_fpga/q13_cheap.sql, which
-- expresses the identical predicate in the table-function plan shape (an anti-join over
-- 45M rows).  Neither runs a regex, so the difference between the two is the cost of the
-- plan shape alone -- the "that plan approach alone costs 8% of the query" claim in
-- section 5.4.5, which was previously not reproducible from anything in the repository.
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
    AND NOT o_orderkey % 97 = 0
GROUP BY
    c_custkey) AS c_orders (c_custkey,
        c_count)
GROUP BY
    c_count
ORDER BY
    custdist DESC,
    c_count DESC;
