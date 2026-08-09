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
            regex_fpga_scan('orders', regex_column := 'o_comment',
                pattern := '[ -~]*spec[ -~]*requ[ -~]*') AS matched_orders)
GROUP BY
    c_custkey) AS c_orders (c_custkey,
        c_count)
GROUP BY
    c_count
ORDER BY
    custdist DESC,
    c_count DESC;
