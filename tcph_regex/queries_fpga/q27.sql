-- Bavaria Postcode Customer Address Report
-- Regex scan over the full customer table; the c_nationkey = 7 (GERMANY) predicate is pushed into
-- regex_fpga_scan so the regex only runs on German customers, while the 37-row-group customer table
-- lets the scan use up to ~32 parallel threads.
SELECT
    c_mktsegment,
    count(*) AS bavaria_postcode_customers,
    sum(c_acctbal) AS total_acctbal
FROM
    regex_fpga_scan(
        'customer',
        regex_column := 'c_address',
        pattern := '\d+ \w+(\.)? 8\d\d\d \w+'
    ) AS customer
WHERE
    c_nationkey = 7
GROUP BY
    c_mktsegment
ORDER BY
    bavaria_postcode_customers DESC,
    c_mktsegment;
