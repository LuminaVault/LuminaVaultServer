#!/usr/bin/env python3
"""
Verify that a cron job's output would be delivered correctly without
actually triggering a delivery.

Usage:
  python3 verify_cron_delivery.py /path/to/script.py [args...]

Behavior:
  1. Runs the target script
  2. Captures stdout (the digest content)
  3. Prints captured output with metadata
  4. Does NOT trigger Hermes cron delivery (safe to run anytime)

Use this to:
  - Debug stdout/stderr separation issues
  - Test digest formatting before committing to cron
  - Validate that ONLY digest appears on stdout (no debug prints)
  - Check digest length for platform limits (Discord: 2000 chars)
"""

import subprocess
import sys
from pathlib import Path

def main():
    if len(sys.argv) < 2:
        print("Usage: verify_cron_delivery.py <script> [args...]")
        sys.exit(1)
    
    script = sys.argv[1]
    script_args = sys.argv[2:]
    
    if not Path(script).exists():
        print(f"❌ Script not found: {script}")
        sys.exit(1)
    
    print(f"→ Running: {script} {' '.join(script_args)}")
    print("─" * 60)
    
    result = subprocess.run(
        [sys.executable, script] + script_args,
        capture_output=True,
        text=True,
        timeout=30
    )
    
    stdout = result.stdout
    stderr = result.stderr
    exit_code = result.returncode
    
    print(f"\nExit code: {exit_code}")
    print(f"Stdout length: {len(stdout)} chars")
    print(f"Stderr length: {len(stderr)} chars")
    
    if stderr:
        print("\n── STDERR (captured by cron framework) ──")
        print(stderr[:2000])
        if len(stderr) > 2000:
            print(f"... ({len(stderr)-2000} more chars)")
    
    print("\n── STDOUT (would be delivered) ──")
    print(stdout)
    
    # Platform limit warnings
    print("\n── Validation ──")
    if len(stdout) > 2000:
        print("⚠️  WARNING: Output exceeds Discord's 2000-char limit.")
        print("   Consider batching or truncating.")
    if len(stdout) > 1900:
        print("⚠️  Close to limit — batch splitting recommended.")
    
    if exit_code != 0:
        print("❌ Script exited non-zero — cron framework would SKIP delivery.")
        print("   Fix the error before scheduling.")
    
    # Check for common mistakes
    if stderr and "debug" in stderr.lower() or "print(" in stderr:
        print("ℹ️  Hint: Move debug prints to stderr or a log file.")
    
    return 0 if exit_code == 0 and len(stdout) <= 2000 else 1

if __name__ == "__main__":
    sys.exit(main())
