# Daily Stock News Digest Runbook

## What happened in this session
- A cron prompt requested:
  `python3 /opt/data/home/.hermes/scripts/daily_stock_news.py`
- That path did **not** exist in the live environment.
- The actual runnable script was discovered here:
  `/root/.hermes/skills/stock-trading/references/portfolio-tracker/scripts/daily_stock_news.py`
- Running the discovered script produced the daily Yahoo Finance digest successfully.

## Practical lesson
- Do **not** trust the requested script path blindly.
- When a scheduled job references a missing script, search the filesystem for the actual script before retrying.
- In this environment, stock-news scripts may live under the stock-trading skill's reference tree instead of `/opt/data/home/.hermes/scripts/`.

## Verified output notes
- The script fetched news for 19 tickers and returned a Markdown digest.
- Near/below-threshold holdings in this run:
  - `RDW` at `$9.20` (below `$10`)
  - `ELF` at `$61.79` (below `$63`)
  - `CELH` at `$34.26` (above `$33`)

## Reuse
If the requested path fails again, search for `daily_stock_news.py` and run the discovered script directly.
