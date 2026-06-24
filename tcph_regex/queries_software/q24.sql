-- Premium SKU Catalog Audit
-- Find parts whose stock-keeping unit follows the premium catalog code format
-- (three uppercase letters, a numeric run, and a EU/US/AS region suffix),
-- reporting how many such parts each manufacturer carries and their average
-- retail price.
SELECT
    p_mfgr,
    count(*) AS premium_part_count,
    avg(p_retailprice) AS avg_retailprice
FROM
    part
WHERE
    p_sku SIMILAR TO '[A-Z][A-Z][A-Z]-[0-9]+-(EU|US|AS)'
GROUP BY
    p_mfgr
ORDER BY
    premium_part_count DESC,
    p_mfgr;
