---
name: stock-market-news-digest
description: Daily digest of S&P 500, NASDAQ, and followed stock news (Yahoo Finance RSS)
triggers:
  - keyword: stock-market-daily-digest
  - cron: daily 9am
trigger_type: keyword
---

# Stock Market News Digest Skill

Yields a Markdown digest of fresh headlines for:
- Indices: ^GSPC (S&P 500), ^IXIC (NASDAQ)
- Stocks: AMD, GOOGL, ZETA, HIMS, RDW, SMR, ELF, OUST

Sources: Yahoo Finance RSS feeds + Google News fallback.

## Usage

This skill runs as a scheduled cron job. To invoke manually:
```bash
hermes skill stock-market-news-digest -- "run daily digest"
```

The agent's stdout is auto-delivered to the configured channel.

## Implementation

Script: `stock_market_daily_digest.py`
Workdir: `/opt/data/home/.hermes/scripts`

State (deduplication): `~/.cache/hermes/stock_market_news/seen_links.json`

## Adding new tickers

Edit the `STOCKS` list in the script and redeploy.
