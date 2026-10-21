-- =====================================================================
-- Promotion uplift  |  06 — Daily check of the week-before jump (display episodes)
-- Each day of weeks -2, -1 and run week 1 is compared with control stores on the
-- same day (same product, stores not promoting it that week), scaled by usual sales.
-- Day-of-week patterns cancel because treated and control stores share them.
-- Early set-up predicts the jump on the last days of week -1, growing into week 1;
-- targeting predicts a jump spread across the whole of week -1.
-- =====================================================================
SET preserve_insertion_order = false;
SET temp_directory = 'tmp_duckdb';
SET threads = 2;

-- daily sales for products that have a usable episode
CREATE OR REPLACE TABLE ep_daily AS
SELECT t.product_id, t.store_id, t.week, ISODOW(t.transaction_timestamp) AS dow, SUM(t.sales_value) AS net_sales
FROM tx_clean t
WHERE t.product_id IN (SELECT DISTINCT product_id FROM episodes_ok)
GROUP BY ALL;

-- control stores' daily sales: stores not promoting the product that week
CREATE OR REPLACE TABLE ctrl_daily AS
SELECT d.product_id, d.week, d.dow, SUM(d.net_sales) AS ctrl_day_sales
FROM ep_daily d
JOIN spine s USING (product_id, store_id, week)
JOIN store_usual u USING (product_id, store_id)
WHERE s.promo_type = 'none'
GROUP BY ALL;

-- event days for weeks -2, -1 and run week 1
CREATE OR REPLACE TABLE event_days AS
WITH ev AS (
    SELECT e.product_id, e.store_id, k.k, e.start_week + k.k AS week
    FROM episodes_ok e CROSS JOIN (VALUES (-2), (-1), (0)) k(k)
), days AS (SELECT * FROM range(1, 8) r(dow))
SELECT ev.product_id, ev.store_id, ev.k, ev.week, days.dow,
       COALESCE(td.net_sales, 0)                                                     AS treated_sales,
       -- control day sales minus this store if it is a control that week
       COALESCE(cd.ctrl_day_sales, 0) - CASE WHEN s.promo_type = 'none' THEN COALESCE(td.net_sales, 0) ELSE 0 END AS ctrl_sales,
       u.usual_net_sales,
       c.ctrl_usual_net_sales - CASE WHEN s.promo_type = 'none' THEN u.usual_net_sales ELSE 0 END             AS ctrl_usual,
       c.ctrl_stores - CASE WHEN s.promo_type = 'none' THEN 1 ELSE 0 END                                      AS n_ctrl
FROM ev CROSS JOIN days
JOIN spine s        ON s.product_id = ev.product_id AND s.store_id = ev.store_id AND s.week = ev.week
JOIN store_usual u  ON u.product_id = ev.product_id AND u.store_id = ev.store_id
JOIN week_control c ON c.product_id = ev.product_id AND c.week = ev.week
LEFT JOIN ep_daily td  ON td.product_id = ev.product_id AND td.store_id = ev.store_id AND td.week = ev.week AND td.dow = days.dow
LEFT JOIN ctrl_daily cd ON cd.product_id = ev.product_id AND cd.week = ev.week AND cd.dow = days.dow;

-- @d d01_daily_uplift  (ratio of sums by event week and weekday; 1 = Monday)
SELECT CASE k WHEN -2 THEN 'week -2' WHEN -1 THEN 'week -1' ELSE 'run week 1' END AS event_week, k, dow,
       COUNT(*) AS episode_days,
       ROUND(100 * (SUM(treated_sales) / SUM(usual_net_sales * ctrl_sales / ctrl_usual) - 1), 1) AS uplift_vs_controls_pct
FROM event_days
WHERE n_ctrl >= 10 AND ctrl_usual > 0
GROUP BY ALL ORDER BY k, dow;

-- @d d02_week_minus1_halves  (first four days vs last three days of week -1)
SELECT CASE WHEN dow <= 4 THEN 'Mon-Thu' ELSE 'Fri-Sun' END AS part_of_week, k,
       ROUND(100 * (SUM(treated_sales) / SUM(usual_net_sales * ctrl_sales / ctrl_usual) - 1), 1) AS uplift_vs_controls_pct
FROM event_days
WHERE n_ctrl >= 10 AND ctrl_usual > 0
GROUP BY ALL ORDER BY k, part_of_week DESC;
