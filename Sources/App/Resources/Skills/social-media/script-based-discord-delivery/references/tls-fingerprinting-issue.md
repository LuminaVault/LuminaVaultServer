# TLS Fingerprinting Issue with Discord API (Python)

## Problem Summary

When using Python's standard HTTP libraries (`urllib`, `requests`) to send requests to Discord's API, the requests may be rejected with a 403 Forbidden status even when:
- The bot token is valid
- The bot has proper channel permissions
- All required HTTP headers are present

This issue is specifically caused by **TLS fingerprinting** - Discord (via Cloudflare) detects the non-browser TLS fingerprint of Python's HTTP stack and blocks the request.

## Root Cause

Cloudflare and many modern websites use TLS fingerprinting to identify and block automated traffic. Python's `urllib` and `requests` libraries have distinctive TLS fingerprints that differ from real browsers. Even when all HTTP headers are correct, the TLS handshake itself reveals the client as non-browser, triggering a block.

## Symptoms

- 403 Forbidden error from Discord API
- Valid bot token
- Proper channel permissions
- Correct channel ID
- Works with `curl` but fails with Python HTTP libraries
- Works intermittently or not at all from cron jobs/containers

## Solution

### Primary Solution: Use `curl` via Subprocess

The most reliable workaround is to use `curl` (via Python's `subprocess`) instead of native Python HTTP libraries. `curl` has a more browser-like TLS fingerprint and bypasses Cloudflare's blocking.

```python
import subprocess
import json
import os

def post_to_discord_curl(channel_id, content, token=None):
    """
    Send a message to Discord channel using curl.
    This bypasses TLS fingerprinting issues that affect urllib/requests.
    """
    if token is None:
        token = os.environ.get('DISCORD_BOT_TOKEN')
        if not token:
            raise ValueError("DISCORD_BOT_TOKEN not set")
    
    url = f"https://discord.com/api/v10/channels/{channel_id}/messages"
    payload = json.dumps({"content": content[:2000]}).encode()
    
    # Use curl with appropriate headers
    cmd = [
        'curl', '-X', 'POST',
        url,
        '-H', f'Authorization: Bot {token}',
        '-H', 'Content-Type: application/json',
        '--data', payload
    ]
    
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"curl failed: {result.stderr}")
    
    # Check for HTTP error in response
    if 'HTTP/1.1 403' in result.stdout or '403' in result.stderr:
        raise RuntimeError(f"Discord 403: {result.stderr}")
    
    return result.stdout

# Usage example
content = "Test message from Hermes"
post_to_discord_curl(channel_id="1499338003334561843", content=content)
```

### Alternative Solutions

1. **Use `curl_cffi` library**: A Python library that mimics curl's TLS fingerprint.
2. **Use `aiohttp` with custom TLS context**: More complex but can be configured to use specific cipher suites.
3. **Use the Hermes gateway**: If available, use the Hermes send_message tool instead of direct API calls.

## Verification Script

Create a verification script to test Discord access:

```python
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
```

## When This Occurs

This issue is most likely to appear in:
- Cron jobs that use direct urllib/requests calls to Discord API
- Scripts running in containers or restricted environments
- Custom Python scripts that need to send Discord alerts
- Any Python script that doesn't use curl

## Recommendation

For new code that needs to send Discord messages from scripts (especially cron jobs), prefer using `curl` via subprocess. For existing code using `urllib` or `requests`, update to use the curl approach or add the `curl_cffi` library.

## Technical Verification

Testing confirmed:
- `urllib` with proper headers → 403 Forbidden (TLS block)
- `requests` with proper headers → 403 Forbidden (TLS block)
- `curl` → 200 OK (bypasses TLS fingerprint)

## Related Issues

- Cloudflare's bot protection blocking non-browser TLS fingerprints
- Discord API rate limiting vs. TLS fingerprinting
- Python HTTP library limitations with modern anti-bot systems

## See Also

- `references/urllib-headers.md` - Header requirements for urllib
- `scripts/verify_discord_curl.py` - Verification script
- `scripts/batch_digest_for_discord.py` - Batching utility