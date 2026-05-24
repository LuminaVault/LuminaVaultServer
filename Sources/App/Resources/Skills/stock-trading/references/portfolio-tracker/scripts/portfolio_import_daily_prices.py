#!/usr/bin/env python3
"""
Import latest prices from your daily stock price outputs.
Assumes you have a daily Hermes script that outputs TSV: TICKER<TAB>PRICE
Usage: python portfolio_import_daily_prices.py /path/to/daily_prices.tsv
"""

import csv, sys
from pathlib import Path

if len(sys.argv) < 2:
    print("Usage: portfolio_import_daily_prices.py <prices.tsv>")
    sys.exit(1)

src = Path(sys.argv[1])
dst = Path.home() / ".hermes" / "portfolio" / "live_prices.csv"

if not src.exists():
    print(f"❌ Source not found: {src}")
    sys.exit(1)

# Load existing prices to preserve manual entries
existing = {}
if dst.exists():
    with dst.open(newline="") as f:
        for row in csv.DictReader(f):
            existing[row["ticker"]] = (row["price"], row["updated_at"])

updated = 0
with src.open() as f:
    lines = f.readlines()

# TSV: ticker<tab>price  (or CSV with header)
reader = csv.reader(lines, delimiter="\t")
for row in reader:
    if not row:
        continue
    if row[0].lower() in ("ticker", "symbol"):
        continue  # skip header
    ticker = row[0].upper()
    price  = row[1]
    updated += 1
    existing[ticker] = (price, "daily-import")

# Write back
with dst.open("w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["ticker", "price", "updated_at"])
    for ticker, (price, ts) in sorted(existing.items()):
        w.writerow([ticker, price, ts])

print(f"✅ Imported {updated} prices → {dst}")

