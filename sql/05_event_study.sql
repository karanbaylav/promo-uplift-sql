-- =====================================================================
-- Promotion uplift  |  05 — Step 3: display event study with method B
-- Episode = consecutive display-only weeks for a product in a store.
-- Each event week compares the store with control stores (same product, same week,
-- not promoted), scaled by each store's usual sales. The store itself is never in its
-- own control group. Ratio of sums throughout.
-- Requires sql/03_uplift.sql (spine, store_usual, week_control, product_week_share).
-- =====================================================================
SET preserve_insertion_order = false;
SET temp_directory = 'tmp_duckdb';
SET threads = 2;

-- 1. Episodes: gaps-and-islands on display-only weeks
CREATE OR REPLACE TABLE display_episodes AS
WITH d AS (
    SELECT product_id, store_id, week,
           week - ROW_NUMBER() OVER (PARTITION BY product_id, store_id ORDER BY week) AS grp
    FROM spine
    WHERE promo_type = 'display only'
)
SELECT product_id, store_id, MIN(week) AS start_week, MAX(week) AS end_week, COUNT(*) AS run_weeks
FROM d GROUP BY product_id, store_id, grp;

-- 2. Usable episodes: an isolated run (no promotion of any kind for that product in that store in the
--    4 weeks before or after), the whole window in weeks 2-53 with no holiday week, the store has
--    usual sales, and B's validity rule holds at the start week.
CREATE OR REPLACE TABLE episodes_ok AS
SELECT e.*
FROM display_episodes e
JOIN store_usual u USING (product_id, store_id)
JOIN product_week_share pw ON pw.product_id = e.product_id AND pw.week = e.start_week
JOIN week_control c       ON c.product_id = e.product_id  AND c.week = e.start_week
WHERE e.start_week - 4 >= 2 AND e.end_week + 4 <= 53
  AND pw.stores_promoted <= 0.5 * pw.stores_selling AND c.ctrl_stores >= 10
  AND NOT EXISTS (SELECT 1 FROM spine s
                  WHERE s.product_id = e.product_id AND s.store_id = e.store_id
                    AND s.promo_type <> 'none'
                    AND (s.week BETWEEN e.start_week - 4 AND e.start_week - 1
                         OR s.week BETWEEN e.end_week + 1 AND e.end_week + 4))
  AND NOT EXISTS (SELECT 1 FROM week_calendar w
                  WHERE w.holiday IS NOT NULL AND w.week BETWEEN e.start_week - 4 AND e.end_week + 4);

-- 3. Event rows: 4 weeks before the start, run weeks 1, 2, 3+ and 4 weeks after the end
CREATE OR REPLACE TABLE event_rows AS
WITH ev AS (
    SELECT e.*, k.k, 'pre' AS phase, e.start_week + k.k AS week, k.k AS event_order
    FROM episodes_ok e CROSS JOIN (VALUES (-4), (-3), (-2), (-1)) k(k)
    UNION ALL
    SELECT e.*, r.k, 'run', e.start_week + r.k - 1, r.k - 1
    FROM episodes_ok e CROSS JOIN range(1, 21) r(k)
    WHERE r.k <= e.run_weeks
    UNION ALL
    SELECT e.*, p.k, 'post', e.end_week + p.k, 100 + p.k
    FROM episodes_ok e CROSS JOIN (VALUES (1), (2), (3), (4)) p(k)
)
SELECT ev.product_id, ev.store_id, ev.start_week, ev.run_weeks, ev.phase, ev.k, ev.week,
       CASE WHEN ev.phase = 'pre'  THEN 'start ' || ev.k
            WHEN ev.phase = 'run'  THEN CASE WHEN ev.k >= 3 THEN 'run week 3+' ELSE 'run week ' || ev.k END
            ELSE 'end +' || ev.k END                         AS event_time,
       CASE WHEN ev.phase = 'pre' THEN ev.k WHEN ev.phase = 'run' THEN LEAST(ev.k, 3) - 1 ELSE 3 + ev.k END AS sort_key,
       s.net_sales, s.units, s.promo_type,
       u.usual_net_sales,
       -- control = non-promoted stores that week, minus this store if it is among them
       (c.ctrl_net_sales - CASE WHEN s.promo_type = 'none' THEN s.net_sales ELSE 0 END)
         / NULLIF(c.ctrl_usual_net_sales - CASE WHEN s.promo_type = 'none' THEN u.usual_net_sales ELSE 0 END, 0) AS ctrl_index,
       c.ctrl_stores - CASE WHEN s.promo_type = 'none' THEN 1 ELSE 0 END AS ctrl_stores
FROM ev
JOIN spine s        USING (product_id, store_id, week)
JOIN store_usual u  USING (product_id, store_id)
JOIN week_control c USING (product_id, week);

-- @e e01_episodes  (what the event study covers)
SELECT (SELECT COUNT(*) FROM display_episodes) AS all_display_episodes,
       (SELECT COUNT(*) FROM episodes_ok)      AS usable_episodes,
       (SELECT ROUND(AVG(run_weeks), 2) FROM episodes_ok) AS avg_run_weeks,
       (SELECT ROUND(100.0 * AVG((run_weeks = 1)::INT), 1) FROM episodes_ok) AS pct_one_week_runs;

-- @e e02_event_study  (B uplift by week relative to the episode; pre-trend = 'start -1')
SELECT event_time, MIN(sort_key) AS sort_key, COUNT(*) AS rows,
       ROUND(100 * (SUM(net_sales) / SUM(usual_net_sales * ctrl_index) - 1), 1) AS uplift_vs_controls_pct,
       ROUND(SUM(net_sales) - SUM(usual_net_sales * ctrl_index))               AS extra_net_sales
FROM event_rows
WHERE ctrl_stores >= 10 AND ctrl_index IS NOT NULL
GROUP BY event_time ORDER BY sort_key;

-- @e e03_pre_trend_by_quarter  (week before the start, by quarter of the start week: is it stable?)
SELECT CASE WHEN start_week <= 14 THEN 'Q1' WHEN start_week <= 27 THEN 'Q2' WHEN start_week <= 40 THEN 'Q3' ELSE 'Q4' END AS quarter,
       COUNT(*) AS rows,
       ROUND(100 * (SUM(net_sales) / SUM(usual_net_sales * ctrl_index) - 1), 1) AS start_minus_1_pct
FROM event_rows
WHERE event_time = 'start -1' AND ctrl_stores >= 10 AND ctrl_index IS NOT NULL
GROUP BY 1 ORDER BY 1;

-- @e e04_net_effect  (episode total: extra sales during the run plus the 4 weeks after the end)
SELECT ROUND(SUM(net_sales - usual_net_sales * ctrl_index) FILTER (WHERE phase = 'run'))  AS extra_during_run,
       ROUND(SUM(net_sales - usual_net_sales * ctrl_index) FILTER (WHERE phase = 'post')) AS change_after_end,
       ROUND(SUM(net_sales - usual_net_sales * ctrl_index) FILTER (WHERE phase = 'pre'))  AS change_before_start,
       ROUND(100 * SUM(net_sales - usual_net_sales * ctrl_index) FILTER (WHERE phase = 'post')
             / NULLIF(SUM(net_sales - usual_net_sales * ctrl_index) FILTER (WHERE phase = 'run'), 0), 1) AS post_as_pct_of_run_gain
FROM event_rows
WHERE ctrl_stores >= 10 AND ctrl_index IS NOT NULL;
