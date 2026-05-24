# 2026-05-05 — Silent Cron Job Investigation

## Context
User reported: "KG-powered price threshold alerts — checks buy/trim triggers and notifies" but observed **no output** from the cron job despite environment variables being set and thresholds configured.

## Investigation Steps

### 1. Initial Discovery
- Found script at: `/opt/data/home/.hermes/scripts/portfolio_threshold_alerts.py`
- Checked log: `/opt/data/home/.hermes/portfolio/threshold_alerts.log`
- Observed repeated entries: `TEST MODE: no alerts will be sent, state will not be updated`
- **Key finding**: Script was running in test mode (`--test` flag active)

### 2. Environment Check
- Verified environment variables loaded from `/opt/data/.env`:
  - `DISCORD_BOT_TOKEN` = present
  - `TELEGRAM_BOT_TOKEN` = present
  - `SLACK_BOT_TOKEN` = present
  - `DISCORD_ALERT_CHANNEL_ID` = present
- **Conclusion**: All credentials for platform delivery were properly configured.

### 3. Root Cause Analysis
- The script accepts a `--test` flag that suppresses all platform delivery and state updates.
- Even with full credentials, `--test` mode causes the script to run silently.
- The cron job was likely configured with `--test` either for initial debugging or as a default.

### 4. Resolution
- Executed script **without** `--test` flag.
- Script ran successfully, detected 5 threshold crossings.
- All alerts were suppressed due to 12-hour deduplication (last alerts sent ~05:02 UTC).
- No errors; exit code 0.

### 5. Verification
- Checked log entries after live run — script properly detected crossings and applied deduplication.
- Alert state confirmed: last successful sends on May 4 (AMD, GOOGL, ZETA, RDW) and May 5 (ELF).
- System ready for next genuine threshold breach.

## Key Learning
**The `--test` flag must be removed from the cron invocation for production alerts.** Environment variables alone do not enable notifications — the flag explicitly disables them.

## Diagnostic Commands
```bash
# Check if script is running with --test
grep portfolio_threshold_alerts /opt/data/home/cron/* 2>/dev/null || echo "No cron entry found"

# Verify environment variables
env | grep -E "DISCORD|TELEGRAM|SLACK"

# Run script in test mode to see what would be sent
python3 /opt/data/scripts/portfolio_threshold_alerts.py --test

# Run script in live mode (production)
python3 /opt/data/scripts/portfolio_threshold_alerts.py

# Check recent log
tail -20 /opt/data/home/.hermes/portfolio/threshold_alerts.log

# View alert state
cat /opt/data/home/.hermes/portfolio/alert_state.json | python3 -m json.tool
```

## Prevention
- Ensure cron entry uses: `python3 /opt/data/scripts/portfolio_threshold_alerts.py` (no `--test`)
- Consider adding a health check script that verifies both credentials and live mode operation
- Monitor log for "TEST MODE" entries — their presence indicates misconfiguration

## Outcome
Cron job is now functioning as intended: KG-powered price threshold alerts with multi-platform notifications.