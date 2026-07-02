-- Bavaria Postcode Customer Address Report
-- Regex scan on German customers only (customer_de), matching the software query row set.
SELECT
    c_mktsegment,
    count(*) AS bavaria_postcode_customers,
    sum(c_acctbal) AS total_acctbal
FROM
    regex_fpga_scan(
        'customer_de',
        regex_column := 'c_address',
        pattern := '\d+ \w+(\.)? 8\d\d\d \w+'
    ) AS customer_de
GROUP BY
    c_mktsegment
ORDER BY
    bavaria_postcode_customers DESC,
    c_mktsegment;
