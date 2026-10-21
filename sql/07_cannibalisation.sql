-- =====================================================================
-- Promotion uplift  |  07 — Step 4: cannibalisation (same event-study design)
-- While product p is on display in store s, do the OTHER products of p's category in
-- store s sell less than the same products in control stores (stores not promoting p
-- that week), relative to each store's usual level?
-- "Other products" = the category total minus p (all other products, promoted or not;
-- other promotions run in control stores too, mostly chain-wide mailers).
-- =====================================================================
SET preserve_insertion_order = false;
SET temp_directory = 'tmp_duckdb';
SET threads = 2;

-- category x store x week totals (spine, so weeks with no sale are zeros)
CREATE OR REPLACE TABLE cat_store_week AS
SELECT p.product_category, s.store_id, s.week,
       SUM(s.net_sales) AS cat_net, SUM(s.shelf_sales) AS cat_shelf
FROM spine s JOIN products p USING (product_id)
GROUP BY ALL;

-- usual weekly level (non-holiday weeks) of the category in a store, and of each product in a store
CREATE OR REPLACE TABLE cat_store_usual AS
SELECT c.product_category, c.store_id, AVG(c.cat_net) AS usual_cat_net
FROM cat_store_week c JOIN week_calendar w USING (week)
WHERE w.holiday IS NULL GROUP BY ALL;

CREATE OR REPLACE TABLE prod_store_mean AS
SELECT s.product_id, s.store_id, AVG(s.net_sales) AS mean_net, AVG(s.shelf_sales) AS mean_shelf
FROM spine s JOIN week_calendar w USING (week)
WHERE w.holiday IS NULL GROUP BY ALL;

-- event rows for the OTHER products of the category, for every usable display episode
CREATE OR REPLACE TABLE cannib_rows AS
WITH ep AS (
    SELECT e.*, p.product_category FROM episodes_ok e JOIN products p USING (product_id)
), ev AS (
    SELECT ep.*, k.k, 'pre' AS phase, ep.start_week + k.k AS week FROM ep CROSS JOIN (VALUES (-4),(-3),(-2),(-1)) k(k)
    UNION ALL
    SELECT ep.*, r.k, 'run', ep.start_week + r.k - 1 FROM ep CROSS JOIN range(1, 21) r(k) WHERE r.k <= ep.run_weeks
    UNION ALL
    SELECT ep.*, q.k, 'post', ep.end_week + q.k FROM ep CROSS JOIN (VALUES (1),(2),(3),(4)) q(k)
), treated AS (     -- others in the treated store = category total minus p
    SELECT ev.product_id, ev.store_id, ev.product_category, ev.phase, ev.k, ev.week,
           cw.cat_net - sp.net_sales                 AS others_net,
           cu.usual_cat_net - pm.mean_net            AS others_usual
    FROM ev
    JOIN cat_store_week cw  ON cw.product_category = ev.product_category AND cw.store_id = ev.store_id AND cw.week = ev.week
    JOIN cat_store_usual cu ON cu.product_category = ev.product_category AND cu.store_id = ev.store_id
    JOIN spine sp           ON sp.product_id = ev.product_id AND sp.store_id = ev.store_id AND sp.week = ev.week
    JOIN prod_store_mean pm ON pm.product_id = ev.product_id AND pm.store_id = ev.store_id
), ctrl AS (        -- the same "others" in control stores: stores that sell p and do not promote it that week
    SELECT sp.product_id, sp.week,
           SUM(cw.cat_net - sp.net_sales)            AS ctrl_others_net,
           SUM(cu.usual_cat_net - pm.mean_net)       AS ctrl_others_usual,
           COUNT(*)                                  AS n_ctrl
    FROM spine sp
    JOIN products p         ON p.product_id = sp.product_id
    JOIN cat_store_week cw  ON cw.product_category = p.product_category AND cw.store_id = sp.store_id AND cw.week = sp.week
    JOIN cat_store_usual cu ON cu.product_category = p.product_category AND cu.store_id = sp.store_id
    JOIN prod_store_mean pm ON pm.product_id = sp.product_id AND pm.store_id = sp.store_id
    WHERE sp.promo_type = 'none'
      AND sp.product_id IN (SELECT DISTINCT product_id FROM episodes_ok)
    GROUP BY ALL
)
SELECT t.*,
       -- remove the treated store from its own control group when it is unpromoted that week
       (c.ctrl_others_net - CASE WHEN sp.promo_type = 'none' THEN t.others_net ELSE 0 END)
         / NULLIF(c.ctrl_others_usual - CASE WHEN sp.promo_type = 'none' THEN t.others_usual ELSE 0 END, 0) AS ctrl_index,
       c.n_ctrl - CASE WHEN sp.promo_type = 'none' THEN 1 ELSE 0 END AS n_ctrl
FROM treated t
JOIN ctrl c   ON c.product_id = t.product_id AND c.week = t.week
JOIN spine sp ON sp.product_id = t.product_id AND sp.store_id = t.store_id AND sp.week = t.week;

-- @c c01_others_event_study  (other products of the category vs control stores, by event week)
SELECT CASE WHEN phase = 'pre' THEN 'start ' || k WHEN phase = 'run' THEN CASE WHEN k >= 3 THEN 'run week 3+' ELSE 'run week ' || k END ELSE 'end +' || k END AS event_time,
       MIN(CASE WHEN phase = 'pre' THEN k WHEN phase = 'run' THEN LEAST(k, 3) - 1 ELSE 3 + k END) AS sort_key,
       COUNT(*) AS rows,
       ROUND(100 * (SUM(others_net) / SUM(others_usual * ctrl_index) - 1), 2) AS others_vs_controls_pct,
       ROUND(SUM(others_net - others_usual * ctrl_index)) AS others_change_net_sales
FROM cannib_rows
WHERE n_ctrl >= 10 AND ctrl_index IS NOT NULL AND others_usual > 0
GROUP BY event_time ORDER BY sort_key;

-- @c c02_net_category_effect  (run weeks: promoted product gain vs change in the rest of the category)
WITH prod AS (
    SELECT SUM(net_sales - usual_net_sales * ctrl_index) AS gain, SUM(usual_net_sales * ctrl_index) AS base
    FROM event_rows WHERE phase = 'run' AND ctrl_stores >= 10 AND ctrl_index IS NOT NULL
), oth AS (
    SELECT SUM(others_net - others_usual * ctrl_index) AS change, SUM(others_usual * ctrl_index) AS base
    FROM cannib_rows WHERE phase = 'run' AND n_ctrl >= 10 AND ctrl_index IS NOT NULL AND others_usual > 0
)
SELECT ROUND(prod.gain)                              AS promoted_product_gain,
       ROUND(oth.change)                             AS rest_of_category_change,
       ROUND(prod.gain + oth.change)                 AS net_category_change,
       ROUND(100 * -oth.change / prod.gain, 1)       AS pct_of_gain_taken_from_rest_of_category,
       ROUND(100 * oth.change / oth.base, 2)         AS rest_of_category_change_pct
FROM prod, oth;
