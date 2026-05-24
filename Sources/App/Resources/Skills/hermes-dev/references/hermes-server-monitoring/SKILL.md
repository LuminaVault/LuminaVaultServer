---
name: hermes-server-monitoring
description: Resource monitoring and alerting for the Hermes agent host server
---

# Hermes Server Monitoring Skill

## When to use

**Use this skill for:**

- Checking current resource usage on a monitored server
- Viewing or troubleshooting monitoring reports and alerts
- **Validating or repairing a monitoring cron job setup** (script path, ownership, duplicate jobs, delivery)
- Adjusting thresholds or schedules on existing deployments
- Understanding what a monitoring output means
- **Diagnosing delivery failures** to message platforms (Discord, Telegram, Slack) and applying fallbacks when gateways are down
- Debugging why a cron job didn't deliver or produced no output
- **Fixing script-level issues**: environment variables (`load_dotenv`), platform-specific API format quirks (Telegram form-encoding), bot permissions (Discord guild membership)

**Do NOT use for initial server deployment.** For that, use `hermes-remote-deploy` which handles:
- SSH key setup and passwordless authentication
- Copying scripts to the remote server
- Installing cron jobs (self-monitoring or centralised)
- Adapting to different Hermes installation paths
- Setting up the backup infrastructure

## Prerequisites

**For local Hermes host monitoring:**
1. **Discord bot token:** `DISCORD_BOT_TOKEN` environment variable set on the Hermes host (required for `send_message` tool to post to Discord)
2. **Monitoring script** deployed at `/opt/hermes/scripts/server_resource_monitor.py` (built into Hermes)
3. **Script permissions:** The script should be owned by `hermes:hermes` and executable (755). If owned by `root`, the `hermes` user may not be able to write output files. Fix: `chown hermes:hermes /opt/hermes/scripts/server_resource_monitor.py`

**For remote server monitoring (centralized pattern):**
1. **Remote server accessible via SSH** from the Hermes host (passwordless key-based auth)
2. **SSH key** at `/opt/data/.ssh/hermes_monitor_key` with root access to the target server
3. **Remote monitoring script** deployed at the same path on the target (handled by `hermes-remote-deploy`)
4. `DISCORD_BOT_TOKEN` configured on the Hermes host (alerts route back through central Hermes)

The monitoring script uses only Python standard library and reads `/proc` directly on the target host.

## Quick Start

### Manual check (local Hermes host)
```bash
/opt/hermes/scripts/server_resource_monitor.py
```

### View latest report (local Hermes host)
```bash
cat /opt/hermes/scripts/latest_report.txt
```

### Create alert cron job (if not already present)

For local Hermes host monitoring, create a 30-minute alert check that posts to Discord only on threshold breaches:

**Pattern A — Direct delivery via `--deliver` (simplest)**
```bash
# Deliver script output to Discord unconditionally
hermes cron create '*/30 * * * *' \
  --name 'hermes-server-resource-alerts' \
  --workdir /opt/hermes/scripts \
  --prompt 'Run /opt/hermes/scripts/server_resource_monitor.py' \
  --deliver discord:1498811072155484330
```

**How it works:** The Hermes cron agent runs the script and delivers its stdout to the Discord channel **regardless of exit code**. Use this only if you want every run delivered (e.g., daily/weekly reports). For alert-only jobs, use Pattern B or C below.

**Pattern B — Agent-managed conditional delivery (recommended for alerts)**
```bash
# Agent handles exit-code check and calls send_message only on breach
hermes cron create '*/30 * * * *' \
  --name 'hermes-server-resource-alerts' \
  --workdir /opt/hermes/scripts \
  --prompt 'Run /opt/hermes/scripts/server_resource_monitor.py' \
  --deliver origin
```

**How it works:** The agent auto-generates a task that executes the script, checks `exit_code`, and calls `send_message` to Discord **only when exit_code is 1**. This is the agent's default pattern when `--deliver origin` is used with a simple execution prompt. Requires `DISCORD_BOT_TOKEN` and the Discord channel hard-coded in the agent-generated logic (typically `discord:1498811072155484330`). Silent on healthy runs (exit code 0).

**Explicit form of Pattern B (if you want to be explicit in the prompt):**
```bash
hermes cron create '*/30 * * * *' \
  --name 'hermes-server-resource-alerts' \
  --workdir /opt/hermes/scripts \
  --prompt 'Run /opt/hermes/scripts/server_resource_monitor.py. If exit_code is 1, immediately call send_message(target="discord:1498811072155484330", message=<stdout>). If exit_code is 0, exit silently.' \
  --deliver origin
```

**Pattern C — Skill-based with centralized SSH execution**
```bash
# Use the skill to handle remote execution logic
hermes cron create '*/30 * * * *' \
  --name 'homepage-resource-alerts' \
  --workdir /opt/hermes/scripts \
  --skill hermes-server-monitoring \
  --deliver local \
  'Check homepage server (49.13.165.238) resource health'
```

**How it works:** Loading `hermes-server-monitoring` injects the SSH command and threshold-check logic. The skill runs `server_resource_monitor.py` on the target host, captures stdout + exit code, and sends a Discord alert only when exit code is 1. The Discord channel is configured inside the skill's implementation (hard-coded to `discord:1498811072155484330`).

## Automated Monitoring Setup

### Local Hermes Host (most common)
The monitoring script runs directly on the Hermes host. Create a cron job that executes the script and sends alert output to Discord via the `send_message` tool when thresholds are breached (exit code 1):

```bash
# Create the 30-minute alert job
hermes cron create '*/30 * * * *' \
  --name 'hermes-server-resource-alerts' \
  --workdir /opt/hermes/scripts \
  --prompt 'Run /opt/hermes/scripts/server_resource_monitor.py' \
  --deliver discord:1498811072155484330
```

**How delivery works:** The Hermes cron system captures the script's stdout. If the script exits with code 0 (healthy), nothing is sent. If it exits with code 1 (breach detected), the output is delivered to `discord:1498811072155484330` via the `send_message` tool using the `DISCORD_BOT_TOKEN` configured in the environment.

**Required environment:** `DISCORD_BOT_TOKEN` must be set on the Hermes host (e.g., in `~/.hermes/.env` or system environment). The Discord bot must have "Send Messages" permission in the target channel.

### Daily/Weekly Reports (optional)
For regular health reports (not just alerts), create additional jobs that always deliver output regardless of exit code:

```bash
# Daily 9 AM report
hermes cron create '0 9 * * *' \
  --name 'hermes-server-resource-daily' \
  --workdir /opt/hermes/scripts \
  --prompt 'Run /opt/hermes/scripts/server_resource_monitor.py' \
  --deliver discord:1498811072155484330

# Weekly Sunday 11 PM summary
hermes cron create '0 23 * * 0' \
  --name 'hermes-server-resource-weekly' \
  --workdir /opt/hermes/scripts \
  --prompt 'Run /opt/hermes/scripts/server_resource_monitor.py' \
  --deliver discord:1498811072155484330
```

**Note:** The daily/weekly jobs always send output (exit code is ignored). Use `--deliver` with a Discord channel target to replicate Telegram+Slack home-channel behavior on a per-platform basis.

### Remote Server (centralized monitoring)
To monitor a remote server from the Hermes host, the cron job runs an SSH command that executes the remote script and returns its output and exit code. Use `hermes-remote-deploy` to provision the remote server first, then create the alert job:

```bash
hermes cron create '*/30 * * * *' \
  --name 'prod-server-resource-alerts' \
  --prompt 'ssh -i /opt/data/.ssh/hermes_monitor_key root@168.119.156.43 "python3 /opt/hermes/scripts/server_resource_monitor.py"' \
  --workdir /opt/hermes/scripts \
  --deliver discord:1498811072155484330
```

The same exit-code-based conditional delivery applies: output is only sent when thresholds are breached.

---

## Job Reference

All monitoring jobs have the prefix `hermes-server-resource-*`:

| Prefix | Scope |
|--------|-------|
| `hermes-server-resource-*` | Local Hermes host monitoring |
| `prod-server-resource-*` | Production server (168.119.156.43) |
| `homepage-resource-*` | Homepage server (49.13.165.238) |
| Custom prefix | Any other monitored server |

The suffix indicates frequency: `-alerts` (every 30 min, threshold-based), `-daily`, `-weekly`.

### Typical deployed jobs (Hermes Host)

| Job name | Schedule | Notes |
|----------|----------|-------|
| `hermes-server-resource-alerts`  | Every 30 min | Alert-only; deliver via cron to `discord:…` (see below) |
| `hermes-server-resource-daily`   | Daily 9:00  | Always-deliver (Telegram + Discord home) |
| `hermes-server-resource-weekly`  | Weekly Sun 23:00 | Always-deliver (Telegram + Discord home) |

**Discord-specific variants** exist for each (e.g., `hermes-server-resource-alerts-discord`, `hermes-server-resource-daily-discord`, `hermes-server-resource-weekly-discord`). The `-discord` variant uses `deliver=discord:1498811072155484330` directly; the base name variants typically use `--deliver origin` or platform home channels.

### Typical deployed jobs (Remote Servers)

| Job name | Target | Method |
|----------|--------|--------|
| `prod-server-resource-alerts` | 168.119.156.43 | SSH → remote script (skill-based) |
| `prod-server-resource-alerts-discord` | 168.119.156.43 | SSH → direct. (both variants exist) |
| `homepage-resource-alerts` | 49.13.165.238 | SSH → remote script (skill-based) |
| `homepage-resource-alerts-discord` | 49.13.165.238 | Direct local execution on Hermes host |

## Thresholds

Default thresholds (adjust in script):

| Metric | Threshold |
|--------|-----------|
| CPU (normalized per-core) | >80% |
| Memory usage | >85% |
| Disk usage | >90% on any mount |
| Swap usage | >80% (if swap enabled) |

## Customization

### Edit thresholds
Edit `/opt/hermes/scripts/server_resource_monitor.py`:
```python
THRESHOLDS = {
    'cpu_percent': 80.0,
    'memory_percent': 85.0,
    'disk_percent': 90.0,
    'swap_percent': 80.0,
}
```

### Change schedule
Use `cronjob` tool:
```bash
cronjob action='update' job_id='JOB_ID' schedule='NEW_SCHEDULE'
```

Cron format: `minute hour day month weekday`
- Hourly: `0 * * * *`
- Every 30 min: `*/30 * * * *`
- Daily 9 AM: `0 9 * * *`
- Weekly Sunday 11 PM: `0 23 * * 0`

### Disable/Enable
```bash
cronjob action='pause' job_id='...'   # stop temporarily
cronjob action='resume' job_id='...'  # restart
```

## Job Reference

All monitoring jobs have the prefix `hermes-server-resource-`:

| Job Name | Purpose | Schedule |
|-----------|---------|----------|
| hermes-server-resource-daily | Daily health report | 9:00 AM daily |
| hermes-server-resource-daily-discord | Daily (Discord) | 9:00 AM daily |
| hermes-server-resource-weekly | Weekly summary | Sun 11:00 PM |
| hermes-server-resource-weekly-discord | Weekly (Discord) | Sun 11:00 PM |
| hermes-server-resource-alerts | Alert-only check | Every 30 min |
| hermes-server-resource-alerts-discord | Alerts (Discord) | Every 30 min |

### Creating New Server Alerts

When adding a **new server** to the monitoring fleet (centralized pattern), create an alert-only job that SSHes to the remote host:

```bash
hermes cron create '*/30 * * * *' \
  --name 'server-alerts-<server-label>' \
  --workdir /opt/hermes/scripts \
  --skill hermes-server-monitoring \
  --deliver local \
  'Run the server_resource_monitor cron script located in the workdir'
```

**Why this form:**
- `--skill hermes-server-monitoring` loads the skill (supplies the monitoring script and SSH logic)
- The minimal prompt satisfies the "prompt required" rule without adding execution overhead
- `--deliver local` keeps control inside the wrapper script, which handles Discord delivery itself only on threshold breaches
- `--workdir /opt/hermes/scripts` ensures the monitor script is in PATH when the skill executes

The skill's internal logic handles SSH execution and conditional Discord delivery. The job stays silent (exit code 0) when all metrics are within thresholds, and alerts (exit code 1) only on breaches.

## Troubleshooting

### Cron job validation checklist (post-deployment)
When verifying that a monitoring cron job is properly set up, check:
1. **Script exists at correct workdir path:** The cron job's `workdir` should contain `server_resource_monitor.py`. If the script lives elsewhere (e.g., `/opt/data/scripts/`), copy it: `cp /opt/data/scripts/server_resource_monitor.py /opt/hermes/scripts/` and `chown hermes:hermes` it.
2. **Script ownership & permissions:** Must be owned by `hermes` (UID 10000) and executable (755). If owned by `root`, the `hermes` user may not be able to write output files.
3. **No duplicate alert jobs:** Multiple cron jobs with the same schedule (`*/30 * * * *`) and same Discord channel (`1498811072155484330`) will cause double alerts. Job names are inconsistent (e.g., `hermes-server-resource-alerts`, `New Server — Alerts`, `prod-server-resource-alerts`), so `grep -i alert` may miss duplicates. Prefer a full scan: `hermes cron list`, then for each `*/30` job check if it delivers to `discord:1498811072155484330` or `local` (which uses the skill and may also deliver to Discord). Verify the actual monitored target via job prompt/SSH host to avoid overlaps. Keep exactly one alert job per server. Use `cronjob action='pause' <job_id>` to disable extras.
4. **Script path in prompt matches reality:** Ensure any hardcoded paths in the cron job's prompt are correct (e.g., `/opt/hermes/scripts/server_resource_monitor.py`). Mismatched paths fail silently.
5. **Discord gateway active:** Lock file exists at `/opt/data/.local/state/hermes/gateway-locks/discord-bot-token-*.lock` and `DISCORD_BOT_TOKEN` is set in `/opt/data/.env`.
6. **Test run:** Execute the script directly from the workdir to verify it produces output and exits with code 0 (healthy) or 1 (breach).

**If any check fails,** fix the underlying issue (copy script to right location, correct ownership, pause duplicates, update cron prompt) and re-test before relying on scheduled runs.

##### Stale duplicate scripts in legacy directories

**Symptom:** Cron job fails with:
```
python3: can't open file '/opt/data/scripts/<script.py>': [Errno 2] No such file or directory
```
even though the script clearly exists at the canonical location (e.g. `/opt/data/home/.hermes/scripts/<script.py>`).

**Root cause:** Over time, multiple copies of Hermes automation scripts accumulate in different directories. Early deployments used `/opt/data/scripts/` as the central scripts dir. Modern convention places the canonical scripts in `~/.hermes/scripts/` (or `/opt/data/home/.hermes/scripts/`) with either symlinks or workdir pointing to `/opt/data/scripts/`. Stale duplicate files in `/opt/data/scripts/` can become orphaned when the real script moves, leading to path confusion.

**Diagnose:**
```bash
# List what's actually in /opt/data/scripts/
ls -l /opt/data/scripts/*.py | grep -v '^l'   # look for real files (not symlinks)
# Check if they are duplicates of the canonical versions
diff /opt/data/scripts/stock_alert_triple.py /opt/data/home/.hermes/scripts/stock_alert_triple.py
```

**Fix:** Remove stale duplicates; keep only symlinks or nothing in `/opt/data/scripts/` so all execution goes through the canonical location.

```bash
# 1. Identify non-symlink Python files in /opt/data/scripts/
find /opt/data/scripts/ -maxdepth 1 -name '*.py' -type f

# 2. For each, verify it's a duplicate of a script in the canonical directory
#    If yes and it's not a symlink, remove it:
rm /opt/data/scripts/<stale_duplicate.py>

# 3. Ensure symlinks to the canonical location exist where needed:
ln -sf /opt/data/home/.hermes/scripts/<script>.py /opt/data/scripts/<script>.py
chmod 755 /opt/data/scripts/<script>.py
```

**Prevention:** Maintain the invariant: `/opt/data/scripts/` contains **only symlinks** (or nothing) pointing to `~/.hermes/scripts/`. Never edit scripts in `/opt/data/scripts/` directly; edit the canonical copy. Periodically audit with `find /opt/data/scripts/ -name '*.py' -type f` to catch accidental real files.

---

#### Systematic Duplicate Detection & Cleanup

When you suspect overlapping or redundant cron jobs (same schedule, same target, or duplicated functionality), follow this procedure:

**Step 1 — Export all jobs to a single view:**
```bash
hermes cron list --limit 100 > /tmp/all_jobs.json
# Or for a pretty table:
python3 -c "
import json, sys
data = json.load(open('/tmp/all_jobs.json'))
for j in data['jobs']:
    print(f\"{j['name']:40s} {j['schedule']:15s} {j['deliver']}\")
"
```

**Step 2 — Filter by schedule frequency:**
```bash
# Alert jobs (every 30m)
grep -E '\*/30|\*\/\* \* \* \*' /tmp/all_jobs.json | jq -r '.jobs[] | "\(.name) | \(.schedule) | \(.deliver) | \(.prompt)"'

# Daily jobs (0 9 * * *)
grep -E '0 9 \* \* \*' /tmp/all_jobs.json | ...
```

**Step 3 — Cluster by deliver target + schedule:**
Group jobs that have the **same `deliver` value and same `schedule`**. These are candidates for consolidation. Examples:
- Three jobs all delivering to `discord:1498811072155484330` on `*/30 * * * *` → likely duplicates
- Two jobs both at `0 9 * * *` delivering to Telegram → consolidate into one

**Step 4 — Inspect each candidate's monitored target:**
Read the `prompt` or `script` field to see *what* they monitor:
- `ssh -i ... root@168.119.156.43 "python3 ..."` → monitors prod server
- `Run /opt/hermes/scripts/server_resource_monitor.py` → monitors local Hermes host
- `server_monitor_multi.py` → consolidated multi-server job

Keep **one job per unique target**. Pause others:
```bash
cronjob action='pause' job_id='DUPLICATE_JOB_ID'
```

**Step 5 — Rename for clarity (optional but recommended):**
Use consistent naming:
- `<server-name>-resource-alerts` for alert-only (e.g., `prod-server-resource-alerts`)
- `<server-name>-resource-daily` for daily reports
- `multi-server-alerts` for consolidated multi-server alerts

```bash
cronjob action='update' job_id='JOB_ID' name='prod-server-resource-alerts'
```

**Step 6 — Verify reduction:**
After cleanup, you should have:
- 1 alert job per monitored server (or 1 consolidated multi-server alert job)
- 1 daily report per server (or 1 consolidated daily)
- 1 weekly summary per server (or 1 consolidated weekly)

No two active jobs should share both the **same schedule** and the **same deliver target** unless they are intentionally partitioned by monitored target (e.g., one watches StockPlan, another watches homepage — but if both deliver to the same Discord channel, consider consolidating into `server_monitor_multi.py` to avoid duplication).

**Common duplication sources:**
- Legacy jobs left behind after migration to a new script
- Per-platform jobs (Discord/Slack/Telegram) with identical schedules — these are intentional if they target different platforms; if targeting the same platform, they're duplicates.
- Jobs with different names but same `deliver` and `schedule` (e.g., `hermes-server-resource-alerts` and `server-health-monitor` both every 30 min → check if they run the same script)

### Job not delivering
1. Check job status: `cronjob action='list'`
2. Verify `last_delivery_error` field
3. Test script manually: `/opt/hermes/scripts/server_resource_monitor.py`
4. Check workdir is `/opt/hermes/scripts`

### Workdir points to wrong location
If the cron job fails with "Script not found" and the troubleshooting checklist suggests copying the script elsewhere, check whether the **workdir configuration itself is wrong** — the fix may be to update the job's `workdir` rather than copy files.

**Symptoms:**
```
Script not found: /opt/data/scripts/server_resource_monitor.py
# but the file exists at /opt/hermes/scripts/server_resource_monitor.py
```
The job's `workdir` is incorrectly set and should be corrected.

### Script blocked by path containment policy
**Symptom:** Cron job fails with:
```
Blocked: script path resolves outside the scripts directory (/opt/data/scripts): '<script_name>'
```

**Root cause:** Hermes cron enforces a security policy: the *resolved* script path (after `Path.resolve()` follows symlinks) must be a subpath of `$HERMES_HOME/scripts/` (`/opt/data/scripts` here). If the script in the cron job's `script` field is a **symlink** whose target lives outside that directory (e.g., `~/.hermes/scripts/...` → `/opt/data/home/.hermes/scripts/...`), the resolved path fails the containment check even though `workdir` is correct.

This differs from a missing script — the file exists and is executable, but its *resolved location* crosses a directory boundary that Hermes treats as a security boundary.

**Quick diagnostic:**
```bash
python3 -c "
from pathlib import Path
scripts_dir = Path('/opt/data/scripts').resolve()
path = Path('stock_alert_triple.py').resolve()
try:
    path.relative_to(scripts_dir)
    print('OK — within allowed directory')
except ValueError:
    print('BLOCKED — resolved path:', path)
"
```

**Fix (choose one):**

**Option A — Copy the script into the allowed directory** (recommended, simplest)
```bash
cp /opt/data/home/.hermes/scripts/<script>.py /opt/data/scripts/
chmod 755 /opt/data/scripts/<script>.py
```
The copy lives entirely inside `/opt/data/scripts/` and passes containment.

**Option B — Restructure so the symlink target is also within `$HERMES_HOME/scripts/`**
Only viable if `$HERMES_HOME/scripts/` itself contains the canonical scripts (i.e., `$HERMES_HOME` points to `/opt/data/` and scripts live at `/opt/data/scripts/`). When `$HERMES_HOME=/opt/data` and canonical location is `~/.hermes/scripts/`, this option doesn't apply.

**Verify:**
```bash
/opt/data/scripts/<script>.py   # should exit 0 (or 1 for an alert)
hermes cron run <job-id>  # re-run manually; Blocked error should disappear
```

**Related patterns:** Affected jobs in this installation: `stock-alert-triple`, `daily-stock-news-triple`, `portfolio-threshold-alerts`, and previously `server-health-monitor` when symlinked from `~/.hermes/scripts/`. Always prefer **Option A (copy)** when your canonical scripts live outside `$HERMES_HOME/scripts/`.

### Symlink convention vs containment policy
Some Hermes installations follow a **symlink convention** where `/opt/data/scripts/` contains symlinks pointing to canonical scripts in `~/.hermes/scripts/`. This provides a single source of truth while satisfying tools that expect scripts to exist in `/opt/data/scripts/`.

**However**, the Hermes cron security policy enforces a **containment check**: the *resolved* script path (after symlink dereferencing) must be a subpath of `$HERMES_HOME/scripts/` (`/opt/data/scripts`). Symlinks whose targets live *outside* that directory fail this check and are blocked before execution, even though the script file itself is readable and executable.

**Installation layout comparison:**

| Installation style | Canonical script location | Symlink target location | Containment safe? |
|-------------------|--------------------------|------------------------|-------------------|
| Modern symlink-safe | `~/.hermes/scripts/` | `/opt/data/scripts/` (symlink → outside) | ❌ BLOCKED |
| Centralized canonical | `/opt/data/scripts/` | (none or symlink within same dir) | ✅ SAFE |
| Legacy symlink-safe | `/opt/hermes/scripts/` | `/opt/data/scripts/` (symlink → outside) | ❌ BLOCKED |

When `$HERMES_HOME=/opt/data` (the standard), only scripts whose *real* path is inside `/opt/data/scripts/` pass the check.

**What changed in this session:**
- `stock_alert_triple.py` was present as a symlink `stock_alert_triple.py -> /opt/data/home/.hermes/scripts/stock_alert_triple.py` → blocked
- `portfolio_threshold_alerts.py` was present as a symlink `-> /opt/data/home/.hermes/scripts/portfolio_threshold_alerts.py` → blocked
- Both failing with `Blocked: script path resolves outside the scripts directory (/opt/data/scripts): '<script>'`
- Fix applied: copied actual script *contents* into `/opt/data/scripts/` (not symlinks); real path resolves inside allowed tree

**Takeaway:** On this installation (`$HERMES_HOME=/opt/data`), **do not use symlinks from `/opt/data/scripts/` to `~/.hermes/scripts/` for cron jobs**. Either:
1. Copy scripts into `/opt/data/scripts/` directly (Option A from above), or
2. Restructure so the canonical location itself is `/opt/data/scripts/` and edit scripts there (abandon the `~/.hermes/scripts/` canonical location)

See `references/hermes-cron-containment-policy.md` for full diagnostics and repair procedures.

#### Hermes scripts directory symlink convention
#### Hermes scripts directory symlink convention
Some Hermes installations use a **symlink convention**: the central scripts directory `/opt/data/scripts/` contains symlinks pointing to actual scripts in `~/.hermes/scripts/`. This allows a single canonical location for script edits while presenting a unified scripts dir for cron jobs.

**Pattern observed:**
```
/opt/data/scripts/
├── daily_stock_news.py -> /opt/data/home/.hermes/scripts/daily_stock_news.py
├── server_resource_monitor.py -> /opt/data/home/.hermes/scripts/server_resource_monitor.py
└── stock_alert_triple.py -> /opt/data/home/.hermes/scripts/stock_alert_triple.py
```

If `workdir` is correctly set to `/opt/data/scripts/` but the script file is missing, **creating the symlink** is often a better fix than copying or changing workdir.

**Why symlink vs copy:**
- ✅ Single source of truth — edits in `~/.hermes/scripts/` immediately visible at the symlink
- ✅ Matches established Hermes convention (see `daily_stock_news.py` as an existing example)
- ✅ Avoids path divergence and stale copies

**Fix — create missing symlink:**
```bash
ln -s /opt/data/home/.hermes/scripts/<script_name>.py /opt/data/scripts/<script_name>.py
chmod 755 /opt/data/scripts/<script_name>.py  # ensure executable bit follows
```

**When to prefer this over workdir edit:**
- The job's `workdir` is already `/opt/data/scripts/` (correct)
- The script exists in `~/.hermes/scripts/` but not in `/opt/data/scripts/`
- Other scripts in `/opt/data/scripts/` are already symlinks (established convention)

**When to correct the workdir instead:**
- The job's `workdir` points to an obsolete directory (e.g., `/opt/data/home/.hermes/scripts/` when the standard is `/opt/data/scripts/`)
- You're intentionally consolidating or restructuring script locations
- The installation doesn't use the symlink pattern (verify by checking existing entries in `/opt/data/scripts/`)

**⚠️ Critical caveat — Symlink containment policy:** Hermes cron enforces a **security containment check**: the *resolved* script path (after following symlinks) must remain within `$HERMES_HOME/scripts/` (the resolved `scripts_dir`). If the symlink target lives outside that directory (e.g., `~/.hermes/scripts/` when `$HERMES_HOME=/opt/data`), the check fails with:

```
Blocked: script path resolves outside the scripts directory (/opt/data/scripts): '<script>'
```

This is not a workdir issue — the workdir may be correct, but the symlink causes the resolved path to escape the allowed tree. The error is **intentional**; it prevents arbitrary script execution via symlink traversal.

**Resolution for broken symlink containment:**
You have two safe options:
1. **Copy the script** into the allowed directory (simplest, works universally):
   ```bash
   cp /opt/data/home/.hermes/scripts/<script>.py /opt/data/scripts/
   chmod 755 /opt/data/scripts/<script>.py
   ```
2. **Restructure so the canonical location is within `$HERMES_HOME/scripts/`** and symlink to a target that also resolves inside that tree (rarely practical; avoid).

If you see earlier troubleshooting advice (including this document's own "Example fix") suggesting `ln -s` to link across these directories, **do not follow it** when the target is outside `$HERMES_HOME/scripts/`. Use **copy** instead.

**Fix — update jobs.json directly:**
```python
import json
with open('/opt/data/cron/jobs.json') as f:
    data = json.load(f)
for job in data['jobs']:
    if job['name'] == 'server-health-monitor':
        job['workdir'] = '/opt/hermes/scripts'  # correct path
with open('/opt/data/cron/jobs.json', 'w') as f:
    json.dump(data, f, indent=2)
```

**Or update via the cronjob tool** (if a `update` action with workdir param exists in your version):
```bash
# Update workdir to the correct location
# (not all versions support workdir updates — fallback to editing jobs.json)
cronjob action='update' job_id='JOB_ID' workdir='/opt/hermes/scripts'
```

**Why this happens:** Early Hermes deployments occasionally used `/opt/data/scripts/` or `/opt/data/home/.hermes/scripts/` as workdirs. The canonical script location on modern installations is `/opt/hermes/scripts/`. Moving/copying the script is a workaround; correcting the job config is the permanent fix.

**Verify:** Re-run the job manually from the Hermes context or wait for the next scheduled tick.

### No metrics showing
The script reads from `/proc` filesystem which is always available on Linux.

### False alerts
Tune thresholds upward if normal operation triggers alerts.

### High CPU reading
The script calculates CPU usage correctly across multiple cores. For a 2-core system, 100% total = 50% average per core.

### Permission denied when running script
If the script fails with `PermissionError` when writing `latest_report.txt` or snapshots, the script directory may be owned by `root` (common in Docker deployments). Since the `hermes` user cannot write to root-owned directories, use this workaround:

```bash
# 1. Copy script to a writable temp location
cp /opt/data/scripts/server_resource_monitor.py /tmp/

# 2. Run from /tmp (script creates output files in current working directory)
cd /tmp && python3 server_resource_monitor.py
```

The script writes output files (`latest_report.txt`, `snapshot_*.json`) to its current working directory when run from `/tmp`, avoiding the permission issue.

**Permanent fix:** Consider changing ownership of the script and outputs directory to `hermes:hermes` so the cron job can write directly without the temp copy workaround:
```bash
# As root
chown -R hermes:hermes /opt/data/scripts/latest_report.txt
chown hermes:hermes /opt/data/scripts/server_resource_monitor.py
```

### Platform gateway not running (Slack/etc.)
If `send_message(target="slack")` fails with `Platform 'slack' is not configured`, the Slack gateway process may be down while other gateways (Discord/Telegram) are running.

**Diagnose:**
```bash
# Check which gateway lock files exist
ls /opt/data/.local/state/hermes/gateway-locks/
# Look for: discord-bot-token-*.lock, telegram-bot-token-*.lock, slack-bot-token-*.lock
```
If the Slack lock file is missing while Discord/Telegram locks are present, the Slack gateway is not running.

**Workaround — Direct API fallback:** Use the platform's native API with credentials from `/opt/data/.env`. Example for Slack:

```python
import json, urllib.request
from pathlib import Path

# Read SLACK_BOT_TOKEN from .env
env_path = Path('/opt/data/.env')
for line in env_path.read_text().split('\n'):
    if line.startswith('SLACK_BOT_TOKEN='):
        token = line.split('=', 1)[1].strip()
        break

# Post directly via Slack Web API
data = json.dumps({
    'channel': 'C0B0BDGEJTT',  # target channel ID
    'text': report_markdown,
    'mrkdwn': True
}).encode('utf-8')

req = urllib.request.Request(
    'https://slack.com/api/chat.postMessage',
    data=data,
    headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'},
    method='POST'
)
with urllib.request.urlopen(req, timeout=30) as resp:
    result = json.loads(resp.read().decode('utf-8'))
```

**Restart the gateway:** If frequent fallbacks are needed, restart the Hermes gateway service to restore platform connectivity.

This pattern applies to any platform with a credential-backed direct API, even when the gateway process is unavailable.

### Script environment variables not loading
Custom monitoring scripts that call `os.environ.get()` directly **do not automatically load** `/opt/data/.env`. If tokens/channels are empty, the script silently fails to deliver.

**Symptoms:**
```
✓ []  ✗ ['Discord', 'Slack', 'Telegram']
```
all platforms fail immediately, with or without explicit errors.

**Fix:** Add `python-dotenv` to the script:
```python
from dotenv import load_dotenv
load_dotenv('/opt/data/.env')

# Then os.environ.get() will pull from .env
DISCORD_BOT_TOKEN = os.environ.get("DISCORD_BOT_TOKEN", "").strip()
```
`python-dotenv` is already installed on the Hermes host; no extra deps needed.

### Telegram API format error — "message text is empty"
If Telegram returns `HTTP 400: Bad Request: message text is empty` even though `text` is non-empty, the payload is likely JSON-encoded. The Telegram Bot API for this token requires `application/x-www-form-urlencoded`, not `application/json`.

**Incorrect (JSON):**
```python
payload = {"chat_id": channel, "text": content}
req = urllib.request.Request(url, data=json.dumps(payload).encode(), ...)
```

**Correct (form-encoded):**
```python
import urllib.parse
payload = urllib.parse.urlencode({"chat_id": channel, "text": content}).encode()
req = urllib.request.Request(url, data=payload,
                             headers={"Content-Type": "application/x-www-form-urlencoded"},
                             method="POST")
```

### Discord bot HTTP 403 — bot lacks channel access
If all Discord API calls return `HTTP 403 error code: 1010`, the bot token is not a member of any guild/channel it's trying to post to.

**Diagnose:**
```python
import urllib.request, json
req = urllib.request.Request(
    "https://discord.com/api/v10/users/@me",
    headers={"Authorization": f"Bot {DISCORD_BOT_TOKEN}"}
)
# If this returns 403, the token is invalid or the bot is not in any guild
```

**Fix:** Re-invite the bot to each Discord server with the `bot` and `applications.commands` scopes and `Send Messages` permission, or update `DISCORD_BOT_TOKEN` with a valid token from <https://discord.com/developers/applications>.

## Output Format

Reports include:
- Timestamp and uptime
- Color-coded status (🟢 green, 🟡 yellow, 🔴 red)
- CPU: percent, core count, load averages
- Memory: used/total, buffers, cached
- Swap: used/total percent
- Disk: all mounted filesystems
- Top 5 processes by CPU and Memory

Alerts are shown at the top with ⚠️ warning symbols.

## Retention

- `latest_report.txt`: Always points to most recent report
- `snapshot_<timestamp>.json`: Full JSON data (kept indefinitely)
- Consider adding a cleanup cron if disk space becomes an issue

## See Also

- `/opt/data/home/.hermes/scripts/SERVER_MONITORING.md` — detailed documentation
- `cronjob` tool for managing scheduled tasks
- The script itself: `/opt/hermes/scripts/server_resource_monitor.py`
- Remote server: `prod-server-resource-*` jobs
- **Script path hygiene** (`references/script-path-hygiene.md`) — canonical vs legacy script locations, symlink conventions, stale duplicate cleanup
- **Containment policy** (`references/hermes-cron-containment-policy.md`) — why symlinks to `~/.hermes/scripts/` are blocked and how to fix

## Multi-Server Monitoring

This skill covers **operating** monitoring on servers that already have the stack deployed:

| Deployment Target | Execution Method | Setup Skill |
|-------------------|------------------|-------------|
| **Hermes host** (local) | Direct execution | Built-in |
| **Production server** (168.119.156.43) | Centralized: Hermes cron → SSH → remote script | `hermes-remote-deploy` |
| **Additional servers** (49.13.165.238, etc.) | Centralized: Hermes cron → SSH → remote script | `hermes-remote-deploy` |
| **Self-monitored servers** (if chosen) | Remote cron runs script locally | `hermes-remote-deploy` (self-monitoring mode) |

All use the same `server_resource_monitor.py` script and thresholds; only the execution method differs. The StockPlan production servers and homepage (49.13.165.238) use **centralized monitoring** where all cron jobs live on the Hermes host.

**Adding a new server?** Use `hermes-remote-deploy` and choose the centralized pattern to match the existing fleet.

### Unified Consolidated Reporting Pattern

When monitoring ≥2 servers, prefer a **single consolidated message per platform** instead of per-server posts. This reduces channel noise and provides a dashboard-style view.

**Implementation:**
1. Write a wrapper script (e.g., `server_monitor_multi.py`) that:
   - Iterates over a `SERVERS` list with `{ip, name}` entries
   - SSHes to each server and runs `server_resource_monitor.py`
   - Collects text output + exit code (1 = alert, 0 = OK)
   - Aggregates all reports into one message body
   - Sets `any_alert = any(server_exit_code == 1)`
   - Chooses title: `🚨 Multi-Server Alert` if any alert, else `📊 Multi-Server Status Report`
2. Set `DISCORD_ALERT_CHANNEL_ID` in `.env` to the unified channel
3. Create **two cron jobs**:
   - **Full report** (e.g., Mon/Thu 9AM): always sends the consolidated message
   - **Alert-only** (every 30 min): sends **only if** `any_alert=True` (use `ALERT_MODE=only` env flag or conditional logic)
4. For the alert-only job, use a wrapper script that exports `ALERT_MODE=only` before calling the main script, or embed the conditional in the script itself.

**Example wrapper (`server_monitor_multi_alert.sh`):**
```bash
#!/bin/bash
export ALERT_MODE=only
exec python3 /opt/data/home/.hermes/scripts/server_monitor_multi.py
```

**Advantages:**
- Single source of truth for all server statuses
- No duplicate messages across platforms
- Easy to compare servers side-by-side
- Centralized threshold logic and formatting

**See also:** `server-monitoring` references for `server_monitor_multi.py` template and ALERT_MODE pattern.

### Quick Reference Tables

**Local Hermes Host Jobs:**
| Job Name | Schedule | Platform |
|----------|----------|----------|
| hermes-server-resource-daily | 9:00 AM daily | Telegram & Discord |
| hermes-server-resource-weekly | 11:00 PM Sun | Telegram & Discord |
| hermes-server-resource-alerts | Every 30 min | Telegram & Discord (alert-only) |

**Production Server Jobs:**
| Job Name | Schedule | Platform |
|----------|----------|----------|
| prod-server-resource-daily | 9:00 AM daily | Telegram & Discord |
| prod-server-resource-weekly | 11:00 PM Sun | Telegram & Discord |
| prod-server-resource-alerts | Every 30 min | Telegram & Discord (alert-only) |

**SSH Key for Remote Monitoring:**
- Path: `/opt/data/.ssh/hermes_monitor_key`
- Owner: `hermes` (UID 10000)
- Permissions: `600`
- Remote authorized_keys appended during setup