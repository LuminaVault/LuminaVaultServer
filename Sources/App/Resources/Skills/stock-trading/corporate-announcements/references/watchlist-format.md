# Watchlist Format

Used by: `corporate-announcements`, `stock-trading/stock-threshold-monitoring`, `stock-trading/portfolio-tracker`

## Structure

Hardcoded Python list in the script:

```python
WATCHLIST = [
    "ZETA", "AMD", "AMZN", "HIMS", "OSCR", "SOFI", "KRKNF", "ONDS",
    "ABCL", "GRAB", "ASTS", "TE", "UBER", "NFLX", "NVO", "NKE", "SIDU",
    "SMR", "FLNC", "RDW", "ELF", "OUST", "CELH", "ZIP", "GOOGL"
]
```

**Order**: No required order; keep alphabetized or grouped by conviction/sector for readability.

## Conventions

- **Tickers only** — no exchange suffixes (`.SK`, `.L`, `.TO`). Use base symbols only.
- **Uppercase** — always store and compare in uppercase (`.upper()` before matching).
- **Length**: 1–5 characters typical; `KRKNF` is 5 chars (Kore钾); `ONDS` is 4 chars (Ondas).
- **No duplicates** — same ticker must not appear multiple times in the list.

## Source of Truth

The watchlist is **hardcoded in each script** that needs it:
- `earnings_announcements.py` — corporate announcements + (optional) earnings
- `stock_threshold_alert.py` — hourly price threshold monitoring
- `stock_alert_triple.py` — orchestrator for Slack/Telegram/Discord alerts

**Do not** read from a CSV or database to keep scripts self-contained and crontab-friendly.

## Sync Across Scripts

If you add/remove a ticker, update all three files. Consider extracting to a shared module later, but for now duplication is acceptable (each script must run standalone without imports).

## Position Sizing (Context)

From user profile:
- 1% position ≈ $380 at current portfolio size ($38k)
- Monthly deploy: $500–600 into top 1–2 convictions
- Allocation bands: large-caps 40–50%, mid-caps 20–30%, speculative 10–20%, cash 5–10%

This watchlist reflects the universe; actual portfolio may not hold all 25 tickers.
