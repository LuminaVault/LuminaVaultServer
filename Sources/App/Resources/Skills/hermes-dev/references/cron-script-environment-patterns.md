# Cron Script Environment Patterns — Session Notes

## Case: stock-alert-triple Missing Platform Credentials

**Date:** 2026-05-04  \n**Script:** `stock_alert_triple.py`  \n**Cron Job ID:** `18186766daf4`  \n**Schedule:** `0 * * * *` (hourly)

---

## Symptoms

- Cron job reports: *"Script ran successfully but produced no output."*
- Script detects threshold crossings (6 tickers below buy/trim levels) but sends nothing to Slack/Telegram/Discord
- Platform wrapper scripts (`stock_alert_slack.py`, `stock_alert_telegram.py`, `stock_alert_discord.sh`) exit with empty stdout and stderr warnings: `⚠️  SLACK_BOT_TOKEN not set` (and similarly for Telegram/Discord)
- Job status shows `last_status: ok` but no messages delivered

## Root Cause

The Hermes cron scheduler loads environment variables from `~/.hermes/.env` before each job run. In this installation:

- `~/.hermes/.env` **does not exist** at `/opt/data/home/.hermes/.env`
- Platform tokens **are stored** in `/opt/data/.env`
- `stock_alert_triple.py` does **not** load any `.env` file itself — it relies entirely on environment injection
- Result: All `os.environ.get("SLACK_BOT_TOKEN")` etc. return `None`; wrappers skip delivery

In contrast, `portfolio_threshold_alerts.py` (same codebase) explicitly loads `/opt/data/.env` at startup, so it works correctly.

## Two Credential Storage Patterns

| Pattern | How It Works | Pros | Cons |
|---------|--------------|------|------|
| **A — Scheduler Injection** | Place tokens in `~/.hermes/.env`; scheduler auto-loads and injects them into every cron job's environment | No code changes; centralized; automatic | Requires maintaining `~/.hermes/.env` separately from `/opt/data/.env` |
| **B — Explicit Dotenv** | Script calls `_load_dotenv("/opt/data/.env")` at startup | Self-contained; uses existing `/opt/data/.env`; works even outside cron (manual runs) | Requires code change per script; duplicates loading logic |

## Fix Pattern — Explicit Dotenv Loading

Add this to the top of any cron script that needs platform credentials:

```python
from pathlib import Path
import os

def _load_dotenv(env_path: Path = Path("/opt/data/.env")) -> None:
    """Load platform credentials from the Hermes managed env file."""
    if not env_path.exists():
        return
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line:
            key, _, val = line.partition("=")
            key = key.strip()
            # Strip quotes and export prefix
            val = val.strip().strip('"\'')
            if key.startswith("export "):
                key = key[7:].strip()
            os.environ[key] = val

_load_dotenv()
```

**Placement:** Put this immediately after `import` statements, before any `os.environ.get()` calls.

**Reference Implementation:** See `portfolio_threshold_alerts.py` lines 34–47 (identical pattern).

## Migration Checklist

For each affected script (`stock_alert_triple.py`, `stock_alert_slack.py`, `stock_alert_telegram.py`, `stock_alert_discord.sh`):

- [ ] Add explicit dotenv loader at top of Python scripts
- [ ] For Bash scripts: create a wrapper that sources `/opt/data/.env` before invoking logic, or convert to Python
- [ ] Test locally: `python3 <script>` should now have env vars available
- [ ] Trigger via cron: `hermes cron run <job_id>`; check output in `/opt/data/cron/output/<job_id>/`
- [ ] Verify platform delivery (check Slack/Telegram/Discord channels)

## Diagnostic Commands

```bash
# Check which env files exist
ls -la ~/.hermes/.env          # Scheduler loads this (may be absent)
ls -la /opt/data/.env          # Traditional env file (usually contains tokens)

# See what tokens are available to the cron environment
# (after scheduler loads ~/.hermes/.env)
python3 -c "import os; print({k: v[:8]+'...' for k,v in os.environ.items() if any(x in k for x in ['TOKEN','CHANNEL','KEY'])})"

# Inspect the actual env file contents (values masked)
grep -E 'TELEGRAM|DISCORD|SLACK' ~/.hermes/.env /opt/data/.env 2>/dev/null

# Manually test a script with explicit loader
python3 /opt/data/home/.hermes/scripts/stock_alert_triple.py

# Check cron job output directory
ls -lt /opt/data/cron/output/stock-alert-triple/
cat /opt/data/cron/output/stock-alert-triple/*.md

# Validate script compiles
python3 -m py_compile /opt/data/home/.hermes/scripts/stock_alert_triple.py
```

## When to Use Which Pattern

- **New scripts:** Use Pattern B (explicit load) — more robust and portable
- **Legacy scripts already working:** Keep Pattern A if already deployed
- **Mixed environment:** Consider centralizing all tokens in `~/.hermes/.env` and symlinking: `ln -s ~/.hermes/.env /opt/data/.env` (then all patterns work)

## Related

- `hermes-dev` — Cron Script Debugging & Credential Injection (overview)
- `hermes-server-monitoring` — Day-to-day cron job health checks
- `stock-trading` — Stock alert scripts and threshold monitoring
