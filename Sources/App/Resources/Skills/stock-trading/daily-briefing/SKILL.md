---
name: daily-briefing
description: Generate and deliver comprehensive daily market intelligence briefings using only Python standard library.
license: MIT
tags: [cron, market-data, yahoo-finance, rss, telegram, discord, slack]
related_skills: [stock-trading, ai-scoreboard]
---

# Daily Briefing Generator

Autonomous generation of morning market intelligence reports for AI cohorts and investment portfolios. This skill provides a complete, dependency-free implementation that fetches live prices, news headlines, and formats a professional Markdown briefing for delivery across all platforms (Telegram, Discord, Slack).

## When to Use

- When a scheduled cron job fails due to a missing script (e.g., `daily_brief.py` not found)
- When you need a lightweight, stdlib-only briefing generator
- When external dependencies like `pandas`/``matplotlib` are not available
- As a template for custom briefing implementations

## Key Features

- **Zero external dependencies** — uses only Python standard library
- **Live market data** — fetches prices directly from Yahoo Finance's public chart API
- **News aggregation** — pulls headlines from Yahoo Finance RSS and Google News
- **Multi-format output** — generates clean Markdown suitable for Hermes origin delivery
- **Cross-platform delivery** — integrates with Hermes's built-in delivery to Telegram, Discord, Slack

## Implementation

### Script Structure

```python
#!/usr/bin/env python3
"""
Daily Morning Briefing — Comprehensive market intelligence for the AI cohort and portfolio.
"""
```

The script performs these steps:

1. **Load environment** — reads credentials from `/opt/data/.env` if present
2. **Fetch major indices** — S&P 500, Nasdaq, Russell 2000, VIX
3. **Fetch AI cohort prices** — reads ticker list from `~/.hermes/scripts/ai-scoreboard/config.yaml`
4. **Fetch news headlines** — for key tickers using RSS/Atom feeds
5. **Format briefing** — assembles into professional Markdown with sections
6. **Output to stdout** — captured by Hermes for delivery to configured platforms

### Direct Yahoo Finance API Usage

Instead of using `yfinance` or `pandas`, the script uses Yahoo's public chart API directly:

```python
def yahoo_price(ticker: str) -> Optional[float]:
    conn = http.client.HTTPSConnection("query1.finance.yahoo.com")
    conn.request("GET", f"/v8/finance/chart/{ticker}?range=1d&interval=1m")
    # ... parse JSON response for regularMarketPrice
```

This approach works without any external packages and is resilient to dependency issues.

### News Aggregation

The script implements custom RSS/Atom parsers to fetch headlines:

```python
def fetch_news_rss(url: str) -> List[Dict]:
    # Fetches and parses RSS 2.0 or Atom feeds
```

It uses Yahoo Finance's headline feed and falls back to Google News RSS.

### Configuration

The AI cohort configuration is read from:
```
~/.hermes/scripts/ai-scoreboard/config.yaml
```

This file defines:
- `winners`: 12 AI winner tickers
- `disrupted`: 12 AI disrupted names
- `watchlist`: High-conviction tactical picks

### Delivery Integration

The script outputs Markdown to stdout. Hermes cron jobs with `Deliver: origin` automatically capture this output and forward it to all configured platforms (Telegram, Discord, Slack) based on other active cron jobs.

## Usage

### Manual Execution

```bash
python3 /opt/data/scripts/daily_brief.py
```

This generates the briefing and delivers it immediately.

### Cron Job Integration

If the original `daily_brief.py` script is missing, replace it with this implementation. The existing cron job configuration will work unchanged.

**Example cron entries that will use this script:**
```
Name:      Morning Briefing
Schedule:  0 8 * * *
Deliver:   origin
Script:    daily_brief.py
```

### Customization

To customize the briefing:
1. Edit the script's `INDICES` list for different market indices
2. Modify the `news_tickers` list to focus on different stocks
3. Adjust the `all_tickers[:6]` slice to show more/fewer cohort members
4. Add new sections by extending the `briefing` string template

## Troubleshooting

### Yahoo Finance API Returns 404

Some tickers may return 404 if they require special suffixes (e.g., `A6I.F`). Add normalization rules to the `YAHOO_NORMALIZE` dictionary:

```python
YAHOO_NORMALIZE = {
    "A6I": "A6I.F",
}
```

### Missing Environment Variables

The script reads credentials from `/opt/data/.env`. Ensure this file contains:
```
TELEGRAM_BOT_TOKEN=***
DISCORD_BOT_TOKEN=***
TELEGRAM_HOME_CHANNEL=***
```

If credentials are missing, delivery will still work via Hermes origin delivery, but platform-specific wrappers won't function.

### Dependencies Not Installed

This is the primary advantage of this implementation — it uses only Python standard library. No `pip install` required.

## Verification

To test the script:

```bash
python3 /opt/data/scripts/daily_brief.py --test
```

The test mode simulates execution without sending alerts or updating state.

## References

- **AI Cohort Scoreboard README** — `/opt/data/scripts/ai-scoreboard/README.md` — Original comprehensive market intelligence system
- **Portfolio Threshold Alerts** — `/opt/data/scripts/portfolio_threshold_alerts.py` — Example of direct Yahoo Finance API usage
- **Yahoo Finance Chart API** — https://query1.finance.yahoo.com/v8/finance/chart/{ticker}?range=1d&interval=1m

## Performance

- **Execution time:** ~30 seconds (network-bound)
- **Memory footprint:** Minimal (no heavy libraries)
- **Reliability:** High — uses direct HTTP connections with timeouts

## Security

- No external package sources (avoids PyPI dependency risks)
- All data fetched over HTTPS
- Credentials read from local .env file only
- No sensitive data logged

## Future Enhancements

- Add technical indicators (SMA, RSI) using Yahoo Finance data
- Include options flow data
- Add insider trading activity
- Support for forex and crypto markets
- Scheduled delivery with timezone awareness

## Changelog

- **2026-05-05:** Initial implementation — stdlib-only daily briefing generator
- **2026-05-05:** Fixed syntax errors, added proper error handling for missing tickers
- **2026-05-05:** Integrated with Hermes delivery system

## See Also

- `stock-trading` skill for portfolio management and alerts
- `ai-scoreboard` skill for comprehensive AI cohort intelligence (if dependencies available)