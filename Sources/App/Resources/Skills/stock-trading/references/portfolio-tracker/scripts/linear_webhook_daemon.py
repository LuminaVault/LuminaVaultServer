#!/usr/bin/env python3
"""
Start the Linear webhook listener.

Run this once to start the daemon that listens for external webhook events
and auto-creates Linear issues. Post JSON payloads to:
  POST http://localhost:8080/webhooks/linear

Required payload fields: title (str), description (str)
Optional: priority (1-4), labels (list[str]), project (str), assignee (str)
"""

import os
import sys
import subprocess
import time

SCRIPT_PATH = "/opt/data/home/.hermes/scripts/linear_webhook_listener.py"
PID_FILE = "/tmp/linear_webhook.pid"
LOG_FILE = "/tmp/linear_webhook.log"

def start():
    if os.path.exists(PID_FILE):
        with open(PID_FILE) as f:
            pid = int(f.read().strip())
        try:
            os.kill(pid, 0)
            print(f"⚠️  Already running (PID {pid}). Kill it first or use restart.")
            sys.exit(1)
        except ProcessLookupError:
            pass  # stale pid file

    env = os.environ.copy()
    env["LINEAR_WEBHOOK_PORT"] = "8080"

    proc = subprocess.Popen(
        [sys.executable, SCRIPT_PATH],
        env=env,
        stdout=open(LOG_FILE, "a"),
        stderr=subprocess.STDOUT,
        cwd=os.path.dirname(SCRIPT_PATH)
    )
    with open(PID_FILE, "w") as f:
        f.write(str(proc.pid))
    print(f"🚀 Linear webhook listener started — PID {proc.pid}")
    print(f"   Endpoint: http://localhost:8080/webhooks/linear")
    print(f"   Logs: {LOG_FILE}")

def stop():
    if not os.path.exists(PID_FILE):
        print("⚠️  No PID file — is it running?")
        sys.exit(1)
    with open(PID_FILE) as f:
        pid = int(f.read().strip())
    try:
        os.kill(pid, 15)  # SIGTERM
        print(f"🛑 Sent SIGTERM to PID {pid}")
        os.remove(PID_FILE)
    except ProcessLookupError:
        print(f"❌ Process {pid} not found — cleaning stale PID file")
        os.remove(PID_FILE)

def status():
    if not os.path.exists(PID_FILE):
        print("🔴 Stopped (no PID file)")
        sys.exit(0)
    with open(PID_FILE) as f:
        pid = int(f.read().strip())
    try:
        os.kill(pid, 0)
        print(f"🟢 Running — PID {pid}")
        print(f"   Logs: tail -f {LOG_FILE}")
    except ProcessLookupError:
        print(f"🔴 Dead (PID {pid} not found) — stale PID file")

def restart():
    stop()
    time.sleep(1)
    start()

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "start"
    if cmd == "start":
        start()
    elif cmd == "stop":
        stop()
    elif cmd == "restart":
        restart()
    elif cmd == "status":
        status()
    else:
        print("Usage: linear_webhook_daemon.py {start|stop|restart|status}")
        sys.exit(1)
