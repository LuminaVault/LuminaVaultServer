# Channel Configuration Reference

## Discord Channel IDs

| Channel ID | Name | Purpose |
|-----------|------|---------|
| `1499338003334561843` | #stock-news | Standalone wrapper delivery (stock_alert_discord.sh) |
| `1499362823342653471` | #alerts | KG script delivery (`DISCORD_ALERT_CHANNEL_ID`) |
| `1498025894751768776` | Hermes Home | KG script fallback (`DISCORD_HOME_CHANNEL`) |
| `1498815493757341896` | (legacy) | Old wrapper hard-coded (deprecated) |

## Script Locations

| Script | Path | Type | Delivery |
|--------|------|------|----------|
| Standalone threshold | `/opt/data/home/.hermes/scripts/stock_threshold_alert.py` | stdout-only | Via wrappers |
| KG threshold | `/opt/data/scripts/portfolio_threshold_alerts.py` | self-delivering | Direct cron |
| Discord wrapper | `/opt/data/scripts/stock_alert_discord.sh` | bash | Posts to 1499338003334561843 |
| Telegram wrapper | `~/.hermes/scripts/stock_alert_telegram.py` | python | Posts to Telegram home |
| Slack wrapper | `~/.hermes/scripts/stock_alert_slack.py` | python | Posts to Slack alerts |
| Orchestrator | `~/.hermes/scripts/stock_alert_triple.py` | python | Calls all three wrappers |

## Required Environment Variables

For **KG script** (`portfolio_threshold_alerts.py`):
```bash
DISCORD_BOT_TOKEN=...
DISCORD_ALERT_CHANNEL_ID=1499362823342653471   # or DISCORD_HOME_CHANNEL
TELEGRAM_BOT_TOKEN=...
TELEGRAM_HOME_CHANNEL=...
```

For **wrappers** (standalone script path):
```bash
DISCORD_BOT_TOKEN=...   # used by stock_alert_discord.sh
# Wrapper uses hard-coded CHANNEL_ID=1499338003334561843
```

## Active Cron Jobs (May 2026)

| Job ID | Name | Schedule | Script |
|--------|------|----------|--------|
| `a35b76eda07c` | portfolio-threshold-alerts | `*/30 * * * *` | KG script direct |
| `44f8186f2313` | portfolio-threshold-alerts-hourly | `0 * * * *` | KG script direct |
| `f610a2fca47a` | daily-stock-news-triple | `0 9 * * *` | Orchestrator → wrappers |
| `18186766daf4` | stock-alert-triple | `0 * * * *` | Orchestrator → wrappers |

Disabled (do not enable):
- `22584368cbfb` — Stock Alert — Discord (hourly) — references missing file
- `4a09e5e68c43` — Stock Alert — Telegram (hourly) — same
- `7934e36017c6` — Stock Alert — Slack (hourly) — same

## The Fix (May 1, 2026)

**Problem:** Channel `1499338003334561843` reported:  
`python3: can't open file '/opt/data/scripts/stock_threshold_alert.py': [Errno 2] No such file or directory`

**Root cause:** Orphaned wrapper `/opt/data/scripts/stock_alert_discord.sh` expects a script at that path, but only the hermes-home version existed.

**Resolution:**
```bash
# Remove any broken file/symlink at /opt/data/scripts/stock_threshold_alert.py
sudo rm -f /opt/data/scripts/stock_threshold_alert.py

# Create symlink to STANDALONE version (not KG version to avoid double-post)
ln -s /opt/data/home/.hermes/scripts/stock_threshold_alert.py /opt/data/scripts/stock_threshold_alert.py

# Verify
ls -l /opt/data/scripts/stock_threshold_alert.py
# -> should show symlink to ~/.hermes/scripts/stock_threshold_alert.py

# Test execution (requires DISCORD_BOT_TOKEN in env for full delivery)
cd /opt/data/scripts && python3 stock_threshold_alert.py --help
```

**Why standalone, not KG?**
- `stock_alert_discord.sh` is designed for stdout-only scripts — it captures output and posts to Discord itself.
- `portfolio_threshold_alerts.py` already posts internally using its own Discord API call.
- Routing KG script through wrapper would produce **duplicate messages** in the channel.

## Verification Commands

```bash
# Check symlink target
readlink -f /opt/data/scripts/stock_threshold_alert.py

# Run standalone script dry (no network call needed; prints alerts or all-clear)
python3 /opt/data/home/.hermes/scripts/stock_threshold_alert.py

# Check orchestrator is using hermes wrappers (correct)
grep -E "stock_alert_(discord|telegram|slack)" ~/.hermes/scripts/stock_alert_triple.py

# List threshold cron jobs
grep -A5 -B2 "stock-threshold\|portfolio-threshold" /opt/data/cron/jobs.json

# View recent threshold alert logs
tail -30 ~/.hermes/portfolio/threshold_alerts.log

# Check which version produced output in cron logs
grep -h "🚨 **Stock Threshold Alert**" /opt/data/cron/output/*/20*.md | tail -5
```

## Alert Output Format

Standalone script output (single platform):
```
🚨 **Stock Threshold Alert** — 2026-05-01 07:54 UTC

_5 ticker(s) at or below threshold:_

  ⬇️ **NVO**: $42.22 (threshold: $50.00)
  ⬇️ **OUST**: $26.96 (threshold: $30.00)
  ⬇️ **RDW**: $9.19 (threshold: $10.00)
  ⬇️ **SIDU**: $3.28 (threshold: $3.50)
  ⬇️ **SMR**: $12.46 (threshold: $14.00)
```

KG script output includes KG decision reference:
```
🚨 **Portfolio Threshold Alert** — 2026-05-01 07:47 UTC

_5 ticker(s) triggered:_

  ⬇️ **NVO** $42.22 ≤ $50.00
     Decision: Buy (2026-04-15, Knowledge Graph)
  ⬇️ **OUST** $26.96 ≤ $30.00
     Decision: Buy (2026-04-20, Knowledge Graph)
...
```

## State Files

- `~/.hermes/portfolio/alert_state.json` — last alert timestamp per ticker+threshold (KG script only)
- `~/.hermes/portfolio/portfolio_thresholds.json` — user overrides (KG script)
- `~/.hermes/portfolio/threshold_alerts.log` — execution log (both scripts append)
- `~/.hermes/knowledge_graph/entities.json` — KG decisions used by KG script
