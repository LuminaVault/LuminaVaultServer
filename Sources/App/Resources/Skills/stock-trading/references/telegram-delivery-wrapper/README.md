# Telegram Delivery Wrapper — Reference

## What it does
`stock_alert_telegram.py` is a generic wrapper that executes any Python script and delivers its stdout to a Telegram chat. Used by cron jobs to post Markdown reports (Linear digests, stock alerts, server monitors) without embedding Telegram logic in each script.

## Location
`/opt/data/home/.hermes/scripts/stock_alert_telegram.py`

## Environment variables
| Variable | Purpose | Source |
|----------|---------|--------|
| `TELEGRAM_BOT_TOKEN` | Bot API token | `/opt/data/.env` |
| `TELEGRAM_HOME_CHANNEL` | Target chat ID (channel or group) | `/opt/data/.env` |
| `TELEGRAM_ALLOWED_USERS` | Fallback: comma-separated user IDs; first is used if `HOME_CHANNEL` unset | `/opt/data/.env` |

## Typical usage patterns

### 1. Simple cron job delivery
```python
#!/usr/bin/env python3
# your_script.py — generates Markdown report
print("# Daily Report\n")
print("All systems nominal.")
```
Cron invocation:
```bash
source /opt/data/.env && cd /opt/data/home/.hermes/scripts && \
  python stock_alert_telegram.py your_script.py
```

### 2. Linear digest integration (actual use case)
```bash
source /opt/data/.env && cd /opt/data/home/.hermes/scripts && \
  python stock_alert_telegram.py linear_daily_digest.py
```
Output: Markdown digest of Linear issues updated in last 24h. Delivered to Telegram home channel even when no issues (quiet message still posted if stdout non-empty).

### 3. Alert-signal semantics
Wrapper sends when:
- stdout is non-empty (any content)
- OR wrapped script exits with code 1 (convention: "alert" signal)
If neither condition holds, Telegram is skipped (silent success).

## Implementation notes
- **HTTP client**: `urllib.request` with JSON payload, 15s timeout
- **Parse mode**: `Markdown` (not `MarkdownV2`)
- **Max message length**: 4096 chars (Telegram limit); output is truncated if longer
- **No parse-mode escaping**: User scripts must produce Telegram-safe Markdown (avoid unbalanced backticks, underscores, etc.)
- **Exit code**: Wrapper propagates wrapped script's exit code (except delivery failures don't override; they log to stderr only)

## Troubleshooting
| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| "TELEGRAM_BOT_TOKEN or TELEGRAM_HOME_CHANNEL not set" | `.env` not sourced | Prepend `source /opt/data/.env` to cron command |
| Message not arriving, exit code 0 | Script produced no stdout and exit code != 1 | Ensure script prints output even for "no activity" cases |
| HTTP 429 (rate limit) | Too many messages; Telegram enforces ~30/sec per bot | Backoff handled automatically (60s wait); retry eventually |
| Markdown rendering broken | Unescaped special chars in output | Escape Telegram Markdown special chars: `_ * [ ] ( ) ~ \` > # + - = | { } . !` |

## Related scripts using this wrapper
- `linear_daily_digest.py` → daily Linear issue summary
- `linear_weekly_sprint.py` → weekly sprint metrics (when wired to Telegram)
- `server_resource_monitor_telegram_cron.py` → server health alerts (uses direct send; wrapper alternative)
- All scripts under `stock-alert-orchestrator/` can use wrapper for simple notifications
