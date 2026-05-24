# Hermes Server Resource Monitoring

## Overview
Automated resource monitoring for the Hermes agent host server (where Hermes itself runs).

## Monitoring Script
**Location:** `/opt/hermes/scripts/server_resource_monitor.py`

**Features:**
- Pure Python standard library (no external dependencies)
- Measures: CPU, memory, swap, disk, load average, top processes
- Threshold-based alerting
- Emits exit code 1 when alerts present, 0 when OK

**Thresholds:**
- CPU: >80% per-core average (normalized across cores)
- Memory: >85% used
- Disk: >90% used on any mount
- Swap: >80% used (if swap exists)

**Outputs:**
- Console: Human-readable Markdown report
- JSON snapshot: `snapshot_<timestamp>.json`
- Latest report: `latest_report.txt`

## Cron Jobs

| Job ID | Name | Schedule | Platform | Deliver |
|--------|------|----------|----------|---------|
| 777c365f3646 | Daily report | 0 9 * * * | Telegram | Home channel |
| 9b4a95630fcf | Daily report | 0 9 * * * | Discord | Home channel |
| e99e815e5a0c | Weekly summary | 0 23 * * 0 | Telegram | Home channel |
| ec4856176b8d | Weekly summary | 0 23 * * 0 | Discord | Home channel |
| ddd4c0a8e9f8 | Alert check | */30 * * * * | Telegram | Home channel (only if alerts) |
| 823cc1177883 | Alert check | */30 * * * * | Discord | Home channel (only if alerts) |

### Job Types

1. **Daily Report** (9:00 AM daily)
   - Always sends full resource report
   - Shows all metrics, even when healthy

2. **Weekly Summary** (11:00 PM Sundays)
   - Full report, useful for weekly health check

3. **Alert Check** (every 30 minutes)
   - Only sends a message if any threshold is breached
   - Silent when system is healthy
   - Exit code 1 triggers notification

## Tuning Thresholds

To adjust alert thresholds, edit the `THRESHOLDS` dict in the script:

```python
THRESHOLDS = {
    'cpu_percent': 80.0,
    'memory_percent': 85.0,
    'disk_percent': 90.0,
    'swap_percent': 80.0,
}
```

Then update the script and all cron jobs will use the new thresholds automatically.

## Manual Check

Run manually anytime:

```bash
/opt/hermes/scripts/server_resource_monitor.py
```

Check exit code: `echo $?` (0 = OK, 1 = alerts)

View latest report: `cat /opt/hermes/scripts/latest_report.txt`

View historical snapshots: `ls /opt/hermes/scripts/snapshot_*.json`

## Managing Jobs

List all cron jobs: `cronjob action='list'`
Pause a job: `cronjob action='pause' job_id='...'`
Resume a job: `cronjob action='resume' job_id='...'`
Remove a job: `cronjob action='remove' job_id='...'`
Run immediately: `cronjob action='run' job_id='...'`

## Production Server Monitoring (168.119.156.43)

Separate set of cron jobs monitors the remote production server via SSH.

### Remote Setup

The monitoring script is installed at `/opt/hermes/scripts/server_resource_monitor.py` on the production server. SSH key-based authentication is configured using:

- **Local key:** `/opt/data/.ssh/hermes_monitor_key`
- **Remote user:** root
- **SSH options:** `-i /opt/data/.ssh/hermes_monitor_key -o StrictHostKeyChecking=no`

### Cron Jobs (on Hermes Host)

| Job Name | Schedule | Platform |
|-----------|----------|----------|
| `prod-server-resource-daily` | 0 9 * * * | Telegram |
| `prod-server-resource-daily-discord` | 0 9 * * * | Discord |
| `prod-server-resource-weekly` | 0 23 * * 0 | Telegram |
| `prod-server-resource-weekly-discord` | 0 23 * * 0 | Discord |
| `prod-server-resource-alerts` | */30 * * * * | Telegram (alert-only) |
| `prod-server-resource-alerts-discord` | */30 * * * * | Discord (alert-only) |

These jobs run **on the Hermes host** and SSH into the production server to collect metrics.

### Verification

Test connectivity:
```bash
ssh -i /opt/data/.ssh/hermes_monitor_key root@168.119.156.43 'python3 /opt/hermes/scripts/server_resource_monitor.py'
```

Manual test of monitoring job:
```bash
cronjob action='run' job_id='e79b1ab96f1e'  # prod daily Telegram
```

### Thresholds

Same thresholds apply on the production server:
- CPU >80% (per-core normalized)
- Memory >85%
- Disk >90%
- Swap >80%
