# Portfolio Threshold Alerts Investigation Reference

## Script Overview

**Location**: `~/.hermes/scripts/portfolio_threshold_alerts.py`

**Purpose**: KG-powered price threshold monitoring that checks buy/trim triggers and sends alerts to Discord and Telegram.

**Schedule**: Designed to run every 30 minutes via cron.

## Key Files

- **Configuration**: `~/.hermes/portfolio/portfolio_thresholds.json`
  - Defines ticker -> {threshold, condition} mappings
  - Example: `"AMD": {"threshold": 200.0, "condition": "trim"}`
  
- **State**: `~/.hermes/portfolio/alert_state.json`
  - Tracks last alert timestamps per ticker/condition to prevent spam
  - Format: `{ "TICKER": { "threshold_condition": "ISO timestamp" } }`

- **Log**: `~/.hermes/portfolio/threshold_alerts.log`
  - Contains execution history with timestamps
  - Shows detection of threshold crossings and delivery status

## Log Format

Typical log entries:
```
=== Portfolio Threshold Alert Run START ===
TICKERS from recent decisions (N): TICKER1, TICKER2, ...
Monitoring N ticker(s) with thresholds
Detected N threshold crossing(s).
Alert payload:
🚨 TICKER $PRICE crossed DIRECTION CONDITION threshold $THRESHOLD — see DECISION_TYPE DATE
=== Portfolio Threshold Alert Run END ===
```

If alerts are sent, additional lines show:
```
Discord alert sent successfully
Telegram alert sent successfully
Alert state saved.
```

## Deduplication Window

- **Default**: 12 hours (changed from 24 in a recent update)
- Alerts are suppressed if the same ticker+threshold combination was already alerted within this window
- This prevents spam when prices hover around thresholds

## Interpreting "No Output"

When the script runs and produces **no alerts**, possible reasons:

1. **Healthy suppression** (most common):
   - All detected threshold crossings occurred within the deduplication window
   - Log will show: `Suppressing alert for TICKER: already sent within 12h (at TIMESTAMP)`
   - This is expected behavior — the system is working correctly

2. **No threshold crossings**:
   - Log will state: `No threshold crossings detected.`
   - Prices are not near any defined thresholds

3. **Test mode**:
   - If run with `--test` flag, no alerts are sent
   - Log will explicitly say: `TEST MODE: no alerts will be sent...`
   - Test mode prints would-be alerts to stdout

## Normal vs Test Mode

- **Live mode**: No stdout output. Alerts go to Discord/Telegram and state is updated.
- **Test mode** (`--test`): Simulates run, prints would-send alerts to stdout, does not update state or send messages.

## Recent Session Findings (May 5, 2026)

- **Last successful alert**: May 5, 2026 at 07:03:04 UTC for tickers AMD, GOOGL, ZETA, RDW
- **Most recent run** (07:30:31): No new alerts due to deduplication
- **System status**: All configured correctly with Telegram/Discord credentials present

## Troubleshooting Tips

- Check `alert_state.json` for recent timestamps
- Review log file for detection and suppression reasons
- Verify Telegram/Discord bot tokens are valid and have channel permissions
- Ensure script has execute permissions (`chmod +x`)

## Correct Invocation

**Important:** The `--test` flag is a **boolean flag** (present or not), not an argument that takes a value. 

- **Live mode (send alerts):** `python3 /path/to/portfolio_threshold_alerts.py` (no `--test` flag)
- **Test mode (simulate):** `python3 /path/to/portfolio_threshold_alerts.py --test`

**Common mistake:** Using `--test=false` or `--test=true` will cause an error because the script expects the flag to be present/absent, not to receive a value.

**Example error:**
```
portfolio_threshold_alerts.py: error: argument --test: ignored explicit argument 'false'
```

**Recommendation:** When calling from cron or automation, simply omit the `--test` flag for live runs. Use `--test` only when you want to simulate without sending alerts or updating state.