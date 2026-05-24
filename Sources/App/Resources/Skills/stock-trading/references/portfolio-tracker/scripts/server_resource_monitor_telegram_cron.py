#!/usr/bin/env python3
"""
Hermes Server Resource Monitor - Telegram Alert Version
Checks server health thresholds and alerts via Telegram if any are breached.
"""

import subprocess
import sys
import os
import json
from datetime import datetime

# Configuration
SSH_KEY = "/opt/data/.ssh/hermes_monitor_key"
SSH_USER = "root"
SSH_HOST = "49.13.165.238"
REMOTE_SCRIPT = "/opt/hermes/scripts/server_resource_monitor.py"
ALERT_BREACH_EXIT_CODE = 1

# Telegram configuration from environment
TELEGRAM_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
TELEGRAM_HOME_CHANNEL = os.environ.get("TELEGRAM_HOME_CHANNEL", "").strip()
# Legacy/alternative: TELEGRAM_HOME_CHANNEL_NAME (display-only, not used for delivery)


def run_remote_monitor():
    """Execute the remote server resource monitoring script via SSH."""
    ssh_cmd = [
        "ssh",
        "-i", SSH_KEY,
        "-o", "StrictHostKeyChecking=no",
        "-o", "BatchMode=yes",
        f"{SSH_USER}@{SSH_HOST}",
        f"python3 {REMOTE_SCRIPT}"
    ]

    try:
        result = subprocess.run(
            ssh_cmd,
            capture_output=True,
            text=True,
            timeout=120
        )
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "SSH command timed out after 120 seconds"
    except Exception as e:
        return -1, "", f"Unexpected error: {str(e)}"


def send_telegram_alert(output, exit_code, error_msg=None):
    """
    Send alert to Telegram via Bot API.
    Requires TELEGRAM_BOT_TOKEN and TELEGRAM_HOME_CHANNEL environment variables.
    """
    if not TELEGRAM_BOT_TOKEN:
        print("ERROR: TELEGRAM_BOT_TOKEN environment variable not set", file=sys.stderr)
        return False

    if not TELEGRAM_HOME_CHANNEL:
        print("ERROR: TELEGRAM_HOME_CHANNEL environment variable not set", file=sys.stderr)
        return False

    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S UTC")
    status = "🚨 THRESHOLD BREACH DETECTED" if exit_code == ALERT_BREACH_EXIT_CODE else "❓ UNKNOWN STATUS"

    # Truncate very long output for Telegram message limits (4096 char limit)
    max_telegram_length = 4000
    if len(output) > max_telegram_length:
        output = output[-max_telegram_length:]
        output = "... (truncated)\\n" + output

    message = (
        f"**Server Resource Alert: {SSH_HOST}**\n\n"
        f"🕒 Timestamp: {timestamp}\n"
        f"📊 Status: {status}\n"
        f"🔢 Exit Code: {exit_code}\n\n"
        f"--- Output ---\n"
        f"```\n{output}\n```"
    )

    # Telegram Bot API endpoint
    api_url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"

    payload = {
        "chat_id": TELEGRAM_HOME_CHANNEL,
        "text": message,
        "parse_mode": "MarkdownV2",
        "disable_web_page_preview": True
    }

    import urllib.request
    import urllib.error
    import json

    try:
        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            api_url,
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST"
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            if resp.status in (200, 201):
                resp_data = json.loads(resp.read().decode("utf-8"))
                if resp_data.get("ok"):
                    print(f"Alert sent to Telegram successfully (message_id: {resp_data.get('result', {}).get('message_id')})")
                    return True
                else:
                    print(f"Telegram API error: {resp_data.get('description')}", file=sys.stderr)
                    return False
            else:
                print(f"Telegram API returned status {resp.status}", file=sys.stderr)
                return False
    except urllib.error.HTTPError as e:
        error_body = e.read().decode("utf-8") if e.fp else str(e)
        print(f"Telegram API HTTP error {e.code}: {error_body}", file=sys.stderr)
        return False
    except Exception as e:
        print(f"Failed to send Telegram alert: {e}", file=sys.stderr)
        return False


def main():
    print(f"[{datetime.now().strftime('%H:%M:%S')}] Starting server health check for {SSH_HOST}...")

    exit_code, stdout, stderr = run_remote_monitor()

    if stderr:
        print(f"STDERR: {stderr}")

    print(f"Remote script exit code: {exit_code}")
    print(f"Output:\\n{stdout}")

    if exit_code == ALERT_BREACH_EXIT_CODE:
        print("ALERT: Resource threshold breached. Sending Telegram notification...")
        alert_sent = send_telegram_alert(stdout, exit_code)
        if not alert_sent:
            print("WARNING: Failed to send Telegram alert. Check TELEGRAM_BOT_TOKEN and TELEGRAM_HOME_CHANNEL.", file=sys.stderr)
        # Print wake gate signal to skip agent processing
        print('{"wakeAgent": false}')
        sys.exit(1)  # Propagate alert exit code
    elif exit_code == 0:
        print("OK: All resource thresholds within normal range. No alert needed.")
        # Print wake gate signal to skip agent processing
        print('{"wakeAgent": false}')
        sys.exit(0)
    else:
        print(f"WARNING: Unexpected exit code {exit_code}. SSH/connection error may have occurred.", file=sys.stderr)
        # Also alert on connection failures to make them visible
        if stderr:
            error_output = f"SSH/Monitor Error:\\n{stderr}"
            send_telegram_alert(error_output, exit_code)
        # Print wake gate signal to skip agent processing
        print('{"wakeAgent": false}')
        sys.exit(exit_code)


if __name__ == "__main__":
    main()
