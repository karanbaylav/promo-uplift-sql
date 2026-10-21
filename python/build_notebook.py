"""Builds and executes notebooks/promo_uplift.ipynb (plus an HTML copy). Every tagged
query in sql/ is run against promo.duckdb in order, so the notebook shows each query and
its result. Requires the database built by run_all.py."""
import pathlib, re, nbformat as nbf
from nbclient import NotebookClient

ROOT = pathlib.Path(__file__).resolve().parents[1]
md, code = nbf.v4.new_markdown_cell, nbf.v4.new_code_cell

SECTIONS = {
    "02": ("Step 1: data checks", "Blocking checks must show 0 failures. The funnel shows what each cleaning rule removed."),
    "03": ("Step 2: uplift by promotion type, methods A and B",
           "A = the product's own last 4 clean weeks. B = control stores selling the same product that week without a promotion. Ratio of sums, holiday weeks never in a baseline."),
    "04": ("Robustness: method C, placebos, ranges, chronic promotions",
           "C measures mailers at product-week level against other categories of the same department. Placebos should be near 0%."),
    "05": ("Step 3: display event study", "Isolated display runs compared with control stores from 4 weeks before to 4 weeks after."),
    "06": ("Daily check of the week-before jump", "Early set-up predicts a jump at the end of week −1; targeting predicts a jump across the whole week."),
    "07": ("Step 4: cannibalisation", "The other products of the category in the treated store, against the same products in control stores."),
    "08": ("Steps 5 and 6: break-even scenarios and ranking",
           "Margins of 20/30/40% are scenarios, not data. Break-even = the most a display-week can cost, as % of normal weekly net sales."),
}
EXTRA = {
    "06": ("Bootstrap 90% intervals (cluster = product-store)", "pd.read_csv(ROOT / 'outputs/boot_daily.csv')"),
    "07": ("Bootstrap 90% intervals, run weeks ($ net sales)", "pd.read_csv(ROOT / 'outputs/boot_cannibalisation.csv')"),
    "08": ("Step 6 ranking with bootstrap 90% ranges (≥ 300 episodes)", "pd.read_csv(ROOT / 'docs/ranking_display_uplift.csv')"),
}

def tagged(sql):
    for chunk in re.split(r";\s*\n", sql):
        m = re.search(r"--\s*@\w+\s+(\w+)([^\n]*)", chunk)
        if m:
            yield m.group(1), m.group(2).strip(" ()"), chunk[m.start():].split("\n", 1)[1].strip()

cells = [md("# Promotion uplift: did displays and mailers raise sales?\n"
            "84.51° *The Complete Journey* 2.0 (via the `completejourney` package). "
            "This notebook re-runs every reported query against `promo.duckdb`; rebuild the database with `python run_all.py`.\n\n"
            "**Summary.** A before-and-after comparison puts display-week uplift at about +60%. Comparing stores with and without the display "
            "in the same week gives +33% across all display weeks. For isolated display runs, sales were already +21% against control stores "
            "the week before, so the run-period uplift is reported as a range, about +30% to +55%. Display weeks also carry deeper loyalty "
            "discounts, so this is the effect of display plus price cut. There is no evidence of a dip in the four weeks after a display ends."),
         code("import pathlib, duckdb, pandas as pd\nfrom IPython.display import Image\n"
              "ROOT = pathlib.Path.cwd().parent if pathlib.Path.cwd().name == 'notebooks' else pathlib.Path.cwd()\n"
              "con = duckdb.connect(str(ROOT / 'promo.duckdb'), read_only=True)\n"
              "pd.set_option('display.max_columns', 30); pd.set_option('display.width', 200)\n"
              "q = lambda sql: con.execute(sql).df()")]
for f in sorted((ROOT / "sql").glob("*.sql")):
    key = f.name[:2]
    if key not in SECTIONS:
        continue
    title, note = SECTIONS[key]
    cells.append(md(f"## {title}\n`{f.name}`. {note}"))
    for name, desc, body in tagged(f.read_text()):
        cells.append(md(f"**{name}**" + (f": {desc}" if desc else "")))
        cells.append(code(f'q("""\n{body}\n""")'))
    if key in EXTRA:
        cells.append(md(f"**{EXTRA[key][0]}** (`python/bootstrap.py`)"))
        cells.append(code(EXTRA[key][1]))
    if key == "05":
        cells.append(code("Image(filename=str(ROOT / 'charts/event_study_display.png'), width=900)"))
cells.append(md("## Limits\nSee `docs/DEFINITIONS.md`, section *Limits (final)*. In short: the display result applies to isolated, mostly "
                 "one-week displays (7.7% of display runs qualify, 30,918 of 402,452, and 64% of those last one week); displays are not "
                 "random, so the effect is a range; mailers are a package of ad plus price cut; no cost data, so break-even uses margin scenarios."))

nb = nbf.v4.new_notebook(cells=cells, metadata={"kernelspec": {"name": "python3", "display_name": "Python 3", "language": "python"}})
out = ROOT / "notebooks"; out.mkdir(exist_ok=True)
NotebookClient(nb, timeout=1200, resources={"metadata": {"path": str(out)}}).execute()
nbf.write(nb, out / "promo_uplift.ipynb")
from nbconvert import HTMLExporter
(out / "promo_uplift.html").write_text(HTMLExporter().from_notebook_node(nb)[0])
print("notebook built:", len(cells), "cells")
