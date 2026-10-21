# Promotion uplift analysis (SQL, DuckDB)

Did promotions (in-store displays and mailer features) raise sales, and was the extra revenue worth it? A promotions-analyst project on 84.51°'s *The Complete Journey* 2.0 (2,469 households, one year, 112 stores with promotion data).

**Start here:** [`summary/one_pager.pdf`](summary/one_pager.pdf) (one page: chart, three numbers, recommendation, limits).

## Findings
- **Display weeks: about +30% to +55%** during the run, against stores without the display that week (isolated runs). Display weeks also carry deeper loyalty discounts (20% of shelf value vs 12%), so this is display plus price cut. Sales were already +21% the week before, so the top of the range treats that jump as display effect and the bottom treats it as targeting. A simple before-and-after says about +60%; across all display weeks the store comparison gives +33%.
- **Mailer feature: about double** (+90% to +119% by two methods). Mailer weeks also carry 34–36% loyalty discounts, so this is the effect of ad plus price cut.
- **No evidence of a dip** in the 4 weeks after a display, and **no evidence of cannibalisation** within the category (net category change +$6,875, 90% interval +$3,969 to +$9,933).
- **Break-even (scenarios, no cost data):** displays come with deeper discounts (20% of shelf value vs 12% normally). Under a 20–30% margin assumption the extra sales would not cover the extra discount; under 40%, the extra margin covers a display only if a display-week costs less than about 7% of the product's normal weekly sales. No profit is claimed.
- **Ranking:** 6 departments and 25 categories with ≥ 300 usable runs, ranked by the low end of the bootstrap 90% range (not the point estimate, which would reward noisy categories), with extra panel sales and break-even at a 40% margin. Where the range includes zero (8 categories) there is no evidence that displays pay off: [`docs/ranking_display_uplift.csv`](docs/ranking_display_uplift.csv).

**Coverage:** 7.7% of display runs qualify (30,918 of 402,452) and 64% of those last one week, so the display result applies to isolated, mostly one-week displays. Full limits in [`docs/DEFINITIONS.md`](docs/DEFINITIONS.md#limits-final).

## Run it
```
pip install duckdb pandas numpy matplotlib nbformat nbclient nbconvert ipykernel
python run_all.py            # everything: load, spine, checks, steps 2-6, bootstrap, chart, notebook
python run_all.py --from 05  # re-run from a later script on an existing database
```
`run_all.py` runs `sql/00`–`08` in order, saves every tagged query (`-- @x name`) to `outputs/<name>.csv`, stops if a blocking data check fails, then runs `python/bootstrap.py`, `python/chart.py` and `python/build_notebook.py`.

The spine has 31.9M rows. The scripts set `threads = 2`, `preserve_insertion_order = false` and a `temp_directory`, so DuckDB spills to disk and the build fits in about 5 GB of RAM. On a larger machine you can raise or remove the thread limit.

## Data
Not included in this repository. The data are 84.51°'s *The Complete Journey* 2.0 (84.51° is Kroger's data science company), as packaged in the R package `completejourney` v1.1.1 (Boehmke and Mortimer; licence CC0 on CRAN) and its Python port `completejourney-py` 0.1.0 on PyPI (code licence MIT; it states that the underlying data are provided by 84.51° for research and educational purposes). I found no separate data licence from 84.51°. Place the parquet files in `data/raw/`; only code and aggregated results are published here.

## Files
| Path | What it is |
|---|---|
| `summary/one_pager.pdf` (`.html`) | One-page summary |
| `notebooks/promo_uplift.ipynb` (`.html`) | Every reported query and its result, in order |
| `docs/DEFINITIONS.md` | Money columns, scope, promotion definition, uplift rules, methods, final limits |
| `docs/ranking_display_uplift.csv` | Step 6 ranking with ranges |
| `run_all.py` | Rebuilds everything |
| `sql/00_load.sql` | Loads the eight tables |
| `sql/01_spine.sql` | Calendar and holiday flags, clean transactions, deduplicated promo flags, product × store × week spine |
| `sql/02_checks.sql` | Blocking checks and data funnel |
| `sql/03_uplift.sql` | Step 2: uplift by promo type, time baseline (A) and control stores (B) |
| `sql/04_robustness.sql` | Method C for mailers, placebos, B sensitivity, week and quarter ranges, chronic promotions |
| `sql/05_event_study.sql` | Step 3: display episodes and event study (pre-trend, run, after) |
| `sql/06_daily_check.sql` | Day-by-day test of the week-before jump |
| `sql/07_cannibalisation.sql` | Step 4: rest-of-category event study |
| `sql/08_breakeven_ranking.sql` | Steps 5–6: break-even scenarios and department table |
| `python/bootstrap.py` | Bootstrap 90% intervals (ranking, daily check, cannibalisation) |
| `python/chart.py` | Event-study chart |
| `python/build_notebook.py` | Builds and executes the notebook |
