#!/usr/bin/env python3
"""
Hermes Stock Alert System Health Check

Verifies that both alert pathways are correctly configured:
1. Standalone wrapper path: /opt/data/scripts/stock_threshold_alert.py → ~/.hermes/scripts/stock_threshold_alert.py
2. KG script present: /opt/data/scripts/portfolio_threshold_alerts.py
3. Cron jobs mapped correctly
4. Environment variables present for self-delivering KG script

Exit codes:
  0 = all green
  1 = warning (some non-critical issues)
  2 = error (critical misconfiguration)
"""

import os
import sys
import json
import subprocess
from pathlib import Path
from datetime import datetime, timezone

# ─── Color helpers ────────────────────────────────────────────────────────────
GREEN = "\033[92m"
YELLOW = "\033[93m"
RED = "\033[91m"
RESET = "\033[0m"

def info(msg):
    print(f"ℹ️  {msg}")

def ok(msg):
    print(f"{GREEN}✓ {msg}{RESET}")

def warn(msg):
    print(f"{YELLOW}⚠️  {msg}{RESET}")

def error(msg):
    print(f"{RED}✗ {msg}{RESET}")

# ─── Checks ───────────────────────────────────────────────────────────────────

errors = 0
warnings = 0

print("=" * 60)
print("Hermes Stock Alert System Health Check")
print(f"Run at: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}")
print("=" * 60)

# 1. Standalone script existence and symlink
standalone_src = Path.home() / ".hermes" / "scripts" / "stock_threshold_alert.py"
wrapper_link = Path("/opt/data/scripts/stock_threshold_alert.py")

print("\n[1] Standalone script & symlink")
if not standalone_src.exists():
    error(f"Missing source: {standalone_src}")
    errors += 1
else:
    ok(f"Source exists: {standalone_src} ({standalone_src.stat().st_size} bytes)")

if not wrapper_link.exists():
    error(f"Wrapper symlink missing: {wrapper_link}")
    errors += 1
else:
    if wrapper_link.is_symlink():
        target = wrapper_link.readlink()
        ok(f"Symlink correct: {wrapper_link} → {target}")
        # Check if points to standalone (not KG)
        if "stock_threshold_alert.py" not in str(target):
            warn(f"Symlink points to unexpected target: {target}")
            warnings += 1
    else:
        warn(f"Wrapper path exists but is a regular file (should be symlink)")
        warnings += 1

# 2. KG script existence
kg_script = Path("/opt/data/scripts/portfolio_threshold_alerts.py")
print("\n[2] KG script presence")
if kg_script.exists():
    ok(f"KG script exists: {kg_script} ({kg_script.stat().st_size} bytes)")
else:
    warn(f"KG script not found: {kg_script}")
    warnings += 1

# 3. Cron jobs configuration
cron_jobs_file = Path("/opt/data/cron/jobs.json")
print("\n[3] Cron job mapping")
if cron_jobs_file.exists():
    with open(cron_jobs_file) as f:
        data = json.load(f)
    jobs = data.get("jobs", [])
    
    # Find relevant jobs
    orchestrator = None
    kg_jobs = []
    legacy_disabled = []
    
    for job in jobs:
        jid = job.get("id", "")
        name = (job.get("name") or "").lower()
        enabled = job.get("enabled", True)
        paused = job.get("paused")
        
        if "stock-alert-triple" in name or "stock alert — triple" in name:
            orchestrator = (jid, name, enabled, paused)
        elif "portfolio-threshold" in name:
            kg_jobs.append((jid, name, job.get("schedule", {}), enabled, paused))
        elif "stock alert" in name and "hourly" in name:
            legacy_disabled.append((jid, name, enabled, paused))
    
    if orchestrator:
        jid, name, enabled, paused = orchestrator
        if enabled and not paused:
            ok(f"Orchestrator active: {name} [{jid}]")
        else:
            warn(f"Orchestrator disabled/paused: {name} [{jid}]")
    else:
        warn("Orchestrator job not found")
        warnings += 1
    
    if kg_jobs:
        for jid, name, sched, enabled, paused in kg_jobs:
            status = "active" if enabled and not paused else "disabled"
            print(f"  KG job: {name} [{jid}] — {status}, schedule: {sched.get('expr','?')}")
    else:
        warn("No KG threshold jobs found")
        warnings += 1
    
    if legacy_disabled:
        for jid, name, enabled, paused in legacy_disabled:
            if not enabled or paused:
                ok(f"Legacy job correctly disabled: {name} [{jid}]")
            else:
                error(f"Legacy job still ENABLED: {name} [{jid}] — should disable")
                errors += 1
else:
    error(f"Cron jobs file missing: {cron_jobs_file}")
    errors += 1

# 4. Environment presence (warn if missing, but not error — cron provides these)
print("\n[4] Environment variables (for KG script)")
env_vars = {
    "DISCORD_BOT_TOKEN": "Discord bot token",
    "DISCORD_ALERT_CHANNEL_ID": "Discord alerts channel ID",
    "TELEGRAM_BOT_TOKEN": "Telegram bot token",
    "TELEGRAM_HOME_CHANNEL": "Telegram chat ID",
}

env_path = Path("/opt/data/.env")
if env_path.exists():
    with open(env_path) as f:
        env_content = f.read()
    for var, desc in env_vars.items():
        if var in env_content:
            ok(f"{var} present in {env_path}")
        else:
            warn(f"{var} not found in {env_path} (KG script will skip that platform)")
else:
    warn(f"No /opt/data/.env file — KG script relies on cron environment")

# 5. Wrapper executable permissions
print("\n[5] Wrapper permissions")
hermes_wrappers = [
    Path.home() / ".hermes" / "scripts" / "stock_alert_discord.sh",
    Path.home() / ".hermes" / "scripts" / "stock_alert_telegram.py",
    Path.home() / ".hermes" / "scripts" / "stock_alert_slack.py",
]
for wrapper in hermes_wrappers:
    if wrapper.exists():
        executable = os.access(wrapper, os.X_OK)
        if executable:
            ok(f"Executable: {wrapper}")
        else:
            error(f"Not executable: {wrapper}")
            errors += 1
    else:
        warn(f"Wrapper not found: {wrapper}")

# 6. Recent execution test (standalone)
print("\n[6] Standalone script test run")
try:
    result = subprocess.run(
        [str(standalone_src)],
        capture_output=True, text=True, timeout=15,
        cwd=str(standalone_src.parent)
    )
    if result.returncode == 0:
        output_lines = result.stdout.strip().split('\n')
        if output_lines and output_lines[0].startswith('🚨'):
            ok("Script runs and produces alert format")
        else:
            warn("Script ran but output format unexpected (maybe no alerts today)")
    else:
        error(f"Script exited {result.returncode}")
        if result.stderr:
            print(f"  stderr: {result.stderr[:200]}")
        errors += 1
except Exception as e:
    error(f"Failed to execute standalone script: {e}")
    errors += 1

# Summary
print("\n" + "=" * 60)
if errors:
    error(f"FAILED — {errors} critical issue(s) found")
    sys.exit(2)
elif warnings:
    warn(f"PASSED with {warnings} warning(s) — review recommended")
    sys.exit(1)
else:
    ok("ALL GREEN — stock alert system healthy")
    sys.exit(0)
