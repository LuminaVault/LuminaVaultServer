#!/usr/bin/env python3
"""
Daily Portfolio Health Check — meant to run after your daily stock price cron job.
Outputs concise markdown summary for Discord/Telegram or local reading.

Designed to be called from your existing daily automation chain.
"""

import csv, os, sys
from datetime import datetime
from pathlib import Path

BASE = Path.home() / ".hermes" / "portfolio"
SNAPSHOT = BASE / "portfolio_snapshot.csv"

def load_rows():
    rows = []
    if not SNAPSHOT.exists():
        return rows, 0
    with SNAPSHOT.open(newline="") as f:
        for row in csv.DictReader(f):
            rows.append(row)
    total = float(rows[-1]["mkt_val"] or 0) if rows and rows[-1]["ticker"].startswith("_") else 0
    return rows, total

def main():
    rows, total = load_rows()
    if total == 0:
        print("⚠️  Portfolio value is $0 — run portfolio_tracker.py with prices first.")
        sys.exit(1)

    print(f"# 💼 Daily Portfolio Check — {datetime.now().strftime('%Y-%m-%d')}")
    print(f"**Total value:** ${total:,.2f}")
    print()

    # Top movers by absolute value
    positions = [r for r in rows if not r["ticker"].startswith("_") and r["shares"]]
    positions.sort(key=lambda x: float(x["mkt_val"] or 0), reverse=True)

    print("## Top 5 holdings")
    for p in positions[:5]:
        print(f"- **{p['ticker']}**: ${float(p['mkt_val']):,.2f}  ({p['note']})")

    print()
    print("## Speculative / micro-cap watchlist")
    spec_tags = ["micro-cap", "pink-sheet", "ventura", "pure", "fwb2", "scm", "otcqb"]
    for p in positions:
        if any(tag in p["note"].lower() for tag in spec_tags):
            print(f"- {p['ticker']}: ${float(p['mkt_val']):,.2f}  ({p['note']})")

    print()
    print("## Next actions")
    print("- Update wishlist conviction scores via ~/.hermes/portfolio/wishlist_conviction.json")
    print("- Check if any position drifted >3% of portfolio — consider trimming")
    print("- Deploy monthly capital to top 1–2 conviction names")

    print("\n---")
    print("Run `python ~/.hermes/scripts/portfolio_summary.py` for full table.")
    print("Update prices: `python ~/.hermes/scripts/portfolio_tracker.py`")

if __name__ == "__main__":
    main()
