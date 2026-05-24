#!/usr/bin/env python3
"""
Portfolio Monthly Review & Rebalance Assistant
Reads snapshot + wishlist, produces a markdown report with action items.
Run monthly via cron. Saves report to ~/.hermes/portfolio/reports/
"""

import csv, json, os
from datetime import datetime
from pathlib import Path

HOME = Path.home()
BASE = HOME / ".hermes" / "portfolio"
SNAPSHOT = BASE / "portfolio_snapshot.csv"
WISHLIST = BASE / "wishlist_conviction.json"
REPORTS  = BASE / "reports"
REPORTS.mkdir(exist_ok=True)

TOTAL_PORTFOLIO_TARGET = 33317  # from screenshot; adjust as it grows
ONE_PCT = TOTAL_PORTFOLIO_TARGET * 0.01

# ── Load snapshot ────────────────────────────────────────────────────────────
holdings = []   # active positions only (shares > 0)
wishlist_items = []

if SNAPSHOT.exists():
    with SNAPSHOT.open(newline="") as f:
        for row in csv.DictReader(f):
            t = row["ticker"]
            if t.startswith("_"):
                continue
            shares = float(row["shares"] or 0)
            price  = float(row["live_price"] or 0)
            mktval = float(row["mkt_val"] or 0)
            note   = row["note"]
            if shares > 0:
                holdings.append({
                    "ticker": t, "shares": shares, "price": price,
                    "mkt_val": mktval, "note": note,
                    "pct_of_port": round(mktval / TOTAL_PORTFOLIO_TARGET * 100, 2) if TOTAL_PORTFOLIO_TARGET else 0,
                })
            else:
                wishlist_items.append(t)

# ── Load wishlist convictions ────────────────────────────────────────────────
conviction_scores = {}
if WISHLIST.exists():
    wl = json.loads(WISHLIST.read_text())
    for t, data in wl.items():
        conviction_scores[t] = data.get("conviction")

# ── Analysis ─────────────────────────────────────────────────────────────────
lines = []
lines.append(f"# 📊 Portfolio Monthly Review — {datetime.now().strftime('%B %Y')}")
lines.append("")
lines.append(f"**Portfolio value:** ${TOTAL_PORTFOLIO_TARGET:,.0f}  —  **1% position** = ${ONE_PCT:,.0f}")
lines.append("")

# 1. Active holdings table
lines.append("## Active Positions")
lines.append("| Ticker | Shares | Last | Mkt Val | % Port | Note |")
lines.append("|--------|--------|------|---------|--------|------|")
for h in sorted(holdings, key=lambda x: -x["mkt_val"]):
    lines.append(
        f"| {h['ticker']} | {h['shares']} | ${h['price']:.2f} | ${h['mkt_val']:,.2f} | {h['pct_of_port']:.1f}% | {h['note']} |"
    )
lines.append("")

# 2. Concentration check
large = [h for h in holdings if h["pct_of_port"] >= 5]
if large:
    lines.append("### ⚠️ Concentration risk (≥5% each)")
    for h in large:
        lines.append(f"- **{h['ticker']}** — {h['pct_of_port']:.1f}% of portfolio")
    lines.append("")

# 3. Speculative / micro-cap flag
spec_sector = ["micro-cap", "pink-sheet", "ventura", "pure", "fwb2", "scm", "otcqb"]
speculative = [h for h in holdings if any(tag in h["note"].lower() for tag in spec_sector)]
if speculative:
    lines.append("### 🔴 Speculative / micro-cap holdings")
    for h in speculative:
        lines.append(f"- {h['ticker']} — {h['pct_of_port']:.1f}%  ({h['note']})")
    lines.append("")

# 4. Wishlist / planned additions
lines.append("## 🎯 Wishlist (planned 1% additions)")
lines.append("| Ticker | Conviction (1–10) | Status |")
lines.append("|--------|-------------------|--------|")
for t in ["RDW", "OUST", "SMR", "ELF"]:
    score = conviction_scores.get(t, "—")
    status = "✓ ready" if isinstance(score, int) and score >= 7 else "⏳ research needed" if score is None else "⚠️ low conviction"
    lines.append(f"| {t} | {score} | {status} |")
lines.append("")

# 5. Action items checklist
lines.append("## ✅ Action Items for This Month")
items = []
if not os.path.exists(str(BASE / "live_prices.csv")):
    items.append("- [ ] Update live_prices.csv with current market prices from your broker")
items.append("- [ ] Review each speculative holding: update thesis, decide hold/trim/exit")
items.append("- [ ] Rank wishlist by conviction; deploy new monthly capital to top 1–2")
items.append("- [ ] Check position sizing: no single speculative > 3% without strong conviction")
items.append("- [ ] Consider trimming any position that has drifted >2× its target 1%")
items.append("- [ ] Update cost basis in a separate ledger if not tracked already")
lines.extend(items)
lines.append("")

# 6. Market commentary placeholder
lines.append("## 📝 Your notes")
lines.append("_Add your thoughts on macro conditions, sector rotation, or specific catalysts._")
lines.append("")

report_md = "\n".join(lines)
stamp = datetime.now().strftime("%Y-%m")
report_path = REPORTS / f"review-{stamp}.md"
report_path.write_text(report_md)

print(f"✅ Monthly review report written → {report_path}")
print(f"   Actions: {len([i for i in items if i.startswith('- [ ]')])} open items")

# Also echo key stats
active_val = sum(h["mkt_val"] for h in holdings)
print(f"   Active holdings: {len(holdings)}  |  Total active value: ${active_val:,.2f}")
print(f"   Wishlist: {', '.join(wishlist_items) if wishlist_items else '(none)'}")

