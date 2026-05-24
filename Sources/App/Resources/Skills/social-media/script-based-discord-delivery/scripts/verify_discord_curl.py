#!/usr/bin/env python3
"""
verify_discord_curl.py - Test Discord API access using curl.
"""
import subprocess
import json
import os
import sys

def test_discord_curl():
    token = os.environ.get('DISCORD_BOT_TOKEN')
    if not token:
        print("ERROR: DISCORD_BOT_TOKEN not set", file=sys.stderr)
        sys.exit(1)
    
    channel_id = "1499338003334561843"  # Stock channel
    test_content = "Test message"
    
    cmd = [
        'curl', '-X', 'POST',
        f'https://discord.com/api/v10/channels/{channel_id}/messages',
        '-H', f'Authorization: Bot {token}',
        '-H', 'Content-Type: application/json',
        '--data', json.dumps({'content': test_content})
    ]
    
    result = subprocess.run(cmd, capture_output=True, text=True)
    
    if result.returncode == 0 and 'message' not in result.stdout:
        print("✓ Discord access verified via curl")
        return 0
    else:
        print(f"✗ Discord access failed: {result.stderr}", file=sys.stderr)
        return 1

if __name__ == "__main__":
    sys.exit(test_discord_curl())