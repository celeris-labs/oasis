-- High-Volume Postcode Address Audit
-- Deliberately unfiltered: every one of the 4.5M customer rows (~143 MB of address
-- text at sf30) passes through the regex, unlike q27 which pre-filters to one nation.
-- The leading [ -~]* also denies the software engine an early exit, so both sides must
-- scan every byte of every address.  Together these isolate raw regex throughput.
SELECT
    c_mktsegment,
    count(*) AS postcode_customers,
    sum(c_acctbal) AS total_acctbal
FROM
    customer
WHERE
    c_address SIMILAR TO '[ -~]*8[0-9][0-9][0-9] [A-Z][ -~]*'
GROUP BY
    c_mktsegment
ORDER BY
    postcode_customers DESC,
    c_mktsegment;
