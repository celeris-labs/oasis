SELECT
    100.00 * sum(
        CASE WHEN p_partkey IN (
                SELECT
                    p_partkey
                FROM
                    regex_fpga_scan('part', regex_column := 'p_type',
                        pattern := 'PROMO.*') AS promo_part) THEN
            l_extendedprice * (1 - l_discount)
        ELSE
            0
        END) / sum(l_extendedprice * (1 - l_discount)) AS promo_revenue
FROM
    lineitem,
    part
WHERE
    l_partkey = p_partkey
    AND l_shipdate >= date '1995-09-01'
    AND l_shipdate < CAST('1995-10-01' AS date);
