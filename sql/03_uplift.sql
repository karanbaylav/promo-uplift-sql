-- =====================================================================
-- Promotion uplift  |  03 — Step 2: uplift by promo type, two methods
-- Rules (docs/DEFINITIONS.md):
--   * Uplift is always a RATIO OF SUMS: sum(actual) / sum(expected) - 1 over all promoted
--     rows in a group. Never an average of per-row ratios.
--   * Baselines use only non-promoted, non-holiday weeks.
--   * Promoted rows in holiday weeks (48, 52, 53) are reported separately.
-- =====================================================================
SET preserve_insertion_order = false;
SET temp_directory = 'tmp_duckdb';
SET threads = 2;

-- Clean baseline weeks: no display, no mailer, not a holiday week
CREATE OR REPLACE TABLE base_weeks AS
SELECT s.product_id, s.store_id, s.week, s.net_sales, s.units, s.in_shelf_tag
FROM spine s JOIN week_calendar w USING (week)
WHERE s.promo_type = 'none' AND w.holiday IS NULL;

-- Promoted rows to evaluate
CREATE OR REPLACE TABLE promo_rows AS
SELECT s.product_id, s.store_id, s.week, s.promo_type, s.net_sales, s.units,
       p.department, p.product_category,
       w.holiday IS NOT NULL AS holiday_week
FROM spine s
JOIN week_calendar w USING (week)
JOIN products p USING (product_id)
WHERE s.promo_type <> 'none';

-- ---------------------------------------------------------------------
-- METHOD A: time baseline = the product's own last 4 clean weeks in that store
-- ---------------------------------------------------------------------
-- Rolling mean over the last 4 CLEAN weeks (rows, not calendar weeks)
CREATE OR REPLACE TABLE base_roll AS
SELECT product_id, store_id, week,
       AVG(net_sales) OVER w4  AS base_net_sales,
       AVG(units)     OVER w4  AS base_units,
       COUNT(*)       OVER w4  AS n_base_weeks,
       MIN(week)      OVER w4  AS first_base_week
FROM base_weeks
WINDOW w4 AS (PARTITION BY product_id, store_id ORDER BY week
              ROWS BETWEEN 3 PRECEDING AND CURRENT ROW);

-- Attach to each promoted row the latest clean baseline that ends BEFORE that week
CREATE OR REPLACE TABLE uplift_a_rows AS
SELECT r.*, b.base_net_sales, b.base_units, b.n_base_weeks, b.first_base_week
FROM promo_rows r
ASOF LEFT JOIN base_roll b
  ON r.product_id = b.product_id AND r.store_id = b.store_id AND r.week > b.week;

-- Eligible: 4 clean weeks found, all within the 12 weeks before the promotion
CREATE OR REPLACE VIEW uplift_a AS
SELECT * FROM uplift_a_rows
WHERE n_base_weeks = 4 AND week - first_base_week <= 12;

-- ---------------------------------------------------------------------
-- METHOD B: same product, same week, promoted stores vs non-promoted stores,
--           each store scaled by its usual (clean-week) sales of that product
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE store_usual AS
SELECT product_id, store_id,
       AVG(net_sales) AS usual_net_sales,
       AVG(units)     AS usual_units,
       COUNT(*)       AS n_clean_weeks
FROM base_weeks
GROUP BY ALL
HAVING COUNT(*) >= 4;

-- Control index per product-week: how non-promoted stores did relative to their usual
CREATE OR REPLACE TABLE week_control AS
SELECT s.product_id, s.week,
       SUM(s.net_sales)        AS ctrl_net_sales,
       SUM(u.usual_net_sales)  AS ctrl_usual_net_sales,
       SUM(s.units)            AS ctrl_units,
       SUM(u.usual_units)      AS ctrl_usual_units,
       COUNT(*)                AS ctrl_stores
FROM spine s
JOIN store_usual u USING (product_id, store_id)
WHERE s.promo_type = 'none'
GROUP BY ALL;

-- How many of the stores that sell a product are promoting it that week
CREATE OR REPLACE TABLE product_week_share AS
SELECT product_id, week, COUNT(*) AS stores_selling,
       COUNT(*) FILTER (WHERE promo_type <> 'none') AS stores_promoted
FROM spine GROUP BY ALL;

-- Method B is only valid where a real control group exists: at most half of the stores
-- selling the product promote it that week, and at least 10 non-promoted stores remain.
-- (Mailers are near chain-wide, so this rule leaves few mailer rows: see u07.)
CREATE OR REPLACE TABLE uplift_b_all AS
SELECT r.*,
       u.usual_net_sales, u.usual_units, c.ctrl_stores,
       u.usual_net_sales * c.ctrl_net_sales / c.ctrl_usual_net_sales AS expected_net_sales,
       u.usual_units     * c.ctrl_units     / c.ctrl_usual_units     AS expected_units
FROM promo_rows r
JOIN store_usual  u USING (product_id, store_id)
JOIN week_control c USING (product_id, week)
WHERE c.ctrl_stores >= 3 AND c.ctrl_usual_net_sales > 0 AND c.ctrl_usual_units > 0;

CREATE OR REPLACE TABLE uplift_b_rows AS
SELECT b.*
FROM uplift_b_all b
JOIN product_week_share pw USING (product_id, week)
WHERE pw.stores_promoted <= 0.5 * pw.stores_selling AND b.ctrl_stores >= 10;

-- ---------------------------------------------------------------------
-- Results
-- ---------------------------------------------------------------------
-- @q u01_coverage  (how many promoted rows each method can evaluate)
SELECT 'promoted product-store-weeks, full promotions table (112 stores, weeks 2-53)' AS item,
       (SELECT COUNT(*) FROM promo_flags f JOIN week_calendar w USING (week)
        WHERE w.in_scope AND (f.on_display OR f.in_mailer)) AS n
UNION ALL SELECT '... of which in the spine (pair bought at least once)', (SELECT COUNT(*) FROM promo_rows)
UNION ALL SELECT '... evaluable by method A (4 clean prior weeks within 12)', (SELECT COUNT(*) FROM uplift_a)
UNION ALL SELECT '... with usual sales and 3+ control stores (B, before validity rule)', (SELECT COUNT(*) FROM uplift_b_all)
UNION ALL SELECT '... evaluable by method B (<= half of stores promoted, 10+ controls)', (SELECT COUNT(*) FROM uplift_b_rows)
UNION ALL SELECT '... evaluable by both', (SELECT COUNT(*) FROM uplift_a a JOIN uplift_b_rows b USING (product_id, store_id, week));

-- @q u02_uplift_by_type  (ratio of sums; holiday weeks excluded / included)
WITH a AS (
    SELECT promo_type, holiday_week, SUM(net_sales) AS act, SUM(base_net_sales) AS exp,
           SUM(units) AS act_u, SUM(base_units) AS exp_u, COUNT(*) AS n
    FROM uplift_a GROUP BY ALL
), b AS (
    SELECT promo_type, holiday_week, SUM(net_sales) AS act, SUM(expected_net_sales) AS exp,
           SUM(units) AS act_u, SUM(expected_units) AS exp_u, COUNT(*) AS n
    FROM uplift_b_rows GROUP BY ALL
), both_m AS (
    SELECT 'A: time baseline' AS method, * FROM a UNION ALL SELECT 'B: control stores', * FROM b
)
SELECT method, promo_type,
       SUM(n) FILTER (WHERE NOT holiday_week)                                   AS rows_excl_holiday,
       ROUND(100 * (SUM(act) FILTER (WHERE NOT holiday_week)
                  / SUM(exp) FILTER (WHERE NOT holiday_week) - 1), 1)          AS uplift_net_sales_pct_excl_holiday,
       ROUND(100 * (SUM(act_u) FILTER (WHERE NOT holiday_week)
                  / SUM(exp_u) FILTER (WHERE NOT holiday_week) - 1), 1)        AS uplift_units_pct_excl_holiday,
       ROUND(100 * (SUM(act) / SUM(exp) - 1), 1)                               AS uplift_net_sales_pct_all_weeks,
       ROUND(SUM(act) FILTER (WHERE NOT holiday_week)
           - SUM(exp) FILTER (WHERE NOT holiday_week))                          AS extra_net_sales_excl_holiday
FROM both_m
GROUP BY method, promo_type
ORDER BY promo_type, method;

-- @q u03_same_rows  (both methods on the identical set of promoted rows, non-holiday)
SELECT a.promo_type, COUNT(*) AS rows,
       ROUND(100 * (SUM(a.net_sales) / SUM(a.base_net_sales) - 1), 1)      AS uplift_A_pct,
       ROUND(100 * (SUM(b.net_sales) / SUM(b.expected_net_sales) - 1), 1)  AS uplift_B_pct
FROM uplift_a a JOIN uplift_b_rows b USING (product_id, store_id, week)
WHERE NOT a.holiday_week
GROUP BY a.promo_type ORDER BY a.promo_type;

-- @q u04_uplift_by_department  (method A vs B, non-holiday, departments with >= 2,000 rows in both)
WITH a AS (SELECT department, SUM(net_sales) act, SUM(base_net_sales) exp, COUNT(*) n
           FROM uplift_a WHERE NOT holiday_week GROUP BY ALL),
     b AS (SELECT department, SUM(net_sales) act, SUM(expected_net_sales) exp, COUNT(*) n
           FROM uplift_b_rows WHERE NOT holiday_week GROUP BY ALL)
SELECT department, a.n AS rows_A, ROUND(100 * (a.act / a.exp - 1), 1) AS uplift_A_pct,
       b.n AS rows_B, ROUND(100 * (b.act / b.exp - 1), 1) AS uplift_B_pct
FROM a JOIN b USING (department)
WHERE a.n >= 2000 AND b.n >= 2000
ORDER BY uplift_A_pct DESC;

-- @q u05_inshelf_sensitivity  (method A, non-holiday: baseline weeks with an in-shelf tag removed)
WITH base2 AS (
    SELECT product_id, store_id, week,
           AVG(net_sales) OVER w4 AS base_net_sales, COUNT(*) OVER w4 AS n4, MIN(week) OVER w4 AS w0
    FROM base_weeks WHERE NOT in_shelf_tag
    WINDOW w4 AS (PARTITION BY product_id, store_id ORDER BY week ROWS BETWEEN 3 PRECEDING AND CURRENT ROW)
), j AS (
    SELECT r.promo_type, r.net_sales, b.base_net_sales
    FROM promo_rows r ASOF JOIN base2 b
      ON r.product_id = b.product_id AND r.store_id = b.store_id AND r.week > b.week
    WHERE b.n4 = 4 AND r.week - b.w0 <= 12 AND NOT r.holiday_week
)
SELECT promo_type, COUNT(*) AS rows, ROUND(100 * (SUM(net_sales) / SUM(base_net_sales) - 1), 1) AS uplift_A_pct_no_inshelf_baseline
FROM j GROUP BY promo_type ORDER BY promo_type;

-- @q u06_loyalty_depth_description  (descriptive only: depth is observed only when something sold)
SELECT promo_type,
       ROUND(100 * SUM(loyalty_disc) / NULLIF(SUM(shelf_sales), 0), 1) AS avg_loyalty_depth_pct_of_shelf_value,
       COUNT(*) FILTER (WHERE units > 0) AS rows_with_sale
FROM spine GROUP BY promo_type ORDER BY promo_type;

-- @q u07_why_B_fails_for_mailers  (share of selling stores promoted, and the control index, by type)
SELECT r.promo_type,
       ROUND(MEDIAN(pw.stores_promoted * 1.0 / pw.stores_selling), 3) AS median_share_of_stores_promoted,
       ROUND(MEDIAN(b.ctrl_stores), 0)                                  AS median_control_stores,
       ROUND(SUM(b.ctrl_net_sales) / SUM(b.ctrl_usual_net_sales), 2)    AS control_stores_actual_vs_usual,
       ROUND(100 * (SUM(b.net_sales) / SUM(b.expected_net_sales) - 1), 0) AS naive_uplift_B_pct
FROM promo_rows r
JOIN product_week_share pw USING (product_id, week)
LEFT JOIN (SELECT u.*, c.ctrl_net_sales, c.ctrl_usual_net_sales
           FROM uplift_b_all u JOIN week_control c USING (product_id, week)) b USING (product_id, store_id, week)
WHERE NOT r.holiday_week
GROUP BY r.promo_type ORDER BY r.promo_type;
