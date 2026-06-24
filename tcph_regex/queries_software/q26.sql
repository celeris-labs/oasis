-- Corporate Supplier Contact Concentration
-- For suppliers in EUROPE, count those reachable through a corporate email
-- domain (a commercial or European country TLD) while excluding consumer
-- free-mail addresses, grouped by nation, to support procurement outreach.
SELECT
    n_name,
    count(*) AS corporate_suppliers,
    sum(s_acctbal) AS total_acctbal
FROM
    supplier,
    nation,
    region
WHERE
    s_nationkey = n_nationkey
    AND n_regionkey = r_regionkey
    AND r_name = 'EUROPE'
    AND s_email SIMILAR TO '.*@.*\\.(com|eu|de|fr|co\\.uk)'
    AND NOT s_email SIMILAR TO '.*@(gmail|yahoo|hotmail|outlook)\\..*'
GROUP BY
    n_name
ORDER BY
    corporate_suppliers DESC,
    n_name;
