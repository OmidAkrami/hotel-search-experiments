"""Turn Kaggle's data.zip into data/train.parquet.

train.csv is 2.4 GB of text with the string 'NULL' for missing values.
Parquet with explicit types is ~150 MB and every query after this is fast.

Kaggle's data.zip is compressed with Deflate64, which Python's zipfile module
can't read, so the system `unzip` command does the extraction.

usage: python scripts/prepare_data.py path/to/data.zip
       (or pass train.csv directly if you already unzipped it)
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile

import duckdb

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "data" / "train.parquet"

src = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "data" / "data.zip")

# types spelled out so DuckDB doesn't guess from the first few thousand rows
cols = {
    "srch_id": "INTEGER", "date_time": "TIMESTAMP", "site_id": "SMALLINT",
    "visitor_location_country_id": "SMALLINT", "visitor_hist_starrating": "DOUBLE",
    "visitor_hist_adr_usd": "DOUBLE", "prop_country_id": "SMALLINT", "prop_id": "INTEGER",
    "prop_starrating": "TINYINT", "prop_review_score": "DOUBLE", "prop_brand_bool": "TINYINT",
    "prop_location_score1": "DOUBLE", "prop_location_score2": "DOUBLE",
    "prop_log_historical_price": "DOUBLE", "position": "SMALLINT", "price_usd": "DOUBLE",
    "promotion_flag": "TINYINT", "srch_destination_id": "INTEGER", "srch_length_of_stay": "SMALLINT",
    "srch_booking_window": "SMALLINT", "srch_adults_count": "TINYINT", "srch_children_count": "TINYINT",
    "srch_room_count": "TINYINT", "srch_saturday_night_bool": "TINYINT",
    "srch_query_affinity_score": "DOUBLE", "orig_destination_distance": "DOUBLE", "random_bool": "TINYINT",
}
for i in range(1, 9):
    cols[f"comp{i}_rate"] = "TINYINT"
    cols[f"comp{i}_inv"] = "TINYINT"
    cols[f"comp{i}_rate_percent_diff"] = "DOUBLE"
cols.update({"click_bool": "TINYINT", "gross_bookings_usd": "DOUBLE", "booking_bool": "TINYINT"})
spec = "{" + ", ".join(f"'{k}': '{v}'" for k, v in cols.items()) + "}"

with tempfile.TemporaryDirectory() as tmp:
    if src.suffix == ".zip":
        if shutil.which("unzip") is None:
            sys.exit("needs the unzip command; or unzip data.zip yourself and pass train.csv")
        print("unzipping train.csv ...")
        subprocess.run(["unzip", "-q", "-o", str(src), "train.csv", "-d", tmp], check=True)
        csv = pathlib.Path(tmp) / "train.csv"
    else:
        csv = src

    OUT.parent.mkdir(exist_ok=True)
    con = duckdb.connect()
    con.execute("set preserve_insertion_order = false")
    con.execute(f"""
        copy (select * from read_csv('{csv}', header = true, nullstr = 'NULL', columns = {spec}))
        to '{OUT}' (format parquet, compression zstd, row_group_size 250000)
    """)

print(OUT, round(OUT.stat().st_size / 1e6), "MB")
