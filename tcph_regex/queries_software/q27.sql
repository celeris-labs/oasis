-- Bavaria Postcode Customer Address Report
-- Regex over the full customer table, restricted to German customers (c_nationkey = 7), matching
-- the FPGA query row set.
SELECT
    c_mktsegment,
    count(*) AS bavaria_postcode_customers,
    sum(c_acctbal) AS total_acctbal
FROM
    customer
WHERE
    c_address SIMILAR TO '\d+ \w+\.? 8\d\d\d \w+'
GROUP BY
    c_mktsegment
ORDER BY
    bavaria_postcode_customers DESC,
    c_mktsegment;
