#!/usr/bin/env python3
"""
Hermes Daemon Health Check — Generic poller validator
Works for x_link_poller_v2.py and similar self-daemonizing Hermes scripts.
"""

import os
import sys
import json
import subprocess
from pathlib import Path
from datetime import datetime, timezone

# ── Configuration ─────────────────────────────────────────────────────────────
STATE_FILE = Path.home() / ".hermes" / "state" / "x_link_poller_state.json"
VAULT_RAW = Path("/opt/data/obsidian-vault/FACorreia/raw")
LOG_DIR = Path("/opt/data/home/.hermes/logs")
SCRIPT_NAME = "x_link_poller_v2.py"

# ── Helpers ────────────────────────────────────────────────────────────────────
def run_cmd(cmd: str) -> str:
    return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout.strip()

def check_single_instance() -> tuple[bool, str]:
    """Return (ok, message). Expect exactly one Python process running the script."""
    output = run_cmd(f"pgrep -fa '{SCRIPT_NAME}' | grep -v grep")
    lines = [l for l in output.splitlines() if l.strip()]
    if len(lines) == 0:
        return False, "No running instance found"
    if len(lines) > 1:
        return False, f"Multiple instances: {len(lines)} PIDs — {[l.split()[0] for l in lines]}"
    return True, f"Single instance PID {lines[0].split()[0]}"

def check_state_freshness(max_age_minutes: int = 10) -> tuple[bool, str]:
    """State file should have been updated within the poll cycle."""
    if not STATE_FILE.exists():
        return False, "State file missing"
    mtime = STATE_FILE.stat().st_mtime
    age = (datetime.now().astimezone().timestamp() - mtime) / 60
    if age > max_age_minutes:
        return False, f"State file {age:.1f}min old (threshold {max_age_minutes}min)"
    return True, f"State updated {age:.1f}min ago"

def check_vault_output(max_age_hours: int = 2) -> tuple[bool, str]:
    """At least one X-sourced article should exist within threshold."""
    if not VAULT_RAW.exists():
        return False, "Vault Raw/ directory not found"
    newest = None
    for md in VAULT_RAW.rglob("*.md"):
        if newest is None or md.stat().st_mtime > newest.stat().st_mtime:
            newest = md
    if newest is None:
        return False, "No articles found in vault"
    age_h = (datetime.now().astimezone().timestamp() - newest.stat().st_mtime) / 3600
    if age_h > max_age_hours:
        return False, f"Newest article {age_h:.1f}h old (threshold {max_age_hours}h)"
    return True, f"Recent article: {newest.name} ({age_h:.1f}h ago)"

def check_log_recency(max_age_minutes: int = 10) -> tuple[bool, str]:
    """Today's log file should have recent entries."""
    today = datetime.now().strftime("%Y%m%d")
    log_file = LOG_DIR / f"{SCRIPT_NAME.replace('.py','')}_{today}.log"
    if not log_file.exists():
        # Fallback: check /tmp if not in logs dir
        log_file = Path(f"/tmp/{SCRIPT_NAME.replace('.py','')}.log")
        if not log_file.exists():
            return False, "No log file found"
    mtime = log_file.stat().st_mtime
    age = (datetime.now().astimezone().timestamp() - mtime) / 60
    if age > max_age_minutes:
        return False, f"Log file {age:.1f}min old"
    # Check for recent successful cycle marker
    content = log_file.read_text()
    if "Poll done" in content:
        return True, f"Log active (last cycle marker present, age {age:.1f}min)"
    return True, f"Log present (age {age:.1f}min, no 'Poll done' line)"

def check_state_vault_consistency() -> tuple[bool, str]:
    """Cross-check state processed_urls against actual files on disk."""
    if not STATE_FILE.exists():
        return False, "State missing — cannot check"
    try:
        state = json.loads(STATE_FILE.read_text())
    except Exception as e:
        return False, f"State parse error: {e}"
    processed = state.get("processed_urls", {})
    if not processed:
        return True, "No processed URLs in state (poller may not have fetched yet)"
    import re
    missing = []
    for uid, info in processed.items():
        url = info.get("url", "")
        # Extract tweet/X status ID
        m = re.search(r'status[/:](\d+)', url)
        if not m:
            continue
        tid = m.group(1)
        if not any(tid in f.name for f in VAULT_RAW.rglob("*.md")):
            missing.append(url)
    if missing:
        return False, f"{len(missing)} of {len(processed)} state entries missing from vault"
    return True, f"All {len(processed)} state entries present in vault"

# ── Main ───────────────────────────────────────────────────────────────────────
def main():
    print("=" * 60)
    print("Hermes Daemon Health Check — x_link_poller_v2")
    print(f"Started: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 60)

    checks = [
        ("Single instance running", check_single_instance),
        ("State file freshness", check_state_freshness),
        ("Vault has recent output", check_vault_output),
        ("Log file recency", check_log_recency),
        ("State-vault consistency", check_state_vault_consistency),
    ]

    all_ok = True
    for name, fn in checks:
        ok, msg = fn()
        status = "✓" if ok else "✗"
        print(f"\n{status} {name}")
        print(f"  {msg}")
        if not ok:
            all_ok = False

    print("\n" + "=" * 60)
    if all_ok:
        print("✓ All checks passed — poller appears healthy")
        sys.exit(0)
    else:
        print("✗ One or more checks failed — review above")
        sys.exit(1)

if __name__ == "__main__":
    main()
