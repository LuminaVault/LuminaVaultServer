# Hermes Scripts Directory Symlink Convention

## Overview

Many Hermes installations use `/opt/data/scripts/` as a **symlink farm**: each `.py` or `.sh` file in this directory is a symlink pointing to its canonical location in the Hermes home scripts directory (typically `/opt/data/home/.hermes/scripts/`).

```
/opt/data/scripts/  (symlink directory — exposed to cron workdirs)
        ↓ symlink
~/.hermes/scripts/  (canonical location — edit here)
```

## Purpose

- **Single source of truth:** Scripts are edited in one place (`~/.hermes/scripts/`) but accessible from both the Hermes user's perspective and central system directories.
- **Cron compatibility:** Cron jobs expect scripts at `/opt/data/scripts/<name>.py`. Symlinks resolve this without copying.
- **Consistency:** Avoids stale copies if scripts are duplicated across locations.

## Identifying the Pattern

Check `/opt/data/scripts/`:

```bash
ls -la /opt/data/scripts/ | head -20
```

If you see entries like:
```
lrwxrwxrwx 1 hermes hermes  50 Apr 30 09:10 daily_stock_news.py -> /opt/data/home/.hermes/scripts/daily_stock_news.py
-rwxr-xr-x 1 hermes hermes 7153 Apr 29 10:23 some_script.py
```

The `.py` files ending in `-> /opt/data/home/.hermes/scripts/...` are symlinks. A regular file (no arrow) indicates it's either a native script or a missing symlink.

## When a Script Is Missing

If a cron job reports `Script not found: /opt/data/scripts/<script>.py` but you can see `<script>.py` in `~/.hermes/scripts/`, create the symlink:

```bash
# Determine Hermes home (common locations)
HERMES_HOME="${HERMES_HOME:-/opt/data/home/.hermes}"
# Or discover: ls -la /opt/data/home/.hermes 2>/dev/null || ls -la /root/.hermes 2>/dev/null

# Create the symlink
ln -s "$HERMES_HOME/scripts/<script>.py" "/opt/data/scripts/<script>.py"

# Set correct permissions (symlink inherits; script itself should already be 755)
chmod 755 "/opt/data/scripts/<script>.py"
```

**Example fix** (this session's case):
```bash
ln -s /opt/data/home/.hermes/scripts/stock_alert_triple.py /opt/data/scripts/stock_alert_triple.py
ln -s /opt/data/home/.hermes/scripts/stock_news_triple.py /opt/data/scripts/stock_news_triple.py
```

## verifying

```bash
# Resolve the symlink to confirm target
readlink -f /opt/data/scripts/<script>.py

# Should print: /opt/data/home/.hermes/scripts/<script>.py

# List with details
ls -la /opt/data/scripts/<script>.py
# Should show: lrwxrwxrwx ... -> /opt/data/home/.hermes/scripts/<script>.py
```

## Exceptions

- If the job's `workdir` is not `/opt/data/scripts/`, correct the `workdir` in `jobs.json` or via `cronjob action='update'` instead of creating symlinks.
- If your Hermes installation doesn't use this convention (no existing symlinks in `/opt/data/scripts/`), it's safer to copy the script or update the job's path rather than introduce symlinks.

## Related Cron Jobs

**Stock alert orchestrator pattern:**
- `stock_alert_triple.py` — orchestration script (runs all 3 platform wrappers)
- `stock_alert_discord.sh` — Discord delivery wrapper
- `stock_alert_telegram.py` — Telegram delivery wrapper
- `stock_alert_slack.py` — Slack delivery wrapper
- Companion: `stock_news_triple.py` — daily stock news aggregator

These scripts live in `~/.hermes/scripts/` and are symlinked into `/opt/data/scripts/` for cron access.
