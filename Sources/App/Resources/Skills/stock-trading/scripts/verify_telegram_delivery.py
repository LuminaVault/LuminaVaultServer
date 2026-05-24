#!/usr/bin/env python3
"""
Test harness for Telegram delivery wrapper functionality.
Verifies that Telegram credentials are loaded and the wrapper can send a test message.

Usage:
  python test_telegram_delivery.py

Exit codes:
  0 — Success (credentials found, test message sent or wrapper reports OK)
  1 — Missing Telegram credentials
  2 — Wrapper execution failed
"""

import subprocess
import sys
import os

def main():
    # Check that Telegram credentials exist in environment
    bot_token = os.environ.get('TELEGRAM_BOT_TOKEN')
    home_channel = os.environ.get('TELEGRAM_HOME_CHANNEL') or os.environ.get('TELEGRAM_ALLOWED_USERS', '').split(',')[0]

    if not bot_token or not home_channel:
        print("ERROR: Missing Telegram credentials.", file=sys.stderr)
        print("  Set TELEGRAM_BOT_TOKEN and TELEGRAM_HOME_CHANNEL (or TELEGRAM_ALLOWED_USERS) in environment.", file=sys.stderr)
        sys.exit(1)

    # Locate wrapper script
    wrapper = '/opt/data/home/.hermes/scripts/stock_alert_telegram.py'

    # Create a minimal test script inline
    test_script = '/tmp/test_telegram_message.py'
    with open(test_script, 'w') as f:
        f.write('#!/usr/bin/env python3\nprint("🧪 Telegram delivery test — wrapper is working!")\n')

    # Run wrapper
    result = subprocess.run(
        [sys.executable, wrapper, test_script],
        capture_output=True, text=True,
        cwd='/opt/data/home/.hermes/scripts',
        env=os.environ.copy()
    )

    if result.returncode == 0:
        print("✓ Telegram delivery test succeeded")
        if result.stdout:
            print(f"  Wrapper stdout: {result.stdout.strip()}")
    else:
        print(f"✗ Wrapper test failed (exit {result.returncode})", file=sys.stderr)
        if result.stderr:
            print(f"  stderr: {result.stderr.strip()}", file=sys.stderr)
        sys.exit(2)

if __name__ == '__main__':
    main()
