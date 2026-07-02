-- Bavaria Postcode Customer Address Report
-- Regex on German customers only (customer_de), matching the FPGA query row set.
SELECT
    c_mktsegment,
    count(*) AS bavaria_postcode_customers,
    sum(c_acctbal) AS total_acctbal
FROM
    customer_de
WHERE
    c_address SIMILAR TO '\d+ \w+\.? 8\d\d\d \w+'
GROUP BY
    c_mktsegment
ORDER BY
    bavaria_postcode_customers DESC,
    c_mktsegment;
