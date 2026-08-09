-- Seasonal Promotion Revenue
-- For parts under an active seasonal promotion campaign (a promo code of the
-- form SEASON-2026-CHANNEL-XXXX), sum the discounted revenue of the line items
-- shipped within the promotion window, broken down by marketing channel.
SELECT
    pr_channel,
    count(DISTINCT pr_promokey) AS campaign_count,
    sum(l_extendedprice * (1 - l_discount)) AS promo_revenue
FROM
    regex_fpga_scan('promotion', regex_column := 'pr_code',
        pattern := '[A-Z]+-2026-[ -~]*') AS promotion,
    part,
    lineitem
WHERE
    pr_partkey = p_partkey
    AND l_partkey = p_partkey
    AND l_shipdate >= pr_startdate
    AND l_shipdate <= pr_enddate
GROUP BY
    pr_channel
ORDER BY
    promo_revenue DESC,
    pr_channel;
