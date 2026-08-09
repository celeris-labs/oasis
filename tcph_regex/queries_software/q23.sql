-- Free-Mail Customer Share Report
-- Identify customers in the BUILDING and AUTOMOBILE segments whose contact
-- email is hosted on a consumer free-mail provider (gmail/yahoo/hotmail/outlook),
-- grouped by nation, to gauge the share and balance of non-corporate buyers.
SELECT
    n_name,
    count(*) AS freemail_customers,
    sum(c_acctbal) AS total_acctbal
FROM
    customer,
    nation
WHERE
    c_nationkey = n_nationkey
    AND c_mktsegment IN ('BUILDING', 'AUTOMOBILE')
    AND c_email SIMILAR TO '[ -~]*@[ghoy][ -~]*\.com'
GROUP BY
    n_name
ORDER BY
    freemail_customers DESC,
    n_name;
