-- Bavaria Postcode Customer Address Report
-- For customers in GERMANY, count those whose mailing address follows the
-- domestic street-number format with a post code in the 8xxx range
-- (Bavaria and parts of Baden-Württemberg), grouped by market segment,
-- to support regional fulfillment planning.
SELECT
    c_mktsegment,
    count(*) AS bavaria_postcode_customers,
    sum(c_acctbal) AS total_acctbal
FROM
    customer,
    nation
WHERE
    c_nationkey = n_nationkey
    AND n_name = 'GERMANY'
    AND regex_fpga(c_address, '\d+ \w+(\.)? 8\d\d\d \w+')
GROUP BY
    c_mktsegment
ORDER BY
    bavaria_postcode_customers DESC,
    c_mktsegment;
