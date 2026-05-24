#!/usr/bin/env python3
"""
Hermes StockPlan Promotion Daemon — manages hourly tweet publisher.

Usage:
  python stockplan_promotion_daemon.py start   → start background loop (publishes hourly)
  python stockplan_promotion_daemon.py stop    → stop running daemon
  python stockplan_promotion_daemon.py status  → check if running
  python stockplan_promotion_daemon.py runonce → publish single tweet now (for cron)

Daemon stores PID in /tmp/stockplan_promo.pid and logs to /tmp/stockplan_promo.log.
Hourly schedule: publishes at HH:00 UTC exactly.
"""

import os
import sys
import json
import time
import signal
import subprocess
import datetime
from pathlib import Path

PID_FILE = Path("/tmp/stockplan_promo.pid")
LOG_FILE = Path("/tmp/stockplan_promo.log")
SCRIPT_PATH = Path("/opt/data/home/.hermes/scripts/stockplan_promotion.py")

def log(msg: str) -> None:
    ts = datetime.datetime.utcnow().isoformat()
    line = f"[{ts}] {msg}\n"
    with LOG_FILE.open("a") as f:
        f.write(line)
    print(line, end="")

def is_running() -> bool:
    if PID_FILE.exists():
        pid = int(PID_FILE.read_text().strip())
        try:
            os.kill(pid, 0)  # Check if process exists
            return True
        except OSError:
            PID_FILE.unlink(missing_ok=True)
    return False

def start() -> int:
    if is_running():
        print("Daemon already running (PID in /tmp/stockplan_promo.pid)")
        return 0

    log("Starting stockplan_promotion daemon…")
    pid = os.fork()
    if pid > 0:
        # Parent
        PID_FILE.write_text(str(pid))
        print(f"Daemon started (PID {pid})")
        return 0

    # Child — become session leader, detach
    os.setsid()
    signal.signal(signal.SIGHUP, signal.SIG_IGN)

    # Main loop
    log("Daemon entered hourly publishing loop")
    while True:
        try:
            # Calculate seconds until next HH:00 UTC
            now = datetime.datetime.utcnow()
            next_hour = (now.replace(minute=0, second=0, microsecond=0) + datetime.timedelta(hours=1))
            sleep_seconds = (next_hour - now).total_seconds()
            log(f"Next publish at {next_hour.isoformat()}Z (sleep {sleep_seconds:.0f}s)")
            time.sleep(sleep_seconds)

            # Run the promotion script once
            log("Running stockplan_promotion.py…")
            result = subprocess.run(
                [sys.executable, str(SCRIPT_PATH)],
                capture_output=True, text=True, timeout=30
            )
            log(f"Script exit: {result.returncode}")
            if result.stdout:
                log("STDOUT:\n" + result.stdout[-500:])
            if result.stderr:
                log("STDERR:\n" + result.stderr[-500:])
        except Exception as e:
            log(f"Loop error: {e}")
            time.sleep(60)

def stop() -> int:
    if not is_running():
        print("Daemon not running")
        return 0
    pid = int(PID_FILE.read_text())
    log(f"Stopping daemon (PID {pid})…")
    try:
        os.kill(pid, signal.SIGTERM)
        time.sleep(2)
        if is_running():
            os.kill(pid, signal.SIGKILL)
        PID_FILE.unlink(missing_ok=True)
        print("✓ Daemon stopped")
        return 0
    except Exception as e:
        print(f"Error stopping daemon: {e}")
        return 1

def status() -> int:
    if is_running():
        pid = int(PID_FILE.read_text())
        print(f"✓ Daemon running (PID {pid})")
        return 0
    else:
        print("✗ Daemon not running")
        return 1

def runonce() -> int:
    """Single run — used by cron if daemon isn't preferred."""
    print("Running one-off publish…")
    result = subprocess.run([sys.executable, str(SCRIPT_PATH)], capture_output=True, text=True)
    print(result.stdout)
    if result.stderr:
        print(result.stderr, file=sys.stderr)
    return result.returncode

# ── Entry ───────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: stockplan_promotion_daemon.py {start|stop|status|runonce}")
        sys.exit(1)

    cmd = sys.argv[1].lower()
    if cmd == "start":
        sys.exit(start())
    elif cmd == "stop":
        sys.exit(stop())
    elif cmd == "status":
        sys.exit(status())
    elif cmd == "runonce":
        sys.exit(runonce())
    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)
