---
name: portfolio-tracker
category: stock-trading
description: Systematic personal portfolio tracking with manual price updates, conviction-based position sizing, and structured monthly reviews. Includes snapshot/history maintenance, thesis validation, and rebalancing checklists.
triggers: ["portfolio", "tracker", "prices", "review", "rebalance", "conviction", "position-sizing"]
---

# Portfolio Tracker Skill

A complete, offline portfolio management system for active investors who want systematic decision-making, not emotional reactions. Tracks holdings, maintains conviction journals, runs monthly reviews, and surfaces drift alerts. Works with any broker via manual CSV entry — no API keys required.

## When to Use

Load this skill when:
- Setting up a personal investment tracking system from scratch
- Needing to maintain conviction scores and thesis documents for each holding
- Running structured monthly portfolio reviews with concentration checks
- Tracking portfolio history and performance drift over time
- Managing multiple speculative positions with mechanical position sizing rules (e.g., 1% per new position)
- Integrating broker price updates into a centralized decision journal
- Building disciplined rebalancing habits (quarterly trim, monthly review)

## What This Skill Provides

### Scripts (installed to `~/.hermes/scripts/`)

| Script | Purpose |
|--------|---------|
| `portfolio_tracker.py` | Core engine — reads `live_prices.csv`, writes `portfolio_snapshot.csv` + `portfolio_history.csv` |
| `portfolio_summary.py` | Terminal dashboard — one-glance view of all holdings with market values and percentages |
| `portfolio_monthly_review.py` | Generates markdown review report with concentration warnings, speculative holdings list, and action items |
| `portfolio_daily_check.py` | Quick health summary for daily cron (top holdings, speculative watchlist, next steps) |
| `portfolio_performance.py` | ASCII trend chart showing total value drift across history |
| `portfolio_import_daily_prices.py` | Bulk price importer from your daily stock news script output (TSV/CSV) |
| `daily_stock_news.py` | Market news digest — fetches Yahoo Finance RSS + Google News for S&P 500, NASDAQ, and followed tickers; outputs Markdown for Discord/Telegram |
| `linear_export.py` | Weekly backup of Linear StockPlan team issues — exports all issues to JSON and CSV with fields: id, identifier, title, description, state, priority, assignee, project, timestamps |
| `portfolio_monthly_report_cron.py` | Cron wrapper that generates and prints the monthly review (for automated delivery) |

### Data Files (stored in `~/.hermes/portfolio/`)

| File | Purpose |
|------|---------|
| `portfolio_snapshot.csv` | Latest snapshot of all positions with live prices and market values |
| `portfolio_history.csv` | Append-only timestamped log for time-series analysis |
| `live_prices.csv` | **Manual price input** — you update this from your broker statement |
| `wishlist_conviction.json` | Structured thesis tracking for planned additions (conviction 1–10, catalyst, exit rule) |
| `reports/review-YYYY-MM.md` | Monthly markdown reviews (generated) |

## Setup

```bash
# If skill is installed via Hermes, scripts are already in ~/.hermes/scripts/
# Initialize data files (first run):
python ~/.hermes/scripts/portfolio_tracker.py --once

# Then update prices:
python ~/.hermes/scripts/portfolio_tracker.py   # interactive prompts
# or bulk:
python ~/.hermes/scripts/portfolio_import_daily_prices.py /path/to/daily_prices.tsv
```

## Quick Commands

```bash
# Daily (2 min)
python ~/.hermes/scripts/portfolio_tracker.py          # enter prices manually
python ~/.hermes/scripts/portfolio_summary.py          # view snapshot

# Weekly check
python ~/.hermes/scripts/portfolio_performance.py      # see value trend
python ~/.hermes/scripts/portfolio_daily_check.py      # health summary

# Monthly (15 min)
# 1. Edit conviction scores:
nano ~/.hermes/portfolio/wishlist_conviction.json
# 2. Generate review:
python ~/.hermes/scripts/portfolio_monthly_review.py
# 3. Read report:
cat ~/.hermes/portfolio/reports/review-$(date +%Y-%m).md
```

## Customization

### Edit your holdings list
Modify the `PORTFOLIO` array in `portfolio_tracker.py`:
```python
PORTFOLIO = [
    ("AMD", 20.2915, "large-cap tech"),
    # ... add/remove as needed
    ("RDW", 0.0, "space infra — planned 1%"),   # wishlist entries have shares=0
]
```

### Adjust 1% position size
The baseline uses `TOTAL_PORTFOLIO_TARGET = 33317`. Update it in `portfolio_monthly_review.py` as your AUM grows:
```python
TOTAL_PORTFOLIO_TARGET = 50000  # updated 2026-05
```

### Set conviction before buying
Edit `wishlist_conviction.json`:
```json
{
  "RDW": {
    "conviction": 7,
    "max_allocation_pct": 1.0,
    "thesis": "Space infrastructure — in-space manufacturing",
    "catalyst": "NASA contract announcement",
    "exit": "Sell if: no revenue growth for 2 quarters; dilution >10%"
  }
}
```
**Conviction scale:** 1–3 (speculative bet), 4–6 (moderate), 7–8 (high), 9–10 (core holding).

### Wire to your daily stock news script
If your daily Hermes stock cron outputs ticker/price pairs, pipe to the importer:
```bash
python ~/.hermes/scripts/daily_stock_prices.py > /tmp/prices.tsv
python ~/.hermes/scripts/portfolio_import_daily_prices.py /tmp/prices.tsv
```

## Automation (cron)

**Monthly review** — first Monday 9 AM:
```bash
hermes cron create \
  --name "📊 Monthly Portfolio Review" \
  --schedule "0 9 1 * *" \
  --prompt "python /opt/data/home/.hermes/scripts/portfolio_monthly_report_cron.py" \
  --deliver origin
```
The cron job prints the markdown report; use `--deliver discord:#channel` to route to a specific channel, or pipe through `kb-report` skill for formatted delivery.

**Daily health check** (optional — after your stock news cron):
```bash
0 8 * * * python /opt/data/home/.hermes/scripts/portfolio_daily_check.py >> ~/cron/daily_portfolio.log 2>&1
```

### Lightweight monthly review (CSV-based) — DEFAULT

The deployed system uses a simple CSV-driven review (`portfolio_review.py`) that reads `~/hermes/portfolio/live_prices.csv` and outputs a markdown table with concentration warnings. This is the **active setup** in your Hermes instance.

```bash
# Ensure CSV exists with columns: ticker, shares, avg_cost, current_price
python3 /opt/data/home/.hermes/scripts/portfolio_review.py
```

**Cron job deployed:**
- Name: `portfolio-review-monthly`
- Schedule: `0 9 1 * *` (first Monday 9 AM UTC, but actually 1st of month at 09:00)
- Deliver: `origin` (Discord/Telegram/Slack/Email)
- Output file: `~/obsidian-vault/FACorreia/Raw/Portfolio/Monthly/YYYY-MM Portfolio Review.md`

**Auto-warnings:**
- ⚠️ Position ≥10% → concentration risk
- 🔶 Position ≥5% → approaching allocation limit
- Full table: Ticker | Shares | Avg Cost | Price | Mkt Value | P&L | % of Port

**User preferences (from memory):**
- Uses 1% position sizing for new names (~$380 per 1% at $38k portfolio)
- Wishlist: RDW, SMR, ELF, OUST — deploy $500–600/month into top 1–2 convictions
- Trim over-concentrated holdings (AMD, GOOGL flagged)
- Buy dips on ZETA and HIMS
- Allocation bands: large-caps 40–50%, mid-caps 20–30%, speculative 10–20% max, cash 5–10%

See `references/lightweight-review.md` for script details. The full `portfolio-tracker` suite (snapshot/history system) remains available but not actively used in this setup.

## Design Principles

- **Manual-first:** No external API dependencies. You own the price data from your broker.
- **Thesis-driven:** Every position (existing or planned) must have a written catalyst and exit rule.
- **Mechanical sizing:** New positions default to 1% of portfolio; speculative caps at 3% total.
- **Monthly cadence:** Formal review prevents reactive day-trading; quarterly rebalancing trims drift.
- **Local-only:** All data stays in `~/.hermes/portfolio/` — no cloud, no third-party tracking.

## Decision Rules (Built-in Checks)

The monthly review script automatically warns if:
- Any position ≥5% of portfolio (concentration risk)
- Speculative/micro-cap tags appear in position notes (high-risk flag)
- No conviction score set for wishlist items (reminder to research before buying)
- Position drifted >2× target allocation (suggest trim)

## Integration with Other Skills

- `kb-report` — use to deliver monthly review markdown to Discord/Telegram automatically
- `obsidian` — your vault already mounts `/opt/obsidian-vault/`; symlink `~/.hermes/portfolio/reports/` into your notes for easy linking
## Linear Integration

The `linear_export.py` script provides automated weekly backups of your Linear StockPlan team issues. This is useful for:

- Maintaining an offline archive of all issues
- Analyzing issue trends and completion rates
- Integrating Linear data with other systems (e.g., portfolio tracking, research)
- Disaster recovery if Linear access is lost

### Script Location

The script is located at:
`~/.hermes/skills/stock-trading/references/portfolio-tracker/scripts/linear_export.py`

It is **not** at `/opt/data/home/.hermes/scripts/linear_export.py` — that path is outdated and should not be used.

### How to Run

Run the script directly with Python 3:

```bash
python3 ~/.hermes/skills/stock-trading/references/portfolio-tracker/scripts/linear_export.py
```

The script will:
- Connect to the Linear GraphQL API using your API key
- Fetch all issues for the StockPlan team (team ID: `fc9cf858-9a37-4215-ba7e-bae0eae499cc`)
- Export issues to JSON and CSV formats
- Save to `~/.cache/hermes/linear_exports/YYYY-WW/` (weekly folders)

### Output Format

**JSON file** (`issues.json`):
```json
{
  "generatedAt": "2026-05-09T10:01:00.000000",
  "team": "StockPlan",
  "issues": [
    {
      "id": "issue-id",
      "identifier": "PROJ-123",
      "title": "Issue title",
      "description": "Issue description",
      "state": {"id": "state-id", "name": "Open", "type": "Open"},
      "priority": "P0",
      "createdAt": "2026-05-01T10:00:00.000Z",
      "updatedAt": "2026-05-08T14:30:00.000Z",
      "completedAt": null,
      "assignee": {"name": "Fernando Correia"},
      "project": {"name": "StockPlan iOS"}
    },
    ...
  ]
}
```

**CSV file** (`issues.csv`):
Columns: identifier, title, state, priority, project, assignee, createdAt, updatedAt, completedAt

### Cron Setup

To automate weekly exports, create a cron job. The script should run on a weekly schedule (e.g., every Monday at 9 AM UTC).

**Important**: Do not use the outdated path. Instead, use the actual script location:

```bash
hermes cron create \
  --name "Linear Weekly Export" \
  --schedule "0 9 * * 1" \
  --prompt "python3 /root/.hermes/skills/stock-trading/references/portfolio-tracker/scripts/linear_export.py" \
  --deliver origin
```

This will run the export and deliver the summary to your configured channels (Discord, Telegram, etc.).

### API Configuration

The script uses these environment-sensitive values:

- **API Key**: `<LINEAR_API_KEY>` (stored in the script)
- **Team ID**: `fc9cf858-9a37-4215-ba7e-bae0eae499cc` (StockPlan team)

**Security note**: The API key is hardcoded in the script for convenience. If this is a security concern, extract it to a configuration file or environment variable.

### Troubleshooting

**Issue**: Script fails with GraphQL errors.
**Check**: Ensure the API key is valid and has permission to read issues for the StockPlan team.

**Issue**: No output files are created.
**Check**: Verify the export directory exists: `~/.cache/hermes/linear_exports/`. The script creates weekly subfolders automatically.

**Issue**: Cron job fails silently.
**Check**: Add logging redirection to capture errors:
```bash
0 9 * * 1 python3 /root/.hermes/skills/stock-trading/references/portfolio-tracker/scripts/linear_export.py >> /var/log/linear_export.log 2>&1
```

### Recent Export Results

The most recent export (2026-05-09) generated:
- **65 issues** exported
- JSON saved to: `~/.hermes/home/.cache/hermes/linear_exports/2026-W18/issues.json`
- CSV saved to: `~/.hermes/home/.cache/hermes/linear_exports/2026-W18/issues.csv`
- Summary: "📦 Linear export complete — 65 issues — JSON: issues.json, CSV: issues.csv — ~/.cache/hermes/linear_exports/2026-W18/"

This demonstrates the script works correctly when run from its proper location.

## Caveats

⚠️ **Not financial advice** — this is a journaling and decision-support system.  
⚠️ Price accuracy depends on your manual entry.  
⚠️ Micro-cap tickers (ADUR, KRKNF, A6I, etc.) carry high failure risk; use the concentration limits.  
⚠️ CAD-denominated positions (ADUR) have FX exposure not tracked by this system.

---

**Version:** 1.0 — created 2026-04-29 for [𝓓𝓻𝓪𝓬𝓪𝓻𝔂𝓼 𝓣𝓲𝓰𝓮𝓻]'s StockPlan portfolio  
**Install path:** `~/.hermes/skills/portfolio-tracker/`  
**Data path:** `~/.hermes/portfolio/`
