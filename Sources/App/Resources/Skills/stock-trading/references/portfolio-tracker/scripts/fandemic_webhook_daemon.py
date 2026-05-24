#!/usr/bin/env python3
"""
Start the Fandemic webhook listener (port 8081).
"""

import os, sys, subprocess, time

SCRIPT_PATH = "/opt/data/home/.hermes/scripts/fandemic_webhook_listener.py"
PID_FILE = "/tmp/fandemic_webhook.pid"
LOG_FILE = "/tmp/fandemic_webhook.log"

def start():
    if os.path.exists(PID_FILE):
        with open(PID_FILE) as f:
            pid = int(f.read().strip())
        try:
            os.kill(pid, 0)
            print(f"⚠️  Already running (PID {pid}).")
            sys.exit(1)
        except ProcessLookupError:
            pass
    env = os.environ.copy()
    env["FEMNIC_WEBHOOK_PORT"] = "8081"
    proc = subprocess.Popen(
        [sys.executable, SCRIPT_PATH],
        env=env,
        stdout=open(LOG_FILE, "a"),
        stderr=subprocess.STDOUT,
        cwd=os.path.dirname(SCRIPT_PATH)
    )
    with open(PID_FILE, "w") as f:
        f.write(str(proc.pid))
    print(f"🚀 Fandemic webhook started — PID {proc.pid}")
    print(f"   Endpoint: http://localhost:8081/webhooks/fandemic")
    print(f"   Logs: {LOG_FILE}")

def stop():
    if not os.path.exists(PID_FILE):
        print("⚠️  No PID file.")
        sys.exit(1)
    with open(PID_FILE) as f:
        pid = int(f.read().strip())
    try:
        os.kill(pid, 15)
        print(f"🛑 Sent SIGTERM to PID {pid}")
        os.remove(PID_FILE)
    except ProcessLookupError:
        print(f"❌ Process {pid} not found — cleaning PID file")
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
        print(f"🔴 Dead (stale PID)")

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
        print("Usage: famdic_webhook_daemon.py {start|stop|restart|status}")
        sys.exit(1)
