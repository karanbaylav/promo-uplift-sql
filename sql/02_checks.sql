-- =====================================================================
-- Promotion uplift  |  02 — Data checks on the spine (failures must be 0 where marked)
-- =====================================================================
-- @k blocking
SELECT 'spine key is unique' AS test,
       (SELECT COUNT(*) - COUNT(DISTINCT (product_id, store_id, week)) FROM spine) AS failures
UNION ALL
SELECT 'spine rows = pairs x weeks',
       (SELECT COUNT(*) FROM spine)
       - (SELECT COUNT(*) FROM (SELECT DISTINCT product_id, store_id FROM sales_psw))
         * (SELECT COUNT(*) FROM week_calendar WHERE in_scope)
UNION ALL
SELECT 'spine net sales reconcile to clean transactions (cents)',
       ROUND(100 * ABS((SELECT SUM(net_sales) FROM spine) - (SELECT SUM(sales_value) FROM tx_clean)))
UNION ALL
SELECT 'promo flags unique after collapsing duplicates',
       (SELECT COUNT(*) - COUNT(DISTINCT (product_id, store_id, week)) FROM promo_flags)
UNION ALL
SELECT 'shelf value >= net value on every row',
       (SELECT COUNT(*) FROM tx_clean WHERE shelf_value < sales_value);

-- @k row_funnel  (what each rule removed from transactions)
SELECT 'all transaction rows'                    AS step, COUNT(*) AS rows, ROUND(SUM(sales_value)) AS net_sales FROM transactions
UNION ALL SELECT 'in the 112 promotion stores', COUNT(*), ROUND(SUM(sales_value)) FROM transactions JOIN promo_stores USING (store_id)
UNION ALL SELECT '... and weeks 2-53',          COUNT(*), ROUND(SUM(sales_value)) FROM transactions JOIN promo_stores USING (store_id) WHERE week BETWEEN 2 AND 53
UNION ALL SELECT '... dropped: quantity = 0',   COUNT(*), ROUND(SUM(sales_value)) FROM transactions JOIN promo_stores USING (store_id) WHERE week BETWEEN 2 AND 53 AND quantity <= 0
UNION ALL SELECT '... dropped: value = 0 (qty > 0)', COUNT(*), ROUND(SUM(sales_value)) FROM transactions JOIN promo_stores USING (store_id) WHERE week BETWEEN 2 AND 53 AND quantity > 0 AND sales_value <= 0
UNION ALL SELECT 'clean rows (tx_clean)',       COUNT(*), ROUND(SUM(sales_value)) FROM tx_clean;

-- @k promo_duplicates
SELECT COUNT(*) FILTER (WHERE source_rows > 1) AS keys_with_duplicate_rows,
       SUM(source_rows) - COUNT(*)            AS rows_collapsed,
       COUNT(*)                               AS product_store_weeks_promoted
FROM promo_flags;

-- @k spine_profile
SELECT COUNT(*)                                             AS spine_rows,
       COUNT(DISTINCT (product_id, store_id))               AS product_store_pairs,
       COUNT(DISTINCT product_id)                           AS products,
       ROUND(100.0 * AVG((units = 0)::INT), 1)              AS pct_rows_zero_sales,
       ROUND(100.0 * AVG((promo_type <> 'none')::INT), 1)   AS pct_rows_promoted,
       ROUND(100.0 * AVG((promo_type <> 'none' AND units = 0)::INT)
             / NULLIF(AVG((promo_type <> 'none')::INT), 0), 1) AS pct_promoted_rows_with_zero_sales
FROM spine;

-- @k promo_mix
SELECT promo_type, COUNT(*) AS rows, ROUND(SUM(net_sales)) AS net_sales,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_rows
FROM spine GROUP BY promo_type ORDER BY rows DESC;

-- @k loyalty_depth_mix  (weeks with a sale only)
SELECT loyalty_depth, COUNT(*) AS rows_with_sale, ROUND(SUM(net_sales)) AS net_sales
FROM spine WHERE units > 0 GROUP BY loyalty_depth ORDER BY rows_with_sale DESC;

-- @k discount_funding
SELECT ROUND(SUM(net_sales))         AS net_sales,
       ROUND(SUM(shelf_sales))       AS shelf_sales,
       ROUND(SUM(loyalty_disc))      AS loyalty_disc_retailer,
       ROUND(SUM(coupon_match_disc)) AS coupon_match_retailer,
       ROUND(SUM(manuf_coupon_disc)) AS manufacturer_coupons
FROM spine;

-- @k holiday_weeks
SELECT w.week, w.first_day, w.last_day, w.holiday, ROUND(SUM(s.net_sales)) AS net_sales
FROM week_calendar w JOIN spine s USING (week)
WHERE w.holiday IS NOT NULL GROUP BY ALL ORDER BY w.week;
