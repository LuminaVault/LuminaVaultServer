#!/usr/bin/env python3
"""Verification script: test bot access to configured Discord channels.

Requires DISCORD_BOT_TOKEN environment variable.
Sends a short test message to each channel ID listed in CHANNEL_IDS.
Prints success/failure per channel. Exits 0 if all succeed, 1 otherwise.
"""

import os
import sys
import json
import urllib.request
import urllib.error

TOKEN = os.environ.get("DISCORD_BOT_TOKEN")
if not TOKEN:
    print("ERROR: DISCORD_BOT_TOKEN not set", file=sys.stderr)
    sys.exit(1)

# Channel IDs to validate — update via references/channel-id-mapping.md
CHANNEL_IDS = [
    "1499331939469889656",  # cinema / daily digest
    "1499338003334561843",  # hermes (stock alerts/news)
    "1498811072155484330",  # alerts (server monitoring)
    "1498988528745451671",  # guild A (origin)
    "1498988480938643527",  # guild B
    "1498025894751768776",  # guild C
]

API_URL = "https://discord.com/api/v10"

def send_test(channel_id):
    url = f"{API_URL}/channels/{channel_id}/messages"
    payload = {"content": "✅ Hermes bot access verified"}
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Authorization": f"Bot {TOKEN}",
            "Content-Type": "application/json",
            "User-Agent": "HermesBot/1.0",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            body = resp.read().decode()
            result = json.loads(body)
            return True, result.get("id")
    except urllib.error.HTTPError as e:
        err_body = e.read().decode()
        try:
            err_json = json.loads(err_body)
            msg = err_json.get("message", str(e))
        except Exception:
            msg = str(e)
        return False, f"HTTP {e.code}: {msg}"
    except Exception as ex:
        return False, str(ex)

def main():
    print("Discord bot channel verification")
    print(f"Token: {TOKEN[:10]}... (length {len(TOKEN)})")
    print(f"Testing {len(CHANNEL_IDS)} channels\n")
    all_ok = True
    for cid in CHANNEL_IDS:
        ok, info = send_test(cid)
        status = "✅ OK (msg_id: {})".format(info) if ok else f"❌ FAIL: {info}"
        print(f"Channel {cid}: {status}")
        if not ok:
            all_ok = False
    print()
    if all_ok:
        print("All channels accessible.")
        sys.exit(0)
    else:
        print("Some channels failed. Review permissions (see references/discord-permission-troubleshooting.md).")
        sys.exit(1)

if __name__ == "__main__":
    main()
