---
name: stock-trading
description: Portfolio management and price alert skills for stocks and cryptocurrencies.
license: MIT
---
# Stock Trading

Consolidated skill set for personal trading workflows:

- **Crypto/stock threshold monitoring** — price alerts to Discord/Telegram/Slack on a schedule.
- **Portfolio tracker** — manual price updates, conviction-based position sizing, monthly review.
- **Telegram Delivery Wrapper** — Standard pattern for sending any script's Markdown output to Telegram from cron jobs.
- **Cron script path resolution** — Understanding how Hermes resolves script paths from `HERMES_HOME/scripts/` (independent of `workdir`), with troubleshooting for "Script not found" errors and recommended fix patterns.

## When to use

Use for tracking investments, setting alerts, performing structured portfolio reviews, or delivering scheduled text/Markdown reports to Telegram. **Specifically, load this skill for any stock news digest, portfolio tracking, or price alert cron job.**

## Subskills

## Subskills

### crypto-threshold-monitoring

**Description:** Cryptocurrency price threshold alerts (BTC, ETH, SUI) to Discord on a 2-hour schedule

**Full details:** `references/crypto-threshold-monitoring/SKILL.md`

### stock-threshold-monitoring

**Description:** Hourly stock price threshold alerts across Discord, Telegram, Slack

**Full details:** `references/stock-threshold-monitoring/SKILL.md`

### portfolio-tracker

**Description:** Systematic personal portfolio tracking with manual price updates, conviction-based position sizing, and structured monthly reviews. Includes snapshot/history maintenance, thesis validation, and rebalancing checklists.

**Full details:** `references/portfolio-tracker/SKILL.md`

### Daily stock news digest

**Description:** Run the daily stock-news script, recover when the requested path is missing, and surface threshold hits at the top of the digest.

**Runbook:** `references/daily_stock_news-runbook.md`

## Telegram Delivery Wrapper (for cron scripts)

**Problem:** Cron-job scripts produce Markdown/text output that needs to be posted to Telegram's home channel, but credentials aren't always in the immediate environment.

**Standard solution:** Use `stock_alert_telegram.py` as a wrapper. It runs your script and auto-delivers stdout to Telegram if output is present or the script signals an alert (exit code 1).

**Invocation:**
```bash
cd /opt/data/home/.hermes/scripts
python stock_alert_telegram.py your_script.py [args...]
```

**Behavior:**
- Runs `your_script.py` via subprocess
- Captures stdout (trimmed to Telegram's 4096 char limit)
- Sends to `TELEGRAM_HOME_CHANNEL` (or first user from `TELEGRAM_ALLOWED_USERS`)
- Only sends when there's output OR exit code 1 (alert signal)
- Preserves original exit code

**Credential loading:** Telegram credentials are read from environment variables:
- `TELEGRAM_BOT_TOKEN` (required)
- `TELEGRAM_HOME_CHANNEL` or `TELEGRAM_ALLOWED_USERS` (required)

In cron or scheduled contexts, source `/opt/data/.env` before invoking the wrapper to ensure credentials are available:
```bash
source /opt/data/.env && python stock_alert_telegram.py linear_daily_digest.py
```

**Pitfalls:**
- If env vars are missing, the wrapper prints a warning but exits with the wrapped script's exit code (non-fatal)
- Wrapper uses Markdown mode; ensure your output uses Telegram-compatible Markdown (avoid special chars that need escaping)
- For scripts that produce multi-part messages >4096 chars, implement chunking in the wrapper (not currently supported)
- Credentials live in `/opt/data/.env`; scripts run directly (without the wrapper) won't automatically have Telegram access

**Verification script:** `scripts/verify_telegram_delivery.py` — tests that credentials are loaded and wrapper can send a message.

**Reference:** See `references/telegram-delivery-wrapper/` for implementation details, environment variable setup, and usage examples.

## Cron Script Path Resolution

Hermes cron jobs resolve script paths from `$HERMES_HOME/scripts/`, **not** from the job's `workdir`. Setting `workdir` only affects the subprocess's working directory during execution — it does not change where the script binary is looked up.

This often surfaces as:
```text
Script not found: /opt/data/scripts/stock_news_triple.py
```
even though the file exists in the user's Hermes scripts directory (`~/.hermes/scripts/stock_news_triple.py`) because `HERMES_HOME` is set to `/opt/data` in this deployment.

**Fix patterns:**
1. **Symlink** the script into `HERMES_HOME/scripts/`:
   ```bash
   ln -s /opt/data/home/.hermes/scripts/stock_news_triple.py \
          /opt/data/scripts/stock_news_triple.py
   ```
2. **Re-align HERMES_HOME** to point at the user's actual Hermes home if all scripts live there:
   ```bash
   export HERMES_HOME=/opt/data/home/.hermes
   ```
3. **Relocate** the script into the expected `HERMES_HOME/scripts/` directory.

**Quick verification:** Run `python3 scripts/verify_cron_scripts.py` (with `HERMES_HOME` set appropriately) to check that all configured cron job scripts are accessible from `$HERMES_HOME/scripts/`. Use `--fix` to create safe symlinks automatically for scripts found in `~/.hermes/scripts/` but missing from the HERMES_HOME scripts directory.

**Session-specific pitfall:** A requested path may not exist even when the script is real. In that case, search the filesystem for `daily_stock_news.py` and run the discovered copy directly. See `references/daily_stock_news-runbook.md`.
