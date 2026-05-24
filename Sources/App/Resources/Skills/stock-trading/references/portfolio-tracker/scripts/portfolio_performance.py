#!/usr/bin/env python3
"""
Portfolio performance over time — reads history.csv and prints a simple ASCII chart.
Shows total portfolio value trend and top-3 position contribution drift.
"""

import csv
from datetime import datetime, timedelta
from pathlib import Path
import sys

BASE = Path.home() / ".hermes" / "portfolio"
HISTORY = BASE / "portfolio_history.csv"

if not HISTORY.exists():
    print("❌ No history file. Run portfolio_tracker.py first.")
    sys.exit(1)

# Read history, group by day (latest snapshot per day)
daily = {}
with HISTORY.open(newline="") as f:
    reader = csv.DictReader(f)
    for row in reader:
        # Parse timestamp, keep only date part
        try:
            dt = datetime.fromisoformat(row["snapshot_dt"].replace("Z","+00:00"))
        except Exception:
            continue
        day = dt.date()
        ticker = row["ticker"]
        if ticker == "_TOTAL_":
            val = float(row["mkt_val"] or 0)
            # Keep the latest total for each day (should all be same, but…)
            daily[day] = val

if not daily:
    print("❌ No total values in history")
    sys.exit(1)

# Sort by date
days = sorted(daily.keys())
if len(days) < 2:
    print("ℹ️  Only one day of data — need multiple runs to show trend")
    print(f"Latest total: ${daily[days[0]]:,.2f}")
    sys.exit(0)

# Print table
print(f"\n{' Date':<12} {' Total Value':>15} {' Day Chg':>10} {' % Chg':>8}")
print("-" * 50)
prev = None
for day in days:
    val = daily[day]
    if prev is not None:
        diff = val - prev
        pct  = diff / prev * 100
        sign = "+" if diff >= 0 else ""
        print(f" {day}  ${val:>12,.2f}  {sign}{diff:>9,.2f}  {sign}{pct:>6.2f}%")
    else:
        print(f" {day}  ${val:>12,.2f}   (first)")
    prev = val

print("-" * 50)
print(f"📈  Period: {days[0]} → {days[-1]}")
print(f"   Change: ${daily[days[-1]] - daily[days[0]]:,.2f}  "
      f"({(daily[days[-1]] - daily[days[0]]) / daily[days[0]] * 100:+.2f}%)")

