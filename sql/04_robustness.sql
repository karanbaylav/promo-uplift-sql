-- =====================================================================
-- Promotion uplift  |  04 — Robustness: B sensitivity, method C for mailers,
--                         placebo tests, week-to-week ranges
-- Requires sql/03_uplift.sql. All uplift = ratio of sums.
-- =====================================================================
SET preserve_insertion_order = false;
SET temp_directory = 'tmp_duckdb';
SET threads = 2;

-- ---------------------------------------------------------------------
-- METHOD C (mailers): product-week level, all stores together, against a control
-- built from UNPROMOTED products in OTHER categories of the SAME department, same week.
-- Each product is measured against its own baseline (last 4 clean weeks within 12).
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE pw_panel AS
SELECT s.product_id, s.week, p.department, p.product_category,
       SUM(s.net_sales) AS net_sales, SUM(s.units) AS units,
       COUNT(*) AS stores_selling,
       AVG(s.in_mailer::INT)  AS share_mailer,
       AVG(s.on_display::INT) AS share_display,
       w.holiday IS NOT NULL  AS holiday_week
FROM spine s JOIN products p USING (product_id) JOIN week_calendar w USING (week)
GROUP BY ALL;

CREATE OR REPLACE TABLE pw_status AS
SELECT *,
       CASE WHEN share_mailer >= 0.5 THEN 'mailer'          -- in the mailer in most stores
            WHEN share_mailer = 0 AND share_display = 0 THEN 'clean'
            ELSE 'mixed' END AS status
FROM pw_panel;

CREATE OR REPLACE TABLE pw_base_roll AS
SELECT product_id, week,
       AVG(net_sales) OVER w4 AS base, COUNT(*) OVER w4 AS n4, MIN(week) OVER w4 AS w0
FROM pw_status
WHERE status = 'clean' AND NOT holiday_week
WINDOW w4 AS (PARTITION BY product_id ORDER BY week ROWS BETWEEN 3 PRECEDING AND CURRENT ROW);

-- every product-week with its own baseline from strictly earlier clean weeks
CREATE OR REPLACE TABLE pw_with_base AS
SELECT s.*, b.base
FROM pw_status s
ASOF JOIN pw_base_roll b ON s.product_id = b.product_id AND s.week > b.week
WHERE b.n4 = 4 AND s.week - b.w0 <= 12;   -- zero baselines kept: dropping them selects on recent sales (regression to the mean)

-- control sums: clean, non-holiday product-weeks, by department x category x week
CREATE OR REPLACE TABLE pw_ctrl_cat AS
SELECT department, product_category, week,
       SUM(net_sales) AS act, SUM(base) AS exp, COUNT(*) AS n
FROM pw_with_base WHERE status = 'clean' AND NOT holiday_week
GROUP BY ALL;

CREATE OR REPLACE TABLE pw_ctrl_dept AS
SELECT department, week, SUM(act) AS act, SUM(exp) AS exp, SUM(n) AS n
FROM pw_ctrl_cat GROUP BY ALL;

-- control index for (department, week) EXCLUDING the product's own category
CREATE OR REPLACE MACRO ctrl_index(dept, cat, wk) AS (
    SELECT (d.act - COALESCE(c.act, 0)) / NULLIF(d.exp - COALESCE(c.exp, 0), 0)
    FROM pw_ctrl_dept d
    LEFT JOIN pw_ctrl_cat c ON c.department = d.department AND c.week = d.week AND c.product_category = cat
    WHERE d.department = dept AND d.week = wk
);

CREATE OR REPLACE TABLE uplift_c_rows AS
SELECT r.*, (d.act - COALESCE(c.act, 0)) / NULLIF(d.exp - COALESCE(c.exp, 0), 0) AS ctrl_index,
       d.n - COALESCE(c.n, 0) AS ctrl_products
FROM pw_with_base r
JOIN pw_ctrl_dept d USING (department, week)
LEFT JOIN pw_ctrl_cat c USING (department, product_category, week)
WHERE r.status = 'mailer' AND NOT r.holiday_week
  AND d.n - COALESCE(c.n, 0) >= 20;

-- @r r01_B_sensitivity  (display only, non-holiday: max share of stores promoted x min control stores)
WITH grid AS (
    SELECT * FROM (VALUES (0.3), (0.5), (0.7)) a(max_share)
    CROSS JOIN (VALUES (5), (10), (20)) b(min_ctrl)
)
SELECT g.max_share, g.min_ctrl, COUNT(*) AS rows,
       ROUND(100 * (SUM(b.net_sales) / SUM(b.expected_net_sales) - 1), 1) AS uplift_B_display_pct
FROM grid g
JOIN uplift_b_all b ON b.promo_type = 'display only' AND NOT b.holiday_week AND b.ctrl_stores >= g.min_ctrl
JOIN product_week_share pw USING (product_id, week)
WHERE pw.stores_promoted <= g.max_share * pw.stores_selling
GROUP BY g.max_share, g.min_ctrl
ORDER BY g.max_share, g.min_ctrl;

-- @r r02_method_C_mailers  (A at product-week level vs C with other-category control)
SELECT COUNT(*) AS mailer_product_weeks,
       ROUND(100 * (SUM(net_sales) / SUM(base) - 1), 1)                AS uplift_A_productweek_pct,
       ROUND(100 * (SUM(net_sales) / SUM(base * ctrl_index) - 1), 1)   AS uplift_C_pct,
       ROUND(SUM(base * ctrl_index) / SUM(base), 3)                    AS avg_control_index,
       ROUND(MEDIAN(ctrl_products))                                     AS median_control_products
FROM uplift_c_rows;

-- @r r03_placebo  (fake promotions on non-promoted weeks: uplift should be near 0)
WITH a_all_clean AS (           -- A: every clean, non-holiday product-store week with a valid baseline
    SELECT SUM(s.net_sales) AS act, SUM(b.base_net_sales) AS exp, COUNT(*) AS n
    FROM base_weeks s
    ASOF JOIN base_roll b ON s.product_id = b.product_id AND s.store_id = b.store_id AND s.week > b.week
    WHERE b.n_base_weeks = 4 AND s.week - b.first_base_week <= 12
),
a_pre_promo AS (                -- A: the clean week just BEFORE a real promotion, by the type that follows
    SELECT nxt.promo_type, SUM(s.net_sales) AS act, SUM(b.base_net_sales) AS exp, COUNT(*) AS n
    FROM base_weeks s
    JOIN promo_rows nxt ON nxt.product_id = s.product_id AND nxt.store_id = s.store_id AND nxt.week = s.week + 1
    ASOF JOIN base_roll b ON s.product_id = b.product_id AND s.store_id = b.store_id AND s.week > b.week
    WHERE b.n_base_weeks = 4 AND s.week - b.first_base_week <= 12
    GROUP BY nxt.promo_type
),
c_pre_mailer AS (               -- C: the clean product-week just before a mailer week
    SELECT SUM(r.net_sales) AS act,
           SUM(r.base * (d.act - COALESCE(c.act, 0) - r.net_sales) / NULLIF(d.exp - COALESCE(c.exp, 0) - r.base, 0)) AS exp,
           COUNT(*) AS n
    FROM pw_with_base r
    JOIN pw_status nxt ON nxt.product_id = r.product_id AND nxt.week = r.week + 1 AND nxt.status = 'mailer'
    JOIN pw_ctrl_dept d ON d.department = r.department AND d.week = r.week
    LEFT JOIN pw_ctrl_cat c ON c.department = r.department AND c.product_category = r.product_category AND c.week = r.week
    WHERE r.status = 'clean' AND NOT r.holiday_week AND d.n - COALESCE(c.n, 0) >= 20
),
b_fake AS (                     -- B: in product-weeks with NO promotion anywhere, half the stores are "treated" at random
    SELECT s.product_id, s.store_id, s.week, s.net_sales, u.usual_net_sales,
           HASH(s.product_id, s.store_id, s.week) % 2 = 0 AS fake_treated
    FROM spine s
    JOIN store_usual u USING (product_id, store_id)
    JOIN product_week_share pw USING (product_id, week)
    JOIN week_calendar w USING (week)
    WHERE pw.stores_promoted = 0 AND w.holiday IS NULL
),
b_ctrl AS (
    SELECT product_id, week, SUM(net_sales) AS c_act, SUM(usual_net_sales) AS c_usual, COUNT(*) AS n_ctrl
    FROM b_fake WHERE NOT fake_treated GROUP BY ALL
),
b_res AS (
    SELECT SUM(f.net_sales) AS act, SUM(f.usual_net_sales * c.c_act / c.c_usual) AS exp, COUNT(*) AS n
    FROM b_fake f JOIN b_ctrl c USING (product_id, week)
    WHERE f.fake_treated AND c.n_ctrl >= 10 AND c.c_usual > 0
),
c_fake AS (                     -- C: clean product-weeks treated as if they were in the mailer
    SELECT SUM(r.net_sales) AS act,
           SUM(r.base * (d.act - COALESCE(c.act, 0) - r.net_sales) / NULLIF(d.exp - COALESCE(c.exp, 0) - r.base, 0)) AS exp,
           COUNT(*) AS n
    FROM pw_with_base r
    JOIN pw_ctrl_dept d USING (department, week)
    LEFT JOIN pw_ctrl_cat c USING (department, product_category, week)
    WHERE r.status = 'clean' AND NOT r.holiday_week AND d.n - COALESCE(c.n, 0) >= 20
)
SELECT 'A: all clean weeks as fake promotions' AS placebo, n AS rows, ROUND(100 * (act / exp - 1), 1) AS uplift_pct FROM a_all_clean
UNION ALL SELECT 'A: clean week just before a ' || promo_type || ' week', n, ROUND(100 * (act / exp - 1), 1) FROM a_pre_promo
UNION ALL SELECT 'B: random half of stores in unpromoted product-weeks', n, ROUND(100 * (act / exp - 1), 1) FROM b_res
UNION ALL SELECT 'C: clean product-weeks vs other-category control', n, ROUND(100 * (act / exp - 1), 1) FROM c_fake
UNION ALL SELECT 'C: clean product-week just before a mailer week', n, ROUND(100 * (act / exp - 1), 1) FROM c_pre_mailer;

-- @r r04_week_ranges  (ratio of sums per week, then median and spread across weeks; weeks with >= 200 rows)
WITH a AS (SELECT 'A' AS m, promo_type, week, SUM(net_sales) / SUM(base_net_sales) - 1 AS u, COUNT(*) AS n
           FROM uplift_a WHERE NOT holiday_week GROUP BY ALL),
     b AS (SELECT 'B', promo_type, week, SUM(net_sales) / SUM(expected_net_sales) - 1, COUNT(*)
           FROM uplift_b_rows WHERE NOT holiday_week GROUP BY ALL),
     c AS (SELECT 'C', 'mailer (product-week)', week, SUM(net_sales) / SUM(base * ctrl_index) - 1, COUNT(*)
           FROM uplift_c_rows GROUP BY ALL),
     wk AS (SELECT * FROM a UNION ALL SELECT * FROM b UNION ALL SELECT * FROM c)
SELECT m AS method, promo_type, COUNT(*) AS weeks,
       ROUND(100 * MEDIAN(u), 1)                AS median_weekly_uplift_pct,
       ROUND(100 * QUANTILE_CONT(u, 0.25), 1)   AS p25,
       ROUND(100 * QUANTILE_CONT(u, 0.75), 1)   AS p75,
       ROUND(100 * MIN(u), 1)                   AS min_pct,
       ROUND(100 * MAX(u), 1)                   AS max_pct
FROM wk WHERE n >= 200 OR m = 'C'
GROUP BY m, promo_type ORDER BY promo_type, m;

-- @r r05_quarter_ranges  (ratio of sums per quarter)
WITH q AS (SELECT week, CASE WHEN week <= 14 THEN 'Q1' WHEN week <= 27 THEN 'Q2' WHEN week <= 40 THEN 'Q3' ELSE 'Q4' END AS quarter
           FROM week_calendar WHERE in_scope)
SELECT 'A' AS method, a.promo_type, q.quarter, COUNT(*) AS rows,
       ROUND(100 * (SUM(a.net_sales) / SUM(a.base_net_sales) - 1), 1) AS uplift_pct
FROM uplift_a a JOIN q USING (week) WHERE NOT a.holiday_week GROUP BY ALL
UNION ALL
SELECT 'B', b.promo_type, q.quarter, COUNT(*), ROUND(100 * (SUM(b.net_sales) / SUM(b.expected_net_sales) - 1), 1)
FROM uplift_b_rows b JOIN q USING (week) WHERE NOT b.holiday_week AND b.promo_type = 'display only' GROUP BY ALL
UNION ALL
SELECT 'C', 'mailer (product-week)', q.quarter, COUNT(*), ROUND(100 * (SUM(c.net_sales) / SUM(c.base * c.ctrl_index) - 1), 1)
FROM uplift_c_rows c JOIN q USING (week) GROUP BY ALL
ORDER BY 2, 1, 3;

-- @r r06_chronic_promotions  (promoted rows method A cannot evaluate, and why)
SELECT r.promo_type, COUNT(*) AS promoted_rows,
       ROUND(100.0 * AVG((a.n_base_weeks = 4 AND a.week - a.first_base_week <= 12)::INT), 1) AS pct_evaluable_by_A,
       ROUND(100.0 * AVG((a.n_base_weeks IS NULL)::INT), 1)  AS pct_no_clean_week_before,
       ROUND(100.0 * AVG((a.n_base_weeks < 4)::INT), 1)       AS pct_fewer_than_4_clean,
       ROUND(100.0 * AVG((a.n_base_weeks = 4 AND a.week - a.first_base_week > 12)::INT), 1) AS pct_clean_weeks_too_old
FROM promo_rows r
JOIN uplift_a_rows a USING (product_id, store_id, week)
WHERE NOT r.holiday_week
GROUP BY r.promo_type ORDER BY r.promo_type;
