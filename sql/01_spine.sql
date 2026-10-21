-- =====================================================================
-- Promotion uplift  |  01 — Calendar, clean transactions, promo flags, date spine
-- Grain of the spine: product x store x week, zero-filled.
-- Definitions (docs/DEFINITIONS.md):
--   * sales_value is NET revenue to the retailer: already after the loyalty discount
--     (retail_disc) and the retailer's coupon match (coupon_match_disc). Discounts are
--     stored as POSITIVE numbers in this release, so
--       shelf_value = sales_value + retail_disc + coupon_match_disc
--     Manufacturer coupons (coupon_disc) are reimbursed to the retailer: not a retailer cost.
--   * Promoted = on display and/or in the mailer that product-store-week.
-- =====================================================================

-- Large joins: let DuckDB spill to disk instead of keeping row order in memory
SET preserve_insertion_order = false;
SET temp_directory = 'tmp_duckdb';
SET threads = 2;

-- 1. Week calendar: dates, holiday flags, analysis scope ---------------------
CREATE OR REPLACE TABLE week_calendar AS
SELECT week,
       MIN(transaction_timestamp)::DATE AS first_day,
       MAX(transaction_timestamp)::DATE AS last_day,
       CASE week WHEN 48 THEN 'Thanksgiving (23 Nov)'
                 WHEN 52 THEN 'Christmas week (to 24 Dec)'
                 WHEN 53 THEN 'Christmas to New Year'
                 ELSE NULL END           AS holiday,
       week BETWEEN 2 AND 53            AS in_scope      -- week 1 is a single day (1 Jan)
FROM transactions
GROUP BY week;

-- 2. Stores with promotion data (the only stores where "not promoted" is observable)
CREATE OR REPLACE TABLE promo_stores AS
SELECT DISTINCT store_id FROM promotions;

-- 3. Promotion flags, one row per product x store x week ------------------------
--    12,785 keys appear twice with different codes: collapse with BOOL_OR.
--    Display code 'A' = "In-Shelf" (not a secondary display): kept as its own flag.
CREATE OR REPLACE TABLE promo_flags AS
SELECT product_id, store_id, week,
       BOOL_OR(display_location NOT IN ('0', 'A'))  AS on_display,      -- secondary display
       BOOL_OR(display_location = 'A')              AS in_shelf_tag,    -- sensitivity only
       BOOL_OR(mailer_location <> '0')              AS in_mailer,
       COUNT(*)                                     AS source_rows
FROM promotions
GROUP BY ALL;

-- 4. Clean transactions: promo stores, in-scope weeks, valid quantity and value ----
CREATE OR REPLACE TABLE tx_clean AS
SELECT t.*,
       t.sales_value + t.retail_disc + t.coupon_match_disc AS shelf_value
FROM transactions t
JOIN promo_stores USING (store_id)
JOIN week_calendar w USING (week)
WHERE w.in_scope
  AND t.quantity > 0
  AND t.sales_value > 0;

-- 5. Weekly sales per product x store (only weeks with a sale) -------------------
CREATE OR REPLACE TABLE sales_psw AS
SELECT product_id, store_id, week,
       SUM(quantity)           AS units,
       SUM(sales_value)        AS net_sales,         -- what the retailer keeps
       SUM(shelf_value)        AS shelf_sales,       -- at regular shelf price
       SUM(retail_disc)        AS loyalty_disc,      -- retailer-funded
       SUM(coupon_match_disc)  AS coupon_match_disc, -- retailer-funded
       SUM(coupon_disc)        AS manuf_coupon_disc, -- manufacturer-funded
       COUNT(DISTINCT basket_id) AS baskets
FROM tx_clean
GROUP BY ALL;

-- 6. The spine: every product-store pair with at least one sale in scope x every in-scope week
--    Pairs never bought by the sample households add only zeros to any sum, so they are left out;
--    within a pair, weeks with no sale are kept as explicit zeros.
CREATE OR REPLACE TABLE spine_pairs AS
SELECT DISTINCT product_id, store_id FROM sales_psw;

-- promo flags restricted to those pairs (keeps the join small enough for memory)
CREATE OR REPLACE TABLE pair_flags AS
SELECT f.* FROM promo_flags f SEMI JOIN spine_pairs p USING (product_id, store_id);

CREATE OR REPLACE TABLE spine AS
WITH pairs AS (SELECT * FROM spine_pairs),
     weeks AS (SELECT week FROM week_calendar WHERE in_scope)
SELECT p.product_id, p.store_id, w.week,
       COALESCE(s.units, 0)              AS units,
       COALESCE(s.net_sales, 0)          AS net_sales,
       COALESCE(s.shelf_sales, 0)        AS shelf_sales,
       COALESCE(s.loyalty_disc, 0)       AS loyalty_disc,
       COALESCE(s.coupon_match_disc, 0)  AS coupon_match_disc,
       COALESCE(s.manuf_coupon_disc, 0)  AS manuf_coupon_disc,
       COALESCE(s.baskets, 0)            AS baskets,
       COALESCE(f.on_display, FALSE)     AS on_display,
       COALESCE(f.in_mailer, FALSE)      AS in_mailer,
       COALESCE(f.in_shelf_tag, FALSE)   AS in_shelf_tag,
       CASE WHEN f.on_display AND f.in_mailer THEN 'display + mailer'
            WHEN f.on_display               THEN 'display only'
            WHEN f.in_mailer                THEN 'mailer only'
            ELSE 'none' END                 AS promo_type,
       -- loyalty discount depth, observable only in weeks with a sale (R4 control)
       CASE WHEN s.shelf_sales IS NULL OR s.shelf_sales = 0 THEN 'no sale'
            WHEN s.loyalty_disc = 0                        THEN 'none'
            WHEN s.loyalty_disc / s.shelf_sales < 0.10     THEN 'under 10%'
            WHEN s.loyalty_disc / s.shelf_sales <= 0.25    THEN '10-25%'
            ELSE 'over 25%' END             AS loyalty_depth
FROM pairs p
CROSS JOIN weeks w
LEFT JOIN sales_psw s   USING (product_id, store_id, week)
LEFT JOIN pair_flags f USING (product_id, store_id, week);
