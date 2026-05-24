---
name: hermes-stock-alerts
description: Architecture, delivery patterns, and operational knowledge for the Hermes stock threshold alert system — covers script variants, wrapper routing, channel mapping, and troubleshooting.
triggers:
  - stock_threshold_alert
  - portfolio_threshold_alerts
  - stock_alert_discord
  - stock_alert_triple
  - threshold alert
  - price threshold
  - KG alert
  - stock alert delivery
  - Discord stock alert
  - Telegram stock alert
  - Slack stock alert
  - orchestrator
  - duplicate alert
  - alert channel
required_tools:
  - terminal
  - execute_code
  - session_search
quality: |
  This skill exists to prevent confusion between two parallel implementations of stock threshold alerts with different delivery contracts. It documents which script to use where, how wrappers interact, and how to diagnose missing-file/delivery issues.
---
# Hermes Stock Alert System Architecture

## Important Warning
**Never pass `--test=false` to `portfolio_threshold_alerts.py`!** The `--test` flag is a boolean switch that takes **no value**. Using `--test=false` will cause an error:
```
usage: portfolio_threshold_alerts.py [-h] [--test]
portfolio_threshold_alerts.py: error: argument --test: ignored explicit argument 'false'
```
For a production run (the default), **omit the `--test` flag entirely**. For a dry-run (test mode), use `--test` alone (no value). See [`portfolio-threshold-monitoring`](#related-skills) for full details.

The Hermes stock alert infrastructure has **two parallel implementations** with different delivery models. Understanding which one to use where is critical to avoid missing alerts or duplicate posts.

## Script Variants

### 1. Standalone `stock_threshold_alert.py`
- **Location:** `~/.hermes/scripts/stock_threshold_alert.py` (or `/opt/data/home/.hermes/scripts/stock_threshold_alert.py`)
- **Size:** ~7 KB
- **Delivery contract:** Outputs alert Markdown to **stdout only**; exits 0 on normal, 1 on alert condition.
- **Intended use:** Called by **per-platform wrapper scripts** (`stock_alert_discord.sh`, `stock_alert_telegram.py`, `stock_alert_slack.py`) which handle actual platform delivery.
- **Channels delivered to:**
  - Discord → `#stock-news` (channel `1499338003334561843`)
  - Telegram → home channel
  - Slack → alerts channel
- **Configuration:** Hard-coded thresholds; no JSON config; no KG integration.
- **State:** No deduplication; alerts fire every run if threshold crossed.

### 2. KG-Powered `portfolio_threshold_alerts.py`
- **Primary Location:** `/opt/data/home/.hermes/scripts/portfolio_threshold_alerts.py` (445 lines)
- **Cron Symlink:** `/opt/data/scripts/portfolio_threshold_alerts.py` (symlink to primary)
- **Size:** ~19 KB
- **Delivery contract:** **Self-delivering** — contains internal `send_discord()` and `send_telegram()` functions; posts directly to platform APIs.
- **Intended use:** Called **directly by cron jobs**, **not** through wrapper scripts.
- **Channels delivered to:**\n  - Discord → `DISCORD_ALERT_CHANNEL_ID` (`1499362823342653471`) or fallback `DISCORD_HOME_CHANNEL` (`1498025894751768776`)\n  - Telegram → `TELEGRAM_HOME_CHANNEL`\n- **Configuration:** Reads `~/.hermes/portfolio/portfolio_thresholds.json`; defaults embedded.\n- **State:** 12-hour deduplication via `~/.hermes/portfolio/alert_state.json`; integrates with knowledge graph decisions.

## Invocation Topology

```
┌─────────────────────────────────────────────────────────────┐
│ Cron Scheduler (Hermes)                                     │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌────────────────────────────────────────────────────┐    │
│  │ stock-alert-triple (enabled)                       │    │
│  │ Schedule: every hour                                │    │
│  │ Calls:                                           │    │
│  │   ~/.hermes/scripts/stock_alert_slack.py          │    │
│  │   ~/.hermes/scripts/stock_alert_telegram.py       │    │
│  │   ~/.hermes/scripts/stock_alert_discord.sh        │    │
│  │       ↓                                            │    │
│  │   Each wrapper calls: ~/.hermes/scripts/          │    │
│  │   stock_threshold_alert.py (standalone)           │    │
│  │   (stdout-only → wrapper delivers)                │    │
│  └────────────────────────────────────────────────────┘    │
│                                                              │
│  ┌────────────────────────────────────────────────────┐    │
│  │ portfolio-threshold-alerts (enabled)               │    │
│  │ Schedule: every 30 min                             │    │
│  │ Calls directly:                                    │    │
│  │   /opt/data/scripts/portfolio_threshold_alerts.py │    │
│  │   (self-delivering; no wrapper)                    │    │
│  └────────────────────────────────────────────────────┘    │
│                                                              │
│  ⚠️  Legacy/disabled jobs (do not use):                    │
│     - Stock Alert — Discord (hourly) → calls               │
│       /opt/data/scripts/stock_threshold_alert.py (missing) │
│     - Stock Alert — Telegram/Slack (hourly) → same issue   │
└─────────────────────────────────────────────────────────────┘
```

## Channel Map

| Channel ID   | Name              | Used By                              |
|--------------|-------------------|--------------------------------------|
| `1499338003334561843` | #stock-news       | Standalone wrapper (discord.sh)      |
| `1499362823342653471` | #alerts           | KG script (`DISCORD_ALERT_CHANNEL_ID`) |
| `1498025894751768776` | Hermes Home       | KG script fallback (`DISCORD_HOME_CHANNEL`) |
| `1498815493757341896` | (deprecated wrapper target) | Old `/opt/data/scripts/stock_alert_discord.sh` hard-coded |

## Common Pitfalls

### Pitfall 1: Missing `stock_threshold_alert.py` in `/opt/data/scripts/`

**Symptom:** `python3: can't open file '/opt/data/scripts/stock_threshold_alert.py': [Errno 2] No such file or directory`

**Cause:** The orphaned wrapper `/opt/data/scripts/stock_alert_discord.sh` expects that file, but only `~/.hermes/scripts/` has the standalone script.

**Fix:** Ensure `/opt/data/scripts/stock_threshold_alert.py` exists **as a symlink** to `~/.hermes/scripts/stock_threshold_alert.py`. Do NOT point it to `portfolio_threshold_alerts.py` — that would cause double delivery if the wrapper ever runs.

```bash
# Correct symlink:
ln -sf ~/.hermes/scripts/stock_threshold_alert.py /opt/data/scripts/stock_threshold_alert.py
```

### Pitfall 2: Double-posting to Discord

**Symptom:** Same alert appears twice in a channel.

**Cause:** Running `portfolio_threshold_alerts.py` through a wrapper. That script already delivers itself internally. Wrapper would forward the same output again.

**Fix:** `portfolio_threshold_alerts.py` must be invoked **directly** (cron → script), never via `stock_alert_*.sh` wrappers.

### Pitfall 3: Wrong channel for threshold alerts

**Symptom:** Alerts land in #stock-news instead of #alerts (or vice versa).

**Cause:** Confusing which script variant is configured for which channel.

**Resolution:**
- If you want alerts in #alerts (`1499362823342653471`), use the **KG script** via its cron jobs.
- If you want alerts in #stock-news (`1499338003334561843`), use the **standalone script** via the orchestrator/wrappers.

### Pitfall 4: Legacy cron jobs still enabled

**Symptom:** Hourly runs fail with missing file errors.

**Cause:** Old jobs (`22584368cbfb` — Discord hourly, `4a09e5e68c43` — Telegram hourly, `7934e36017c6` — Slack hourly) reference `stock_threshold_alert.py` from `~/.hermes/` but wrapper paths may be stale.

**Fix:** These jobs should remain **disabled** (`enabled: false`). The active path is `stock-alert-triple` (which calls hermes wrappers) and `portfolio-threshold-alerts` (direct KG script).

### Pitfall 6: Cron job invocation uses `--test=false` incorrectly

**Symptom:** `usage: portfolio_threshold_alerts.py [-h] [--test]\\nportfolio_threshold_alerts.py: error: argument --test: ignored explicit argument 'false'`

**Cause:** The `--test` flag is defined as `action=\"store_true\"` (boolean flag). It should be used without a value. The cron job configuration that passes `--test=false` is incorrect.

**Fix:** For a real alert check (the default), **omit the `--test` flag entirely**. For a simulation run (no alerts sent, no state updated), use `--test` alone (no value). The script's usage is:

```bash
# Real run (cron job default)
python /opt/data/scripts/portfolio_threshold_alerts.py

# Simulation run (test)
python /opt/data/scripts/portfolio_threshold_alerts.py --test
```

**Note:** The `--test` flag is only relevant for the KG-powered `portfolio_threshold_alerts.py`. The standalone `stock_threshold_alert.py` may have different argument expectations.
- Inspect the log file `~/.hermes/portfolio/threshold_alerts.log` for lines containing \"Suppressing alert\" — they will indicate which tickers are in cooldown and when they were last sent.
- Check the deduplication state file `~/.hermes/portfolio/alert_state.json` to see the last-sent timestamps.
- Compute the next alert window: `last_sent + 24 hours`. Alert will fire on the next cron run at or after that time if the price is still crossing.

**Test Mode Output Behavior:** When running with `--test`, the script prints the would-send alert payload to stdout **only if there are new alerts to send** (i.e., after deduplication, there is at least one alert that hasn't been sent in the past 24 hours). If all detected alerts are suppressed by the 24-hour cooldown, test mode produces **no stdout output** (exit code 0). This is intentional — the script only outputs when there is something to report.

**Implication for Cron Jobs:** A cron job that expects stdout output to verify execution may see empty output even though the script ran successfully. To distinguish between "working correctly with no alerts" and "not working at all", use the diagnostic health check script (see below) or inspect the log file for run entries.

**Exit Code Semantics:** 
- Exit code 0: No alerts were sent (either no thresholds crossed, or all were suppressed by cooldown).
- Exit code 1: Alerts were successfully delivered (in live mode, i.e., without `--test`).

**Verification Script:**
```bash
# Quick health check to distinguish \"working correctly with no alerts\" from \"not working at all\"
python3 -c "
import json, datetime, os
from pathlib import Path

# Check if script exists and is executable
script_path = Path.home() / '.hermes/scripts/portfolio_threshold_alerts.py'
if not script_path.exists():
    print('❌ Missing: portfolio_threshold_alerts.py')
    exit(1)
if not os.access(str(script_path), os.X_OK):
    print('❌ Not executable: portfolio_threshold_alerts.py')
    exit(1)

# Check log file
log_path = Path.home() / '.hermes' / 'portfolio' / 'threshold_alerts.log'
if not log_path.exists():
    print('❌ Missing log file')
    exit(1)

# Read recent log entries
with open(log_path, 'r') as f:
    lines = f.readlines()[-20:]

# Look for recent runs
recent_runs = [line for line in lines if 'Portfolio Threshold Alert Run START' in line]
if not recent_runs:
    print('⚠️  No recent runs in log (script may not have executed)')
else:
    print('✅ Script is running regularly')
    
    # Check for suppression messages
    suppressions = [line for line in lines if 'Suppressing alert' in line]
    if suppressions:
        print('📊 Alerts are being detected but suppressed by 24h cooldown')
        for line in suppressions[-3:]:
            print('  ' + line.strip().split(' - ')[-1])
    else:
        # Check if any thresholds were crossed
        crossings = [line for line in lines if 'Detected threshold crossing' in line]
        if crossings:
            print('⚠️  Crossings detected but no alerts sent — check cooldown logic')
        else:
            # Check if any tickers are being monitored
            tickers_line = [line for line in lines if 'Monitoring' in line][-1] if lines else None
            if tickers_line:
                print('✅ Monitoring active tickers')
                print('  ' + tickers_line.strip().split(' - ')[-1])
            else:
                print('⚠️  No evidence of threshold monitoring — check configuration')

print('\\\\nHealthCheck complete.')
"
```

**Quick Interpretation Guide:**
- If the script runs regularly and shows suppression messages → **System is working correctly**
- If the script runs but shows no crossings detected → **Check if any thresholds are configured or if tickers are in KG**
- If the script doesn't run at all → **Check cron job status and permissions**
- If the script runs but can't fetch prices → **Check network/API connectivity**

**Note:** The \"no output\" from the cron job itself is intentional — the script only produces stdout when new alerts are sent. A successful run with no output typically means either:
1. No thresholds were crossed (no detections), OR
2. All detections were within the 24-hour cooldown window (most common after initial alert burst)

Use the diagnostic script above to distinguish between these cases and verify system health.

**Expected behavior:** Once the 24-hour window expires and the threshold is still crossed, the next scheduled run will send fresh alerts for that ticker.
**Verification:**
```bash
# View the deduplication state
cat ~/.hermes/portfolio/alert_state.json

# Quick Python check for next window
python3 -c "
from datetime import datetime, timedelta, timezone
from pathlib import Path
import json
p = Path.home() / '.hermes' / 'portfolio' / 'alert_state.json'
state = json.loads(p.read_text())
now = datetime.now(timezone.utc)
for ticker, entries in state.items():
    for key, ts in entries.items():
        last = datetime.fromisoformat(ts.replace('Z', '+00:00'))
        remaining = (last + timedelta(hours=24)) - now
        print(f'{ticker} {key}: next alert in {remaining} (at {last + timedelta(hours=24)})')
"
```

**Expected behavior:** Once the 24-hour window expires and the threshold is still crossed, the next scheduled run will send fresh alerts for that ticker.

## Troubleshooting Checklist

When a threshold alert fails:

1. **Identify which channel should receive the alert** (stock-news vs alerts).
2. **Check which script variant is appropriate** (standalone for wrappers, KG for direct).
3. **Verify symlink at `/opt/data/scripts/stock_threshold_alert.py`** points to standalone, not KG version.
4. **Confirm cron job mapping:**
   - `stock-alert-triple` → orchestrator → wrappers → standalone script.
   - `portfolio-threshold-alerts*` → direct KG script.
5. **Inspect recent logs:** `/opt/data/cron/output/<job-id>/<timestamp>.md`
6. **Check environment:** `DISCORD_BOT_TOKEN`, `DISCORD_ALERT_CHANNEL_ID`, `TELEGRAM_BOT_TOKEN` present for self-delivering KG script; wrapper path needs `DISCORD_BOT_TOKEN` in cron env.

## Migration Path

If consolidating to a single system:

- **Recommended:** Use **KG version everywhere** (more features: KG integration, deduplication, JSON config).
  - Enable `portfolio-threshold-alerts` (runs every 30 min).
  - Disable `stock-alert-triple` and all per-platform wrappers.
  - Set `DISCORD_ALERT_CHANNEL_ID=1499362823342653471` to unify channel.
- **Alternative:** Keep **standalone version** (simpler, no state).
  - Ensure wrappers are functional.
  - Accept no deduplication or KG decision tracking.

## Third Implementation: Market Alert Service

In addition to the two parallel implementations described above, there is a **third implementation** located at `~/hermes/market-alerts/`. This is a self-contained service for continuous market monitoring that can also be run as a one-time check.

### Market Alert Service Overview

- **Location:** `~/hermes/market-alerts/`
- **Architecture:** Python service with separate data fetching and alert engine components
- **Features:**
  - Monitors stocks, crypto, and news simultaneously
  - Configurable thresholds for each market type
  - Persistent data storage (JSON files)
  - Multi-channel delivery (Discord, Telegram, Slack)
  - 24/7 operation with configurable intervals
- **Deployment Options:**
  - Systemd service (recommended for Linux)
  - Docker container
  - Direct Python execution

### Service Components

| Component | Location | Purpose |
|-----------|----------|---------|
| `market_alert_service.py` | `~/hermes/market-alerts/` | Main service entry point |
| `service_core.py` | `~/hermes/market-alerts/` | Core logic: `MarketAlertService` class |
| `market_data_fetcher.py` | `~/hermes/market-alerts/scripts/` | Fetches market data from web |
| `alert_engine.py` | `~/hermes/market-alerts/scripts/` | Analyzes data and generates alerts |
| `config.json` | `~/hermes/market-alerts/` | Configuration file |

### One-Time Check Using Service Core

When you need to run a manual threshold alert check (e.g., for debugging or ad-hoc monitoring), you can use the service core directly without starting the full continuous service.

**Procedure:**
```python
#!/usr/bin/env python3
import sys
sys.path.insert(0, '/root/hermes/market-alerts')
from service_core import MarketAlertService

service = MarketAlertService()
alerts_generated = service.process_cycle()
print(f"✅ Generated {alerts_generated} alerts")
```

**Alternative via command line:**
```bash
python3 -c "import sys, os; sys.path.insert(0, os.path.expanduser('~/hermes/market-alerts')); from service_core import MarketAlertService; s=MarketAlertService(); print(f'Alerts: {s.process_cycle()}')"
```

This runs a single data fetch and alert generation cycle, then exits. It's useful for:
- Manual checks outside cron schedule
- Debugging alert logic
- Testing configuration changes
- Verifying market data sources

### Troubleshooting Missing or Broken Scripts

If the expected `portfolio_threshold_alerts.py` script is missing or broken, you can use the market alert service as an alternative. However, note the differences:

| Aspect | `portfolio_threshold_alerts.py` | Market Alert Service |
|--------|--------------------------------|----------------------|
| Integration | KG-powered, uses knowledge graph decisions | General market monitoring, no KG integration |
| Deduplication | 12-hour window | Configurable (default 24 hours) |
| Schedule | Every 30 min / hourly | Continuous, configurable interval |
| Configuration | `~/.hermes/portfolio/portfolio_thresholds.json` | `~/hermes/market-alerts/config.json` |
| State | `~/.hermes/portfolio/alert_state.json` | `~/hermes/market-alerts/data/` and `alerts/` |

**If you encounter errors like:**
- `python3: can't open file '/opt/data/scripts/portfolio_threshold_alerts.py'`
- `ModuleNotFoundError: No module named 'hermes_tools'`
- Syntax errors in `alert_engine.py`

**First, check if the market alert service is available:**
```bash
ls ~/hermes/market-alerts/scripts/market_fetcher.py 2>/dev/null && echo "Market alert service exists"
```

**If it exists, use it for manual checks:**
```bash
# Run a one-time check
python3 -c "import sys; sys.path.insert(0, os.path.expanduser('~/hermes/market-alerts')); from service_core import MarketAlertService; s=MarketAlertService(); s.process_cycle()"
```

### Market Alert Service Health Check

To verify the market alert service is functioning correctly:

```bash
#!/bin/bash
# Market Alert Service Health Check

SERVICE_DIR="$HOME/hermes/market-alerts"

echo "📊 Market Alert Service Health Check"
echo "===================================="

# Check if service directory exists
if [ ! -d "$SERVICE_DIR" ]; then
    echo "❌ Service directory not found: $SERVICE_DIR"
    exit 1
fi

# Check for required scripts
for script in market_fetcher.py alert_engine.py; do
    if [ -f "$SERVICE_DIR/scripts/$script" ]; then
        echo "✅ $script exists"
    else
        echo "❌ $script missing"
    fi
done

# Check data directory
if [ -d "$SERVICE_DIR/data" ]; then
    FILES=$(ls "$SERVICE_DIR/data"/*.json 2>/dev/null | wc -l)
    echo "✅ Data directory: $FILES files"
else
    echo "❌ Data directory missing"
fi

# Check alerts directory
if [ -d "$SERVICE_DIR/alerts" ]; then
    FILES=$(ls "$SERVICE_DIR/alerts"/*.json 2>/dev/null | wc -l)
    echo "✅ Alerts directory: $FILES files"
else
    echo "❌ Alerts directory missing"
fi

# Check configuration
if [ -f "$SERVICE_DIR/config.json" ]; then
    echo "✅ Config file exists"
else
    echo "❌ Config file missing"
fi

echo ""
echo "💡 To run a one-time check: python3 -c \"from service_core import MarketAlertService; MarketAlertService().process_cycle()\""
```

### When to Use Which Implementation

- **Use `portfolio_threshold_alerts.py`** when you need KG integration, portfolio-specific thresholds, and 12-hour deduplication.
- **Use market alert service** for general market monitoring, crypto alerts, news monitoring, or when the KG script is unavailable.
- **Use standalone `stock_threshold_alert.py`** for simple threshold checks without state or KG integration, routed through wrappers.

### Cron Job Mapping Update

The following cron jobs should be active (May 2026):

| Job ID | Name | Schedule | Script |
|--------|------|----------|--------|
| `a35b76eda07c` | portfolio-threshold-alerts | `*/30 * * * *` | KG script direct |
| `44f8186f2313` | portfolio-threshold-alerts-hourly | `0 * * * *` | KG script direct |
| `f610a2fca47a` | daily-stock-news-triple | `0 9 * * *` | Orchestrator → wrappers |
| `18186766daf4` | stock-alert-triple | `0 * * * *` | Orchestrator → wrappers |
| `market-alert-service` | Market Alert Service | `systemd` | Continuous service |

Disabled (do not enable):
- Orphaned wrapper jobs that expect `stock_threshold_alert.py` at `/opt/data/scripts/`

### Migration Considerations

If consolidating to a single system:

- **Recommended:** Use **KG version** for portfolio alerts, **market alert service** for general monitoring.
- **Alternative:** Use **market alert service** for everything if you don't need KG integration.
- **Avoid:** Mixing `portfolio_threshold_alerts.py` with wrappers or using both KG and market alert service for the same tickers (causes duplicate alerts).

## Third Implementation: Market Alert Service

In addition to the two parallel implementations described above, there is a **third implementation** located at `~/hermes/market-alerts/`. This is a self-contained service for continuous market monitoring that can also be run as a one-time check.

### Market Alert Service Overview

- **Location:** `~/hermes/market-alerts/`
- **Architecture:** Python service with separate data fetching and alert engine components
- **Features:**
  - Monitors stocks, crypto, and news simultaneously
  - Configurable thresholds for each market type
  - Persistent data storage (JSON files)
  - Multi-channel delivery (Discord, Telegram, Slack)
  - 24/7 operation with configurable intervals
- **Deployment Options:**
  - Systemd service (recommended for Linux)
  - Docker container
  - Direct Python execution

### Service Components

| Component | Location | Purpose |
|-----------|----------|---------|
| `market_alert_service.py` | `~/hermes/market-alerts/` | Main service entry point |
| `service_core.py` | `~/hermes/market-alerts/` | Core logic: `MarketAlertService` class |
| `market_data_fetcher.py` | `~/hermes/market-alerts/scripts/` | Fetches market data from web |
| `alert_engine.py` | `~/hermes/market-alerts/scripts/` | Analyzes data and generates alerts |
| `config.json` | `~/hermes/market-alerts/` | Configuration file |

### One-Time Check Using Service Core

When you need to run a manual threshold alert check (e.g., for debugging or ad-hoc monitoring), you can use the service core directly without starting the full continuous service.

**Procedure:**
```python
#!/usr/bin/env python3
import sys
sys.path.insert(0, '/root/hermes/market-alerts')
from service_core import MarketAlertService

service = MarketAlertService()
alerts_generated = service.process_cycle()
print(f"✅ Generated {alerts_generated} alerts")
```

**Alternative via command line:**
```bash
python3 -c "import sys, os; sys.path.insert(0, os.path.expanduser('~/hermes/market-alerts')); from service_core import MarketAlertService; s=MarketAlertService(); print(f'Alerts: {s.process_cycle()}')"
```

This runs a single data fetch and alert generation cycle, then exits. It's useful for:
- Manual checks outside cron schedule
- Debugging alert logic
- Testing configuration changes
- Verifying market data sources

### Troubleshooting Missing or Broken Scripts

If the expected `portfolio_threshold_alerts.py` script is missing or broken, you can use the market alert service as an alternative. However, note the differences:

| Aspect | `portfolio_threshold_alerts.py` | Market Alert Service |
|--------|--------------------------------|----------------------|
| Integration | KG-powered, uses knowledge graph decisions | General market monitoring, no KG integration |
| Deduplication | 12-hour window | Configurable (default 24 hours) |
| Schedule | Every 30 min / hourly | Continuous, configurable interval |
| Configuration | `~/.hermes/portfolio/portfolio_thresholds.json` | `~/hermes/market-alerts/config.json` |
| State | `~/.hermes/portfolio/alert_state.json` | `~/hermes/market-alerts/data/` and `alerts/` |

**If you encounter errors like:**
- `python3: can't open file '/opt/data/scripts/portfolio_threshold_alerts.py'`
- `ModuleNotFoundError: No module named 'hermes_tools'`
- Syntax errors in `alert_engine.py`

**First, check if the market alert service is available:**
```bash
ls ~/hermes/market-alerts/scripts/market_fetcher.py 2>/dev/null && echo "Market alert service exists"
```

**If it exists, use it for manual checks:**
```bash
# Run a one-time check
python3 -c \"import sys; sys.path.insert(0, os.path.expanduser('~/hermes/market-alerts')); from service_core import MarketAlertService; s=MarketAlertService(); s.process_cycle()\"
```

### Market Alert Service Health Check

To verify the market alert service is functioning correctly:

```bash
#!/bin/bash
# Market Alert Service Health Check

SERVICE_DIR=\"$HOME/hermes/market-alerts\"

echo \"📊 Market Alert Service Health Check\"
echo \"====================================\"

# Check if service directory exists
if [ ! -d \"$SERVICE_DIR\" ]; then
    echo \"❌ Service directory not found: $SERVICE_DIR\"
    exit 1
fi

# Check for required scripts
for script in market_fetcher.py alert_engine.py; do
    if [ -f \"$SERVICE_DIR/scripts/$script\" ]; then
        echo \"✅ $script exists\"
    else
        echo \"❌ $script missing\"
    fi
done

# Check data directory
if [ -d \"$SERVICE_DIR/data\" ]; then
    FILES=$(ls \"$SERVICE_DIR/data\"/*.json 2>/dev/null | wc -l)
    echo \"✅ Data directory: $FILES files\"
else
    echo \"❌ Data directory missing\"
fi

# Check alerts directory
if [ -d \"$SERVICE_DIR/alerts\" ]; then
    FILES=$(ls \"$SERVICE_DIR/alerts\"/*.json 2>/dev/null | wc -l)
    echo \"✅ Alerts directory: $FILES files\"
else
    echo \"❌ Alerts directory missing\"
fi

# Check configuration
if [ -f \"$SERVICE_DIR/config.json\" ]; then
    echo \"✅ Config file exists\"
else
    echo \"❌ Config file missing\"
fi

echo \"\"
echo \"💡 To run a one-time check: python3 -c \\\"from service_core import MarketAlertService; MarketAlertService().process_cycle()\\\"\"
```

### When to Use Which Implementation

- **Use `portfolio_threshold_alerts.py`** when you need KG integration, portfolio-specific thresholds, and 12-hour deduplication.
- **Use market alert service** for general market monitoring, crypto alerts, news monitoring, or when the KG script is unavailable.
- **Use standalone `stock_threshold_alert.py`** for simple threshold checks without state or KG integration, routed through wrappers.

### Cron Job Mapping Update

The following cron jobs should be active (May 2026):

| Job ID | Name | Schedule | Script |
|--------|------|----------|--------|
| `a35b76eda07c` | portfolio-threshold-alerts | `*/30 * * * *` | KG script direct |
| `44f8186f2313` | portfolio-threshold-alerts-hourly | `0 * * * *` | KG script direct |
| `f610a2fca47a` | daily-stock-news-triple | `0 9 * * *` | Orchestrator → wrappers |
| `18186766daf4` | stock-alert-triple | `0 * * * *` | Orchestrator → wrappers |
| `market-alert-service` | Market Alert Service | `systemd` | Continuous service |

Disabled (do not enable):
- Orphaned wrapper jobs that expect `stock_threshold_alert.py` at `/opt/data/scripts/`

### Migration Considerations

If consolidating to a single system:

- **Recommended:** Use **KG version** for portfolio alerts, **market alert service** for general monitoring.
- **Alternative:** Use **market alert service** for everything if you don't need KG integration.
- **Avoid:** Mixing `portfolio_threshold_alerts.py` with wrappers or using both KG and market alert service for the same tickers (causes duplicate alerts).

## Related Skills
- `stock-trading` — portfolio management and price thresholds
- `knowledge-base` — for querying KG decision history that feeds KG alerts
- `hermes-dev` — cron job management and deployment
- `portfolio-threshold-monitoring` — detailed operational guide for the KG-powered alert system
- `market-alert-agent` — comprehensive guide to the market alert service (new)

## Support Files
This skill ships with operational support files:
- `references/alert-system-config.md` — exact channel IDs, script paths, cron job IDs, environment variables, and the May 2026 fix recipe.
- `scripts/health_check.py` — diagnostic script to verify alert system health (symlinks, cron mapping, env vars, script executability). Run manually or from cron to detect misconfiguration early.
- `scripts/market_alert_service_check.py` — health check for the market alert service (added June 2026).
- `market-alert-agent` — comprehensive guide to the market alert service (new)

## Support Files
This skill ships with operational support files:
- `references/alert-system-config.md` — exact channel IDs, script paths, cron job IDs, environment variables, and the May 2026 fix recipe.
- `scripts/health_check.py` — diagnostic script to verify alert system health (symlinks, cron mapping, env vars, script executability). Run manually or from cron to detect misconfiguration early.
- `scripts/market_alert_service_check.py` — health check for the market alert service (added June 2026).

## Support Files

This skill ships with operational support files:

- **`references/alert-system-config.md`** — exact channel IDs, script paths, cron job IDs, environment variables, and the May 2026 fix recipe.
- **`scripts/health_check.py`** — diagnostic script to verify alert system health (symlinks, cron mapping, env vars, script executability). Run manually or from cron to detect misconfiguration early.
```