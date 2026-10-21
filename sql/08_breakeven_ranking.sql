-- =====================================================================
-- Promotion uplift  |  08 — Step 5 break-even scenarios and step 6 ranking (displays)
-- No cost data: profit is NOT claimed. Gross margins of 20%, 30% and 40% (on the
-- regular shelf price) are SCENARIOS, not data. Cost of goods = (1 - margin) x shelf value,
-- so deeper loyalty discounts during a display are charged against the gain.
-- Lower bound: expected sales scaled up by the week-before jump (+21%, all of it treated as
-- targeting). Upper bound: method B as measured.
-- =====================================================================
SET preserve_insertion_order = false;
SET temp_directory = 'tmp_duckdb';
SET threads = 2;

-- usual shelf value per product-store (clean, non-holiday weeks), to price the expected units
CREATE OR REPLACE TABLE store_usual_shelf AS
SELECT b.product_id, b.store_id, AVG(s.shelf_sales) AS usual_shelf_sales
FROM base_weeks b JOIN spine s USING (product_id, store_id, week)
GROUP BY ALL;

CREATE OR REPLACE TABLE run_rows AS
SELECT r.product_id, r.store_id, r.start_week, r.week, p.department, p.product_category,
       r.net_sales, s.shelf_sales,
       r.usual_net_sales * r.ctrl_index      AS exp_net,
       us.usual_shelf_sales * r.ctrl_index   AS exp_shelf
FROM event_rows r
JOIN spine s              USING (product_id, store_id, week)
JOIN store_usual_shelf us USING (product_id, store_id)
JOIN products p           USING (product_id)
WHERE r.phase = 'run' AND r.ctrl_stores >= 10 AND r.ctrl_index IS NOT NULL;

-- the week-before jump used for the lower bound
CREATE OR REPLACE TABLE pre_jump AS
SELECT SUM(net_sales) / SUM(usual_net_sales * ctrl_index) AS f
FROM event_rows WHERE event_time = 'start -1' AND ctrl_stores >= 10 AND ctrl_index IS NOT NULL;

-- @b b01_breakeven  (the extra margin covers a display if one display-week costs less than X% of the product's normal weekly net sales; scenarios, not profit)
WITH t AS (
    SELECT SUM(net_sales) AS net, SUM(shelf_sales) AS shelf, SUM(exp_net) AS exp_net, SUM(exp_shelf) AS exp_shelf
    FROM run_rows
), m AS (SELECT * FROM (VALUES (0.20), (0.30), (0.40)) v(margin)),
b AS (SELECT 'upper (B as measured)' AS bound, 1.0 AS scale UNION ALL SELECT 'lower (week-before jump = targeting)', (SELECT f FROM pre_jump))
SELECT b.bound, m.margin AS gross_margin_scenario,
       ROUND(100 * (t.net / (t.exp_net * b.scale) - 1), 1) AS net_sales_uplift_pct,
       ROUND(100 * (t.shelf / (t.exp_shelf * b.scale) - 1), 1) AS shelf_value_uplift_pct,
       ROUND(100 * ((t.net - t.exp_net * b.scale) - (1 - m.margin) * (t.shelf - t.exp_shelf * b.scale))
                 / (t.exp_net * b.scale), 1) AS breakeven_cost_pct_of_normal_weekly_sales
FROM t, m, b
ORDER BY b.bound DESC, m.margin;

-- @b b02_department_counts  (how many usable episodes each department / category has)
SELECT department, COUNT(DISTINCT (product_id, store_id, start_week)) AS episodes, COUNT(*) AS run_weeks
FROM run_rows GROUP BY department ORDER BY episodes DESC;

-- @b b03_department_table  (step 6: uplift, discount depth and break-even by department, >= 300 episodes,
--                          bootstrap 90% ranges over episodes are added in python, see notebook)
SELECT department,
       COUNT(DISTINCT (product_id, store_id, start_week))                                   AS episodes,
       ROUND(100 * (SUM(net_sales) / SUM(exp_net) - 1), 1)                                  AS uplift_upper_pct,
       ROUND(100 * (SUM(net_sales) / (SUM(exp_net) * (SELECT f FROM pre_jump)) - 1), 1)     AS uplift_lower_pct,
       ROUND(100 * (1 - SUM(exp_net) / SUM(exp_shelf)), 1)                                  AS usual_discount_pct,
       ROUND(100 * (1 - SUM(net_sales) / SUM(shelf_sales)), 1)                              AS display_discount_pct,
       ROUND(100 * ((SUM(net_sales) - SUM(exp_net)) - 0.7 * (SUM(shelf_sales) - SUM(exp_shelf))) / SUM(exp_net), 1) AS breakeven_30_upper,
       ROUND(100 * ((SUM(net_sales) - SUM(exp_net)) - 0.6 * (SUM(shelf_sales) - SUM(exp_shelf))) / SUM(exp_net), 1) AS breakeven_40_upper
FROM run_rows
GROUP BY department HAVING COUNT(DISTINCT (product_id, store_id, start_week)) >= 300
ORDER BY uplift_upper_pct DESC;
