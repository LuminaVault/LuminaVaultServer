#!/usr/bin/env python3
"""
Hermes Portfolio Quick Summary — one-column terminal view
Usage: portfolio_summary.py [--refresh]
"""

import csv, os, sys
from pathlib import Path

BASE = Path.home() / ".hermes" / "portfolio"
SNAPSHOT = BASE / "portfolio_snapshot.csv"
PRICES   = BASE / "live_prices.csv"

def load_snapshot():
    rows = []
    if not SNAPSHOT.exists():
        print("❌ No snapshot. Run portfolio_tracker.py first.")
        sys.exit(1)
    with SNAPSHOT.open(newline="") as f:
        for row in csv.DictReader(f):
            rows.append(row)
    return rows

def colorize(text, color):
    colors = {"green": "\033[32m", "red": "\033[31m", "yellow": "\033[33m", "blue": "\033[34m", "reset": "\033[0m"}
    return f"{colors.get(color,'')}{text}{colors['reset']}"

def main():
    args = sys.argv[1:]
    if "--refresh" in args:
        # Call tracker
        tracker = Path.home() / ".hermes" / "scripts" / "portfolio_tracker.py"
        import subprocess
        subprocess.run([sys.executable, str(tracker), "--once"])
    
    rows = load_snapshot()
    
    print(f"\n{' Ticker':<6} {' Shares':>12} {' Price':>10} {' Value':>14} {' %':>6} {' Note'}")
    print("-" * 70)
    
    total_val = 0.0
    for r in rows:
        if r["ticker"].startswith("_"):
            total_val = float(r["mkt_val"] or 0)
            continue
        shares = float(r["shares"] or 0)
        if shares == 0:
            continue  # skip wishlist
        price  = float(r["live_price"] or 0)
        val    = float(r["mkt_val"] or 0)
        pct    = f"{(val/total_val*100) if total_val else 0:.1f}%"
        note   = r["note"]
        
        price_str = f"${price:,.2f}" if price else "   —   "
        print(f" {r['ticker']:<5} {shares:>12.4f} {price_str:>10}  ${val:>12,.2f} {pct:>6}  {note}")
    
    print("-" * 70)
    print(f" {'_TOTAL_':<5} {'':>12} {'':>10}  ${total_val:>12,.2f}  {'100.0%':>6}")
    print()
    
    # Price recency
    if PRICES.exists():
        import json
        with PRICES.open() as f:
            lines = f.readlines()
        last_line = lines[-1].strip() if len(lines) > 1 else ""
        print(f"📅 Prices updated: {last_line.split(',')[-1] if ',' in last_line else 'unknown'}")
    
    print()

if __name__ == "__main__":
    main()
