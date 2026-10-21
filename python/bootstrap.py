"""Bootstrap 90% intervals (1,000 resamples). Inputs are sorted so the intervals are reproducible. Resampling unit: display episode, or
product-store pair where episodes cannot be told apart. Writes outputs/boot_*.csv
and docs/ranking_display_uplift.csv."""
import pathlib, duckdb, numpy as np, pandas as pd

ROOT = pathlib.Path(__file__).resolve().parents[1]
con = duckdb.connect(str(ROOT / "promo.duckdb"), read_only=True)
rng = np.random.default_rng(7)
B = 1000

def ci(groups, stat):
    """groups: DataFrame of per-cluster sums; stat: function of a resampled DataFrame -> float"""
    k = len(groups); vals = [stat(groups.iloc[rng.integers(0, k, k)]) for _ in range(B)]
    return np.percentile(vals, [5, 95])

# 1. step 6 ranking: run-week uplift by department / category (>= 300 episodes)
f = con.execute("SELECT f FROM pre_jump").fetchone()[0]
ep = con.execute("""SELECT product_id, store_id, start_week, department, product_category,
                           SUM(net_sales) n, SUM(exp_net) e, SUM(shelf_sales) s, SUM(exp_shelf) es
                    FROM run_rows GROUP BY ALL ORDER BY ALL""").df()
rows = []
for lvl in ["department", "product_category"]:
    for name, g in ep.groupby(lvl):
        if len(g) < 300:
            continue
        n, e = g.n.values, g.e.values
        idx = rng.integers(0, len(g), (B, len(g)))
        lo, hi = np.percentile(n[idx].sum(1) / e[idx].sum(1), [5, 95])
        pt = n.sum() / e.sum()
        d_net, d_shelf = n.sum() - e.sum(), g.s.sum() - g.es.sum()
        rows.append(dict(level=lvl, name=name, episodes=len(g),
                         range90_lo=100 * (lo - 1), uplift_upper_pct=100 * (pt - 1), range90_hi=100 * (hi - 1),
                         uplift_lower_pct=100 * (pt / f - 1),
                         extra_net_sales_total=d_net,                                  # $ over all runs, panel households only, upper bound
                         breakeven_40_pct=100 * (d_net - 0.6 * d_shelf) / e.sum()))     # 40% margin scenario, upper bound
# ranked by the LOWER end of the 90% range, not the point estimate (avoids rewarding noisy categories)
rank = pd.DataFrame(rows).sort_values(["level", "range90_lo"], ascending=[True, False]).round(1)
rank.to_csv(ROOT / "docs/ranking_display_uplift.csv", index=False)
rank.to_csv(ROOT / "outputs/boot_ranking.csv", index=False)

# 2. daily check: week -1 Mon-Thu vs Fri-Sun (cluster = product-store)
d = con.execute("""SELECT product_id, store_id, k, dow <= 4 AS early,
                          SUM(treated_sales) t, SUM(usual_net_sales * ctrl_sales / ctrl_usual) x
                   FROM event_days WHERE n_ctrl >= 10 AND ctrl_usual > 0 GROUP BY ALL ORDER BY ALL""").df()
out = []
for k in (-2, -1, 0):
    w = d[d.k == k].pivot_table(index=["product_id", "store_id"], columns="early", values=["t", "x"], aggfunc="sum").fillna(0)
    w.columns = [f"{a}_{'early' if b else 'late'}" for a, b in w.columns]
    up = lambda s, p: 100 * (s[f"t_{p}"].sum() / s[f"x_{p}"].sum() - 1)
    for part in ("early", "late"):
        lo, hi = ci(w, lambda s: up(s, part))
        out.append(dict(event_week=k, part="Mon-Thu" if part == "early" else "Fri-Sun", uplift_pct=up(w, part), lo=lo, hi=hi))
    lo, hi = ci(w, lambda s: up(s, "late") - up(s, "early"))
    out.append(dict(event_week=k, part="late minus early (points)", uplift_pct=up(w, "late") - up(w, "early"), lo=lo, hi=hi))
pd.DataFrame(out).round(1).to_csv(ROOT / "outputs/boot_daily.csv", index=False)

# 3. cannibalisation: rest of category and net category change in run weeks (cluster = product-store)
c = con.execute("""SELECT product_id, store_id, SUM(others_net - others_usual * ctrl_index) oc
                   FROM cannib_rows WHERE phase = 'run' AND n_ctrl >= 10 AND ctrl_index IS NOT NULL AND others_usual > 0
                   GROUP BY ALL ORDER BY ALL""").df()
p = con.execute("""SELECT product_id, store_id, SUM(net_sales - usual_net_sales * ctrl_index) pg
                   FROM event_rows WHERE phase = 'run' AND ctrl_stores >= 10 AND ctrl_index IS NOT NULL
                   GROUP BY ALL ORDER BY ALL""").df()
m = p.merge(c, how="outer", on=["product_id", "store_id"]).fillna(0)
res = []
for label, fn in [("promoted product gain", lambda s: s.pg.sum()), ("rest of category change", lambda s: s.oc.sum()),
                  ("net category change", lambda s: s.pg.sum() + s.oc.sum())]:
    lo, hi = ci(m, fn)
    res.append(dict(measure=label, value=fn(m), lo=lo, hi=hi))
pd.DataFrame(res).round(0).to_csv(ROOT / "outputs/boot_cannibalisation.csv", index=False)
print(rank.head(6).to_string(index=False))
print(pd.DataFrame(out).round(1).to_string(index=False))
print(pd.DataFrame(res).round(0).to_string(index=False))
