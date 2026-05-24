#!/usr/bin/env python3
"""
Hermes Daemon Health Check — reusable diagnostic for any self-daemonizing Hermes script.

Checks:
  1. Single instance running (no orphans/duplicates)
  2. State file freshness and parseability
  3. Vault output existence (last N files)
  4. Log recency
  5. Platform-specific failure counters (if script tracks them)

Usage:
  python3 healthcheck-hermes-daemon.py \
    --script "x_link_poller_v2.py" \
    --state ~/.hermes/state/x_link_poller_state.json \
    --vault /opt/data/obsidian-vault/FACorreia/Raw \
    --log /tmp/x_poller_v2.log \
    [--min-age-minutes 5]

Exit codes:
  0 = healthy
  1 = multiple instances found
  2 = state stale or corrupt
  3 = vault output missing
  4 = log stale
"""

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def sh(cmd: str) -> str:
    return subprocess.check_output(cmd, shell=True, text=True).strip()


def check_single_instance(script_name: str) -> tuple[bool, str]:
    """Ensure exactly one instance of the script is running."""
    try:
        result = subprocess.run(
            ['ps', '-eo', 'pid,stat,cmd'],
            capture_output=True, text=True, check=True
        )
        lines = [l for l in result.stdout.split('\n') if script_name in l and 'grep' not in l]
        if len(lines) == 0:
            return False, f"No running instance found"
        if len(lines) > 1:
            details = '\n'.join(lines)
            return False, f"Multiple instances ({len(lines)}):\n{details}"
        return True, "Single instance OK"
    except Exception as e:
        return False, f"Process check failed: {e}"


def check_state_freshness(state_path: Path, max_age_minutes: int = 10) -> tuple[bool, str]:
    """Verify state file exists, is valid JSON, and has recent activity."""
    if not state_path.exists():
        return False, f"State file missing: {state_path}"
    try:
        state = json.loads(state_path.read_text())
    except json.JSONDecodeError as e:
        return False, f"State JSON corrupt: {e}"

    processed_urls = state.get('processed_urls', {})
    if not processed_urls:
        return True, "State empty (first run or reset) — OK"

    # Find most recent saved_at timestamp
    recent = None
    for info in processed_urls.values():
        ts = info.get('saved_at')
        if ts:
            dt = datetime.fromisoformat(ts)
            if recent is None or dt > recent:
                recent = dt

    if recent is None:
        return True, "No saved_at timestamps in state"

    age = (datetime.now(timezone.utc) - recent).total_seconds() / 60
    if age > max_age_minutes:
        return False, f"State stale: last activity {age:.0f}min ago (threshold {max_age_minutes}min)"
    return True, f"State fresh (last activity {age:.0f}min ago)"


def check_vault_output(vault_path: Path, min_files: int = 1, max_age_minutes: int = 60) -> tuple[bool, str]:
    """Verify vault has recent output files."""
    if not vault_path.exists():
        return False, f"Vault path missing: {vault_path}"

    md_files = list(vault_path.rglob("*.md"))
    if len(md_files) < min_files:
        return False, f"Vault has only {len(md_files)} files (need ≥{min_files})"

    newest = max(f.stat().st_mtime for f in md_files)
    age = (datetime.now().timestamp() - newest) / 60
    if age > max_age_minutes:
        return False, f"Vault files stale: newest is {age:.0f}min old (threshold {max_age_minutes}min)"
    return True, f"Vault healthy: {len(md_files)} files, newest {age:.0f}min old"


def check_log_recency(log_path: Path, max_age_minutes: int = 15) -> tuple[bool, str]:
    """Verify log file exists and has recent entries."""
    if not log_path.exists():
        return False, f"Log file missing: {log_path}"

    mtime = log_path.stat().st_mtime
    age = (datetime.now().timestamp() - mtime) / 60
    if age > max_age_minutes:
        return False, f"Log stale: {age:.0f}min since last write (threshold {max_age_minutes}min)"

    # Check for "Sleeping" message in last lines (heartbeat)
    try:
        lines = log_path.read_text().split('\n')
        for line in reversed([l for l in lines if l.strip()]):
            if 'Sleeping' in line:
                return True, f"Log shows heartbeat: {line.strip()[:80]}"
        return True, f"Log fresh but no 'Sleeping' line found (might be first cycle)"
    except Exception as e:
        return True, f"Log readable but scan failed: {e}"


def check_state_vault_consistency(state_path: Path, vault_path: Path, threshold_pct: float = 80.0) -> tuple[bool, str]:
    """
    Cross-check that most URLs in state exist as files in vault.
    Threshold allows for in-flight or legitimately missing articles (< threshold%).
    Returns:
      (OK, details) if match rate ≥ threshold_pct
      (False, reason) otherwise
    """
    if not state_path.exists() or not vault_path.exists():
        return False, "Cannot check consistency — state or vault missing"

    try:
        state = json.loads(state_path.read_text())
    except:
        return False, "State unreadable (JSON error)"

    urls = state.get('processed_urls', {})
    if not urls:
        return True, "No URLs in state to cross-check"

    # Extract tweet IDs from vault filenames
    vault_ids = set()
    for f in vault_path.rglob("*.md"):
        # Filenames like: "2026-05-02 — X - Edward Sanchez - 20499071.md"
        m = re.search(r'(\d{10,})\.md$', f.name)
        if m:
            vault_ids.add(m.group(1))

    matched = 0
    missing_tids = []
    for uid, info in urls.items():
        url = info['url']
        m = re.search(r'status[/:](\d+)', url)
        if not m:
            continue
        tid = m.group(1)
        if tid in vault_ids:
            matched += 1
        else:
            missing_tids.append(tid)

    total_with_tid = len([u for u in urls.values() if re.search(r'status[/:](\d+)', u['url'])])
    if total_with_tid == 0:
        return True, "No tweet URLs in state to cross-check"

    pct = (matched / total_with_tid) * 100
    if pct >= threshold_pct:
        return True, f"State-vault consistency {pct:.0f}% ({matched}/{total_with_tid} matched)"
    else:
        return False, (f"State-vault consistency LOW: {pct:.0f}% ({matched}/{total_with_tid} matched). "
                       f"Missing tweet IDs: {missing_tids[:5]}{'...' if len(missing_tids)>5 else ''}")


def main():
    parser = argparse.ArgumentParser(description="Hermes Daemon Health Check")
    parser.add_argument('--script', required=True, help='Script name (e.g. x_link_poller_v2.py)')
    parser.add_argument('--state', type=Path, required=True, help='Path to state JSON file')
    parser.add_argument('--vault', type=Path, required=True, help='Path to vault Raw/ directory')
    parser.add_argument('--log', type=Path, required=True, help='Path to daemon log file')
    parser.add_argument('--min-files', type=int, default=1, help='Minimum files expected in vault')
    parser.add_argument('--max-age', type=int, default=15, help='Max age in minutes for log/state freshness')
    parser.add_argument('--consistency-threshold', type=float, default=80.0,
                       help='Minimum %% state-vault match rate (default 80%%)')
    args = parser.parse_args()

    all_ok = True

    # 1. Single instance
    ok, msg = check_single_instance(args.script)
    print(f"[INSTANCE] {msg}")
    if not ok:
        all_ok = False

    # 2. State freshness
    ok, msg = check_state_freshness(args.state, max_age_minutes=args.max_age)
    print(f"[STATE] {msg}")
    if not ok:
        all_ok = False

    # 3. Vault output
    ok, msg = check_vault_output(args.vault, min_files=args.min_files, max_age_minutes=args.max_age*4)
    print(f"[VAULT] {msg}")
    if not ok:
        all_ok = False

    # 4. Log recency
    ok, msg = check_log_recency(args.log, max_age_minutes=args.max_age)
    print(f"[LOG] {msg}")
    if not ok:
        all_ok = False

    # 5. State-vault consistency
    ok, msg = check_state_vault_consistency(args.state, args.vault, args.consistency_threshold)
    print(f"[CONSISTENCY] {msg}")
    if not ok:
        all_ok = False

    print()
    if all_ok:
        print("✓ All health checks passed")
        sys.exit(0)
    else:
        print("✗ One or more health checks failed — review output above")
        sys.exit(1)


if __name__ == '__main__':
    main()
