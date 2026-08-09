-- Corporate Supplier Contact Concentration
-- For suppliers in EUROPE, count those reachable through a corporate email
-- domain (a commercial or European country TLD) while excluding consumer
-- free-mail addresses, grouped by nation, to support procurement outreach.
SELECT
    n_name,
    count(*) AS corporate_suppliers,
    sum(s_acctbal) AS total_acctbal
FROM
    -- Single scan: the corporate-domain and not-freemail predicates are folded into one
    -- pattern ([aism] = acme-parts/supply-co/industrial/metals, which excludes the
    -- gmail/yahoo/hotmail/outlook domains).  Two concurrent regex_fpga_scans in one query
    -- currently exhaust the huge-page pool, so keep this to a single scan.
    regex_fpga_scan('supplier', regex_column := 's_email',
        pattern := '[ -~]*@[aism][ -~]*\.[cdefu][ -~]*') AS supplier,
    nation,
    region
WHERE
    s_nationkey = n_nationkey
    AND n_regionkey = r_regionkey
    AND r_name = 'EUROPE'
GROUP BY
    n_name
ORDER BY
    corporate_suppliers DESC,
    n_name;
