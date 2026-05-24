# Portfolio Threshold Monitoring — Invocation and Path Troubleshooting

## Common Issues and Solutions

### 1. "File not found" when using `$HERMES_HOME/scripts/portfolio_threshold_alerts.py`

**Symptom:**  
`python3 $HERMES_HOME/scripts/portfolio_threshold_alerts.py: No such file or directory`

**Cause:**  
The script is not stored in `$HERMES_HOME/scripts/` in this deployment. The actual locations are:

- **Primary script:** `/opt/data/home/.hermes/scripts/portfolio_threshold_alerts.py`
- **Cron symlink:** `/opt/data/scripts/portfolio_threshold_alerts.py` (should be a symlink to primary)

`$HERMES_HOME` typically resolves to `/usr/local/lib/hermes-agent`, which does **not** contain the script.

**Solution:**  
Use the correct path. For manual execution:

```bash
python3 /opt/data/home/.hermes/scripts/portfolio_threshold_alerts.py
# or
python3 /opt/data/scripts/portfolio_threshold_alerts.py  # if symlink exists
```

For cron jobs, use the symlink path (`/opt/data/scripts/portfolio_threshold_alerts.py`) to ensure the script runs from the canonical location.

---

### 2. `--test=false` argument error

**Symptom:**  
```
usage: portfolio_threshold_alerts.py [-h] [--test]
portfolio_threshold_alerts.py: error: argument --test: ignored explicit argument 'false'
```

**Cause:**  
The `--test` flag is a boolean switch that takes **no value**. Using `--test=false` or `--test=true` is invalid.

**Solution:**  
Use one of these valid invocations:

```bash
# Dry-run (test mode) — prints to stdout, sends nothing, no state update
python3 /opt/data/home/.hermes/scripts/portfolio_threshold_alerts.py --test

# Production mode — sends alerts, updates state, logs to file (no stdout output)
python3 /opt/data/home/.hermes/scripts/portfolio_threshold_alerts.py
```

**Note:** `--test` mode still respects the 24-hour deduplication window. If all tickers are suppressed, `--test` may produce no output. To force a dry-run that shows all current crossings, temporarily clear the alert state:

```bash
echo '{}' > /opt/data/home/.hermes/portfolio/alert_state.json && python3 /opt/data/home/.hermes/scripts/portfolio_threshold_alerts.py --test
```

---

### 3. Cron job runs silently even when thresholds are crossed

**Symptom:**  
Cron reports `ok` but no alerts appear in Discord/Telegram, even though prices have crossed thresholds.

**Possible causes:**

1. **Cron includes `--test` flag**  
   The `--test` flag suppresses all platform delivery. Check your crontab entry:
   ```bash
   crontab -l | grep portfolio_threshold_alerts
   ```
   Should show:
   ```bash
   */30 * * * * cd /opt/data/home && /usr/bin/python3 /opt/data/scripts/portfolio_threshold_alerts.py
   ```
   **Not:**
   ```bash
   */30 * * * * cd /opt/data/home && /usr/bin/python3 /opt/data/scripts/portfolio_threshold_alerts.py --test
   ```
   Remove `--test` for live operation.

2. **All alerts suppressed by deduplication**  
   If an alert for a ticker+threshold was sent within the last 24 hours, it will be suppressed. Check the log:
   ```bash
   tail -n 30 /opt/data/home/.hermes/portfolio/threshold_alerts.log
   ```
   Look for lines like `Suppressing alert for AMD: already sent within 24h`.

3. **Missing credentials**  
   Ensure `DISCORD_BOT_TOKEN`, `DISCORD_ALERT_CHANNEL_ID`, `TELEGRAM_BOT_TOKEN`, and `TELEGRAM_CHAT_ID` are set in the environment (e.g., in `/opt/data/.env`).

4. **Script path mismatch**  
   If the cron job uses `$HERMES_HOME/scripts/portfolio_threshold_alerts.py` and that path doesn't exist, the job will fail silently or error. Use the absolute path to the symlink: `/opt/data/scripts/portfolio_threshold_alerts.py`.

---

### 4. Verifying script execution and paths

**Check if the script exists and is executable:**
```bash
ls -la /opt/data/home/.hermes/scripts/portfolio_threshold_alerts.py
ls -la /opt/data/scripts/portfolio_threshold_alerts.py
```

**Check if the symlink is correct:**
```bash
ls -la /opt/data/scripts/portfolio_threshold_alerts.py
# Should show something like:
# lrwxrwxrwx 1 root root 45 May 10 01:00 /opt/data/scripts/portfolio_threshold_alerts.py -> /opt/data/home/.hermes/scripts/portfolio_threshold_alerts.py
```

**Check cron job configuration:**
```bash
crontab -l | grep portfolio_threshold_alerts
# or for system crontabs:
cat /etc/crontab | grep portfolio_threshold_alerts
```

**Check recent log output:**
```bash
tail -n 50 /opt/data/home/.hermes/portfolio/threshold_alerts.log
```

---

### 5. Quick health check commands

```bash
# Verify KG decisions exist
python3 -c "import json; d=json.load(open('/opt/data/home/.hermes/knowledge_graph/entities.json')); decisions=[v for v in d.values() if isinstance(v,dict) and v.get('type')=='decision']; print(f'Decisions: {len(decisions)}')"

# Verify thresholds file
cat /opt/data/home/.hermes/portfolio/portfolio_thresholds.json | python3 -m json.tool

# Check alert state (deduplication)
cat /opt/data/home/.hermes/portfolio/alert_state.json | python3 -m json.tool

# Manual price check for monitored tickers
python3 -c "
import urllib.request, json
tickers = ['AMD','GOOGL','ZETA','RDW','ELF']
for t in tickers:
    url = f'https://query2.finance.yahoo.com/v8/finance/chart/{t}?range=1d&interval=1d'
    req = urllib.request.Request(url, headers={'User-Agent':'Mozilla/5.0'})
    d = json.loads(urllib.request.urlopen(req, timeout=10).read())
    meta = d['chart']['result'][0]['meta']
    print(f'{t}: ${meta[\"regularMarketPrice\"]} (as of {meta[\"regularMarketTime\"]})')
"
```

---

## Summary

- Use `/opt/data/home/.hermes/scripts/portfolio_threshold_alerts.py` or `/opt/data/scripts/portfolio_threshold_alerts.py` (symlink) for execution.
- `--test` is a flag without a value; `--test=false` causes an error.
- Cron jobs must omit `--test` for live alerts.
- Check logs and deduplication when alerts are expected but not sent.
- Ensure the symlink exists to avoid configuration drift.

**Note:** If your deployment uses a different path (e.g., `$HERMES_HOME/scripts/`), adjust accordingly but ensure the script exists at that location.