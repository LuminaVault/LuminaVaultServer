# Lightweight Portfolio Monthly Review

This reference documents the simple CSV-based portfolio review automation introduced in the Portfolio Tracker skill.

## Overview

- **Script**: `portfolio_review.py`
- **Reads**: `~/hermes/portfolio/live_prices.csv` (columns: `ticker`, `shares`, `avg_cost`, `current_price`)
- **Computes**: market value, unrealized P&L, % of portfolio per position
- **Warns**: concentration risk (≥10% ⚠️, ≥5% 🔶)
- **Saves**: markdown report to `~/obsidian-vault/FACorreia/Raw/Portfolio/Monthly/YYYY-MM Portfolio Review.md`
- **Prints**: summary to stdout (for cron delivery to Discord/Telegram/Slack/Email)

## CSV Format

```csv
ticker,shares,avg_cost,current_price
AMD,20.2915,300,329.54
GOOGL,11.641,320,350.96
ZETA,200.378,18,18.33
...
```

`avg_cost` may be zero if unknown; P&L will be unrealized only (no cost basis).

## Full Script

```python
#!/usr/bin/env python3
"""
Monthly portfolio review automation.
Reads ~/hermes/portfolio/live_prices.csv and outputs markdown review to vault.
"""
import os, csv, datetime

HOME = os.path.expanduser('~')
PORTFOLIO_DIR = os.path.join(HOME, 'hermes', 'portfolio')
CSV_PATH = os.path.join(PORTFOLIO_DIR, 'live_prices.csv')
VAULT_ROOT = os.path.expanduser('~/obsidian-vault/FACorreia')
OUTPUT_DIR = os.path.join(VAULT_ROOT, 'Raw', 'Portfolio', 'Monthly')

def read_csv(path):
    pos = []
    with open(path, newline='', encoding='utf-8') as f:
        for row in csv.DictReader(f):
            pos.append({
                'ticker': row['ticker'],
                'shares': float(row['shares']),
                'avg_cost': float(row['avg_cost'] or 0),
                'current_price': float(row['current_price']),
            })
    return pos

def compute(pos):
    total_mv = 0; total_cb = 0
    for p in pos:
        mv = p['shares'] * p['current_price']
        cb = p['shares'] * p['avg_cost'] if p['avg_cost'] else 0
        p['mkt_val'] = mv
        p['cost_basis'] = cb
        p['pnl'] = mv - cb
        total_mv += mv; total_cb += cb
    enriched = []
    for p in pos:
        pct = (p['mkt_val'] / total_mv * 100) if total_mv else 0
        enriched.append({**p, 'pct': pct})
    return enriched, total_mv, total_mv - total_cb, total_cb

def warnings(pos):
    ws = []
    for p in pos:
        pct = p['pct']
        if pct > 10:
            ws.append(f"⚠️  {p['ticker']} is {pct:.1f}% of portfolio — concentration risk")
        elif pct > 5:
            ws.append(f"🔶 {p['ticker']} is {pct:.1f}% — approaching allocation limit")
    return ws

def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    now = datetime.date.today()
    out_path = os.path.join(OUTPUT_DIR, f"{now.strftime('%Y-%m')} Portfolio Review.md")

    if not os.path.exists(CSV_PATH):
        print(f"❌ CSV not found: {CSV_PATH}")
        return

    pos = read_csv(CSV_PATH)
    enriched, tot_val, tot_pnl, tot_cb = compute(pos)
    ws = warnings(enriched)

    lines = [
        f"# 📊 Portfolio Review — {now.strftime('%B %Y')}",
        "",
        f"> ⏰ {now.isoformat()}",
        f"> 💰 Total Value: ${tot_val:,.2f}",
        f"> 📈 Unrealized P&L: ${tot_pnl:+,.2f}",
        "",
        "| Ticker | Shares | Avg Cost | Price | Mkt Value | P&L | % of Port |",
        "|--------|--------|----------|-------|-----------|-----|-----------|"
    ]
    for p in enriched:
        ac = f"${p['avg_cost']:.2f}" if p['avg_cost'] else "—"
        lines.append(
            f"| {p['ticker']} | {p['shares']:.4f} | {ac} | ${p['current_price']:.2f} | "
            f"${p['mkt_val']:,.2f} | ${p['pnl']:+,.2f} | {p['pct']:.2f}% |"
        )
    if ws:
        lines.extend(["", "## ⚠️ Warnings", ""]); lines.extend(ws)

    with open(out_path, 'w', encoding='utf-8') as f:
        f.write("\n".join(lines) + "\n")
    print(f"✅ Review saved: {out_path}")
    print(f"💰 ${tot_val:,.2f}  📈 ${tot_pnl:+,.2f}")
    for w in ws: print(w)

if __name__ == '__main__':
    main()
```

## Cron Setup

Create a monthly cron job (first Monday 9 AM UTC):

```bash
hermes cron create \
  --name "portfolio-review-monthly" \
  --schedule "0 9 1 * *" \
  --prompt "python3 /opt/data/home/.hermes/scripts/portfolio_review.py" \
  --deliver origin
```

The job will run automatically and post the summary to all configured platforms (Discord, Telegram, Slack, Email).

## Customization

- **Thresholds**: edit `warnings()` function to change % limits.
- **Output path**: modify `OUTPUT_DIR`.
- **Extra metrics**: extend `compute()` to include sector tags, daily change, etc.

## Caveats

- This lightweight script does not maintain history or conviction scores. For those features, adopt the full `portfolio_tracker.py` system.
- FX exposure for non-USD positions (e.g., ADUR) is not adjusted.
- Ensure `live_prices.csv` is kept reasonably up-to-date for meaningful review.
