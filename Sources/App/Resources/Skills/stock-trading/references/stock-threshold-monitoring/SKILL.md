---
name: stock-threshold-monitoring
description: Hourly stock price threshold alerts across Discord, Telegram, Slack
version: 1.1.0
author: Hermes Agent
license: MIT
---

# Stock Threshold Monitoring

Monitors a list of stock tickers and sends an alert when any price falls at or below a user-defined threshold. Sends updates hourly on all configured platforms (Discord, Telegram, Slack) via separate per-platform cron jobs.

## Files

- **Script**: `~/.hermes/scripts/stock_threshold_alert.py`
- **Cron jobs**: Three hourly jobs (Discord, Telegram, Slack)
- **Related**: `crypto-threshold-monitoring` for cryptocurrency alerts

## Tickers & Thresholds (20 total)

| Ticker | Threshold | Notes |
|--------|-----------|-------|
| ZETA   | $15.00    | |
| AMD    | $200.00   | |
| AMZN   | $205.00   | |
| HIMS   | $25.00    | |
| OSCR   | $13.00    | |
| SOFI   | $16.00    | |
| KRKNF  | $5.50     | Karsi (KOSPI) |
| ONDS   | $8.00     | Ondas Holdings |
| ABCL   | $4.00     | |
| GRAB   | $3.50     | Grab Holdings |
| ASTS   | $60.00    | |
| TE     | $4.50     | |
| UBER   | $72.00    | |
| NFLX   | $80.00    | |
| NVO    | $40.00    | |
| NKE    | $40.00    | |
| SIDU   | $3.50     | |
| SMR    | $10.00    | Added 2026-04-28 |
| FLNC   | $10.00    | Added 2026-04-28 |
| RDW    | $7.00     | Added 2026-04-28 |

Thresholds are hard-coded in the script. To change them, edit the `THRESHOLDS` dict inside `stock_threshold_alert.py`.

## How It Works

1. The script fetches live prices from Yahoo Finance (`query1.finance.yahoo.com` chart API v8)
2. Compares each ticker's current price to its threshold
3. If any ticker ≤ threshold: Emits a formatted markdown alert with breach details (exit code 1)
4. If all clear: Emits nothing (exit code 0) — cron delivers silence
5. Cron jobs run the script hourly and deliver stdout to the assigned platform via Hermes gateway

## Channel Routing

By default, the three platform jobs deliver to their respective home channels. However, you can route specific platforms to named channels:

- **Discord stock alerts**: `discord:1498815493757341896` (channel `<#1498815493757341896>`)
- **Telegram**: Telegram home chat (unless overridden)
- **Slack**: Slack home channel (requires `SLACK_BOT_TOKEN`; may show delivery errors if not configured)

To re-route, edit the cron job's `--deliver` target via `hermes cron edit <job_id> --deliver <channel>`.

## Adding/Removing Tickers

Edit `~/.hermes/scripts/stock_threshold_alert.py`:
- Add/remove entries in the `THRESHOLDS` dictionary
- For non-standard Yahoo Finance symbols, add a mapping in `YAHOO_NORMALIZE`

## Testing

Run manually:
```bash
python3 ~/.hermes/scripts/stock_threshold_alert.py
```

Trigger a cron job manually:
```bash
hermes cron run <job_id>
```

## Job IDs (current)

| Platform  | Job ID | Deliver Target |
|-----------|--------|----------------|
| Discord   | `22584368cbfb` | `discord:1498815493757341896` |
| Telegram  | `4a09e5e68c43` | Telegram home |
| Slack     | `7934e36017c6` | Slack home (requires token) |

## Maintenance

- If the Yahoo Finance API changes, update the endpoint in `yahoo_price()`
- Prices are fetched from `chart` API v8, using `regularMarketPrice` from meta
- Network errors are logged to stderr but do not stop execution
- The script exits 0 when all clear, 1 when any breach detected (cron uses exit code for conditional delivery)

## Pitfalls & Environment Notes

**Tool environment mismatch**: When running stock price lookups that depend on `yfinance` or other non-stdlib Python packages:
- `execute_code()` uses `/opt/hermes/.venv/bin/python` — a minimal environment WITHOUT user-installed packages
- `terminal()` uses `/usr/bin/python3` — the system Python WITH site-packages at `/opt/data/home/.local/lib/python3.13/site-packages`

→ **Always use `terminal()` to run Python scripts that import yfinance, pandas, numpy, or other pip-installed packages.** Either:
1. Write a temp script file (`/tmp/script.py`) and run `python3 /tmp/script.py` via `terminal()`, OR
2. Use `terminal("python3 -c 'import yfinance...'")` with careful shell quoting

**Yahoo Finance API rate limiting**: Direct curl calls to `query1.finance.yahoo.com` may return "Too Many Requests" (HTTP 429). The v8 chart API is throttled. The production script handles this gracefully; ad-hoc queries may fail. If blocked, wait a few minutes before retrying.

## Related

- **Crypto alerts**: See `crypto-threshold-monitoring` skill for Bitcoin, Ethereum, Sui alerts on a 2-hour schedule to a separate Discord channel
- **X-based ticker discovery**: See `x-social-monitor` and `~/.hermes/scripts/follow_tickers.py` for discovering relevant accounts to follow
