"""Run sql/ in order, then export result views to results/ and dash_ views to dashboard/.

usage: python scripts/build.py              full run
       python scripts/build.py --from 03    skip files before 03 (tables already built)
"""
import os
import pathlib
import sys
import time

import duckdb

ROOT = pathlib.Path(__file__).resolve().parent.parent
os.chdir(ROOT)  # sql/00_load.sql reads data/train.parquet relative to the repo root
PREFIXES = ("chk_", "pos_", "ab_", "rank_", "pow_", "geo_")

start = sys.argv[sys.argv.index("--from") + 1] if "--from" in sys.argv else "00"

con = duckdb.connect(str(ROOT / "experiments.duckdb"))
for f in sorted((ROOT / "sql").glob("*.sql")):
    if f.name[:2] < start and not f.name.startswith("00"):
        continue
    t = time.time()
    con.execute(f.read_text())
    print(f"{f.name:<28} {time.time() - t:5.1f}s")

(ROOT / "results").mkdir(exist_ok=True)
(ROOT / "dashboard").mkdir(exist_ok=True)
n = 0
for (v,) in con.execute(
    "select table_name from information_schema.tables where table_type = 'VIEW' order by 1"
).fetchall():
    if v.startswith("dash_"):
        con.sql(f"select * from {v}").write_csv(str(ROOT / "dashboard" / f"{v[5:]}.csv"))
    elif v.startswith(PREFIXES):
        con.sql(f"select * from {v}").write_csv(str(ROOT / "results" / f"{v}.csv"))
    else:
        continue
    n += 1
print(f"exported {n} views")
