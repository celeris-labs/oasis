-- WARNING: this is a BROKEN baseline, kept as a labelled control.  `NOT strlen(o_comment)
-- > 0` is false for every row, so the LEFT OUTER JOIN keeps no orders and the hash join
-- does no work: it measures q13 with the *join* removed, not just the matching (148 ms
-- against 1123 ms for the real query).  Use queries_software/q13_cheap.sql as the floor --
-- it preserves join cardinality and reproduces the thesis 0.406 s to within 2%.
--
-- q13 with the pattern replaced by strlen(o_comment) > 0: the same plan and the same
-- column touched, with the matching removed.  The thesis footnote in section 5.4.5
-- quotes "0.406 s of 1.102 s" from this comparison to argue that matching is only ~37%
-- of q13 and that Amdahl caps the achievable speed-up at 1.6x.  There is no FPGA twin:
-- the point of the file is to measure q13 *without* a regex.
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
    AND NOT strlen(o_comment) > 0
GROUP BY
    c_custkey) AS c_orders (c_custkey,
        c_count)
GROUP BY
    c_count
ORDER BY
    custdist DESC,
    c_count DESC;
