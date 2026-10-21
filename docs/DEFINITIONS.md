# Definitions (agreed before step 1)

## Money columns (verified against the completejourney package documentation)
- `sales_value` = dollars the **retailer receives**, already **after** the loyalty-card discount (`retail_disc`) and the retailer's coupon match (`coupon_match_disc`). It is not the price the customer paid when a manufacturer coupon is used, because the manufacturer reimburses the retailer.
- In this release all discounts are stored as **positive** numbers. The package vignette's worked example adds them back: shelf price = (sales_value + retail_disc) / quantity. So here:
  - `shelf_value = sales_value + retail_disc + coupon_match_disc` (regular shelf price × quantity)
  - retailer-funded discount = `retail_disc + coupon_match_disc`
  - `coupon_disc` (manufacturer coupon) is reimbursed: not a retailer cost.
- **Consequence for step 5:** uplift is measured in `sales_value` (net), so the discount is already inside it. Net extra revenue = promoted-week net sales − baseline net sales, with **no second subtraction** of discount cost. Shelf value and discounts are reported alongside for transparency only.

## Scope
- 112 stores that appear in `promotions` (98.6% of net sales). Elsewhere "not promoted" can't be observed.
- Weeks 2–53 (week 1 is a single day, 1 Jan 2017). Holiday weeks flagged: 48 (Thanksgiving, 23 Nov), 52 (to Christmas Eve), 53 (Christmas to New Year).
- Dropped rows: quantity = 0 (8,773 rows) and value = 0 with quantity > 0 (2,390 rows). There are no negative quantities or values (no returns in this release).

## Promotion
- Promoted product-store-week = on a secondary **display** (display code not 0 and not `A`) and/or in the **mailer** (mailer code not 0).
- Promo types: display only, mailer only, display + mailer, none.
- Display code `A` ("In-Shelf") is kept as a separate flag for a sensitivity check, not counted as a display.
- Duplicate promotion rows (12,785 product-store-weeks with two rows) are collapsed: a flag is true if any row has it.
- Coupons are **not** a promo type (2,102 redemptions is too thin); mentioned in the limits.
- Loyalty discount depth (none, under 10%, 10–25%, over 25%) is **not** a promo type and **not** a control: it is described by promo type only (see below).

## Spine
- Grain: product × store × week, zero-filled for weeks with no sale.
- Universe: product-store pairs with at least one sale in scope (612,707 pairs × 52 weeks = 31.9M rows). Pairs never bought by the sample households add only zeros to sums and are left out.
- Because 96% of spine rows have zero sales, no per-row ratio is meaningful; only sums are compared (next section).

## How uplift is measured (applies to every step)
- **Uplift is always a ratio of sums**: sum(actual) / sum(expected) − 1 over all promoted rows in a group (promo type, category, store). Never an average or median of per-row or per-pair ratios.
- Why: the spine leaves out product-store pairs the sample never bought. Those pairs add zeros to sums, so ratios of sums are unaffected, but any per-row average, median or share would be **biased upward** because failed promotions (nothing sold) are missing.
- **Counts "per promoted product-week"** (how many promotions ran, what share sold nothing) come from the **full promotions table** (20.2M promoted product-store-weeks in scope), not from the spine (2.9M).
- **Holiday weeks** (48, 52, 53) never enter a baseline. Uplift is reported excluding promoted holiday weeks, and including them as a check.
- **Loyalty discount depth is descriptive only** (average depth by promo type). It is observed only in weeks where something sold, so using it as a control would condition on the outcome.

## Step 2 methods
- **A, time baseline:** for each promoted product-store-week, the expected sales are the mean of that product's last 4 clean weeks in that store (not promoted, not a holiday), all within the 12 weeks before the promotion (DuckDB `ASOF JOIN`). Summed over a group, this is the same as comparing the group's total with its pooled baseline.
- **B, control stores:** expected sales = the store's usual sales of the product (mean of its clean weeks, at least 4) × how the non-promoted stores did that same week relative to their own usual sales. Removes seasonality.
- **B is only valid where a control group exists:** at most half of the stores selling the product promote it that week, and at least 10 non-promoted stores remain. Mailers reach a median 98% of stores, so B can't evaluate mailer promotions; for them only A is available.

## Data provenance and terms
- 84.51° *The Complete Journey* 2.0 (2,469 households, one year; 84.51° is Kroger's data science company), as packaged in the R package `completejourney` v1.1.1 (Boehmke and Mortimer; package licence CC0 on CRAN) and its Python port `completejourney-py` 0.1.0 (code licence MIT; states the underlying data are provided by 84.51° for research and educational purposes). Earlier drafts attributed the data to dunnhumby; that was wrong for this release.
- No separate data licence from 84.51° was found. Raw data are **not** included in this repository; only code and aggregated results are published.

## Method C (mailers) and robustness (sql/04_robustness.sql)
- **C, other-category control:** at product × week level (all stores together, because mailers are chain-wide). A product-week is "in the mailer" if at least half the stores selling it carry it in the mailer; "clean" if no store promotes it. Each product is measured against its own baseline (last 4 clean, non-holiday weeks within 12). Expected sales = own baseline × how clean products in **other categories of the same department** did against their own baselines that week. The same category is excluded because a mailer feature can take sales from its competitors.
- Zero baselines are kept. Dropping them selects products with recent sales and builds in regression to the mean (it pushed the clean products' index to 0.82).
- **Placebo tests:** each method is run on non-promoted weeks as if they were promoted; the result should be near 0%. A pre-promotion placebo (the clean week just before a real promotion) tests whether promotions are timed on already-rising sales.
- **Uncertainty:** ratio of sums computed per week, then the median and interquartile range across weeks, plus per-quarter values. These ranges describe week-to-week variation, not sampling error.
- **Thin cells are not reported as findings:** display + mailer under method B (260 rows) is reported from A only, with a warning.

## Step 3: display event study (sql/05_event_study.sql)
- Episode = consecutive display-only weeks for a product in a store (gaps and islands). Usable episodes: isolated (no promotion of any kind for that product in that store in the 4 weeks before or after), window inside weeks 2–53 with no holiday week, B's validity rule at the start week. 30,918 of 402,452 episodes qualify; 64% are one-week runs.
- Each event week compares the store with non-promoted stores selling the same product that week, scaled by each store's usual sales. The store is removed from its own control group. The dip after the end is measured against the same controls, so regression to the mean is not mistaken for stockpiling.
- Pre-trend check for B: the week before the start is +21% against controls (weeks −4 to −2: −1% to +2%). B is therefore an upper bound for display uplift if that jump is targeting; if it is displays going up before the recorded week (week −1 sales lean slightly towards the weekend), B understates. Bounds: run week 1 +54% against controls; +27% relative to week −1.
- No evidence of a dip after displays: +10%, +7%, +8% in the 3 weeks after the end, 0% in week 4, against controls. (This is not evidence that displays help afterwards; the post weeks are not cleaner than the pre weeks.)

## Daily check of the week-before jump (sql/06_daily_check.sql)
- Each day of weeks −2, −1 and run week 1 compared with control stores on the same day. Bootstrap 90% intervals over episodes.
- Week −1: Mon–Thu +13.5% (4.0 to 23.0), Fri–Sun +29.1% (19.8 to 39.4); late minus early +15.6 points (0.8 to 30.0). Week −2 shows no such pattern (−9.0 points, −20.5 to 2.9). Intervals cluster on product-store.
- Reading: part of the jump looks like displays going up at the end of the week before the recorded start, but Mon–Thu is still elevated, so some targeting remains. Treating the Mon–Thu level as targeting gives about +36% for run week 1; the full jump as targeting gives about +29% over the run.

## Step 4: cannibalisation (sql/07_cannibalisation.sql)
- Same event-study design at category level: the other products of the promoted product's category in the treated store, against the same "others" in control stores, scaled by usual levels.
- Run weeks: rest of the category +0.7% (+$2,939; 90% interval +$143 to +$5,758). Promoted product +$3,936; net category change +$6,875 (+$3,969 to +$9,933).
- No evidence of cannibalisation. A positive halo is not claimed: the rest of the category was already +1.0–1.4% in weeks −2 and −1, the same pre-trend issue as the product itself.

## Step 5: break-even (sql/08_breakeven_ranking.sql, b01)
- No cost data, so no profit claims. Gross margins of 20%, 30% and 40% on the regular shelf price are scenarios. Cost of goods = (1 − margin) × shelf value, so the deeper loyalty discount during a display is charged against the gain.
- Break-even = the most a display can cost per display-week, as a % of the product's normal weekly net sales, before the extra margin is used up.
- Upper bound (B as measured; net +56%, shelf value +72%): −9.3% / −1.1% / +7.0% at 20 / 30 / 40% margin. Lower bound (week −1 jump as targeting; net +29%, shelf +42%): −9.2% / −4.5% / +0.3%.
- A negative value means that, under that margin assumption, the extra sales would not cover the extra discount, because display weeks come with deeper discounts (usual 12% of shelf value, 20% during displays). Under these assumptions, the extra margin covers a display only at higher margins, and then only if a display-week costs less than about 7% of normal weekly sales.

## Step 6: ranking (sql/08_breakeven_ranking.sql, b02–b03; ranges in the notebook)
- Departments and categories with at least 300 usable episodes. Upper = B as measured over run weeks; range = bootstrap 90% interval over episodes (seed 7, sorted inputs, so it reproduces); lower = upper divided by the overall week −1 jump (1.21). Saved to `docs/ranking_display_uplift.csv`.
- **Ranked by the low end of the 90% range**, not the point estimate: ranking by the point estimate rewards categories that were lucky (winner's curse).
- Absolute measures next to the percentage: extra net sales over all runs (panel households only, so small in dollars) and break-even at a 40% margin (upper bound).
- Where the range includes zero (8 of 25 categories), the wording is "no evidence that displays pay off", not "displays don't work".
- The ranking is about sales uplift; break-even by department uses the same 30% / 40% margin scenarios and is equally assumption-driven.

## Limits (final)
- **Coverage.** The display result rests on isolated runs: 7.7% of display runs qualify (30,918 of 402,452) and 64% of those last one week. It applies to isolated, mostly one-week displays, not to displays that run back to back or alongside a mailer.
- **Display weeks, not displays.** Display weeks carry deeper loyalty discounts (20% of shelf value vs 12% normally), and mailer weeks deeper still. Neither effect can be separated from its price cut; the results are for the package.
- **Not random.** Displays start when the product is already above its level (+21% against controls in the week before). The display-week effect is therefore a range: about +30% to +55% over the run, not a single number. Across all display weeks (not only isolated runs) B gives +33%.
- **Mailers are a package.** Mailer weeks come with deep loyalty discounts (about 34–36% of shelf value vs 17% for display only), so "about double" is the effect of ad plus price cut. Method B cannot measure mailers (they reach almost every store); the figure comes from A (+90%) and C (+119%).
- **No evidence of a dip** after displays, and no evidence of cannibalisation within the category. Neither result shows a benefit after or around the display.
- **No costs.** Break-even uses margin scenarios, not data. No profit claims.
- Coupons are not analysed. Holiday weeks are excluded from baselines. Grocery retail, one retailer, one year, a 2,469-household panel: the results show a method. All results are associations.
