#!/usr/bin/env python3
"""
Hermes Portfolio Tracker — CSV-based, no external deps.
Designed to work with your daily stock price reports.
Usage:
  python portfolio_tracker.py                 → interactive update (manual entry)
  python portfolio_tracker.py --from-prices /path/to/prices.csv  → bulk update
  python portfolio_tracker.py --snapshot      → just write snapshot (no prompts)
"""

import csv, json, argparse, os
from datetime import datetime
from pathlib import Path

# ── Holdings definition ─────────────────────────────────────────────────────
# ticker, shares held, type label
PORTFOLIO = [
    ("AMD",   20.2915,  "large-cap tech"),
    ("GOOGL", 11.641,   "large-cap tech"),
    ("ZETA",  200.378,  "mid-cap MarTech"),
    ("OSCR",  178.9193, "mid-cap health-tech"),
    ("HIMS",  108.7022, "mid-cap telehealth"),
    ("AMZN",  11.4169,  "large-cap tech/retail"),
    ("ASTS",  30.0032,  "small-cap space"),
    ("SOFI",  112.6557, "fintech"),
    ("ADUR",  130.0497, "micro-cap (CAD)"),
    ("TE",    259.736,  "small-cap telecom"),
    ("NFLX",  12.0,     "large-cap streaming"),
    ("ONDS",  104.524,  "micro-cap"),
    ("UBER",  14.4919,  "large-cap mobility"),
    ("NVO",   25.0,     "large-cap pharma"),
    ("KRKNF", 153.3175, "pink-sheet"),
    ("A6I",   220.0,    "frankfurt-listed"),
    ("ABCL",  200.0529, "biotech"),
    # Wishlist (0 shares until purchased)
    ("RDW",   0.0,  "space infra — planned 1%"),
    ("OUST",  0.0,  "lidar — planned 1%"),
    ("SMR",   0.0,  "SMR nuclear — planned 1%"),
    ("ELF",   0.0,  "beauty — planned 1%"),
]

BASE = Path.home() / ".hermes" / "portfolio"
BASE.mkdir(parents=True, exist_ok=True)
SNAPSHOT_FILE = BASE / "portfolio_snapshot.csv"
HISTORY_FILE  = BASE / "portfolio_history.csv"
WISHLIST_FILE = BASE / "wishlist_conviction.json"
PRICES_FILE   = BASE / "live_prices.csv"   # manual price updates

WISHLIST_DEFAULT = {
    "RDW": {"conviction": None, "max_allocation_pct": 1.0,
            "thesis": "Space infrastructure — in-space manufacturing/microgravity R&D",
            "catalyst": "NASA/DoD contracts; commercial station partnerships",
            "exit": "Sell if: no revenue growth for 2 quarters; dilution; >2% portfolio"},
    "OUST":{"conviction": None, "max_allocation_pct": 1.0,
            "thesis": "Digital lidar for AV/robotics/industrial",
            "catalyst": "Major OEM win; EBITDA breakeven; auto-sales inflection",
            "exit": "Sell if: cash runway <12mo; market share loss; better lidar alternative"},
    "SMR": {"conviction": None, "max_allocation_pct": 1.0,
            "thesis": "Small modular nuclear reactors — first-mover US licensing",
            "catalyst": "NRC design approval; first utility EPC contract",
            "exit": "Sell if: regulatory delay >18mo; cost overruns >30%; no new customers"},
    "ELF": {"conviction": None, "max_allocation_pct": 1.0,
            "thesis": "Value cosmetics — viral DTC brand, strong margins, cash flow",
            "catalyst": "International expansion; same-store growth; margin sustain",
            "exit": "Sell if: val >45x P/E with flat growth; brand fatigue; multiple contraction"},
}

def load_prices(path: Path) -> dict:
    prices = {}
    if not path.exists():
        return prices
    with path.open(newline="") as f:
        for row in csv.DictReader(f):
            t = row.get("ticker", "").upper()
            p = row.get("price")
            if t and p:
                try:
                    prices[t] = float(p)
                except ValueError:
                    pass
    return prices


def build_snapshot(manual_prices: dict | None = None) -> list[dict]:
    rows = []
    total_val = 0.0
    prices_used = manual_prices or {}

    for ticker, shares, note in PORTFOLIO:
        price = prices_used.get(ticker)
        mkt_val = round(shares * price, 2) if price else None
        if mkt_val:
            total_val += mkt_val
        rows.append({
            "ticker": ticker, "shares": shares, "live_price": price, "currency": "USD",
            "mkt_val": mkt_val, "note": note,
            "snapshot_dt": datetime.utcnow().isoformat(timespec="seconds") + "Z",
        })
    rows.append({
        "ticker": "_TOTAL_", "shares": "", "live_price": "", "currency": "",
        "mkt_val": round(total_val, 2), "note": "sum of all positions",
        "snapshot_dt": rows[-1]["snapshot_dt"],
    })
    return rows


def write_snapshot(rows):
    fieldnames = ["ticker", "shares", "live_price", "currency", "mkt_val", "note"]
    with SNAPSHOT_FILE.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in rows[:-1]:
            w.writerow({k: r[k] for k in fieldnames})
        w.writerow({"ticker": "_TOTAL_", "mkt_val": rows[-1]["mkt_val"]})


def append_history(rows):
    hist_fields = ["ticker", "shares", "live_price", "currency", "mkt_val", "note", "snapshot_dt"]
    exists = HISTORY_FILE.exists()
    with HISTORY_FILE.open("a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=hist_fields)
        if not exists:
            w.writeheader()
        w.writerows(rows)


def init_wishlist():
    if WISHLIST_FILE.exists():
        return
    WISHLIST_FILE.write_text(json.dumps(WISHLIST_DEFAULT, indent=2))
    print(f"[init] wishlist template → {WISHLIST_FILE}")


def interactive_update() -> dict:
    print("\n📝 Manual price update — enter last price for each ACTIVE holding")
    print("   (Enter to skip; 'q' to quit)\n")
    existing = load_prices(PRICES_FILE)
    updates = dict(existing)

    for ticker, shares, _ in PORTFOLIO:
        if shares <= 0:
            continue
        current = updates.get(ticker, "")
        resp = input(f"  {ticker:6}  shares={shares:<10}  price").strip()
        if resp.lower() == "q":
            break
        if resp:
            try:
                updates[ticker] = float(resp)
                print(f"    ✓ {ticker} ← {resp}")
            except ValueError:
                print(f"    ✗ invalid, keeping {current}")
    # Save
    with PRICES_FILE.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["ticker", "price", "updated_at"])
        w.writeheader()
        now = datetime.utcnow().isoformat(timespec="seconds") + "Z"
        for t, p in sorted(updates.items()):
            w.writerow({"ticker": t, "price": p, "updated_at": now})
    print(f"\n✅ Prices saved → {PRICES_FILE}")
    return updates


def bulk_update_from_csv(path: Path) -> dict:
    prices = {}
    with path.open(newline="") as f:
        for row in csv.DictReader(f):
            t = row.get("ticker", "").upper()
            p = row.get("price") or row.get("last") or row.get("close")
            if t and p:
                try:
                    prices[t] = float(p)
                except ValueError:
                    pass
    existing = load_prices(PRICES_FILE)
    existing.update(prices)
    with PRICES_FILE.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["ticker", "price", "updated_at"])
        w.writeheader()
        now = datetime.utcnow().isoformat(timespec="seconds") + "Z"
        for t, p in sorted(existing.items()):
            w.writerow({"ticker": t, "price": p, "updated_at": now})
    print(f"✅ Bulk update: {len(prices)} tickers from {path.name}")
    return existing


def main():
    parser = argparse.ArgumentParser(
        description="Portfolio tracker — manual price management (no external APIs)"
    )
    parser.add_argument("--snapshot", action="store_true", help="Write snapshot only (non-interactive)")
    parser.add_argument("--from-prices", type=str, metavar="CSV", help="Bulk update from CSV")
    parser.add_argument("--once", action="store_true", help="Single run, no interactive prompts")
    args = parser.parse_args()

    init_wishlist()

    if args.from_prices:
        prices = bulk_update_from_csv(Path(args.from_prices))
    elif not args.snapshot and not args.once:
        prices = interactive_update()
    else:
        prices = load_prices(PRICES_FILE)

    rows = build_snapshot(manual_prices=prices if prices else None)
    write_snapshot(rows)
    append_history(rows)

    total = rows[-1]["mkt_val"] or 0.0
    priced_positions = sum(1 for r in rows[:-1] if r["mkt_val"])
    print(f"\n📊 Portfolio snapshot written")
    print(f"   • Positions with price: {priced_positions} / {len(PORTFOLIO)-1}")
    print(f"   • Total market value: ${total:,.2f}")
    print(f"   • Files → {SNAPSHOT_FILE}, {HISTORY_FILE}")


if __name__ == "__main__":
    main()
