-- Free-Mail Customer Share Report
-- Identify customers in the BUILDING and AUTOMOBILE segments whose contact
-- email is hosted on a consumer free-mail provider (gmail/yahoo/hotmail/outlook),
-- grouped by nation, to gauge the share and balance of non-corporate buyers.
SELECT
    n_name,
    count(*) AS freemail_customers,
    sum(c_acctbal) AS total_acctbal
FROM
    regex_fpga_scan('customer', regex_column := 'c_email',
        pattern := '[ -~]*@[ghoy][ -~]*\.com') AS customer,
    nation
WHERE
    c_nationkey = n_nationkey
    AND c_mktsegment IN ('BUILDING', 'AUTOMOBILE')
GROUP BY
    n_name
ORDER BY
    freemail_customers DESC,
    n_name;
