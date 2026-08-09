SELECT
    p_brand,
    p_type,
    p_size,
    count(DISTINCT ps_suppkey) AS supplier_cnt
FROM
    partsupp,
    part
WHERE
    p_partkey = ps_partkey
    AND p_brand <> 'Brand#45'
    AND p_partkey NOT IN (
        SELECT
            p_partkey
        FROM
            regex_fpga_scan('part', regex_column := 'p_type',
                pattern := 'MEDIUM PO[ -~]*') AS polished_part)
    AND p_size IN (49, 14, 23, 45, 19, 3, 36, 9)
    -- Deliberately left in software: a second concurrent regex_fpga_scan in the same query
    -- exhausts the huge-page pool (libstf's OBM enqueues a buffer per interrupt but only
    -- reclaims one when bytes_written > 0).  supplier is 300k rows against part's 6M, so the
    -- FPGA scan stays where it pays off.  Revert to a scan once the OBM is fixed.
    AND ps_suppkey NOT IN (
        SELECT
            s_suppkey
        FROM
            supplier
        WHERE
            s_comment LIKE '%Cust%Compl%')
GROUP BY
    p_brand,
    p_type,
    p_size
ORDER BY
    supplier_cnt DESC,
    p_brand,
    p_type,
    p_size;
