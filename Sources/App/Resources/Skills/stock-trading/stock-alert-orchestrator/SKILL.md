---
name: stock-alert-orchestrator
description: "Cross-platform stock alert orchestrator: unified YAML-configured, stateful coordinator with per-platform deliverer subprocesses, threshold evaluation, and retry logic."
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: ["stock-alerts", "orchestrator", "cross-platform", "yaml-config", "stateful", "thresholds"]
    related_skills: ["stock-threshold-monitoring", "hermes-stock-alerts", "systematic-debugging"]
---

# Stock Alert Orchestrator

## Overview

A robust, modular stock monitoring system that checks prices hourly and sends alerts to Slack, Telegram, and Discord using webhook URLs. Unlike the simpler `stock-threshold-monitoring` approach (single script with per-platform wrappers), this is a **unified orchestrator** with:

- **YAML configuration** (`config/config.yaml`) for symbols, thresholds, and platform credentials
- **Stateful deduplication** (`state/alert_state.json`) — only alerts on new threshold crossings since last alert
- **Per-symbol threshold overrides** — fine-grained control beyond global defaults
- **Platform deliverer subprocesses** — each platform has an isolated deliverer script
- **Retry with exponential backoff** — configurable per-platform resilience
- **Structured JSON logging** — cron-friendly, aggregatable logs
- **Heartbeat file** — `state/last_run.txt` for monitoring liveness

## Directory Layout

```
stock-alert-orchestrator/
├── config/
│   ├── config.yaml          # symbols, thresholds, platform credentials, settings
│   └── README.md
├── scripts/
│   ├── stock_alert_orchestrator.py   # main coordinator
│   ├── stock_client.py               # Yahoo Finance fetcher (yfinance)
│   ├── deliver_slack.py              # Slack webhook deliverer
│   ├── deliver_telegram.py           # Telegram Bot API deliverer
│   └── deliver_discord.py            # Discord webhook deliverer
├── logs/
│   └── orchestrator.log              # structured JSON log lines
├── state/
│   ├── alert_state.json              # persistent deduplication state
│   └── last_run.txt                  # UTC timestamp heartbeat
├── requirements.txt                  # yfinance, requests, PyYAML
├── deploy.sh                         # install dependencies, validate config, install cron
└── crontab.example                  # hourly cron entry
```

## Configuration (`config/config.yaml`)

```yaml
symbols:
  - AAPL
  - GOOGL
  - TSLA
  - NVDA
  - SPY

thresholds:
  default:
    price_above: null          # no upper-bound alert by default
    price_below: null          # no lower-bound alert by default
    change_pct_above: 3.0      # alert if 1h change > +3%
    change_pct_below: -3.0     # alert if 1h change < -3%

symbol_thresholds:               # per-symbol overrides (merge with default)
  TSLA:
    change_pct_above: 5.0
    price_above: 250.00
  NVDA:
    price_above: 120.00
    price_below: 90.00

platforms:
  slack:
    enabled: false
    webhook_url: ""
    channel: "#stock-alerts"
    username: "Stock Alert Bot"
  telegram:
    enabled: false
    bot_token: ""
    chat_id: ""
  discord:
    enabled: false
    webhook_url: ""

settings:
  price_cache_ttl_seconds: 300   # yfinance cache TTL (5 min)
  max_retries: 3
  retry_backoff_seconds: 2
  state_file: "state/alert_state.json"
  log_file: "logs/orchestrator.log"
```

**Environment variable overrides** (useful for secrets):
- `SLACK_WEBHOOK_URL`, `SLACK_CHANNEL`, `SLACK_USERNAME`
- `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`
- `DISCORD_WEBHOOK_URL`
- `PRICE_CACHE_TTL`, `MAX_RETRIES`, `RETRY_BASE`

## Deployment

```bash
cd /opt/data/home/.hermes/scripts/stock-alert-orchestrator
./deploy.sh                    # installs deps, validates config, offers cron install
```

Or manually:
```bash
# 1. Install dependencies (requires pip)
python3 -m pip install --user -r requirements.txt

# 2. Edit config/config.yaml — set at least one platform enabled with credentials

# 3. Install hourly cron
# 0 * * * * cd /opt/data/home/.hermes/scripts/stock-alert-orchestrator && /usr/bin/python3 scripts/stock_alert_orchestrator.py >> /dev/null 2>&1

# 4. Monitor
tail -f logs/orchestrator.log
```

## How It Works (Flow)

1. **Load config** — YAML + environment overrides
2. **Fetch market data** — batch prices + 1-hour % change via `stock_client.py` (yfinance with caching)
3. **Evaluate thresholds** — for each symbol, check if any condition crossed since last alert (using `state/alert_state.json`)
4. **Generate alert event** — JSON event with symbol, price, change, triggered conditions, timestamp
5. **Dispatch to enabled platforms** — for each enabled platform, call deliverer script via subprocess with 30s timeout; retry on failure
6. **Update state** — only if **all** enabled platforms delivered successfully (atomic write)
7. **Write heartbeat** — `state/last_run.txt` with UTC timestamp
8. **Exit code** — 0 if all platforms ok; 1 otherwise (cron can email stderr)

## Threshold Logic

An alert fires when **ANY** threshold is crossed **and** it represents a new crossing since the last alert for that symbol:

- **First run** (no prior state) → always fires if any threshold is set
- **Subsequent runs** → compares current value against last alert value to detect direction changes
  - Example: `price_above=105`, last_alert_price=100, current=106 → fires (crossed up)
  - Example: last_alert_price=110, current=104 → no fire (already above, now below but didn't cross threshold boundary from below)

State keys per symbol: `last_alert_price`, `last_change_pct`, `last_alert_time`, `alert_count`, `last_triggered_conditions`.

## Deliverer Scripts

Each deliverer is standalone:
- **Input**: `python deliver_<platform>.py <platform_name> <alert_json_string>`
- **Output**: exit 0 on success, non-zero on failure (triggers orchestrator retry)
- **Credentials**: read from environment variables OR from keys injected into alert JSON by orchestrator
- **Logging**: print JSON log lines to stdout (captured by orchestrator)

## Common Pitfalls & Fixes

### Pitfall 1: SyntaxError — Unterminated f-strings

**Symptom**: `SyntaxError: unterminated string literal` at a line containing an f-string.

**Cause**: File corruption or editor mishandling of multi-line f-strings. Often appears when:
- Multi-line f-strings are split across lines with mismatched quotes
- A line ends with `"\n` (literal backslash-n inside quote) but the closing quote is on the next line with wrong escaping

**Detection**: `python3 -m py_compile <script>` will catch without executing.

**Fix**:
1. Locate the exact line and neighboring lines
2. Ensure multi-line f-strings use proper continuation:
   ```python
   # GOOD
   formatted = (
       f"Line 1\n"
       f"Line 2\n"
   )
   # BAD (broken)
   formatted = (
       f"Line 1
       "  # <- quote not on same line as f-string content
   )
   ```
3. Re-write the entire f-string block cleanly if needed (replace function).

### Pitfall 2: NameError — Missing imports

**Symptom**: `NameError: name 'os' is not defined` even though `os.getenv()` is called.

**Cause**: `import os` missing at top of file.

**Fix**: Add `import os` to the imports section. Always verify imports match usage.

### Pitfall 3: ModuleNotFoundError — dependencies not installed

**Symptom**: `ModuleNotFoundError: No module named 'yfinance'` (or `schedule`, etc.)

**Cause**: Python environment lacks required packages from `requirements.txt`.

**Fix** (choose one):
- Enable pip in the venv and `pip install -r requirements.txt`
- Install packages system-wide if available via system Python
- If no pip and no root: request package installation from system admin / switch to a Python with internet install access

**Note**: The orchestrator uses `yfinance` for market data; without it, the script cannot run.

### Pitfall 4: All platforms disabled → silent no-op

**Symptom**: Script runs, produces no alerts, no deliveries.

**Cause**: Every `platforms.*.enabled` is `false` in config.yaml.

**Fix**: Set at least one platform to `enabled: true` and provide valid credentials (webhook URL, bot token/chat ID, etc.).

### Pitfall 5: State file not updating after alerts

**Symptom**: Same alert fires every hour even though conditions haven't changed.

**Cause**: State update only happens when **all enabled platforms deliver successfully**. If any platform fails, state is NOT updated, so the alert remains "unacknowledged" and will re-fire.

**Fix**: Check logs for platform delivery failures; fix platform credentials or network issues. Use `tail -f logs/orchestrator.log` and look for `"Alert NOT fully delivered; state NOT updated"`.

### Pitfall 6: Cron runs but no log file created

**Symptom**: No `logs/orchestrator.log` file appears after cron runs.

**Cause**: Cron stdout/stderr may be redirected to `/dev/null` (as in crontab.example). The orchestrator only logs to file, not to stdout unless ERROR/CRITICAL.

**Fix**: Remove `>> /dev/null 2>&1` from cron entry during debugging, or ensure `logs/` directory is writable. Better: keep file logging and monitor the log file directly.

## Verification Checklist

Before declaring the orchestrator healthy:

- [ ] `python3 scripts/stock_alert_orchestrator.py` compiles (`py_compile` OK)
- [ ] All deliverer scripts compile (`deliver_slack.py`, `deliver_telegram.py`, `deliver_discord.py`)
- [ ] `stock_client.py` imports cleanly (no missing imports like `os`)
- [ ] Dependencies installed (`yfinance`, `requests`, `PyYAML`)
- [ ] `config/config.yaml` has at least one platform `enabled: true` with valid credentials
- [ ] `logs/` and `state/` directories exist and are writable
- [ ] Manual test run exits 0 and produces either an alert or a clean "no alerts" log entry
- [ ] Heartbeat file `state/last_run.txt` updates with current UTC timestamp
- [ ] Cron entry installed and pointing to correct absolute paths

## Troubleshooting Flow

1. **Script won't start / SyntaxError**
   - Run `python3 -m py_compile scripts/stock_alert_orchestrator.py`
   - Check for unterminated strings; fix with patch/replace
   - Verify all imports present

2. **Runtime import error (ModuleNotFoundError)**
   - Check `requirements.txt`
   - Verify Python environment has packages installed
   - If venv without pip: bootstrap pip or use system Python with packages

3. **No alerts ever fire**
   - Confirm thresholds are actually crossable (e.g., change_pct_above=3.0 is aggressive; price bounds may be too high/low)
   - Check log for "No price data for symbol" warnings
   - Test `stock_client.py` manually to see if yfinance returns data

4. **Alerts fire but not delivered**
   - Check which platforms are enabled in config
   - Verify webhook URLs / bot tokens are correct
   - Look in `orchestrator.log` for `" delivery failed"` entries
   - Fix credentials, re-run

5. **Alerts keep re-firing every hour**
   - Check state file: is it being updated?
   - Look for `"Alert NOT fully delivered; state NOT updated"` in logs → indicates partial platform failure
   - Fix failing platform or temporarily disable it

## Related Skills

- `systematic-debugging` — 4-phase root cause debugging methodology (use when orchestrator misbehaves)
- `stock-threshold-monitoring` — simpler single-script variant with per-platform wrappers (no state, no config)
- `hermes-stock-alerts` — architecture comparison between standalone and KG-powered alert systems
- `python-debugpy` — advanced Python debugging (pdb/remote) if deeper issues arise

## Support Files

This skill ships with operational helpers:

- **`references/syntax-error-patterns.md`** — common Python string literal corruption patterns seen in cron-deployed scripts and how to fix them.
- **`scripts/verify_orchestrator.py`** — pre-flight check script: validates syntax, imports, config schema, directory permissions, and dependency availability. Run after any change.
