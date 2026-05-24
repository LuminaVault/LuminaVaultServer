---
name: portfolio-threshold-monitoring
description: Knowledge-graph-driven portfolio threshold alerts with deduplication and multi-platform delivery
version: 1.0.0
author: Hermes Agent
license: MIT
---

# Portfolio Threshold Monitoring (KG-Powered)

Designed for cron-deployed autonomous operation.
    
### ⚠️ Critical: Correct Invocation
    
**Never use `--test=false` or `--test true`.** The `--test` flag is a simple boolean switch that takes **no value**. The script expects either:
- `--test` (dry-run, no alerts sent)
- No `--test` flag (production mode, alerts sent)
    
Using `--test=false` will cause an argument parsing error. If you need to see what would be sent, use `--test` and check the stdout.
    
## When to Use

- You want threshold alerts **only for tickers you've made decisions about** (KG-driven watchlist)
- You need both **buy and trim** triggers in one system
- You want **built-in 24-hour deduplication** to avoid spam
- You prefer **JSON-configurable thresholds** (not hard-coded)
- You want a **single cron job** that routes to multiple platforms

## Comparison

| Feature | stock-threshold-monitoring | portfolio-threshold-monitoring |
|---------|---------------------------|-------------------------------|
| Ticker source | Hard-coded list | KG decision entities (past 90 days) |
| Threshold storage | In-script dict | JSON config file |
| Conditions | Buy only (≤ threshold) | Buy **and** trim (≥ threshold) |
| Deduplication | None (exits 1/0) | 24h stateful suppression |
| Platform routing | 3 separate cron jobs | 1 job → Discord + Telegram |
| Exit code usage | 0=clear, 1=breach | Always 0 (sends directly) |
| Config path | Edit script | Edit `~/.hermes/portfolio/portfolio_thresholds.json` |

## Architecture

```
cron (every 30 min)
    ↓
portfolio_threshold_alerts.py
    ├─ 1. Load KG entities.json → recent decisions (past 90d)
    ├─ 2. Load portfolio_thresholds.json → threshold configs
    ├─ 3. Fetch live prices (Yahoo Finance chart API)
    ├─ 4. Compare: buy if price ≤ thr, trim if price ≥ thr
    ├─ 5. Deduplicate against alert_state.json (24h window)
    ├─ 6. Send to Discord + Telegram (if new alerts)
    └─ 7. Update alert_state.json
```

## Files & Paths

| Purpose | Path | Notes |
|---------|------|-------|
| Script (primary) | `$HERMES_HOME/.hermes/scripts/portfolio_threshold_alerts.py` | Authoritative location; may be symlinked |
| Script (symlink) | `$HERMES_HOME/scripts/portfolio_threshold_alerts.py` | Used by cron; should point to primary |
| KG source | `/opt/data/home/.hermes/knowledge_graph/entities.json` | Must contain decision entities |
| Thresholds | `/opt/data/home/.hermes/portfolio/portfolio_thresholds.json` | User-editable JSON |
| Alert state | `/opt/data/home/.hermes/portfolio/alert_state.json` | Auto-updated, keep writable |
| Log file | `/opt/data/home/.hermes/portfolio/threshold_alerts.log` | Rotate as needed |
| Status script | `scripts/alert_status_summary.py` | Quick overview of prices, suppression countdowns, eligibility |
| Cron job | `*/30 * * * *` | ID: `a35b76eda07c` (may vary) |

### Path Resolution Notes

- **HOME directory:** In this Hermes deployment, `$HOME` resolves to `/root`. All `~` expansions and relative paths use this base. Note that `$HERMES_HOME` may be set to a different location (e.g., `/root/.hermes`).
- **Dual script locations:** The script lives at `$HERMES_HOME/.hermes/scripts/` and is symlinked to `$HERMES_HOME/scripts/` for cron accessibility. Always edit the primary location; the symlink mirrors it.
- **KG entities:** The knowledge graph file is stored under the Hermes home directory, not at a generic `~/.hermes/` path if that resolves elsewhere. Use the absolute path to avoid ambiguity.
- **Tilde expansion caution:** Shell `~` works in interactive contexts, but Python `os.path.expanduser('~/.hermes/...')` depends on `$HOME`. Prefer absolute paths in documentation and scripts.

## KG Decision Entity Format

**Important:** The `entities.json` file is a **flat dictionary** keyed by entity ID, not a JSON object with an `"entities"` array. Each value is an entity object.

```json
{
  "decision_2026-04-29 Hermes Q&A — Portfolio Build": {
    "id": "decision_2026-04-29 Hermes Q&A — Portfolio Build",
    "type": "decision",
    "properties": {
      "date": "2026-04-29",
      "tickers": ["AMD", "GOOGL", "ZETA", "ELF", "RDW", ...],
      ...
    }
  },
  "ticker_AMD": { ... },
  ...
}
```

The script discovers decision entities by iterating over **all values** in the JSON object, filtering for `type == "decision"`. It extracts `properties.tickers` and keeps only the **most recent decision per ticker** within the lookback window (default 90 days).

**Verification command:**
```bash
python3 -c "import json; d=json.load(open('/opt/data/home/.hermes/knowledge_graph/entities.json')); decisions=[v for v in d.values() if isinstance(v,dict) and v.get('type')=='decision']; print(f'Decisions: {len(decisions)}'); [print(f\"  {d.get('properties',{}).get('date','?')} | {d.get('properties',{}).get('tickers',[])}\") for d in decisions]"
```

## Thresholds File Format (`~/.hermes/portfolio/portfolio_thresholds.json`)

```json
{
  "CELH": {"threshold": 33.0, "condition": "buy"},
  "ELF":  {"threshold": 63.0, "condition": "buy"},
  "RDW":  {"threshold": 10.0, "condition": "buy"},
  "AMD":  {"threshold": 200.0, "condition": "trim"},
  "GOOGL": {"threshold": 205.0, "condition": "trim"},
  "ZETA": {"threshold": 15.0, "condition": "trim"}
}
```

Valid `condition` values:
- `"buy"` → trigger when `current_price ≤ threshold`
- `"trim"` → trigger when `current_price ≥ threshold`

**Important:** Only tickers that appear in recent KG decisions **and** have a threshold entry are monitored. Others are silently skipped.

## Alert Deduplication State Format (`alert_state.json`)
## Alert Deduplication State Format (`alert_state.json`)
```json
{
  "AMD": {
    "200.00_trim": "2026-05-02T02:30:46.530411+00:00"
  },
  "ELF": {
    "63.00_buy": "2026-05-01T13:30:28.076509+00:00"
  }
}
```

- **Top-level keys:** ticker symbols
- **Inner keys:** `"{threshold:.2f}_{condition}"` (threshold formatted to exactly 2 decimal places, underscore separator, condition literal `"buy"` or `"trim"`)
- **Values:** ISO 8601 UTC timestamp of last successful send
- **Suppression rule:** if `now - last_alert < 12 hours`, the alert is **suppressed** (not sent, no state update). The script logs `"Suppressing alert for {ticker}: already sent within 12h"`. **Note:** As of 2026-05-04, the deduplication window is set to **12 hours** (twice daily) instead of 24 hours for more frequent updates.
- **State update:** `alert_state.json` is only updated when at least one platform succeeds in sending. If both Discord and Telegram fail, the state is not advanced.

## Output & Exit Codes
    
- **Normal cron run (production):** No stdout. All info → log file. 
  - Exit code `0` = successful completion (including when alerts were sent)
  - Exit code `1` = error (e.g., failed to load KG entities or thresholds)
- **Test mode (`--test`):** Prints alert payload to stdout for tickers not suppressed by the 24-hour deduplication window. Exit code always 0. No sends, no state update.
- **No new alerts:** Log shows `No threshold crossings detected.` or `No new alerts to send after deduplication.`
- **Alerts sent:** Log shows `Alert payload:` then `Discord alert sent successfully` / `Telegram alert sent successfully.`
    
**Note:** Unlike some cron jobs, this script does not use exit code 1 to indicate alerts were sent. It always exits 0 on success. If you need to trigger external delivery based on output, you must check the log file or stdout (in test mode) instead.

## Testing

```bash
# Dry-run: show what would be sent (no state update, no platform delivery)
# Note: --test respects 24h deduplication; may print nothing if all tickers suppressed.
python3 /opt/data/home/.hermes/scripts/portfolio_threshold_alerts.py --test

# Alternatively use symlink path (both are equivalent)
# python3 /opt/data/scripts/portfolio_threshold_alerts.py --test
```

**Important:** The `--test` flag is a boolean switch — it takes **no value**. Use `--test` for a dry-run (test mode), or omit it entirely for production execution. Using `--test=false` or `--test true` will result in an error, as the script expects only the presence/absence of the flag.
# Quick health check — verifies KG decisions, thresholds, deduplication state, log recency
python3 /opt/data/skills/stock-trading/portfolio-threshold-monitoring/scripts/portfolio_threshold_healthcheck.py

# Check latest log
tail -n 30 /opt/data/home/.hermes/portfolio/threshold_alerts.log

# Verify state file and deduplication windows
cat /opt/data/home/.hermes/portfolio/alert_state.json | python3 -m json.tool

# Manual price check (sanity)
python3 -c "
import urllib.request, json
for t in ['AMD','GOOGL','ZETA','RDW','ELF']:
    url = f'https://query2.finance.yahoo.com/v8/finance/chart/{t}?range=1d&interval=1d'
    req = urllib.request.Request(url, headers={'User-Agent':'Mozilla/5.0'})
    d = json.loads(urllib.request.urlopen(req, timeout=10).read())
    print(f'{t}: \${d[\"chart\"][\"result\"][0][\"meta\"][\"regularMarketPrice\"]}')
"
```

**Note:** `--test` mode still respects the 24-hour deduplication window. If a ticker+threshold was recently alerted (<24h), `--test` will print nothing even if the price remains crossed. To force a dry-run that shows all current crossings, temporarily clear the relevant keys from `alert_state.json` or wait for the deduplication window to expire.

## Troubleshooting: "No output" from Cron

If cron reports `ok` but you expect alerts:

1. **Check recent log** → `tail -n 20 ~/.hermes/portfolio/threshold_alerts.log`
   - Look for `Tickers from recent decisions` — should list ≥1 ticker
   - Look for `Monitoring N ticker(s) with thresholds` — N should be ≥1
   - If N=0 → either no KG decisions or no thresholds match

2. **Verify KG entities**  
   ```bash
   python3 -c "import json; e=json.load(open('/opt/data/home/.hermes/knowledge_graph/entities.json')); print('entities:', len(e)); d=[v for v in e.values() if isinstance(v,dict) and v.get('type')=='decision']; print('decisions:', len(d))"
   ```
   - Should print `decisions: ≥1`. If 0 → regenerate KG decisions from conversations.

3. **Check thresholds file** → `cat ~/.hermes/portfolio/portfolio_thresholds.json`
   - Must be valid JSON
   - Must include threshold entries for tickers you expect

4. **Inspect alert state** → `cat ~/.hermes/portfolio/alert_state.json`
   - If a ticker+threshold key exists with timestamp < 24h old, it will be suppressed
   - Wait 24h from last alert for re-notification

5. **Verify prices actually crossed**  
   Run `--test` and compare to current market. If test shows no crossings, prices haven't breached thresholds.

6. **Confirm credentials** (for actual sends)  
   - `DISCORD_BOT_TOKEN`, `DISCORD_ALERT_CHANNEL_ID`
   - `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`
   - Missing credentials cause send failures but don't stop script (errors logged)

## Common Pitfalls

| Symptom | Likely Cause | Fix |
| ------- | ------------ | --- |
| `--test` produces no output despite expected crossings | All monitored tickers are suppressed by 24h deduplication, or the `--test` flag was used incorrectly | 1. **Verify flag usage:** `--test` takes no value — omit it or use just `--test` (not `--test=false`).<br>2. **Check deduplication:** If crossings exist but are suppressed, you can temporarily clear `alert_state.json` to force output for testing:<br>   ```bash<br>   echo '{}' > /opt/data/home/.hermes/portfolio/alert_state.json && python3 /opt/data/scripts/portfolio_threshold_alerts.py --test<br>   ```<br>   This resets the state so no tickers are suppressed.<br>3. **Manual price check:** Run the manual price check script in the Testing section to verify current prices actually cross thresholds. |
| `--test` produces no output **despite fresh crossings** | Deduplication is **still active in test mode** — this is a known script limitation; `--test` respects the same 24h suppression as production. For diagnostics, manually clear recent keys from `alert_state.json`. | Delete relevant `(ticker, threshold, condition)` keys from `alert_state.json`, then re-run `--test`. |
| **Script runs silently in production even with credentials set** | The cron job is likely invoking the script with the `--test` flag, which suppresses all platform delivery regardless of environment variable presence. | **Remove the `--test` flag from the cron command.** The script should be called **without** `--test` for live operation. Environment variables are required for delivery, but their presence alone does not override test mode. Check your cron entry and ensure it calls the script directly (e.g., `python3 /opt/data/scripts/portfolio_threshold_alerts.py`). |
| Ticker seems ignored despite threshold crossing | Ticker present in `portfolio_thresholds.json` but absent from recent KG decisions → **not part of monitored set** | Create a decision entity that includes the ticker; monitoring requires both KG decision AND threshold entry. |
| Price shows $0.00 or very old timestamp | Price import script hasn't run recently or Yahoo Finance returned stale data. | Run `python3 /opt/data/scripts/portfolio_import_daily_prices.py` manually or wait for daily refresh. |
| JSONDecodeError on load | KG entities or alert_state corrupted | Restore from backup or regenerate (state can be deleted; will recreate empty) |
| Price fetch fails (network/Yahoo down) | Script logs warning and skips failed tickers for that run | Retry later; check network connectivity |

## Important Configuration Note\n\n**The `--test` flag is for dry-runs only.** When called with `--test`, the script will **never** send alerts or update state, regardless of whether environment variables are set. For production execution, **omit the `--test` flag entirely**. If your cron job includes `--test`, it will run silently even if all credentials are properly configured.\n\n**Important:** The `--test` flag is a boolean switch — it takes **no value**. Use `--test` for a dry-run (test mode), or omit it entirely for production execution. Using `--test=false` or `--test true` will result in an error, as the script expects only the presence/absence of the flag.\n\nTo verify your cron job is configured correctly:\n```bash\n# Check crontab entry\ncrontab -l | grep portfolio_threshold_alerts\n# Should show something like:\n# */30 * * * * cd /opt/data/home && /usr/bin/python3 /opt/data/scripts/portfolio_threshold_alerts.py\n# NOT: */30 * * * * cd /opt/data/home && /usr/bin/python3 /opt/data/scripts/portfolio_threshold_alerts.py --test\n```\n\n### Script Invocation and Output\n\n- **Production mode** (`./portfolio_threshold_alerts.py`): Sends alerts via Discord/Telegram, updates state, and logs to file. **Produces no stdout output.** Exit code 0 = no new alerts sent; 1 = alerts delivered.\n- **Test mode** (`./portfolio_threshold_alerts.py --test`): Prints alert payload to stdout for verification, but **does not send alerts or update state**. Always exits 0.\n\n**When investigating a silent cron job:** Remember that production runs are silent by design. Check the log file (`~/.hermes/portfolio/threshold_alerts.log`) for details.\n\n### Script Path Resolution\n\nThe script may exist in two locations:\n- **Primary:** `/opt/data/home/.hermes/scripts/portfolio_threshold_alerts.py`\n- **Cron symlink:** `/opt/data/scripts/portfolio_threshold_alerts.py` (should be a symlink to primary)\n\nIf the script is not found at `$HERMES_HOME/scripts/`, check the primary location. The cron job should use the symlink path for reliability.\n\n### Troubleshooting: \"Script not found\" Errors\n\nIf you encounter \"File not found\" errors when trying to run the script:\n\n1. **Verify the script exists:**\n   ```bash\n   ls -la /opt/data/home/.hermes/scripts/portfolio_threshold_alerts.py\n   ls -la /opt/data/scripts/portfolio_threshold_alerts.py\n   ```\n\n2. **Check for symlink issues:**\n   - If `/opt/data/scripts/` contains a regular file (not a symlink), it may have diverged from the primary.\n   - Ensure the cron job uses the correct path.\n\n3. **Use absolute paths:** When running manually, use the full path to avoid PATH issues.\n\n4. **Check environment variables:** The script uses `HERMES_HOME` to resolve paths. Ensure it's set correctly or use absolute paths.\n\n## Maintenance\n\n- **Add a ticker to monitor:**  \n  1. Create a KG decision entity (via conversation/capture pipeline) that includes the ticker  \n  2. Add threshold entry to `portfolio_thresholds.json`  \n  3. Wait for next cron run (or run `--test`)\n\n- **Change a threshold:** Edit `~/.hermes/portfolio/portfolio_thresholds.json` directly; script reloads each run.\n\n- **Change deduplication window:** Edit line ~383 in script: `timedelta(hours=24)` → desired hours.\n\n- **Add a platform:** Implement `send_<platform>()` function and add call in main after line 420.\n\n- **Rotate logs:** Log file grows ~1–2 KB per run. Rotate monthly:  \n  ```bash\n  mv ~/.hermes/portfolio/threshold_alerts.log ~/.hermes/portfolio/threshold_alerts.log.$(date +%Y-%m)\n  touch ~/.hermes/portfolio/threshold_alerts.log\n  ```\n\n- **Backup state:** `alert_state.json` preserves deduplication history. Back up occasionally to avoid losing suppression tracking after housekeeping.\n\n## Related Skills\n\n- `stock-threshold-monitoring` — simpler, hard-coded hourly alerts (buy-side only, no dedup, 3 cron jobs)\n- `crypto-threshold-monitoring` — BTC/ETH/SUI alerts to Discord\n- `portfolio-tracker` — manual snapshot updates, conviction tracking, monthly review\n- `knowledge-base` — KG entity management and capture workflows

## Investigation Notes

- **2026-05-02 — Silent run diagnosis**: Full diagnostic trace confirming the cron job was working correctly; all threshold crossings were suppressed by 24-hour deduplication. Contains price snapshot, alert state analysis, log timeline, and troubleshooting checklist. See `references/2026-05-02-silent-run-investigation.md`.

- **2026-05-02 — Extended silent run (19:00 UTC) follow-up**: Confirmed ongoing suppressed state; identified stale price data and unthresholded KG decision tickers. Clarified monitored ticker selection logic (KG ∩ thresholds). Added explicit stale-data detection and CELH gap analysis. See `references/2026-05-02-silent-run-evening-investigation.md`.
#### 2026-05-03 — Cron silent run (01:30 & 05:30 UTC) operational review
Confirmed all 5 monitored tickers suppressed; documented dual script locations (`/opt/data/home/.hermes/scripts/` primary vs `/opt/data/scripts/` symlink), `$HOME=/opt/data/home` nuance, verified live prices, and identified `--test` mode deduplication limitation. Provides verification commands and next alert windows. See `references/2026-05-03-cron-silent-run-investigation.md`.

#### 2026-05-11 — User command `--test=false` and stdout expectation
- The script does not accept `--test=false`; it expects either `--test` (dry-run) or no flag (production).
- Production runs (no `--test`) produce no stdout; all output goes to the log file.
- If you need to see the alert payload, use `--test`, but note that test mode does not send alerts.
- The exit code is always 0 on success; it does not indicate whether alerts were sent.

- **2026-05-10 — Invocation and Path Troubleshooting**: Added a comprehensive reference guide for common errors when running the portfolio threshold alerts script, including `$HERMES_HOME/scripts/portfolio_threshold_alerts.py not found`, `--test=false` argument errors, and cron job configuration issues. See `references/invocation-and-path-troubleshooting.md`.
