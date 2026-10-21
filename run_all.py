"""Rebuild everything from the raw parquet files: python run_all.py [--from 05]
Runs sql/00..08 in order. Each statement runs in turn; every query tagged
`-- @<x> <name>` is saved to outputs/<name>.csv. Then builds the bootstrap ranges,
the chart and the notebook."""
import pathlib, re, sys, time, duckdb

ROOT = pathlib.Path(__file__).parent
OUT = ROOT / "outputs"; OUT.mkdir(exist_ok=True)
start = sys.argv[sys.argv.index("--from") + 1] if "--from" in sys.argv else "00"

def statements(sql):
    """Split on semicolons at line end; keep the '-- @x name' tag that precedes a statement."""
    for chunk in re.split(r";\s*\n", sql):
        if not re.sub(r"--[^\n]*", "", chunk).strip():
            continue
        tag = re.search(r"--\s*@\w+\s+(\w+)", chunk)
        yield (tag.group(1) if tag else None), chunk

for f in sorted((ROOT / "sql").glob("*.sql")):
    if f.name[:2] < start:
        continue
    con = duckdb.connect(str(ROOT / "promo.duckdb"))   # fresh connection per script: each sets its own temp directory
    t0 = time.time()
    for name, stmt in statements(f.read_text()):
        if name:
            df = con.execute(stmt).df()
            df.to_csv(OUT / f"{name}.csv", index=False)
            if name == "blocking" and df["failures"].sum() != 0:
                sys.exit(f"Blocking check failed:\n{df}")
        else:
            con.execute(stmt).fetchall()
    con.close()
    print(f"{f.name}: {time.time() - t0:.0f}s")

import subprocess
for step in ["python/bootstrap.py", "python/chart.py", "python/build_notebook.py"]:
    subprocess.run([sys.executable, str(ROOT / step)], check=True)
