---
name: script-based-discord-delivery
category: social-media
description: Deliver content to Discord via Python script fallback when send_message tool unavailable. Handles credential resolution from gateway/runtime environment.
triggers:
  - discord delivery fallback
  - direct discord api post
  - send_message tool missing
  - bot token available
  - cron job needs discord
---

## Purpose
When the standard Hermes Discord tools (send_message, gateway) are unavailable or misconfigured, this skill provides a direct Python API fallback to post content to Discord channels using the bot token. Useful for cron jobs and standalone scripts that need reliable Discord delivery without depending on the Hermes gateway.

**Important Note for Hermes Agent Environments:** In some execution contexts (e.g., when running via `execute_code`), environment variables from the parent process may not be fully accessible. When the `DISCORD_BOT_TOKEN` environment variable appears missing, check the `.env` configuration file as a reliable fallback.\n\n### ⚠️ Using urllib.request with Discord API\n\nWhen sending requests via Python's `urllib.request` (instead of the `requests` library), Discord may return 403 Forbidden responses due to missing HTTP headers. This is a common pitfall in cron jobs and standalone scripts.\n\n**Solution:** Always include the following headers when using `urllib`:\n- `Accept-Encoding: gzip, deflate`\n- `Accept: */*`\n- `Connection: keep-alive`\n\nAlternatively, consider using the `requests` library which handles these headers automatically and is generally more robust for HTTP interactions.\n\nSee `references/urllib-headers.md` for a full technical analysis and verification.

## Prerequisites
- DISCORD_BOT_TOKEN environment variable set with a valid bot token
- Bot must be a member of the target guild and have appropriate channel permissions
- Channel ID must be known (snowflake format)

## Procedure

### 1. Validate Bot Access
Before posting, verify the bot can access the channel. Use this enhanced approach that handles both environment variable access and .env file fallback:

```python
import os
import requests

# Primary: Try to get token from environment
token = os.environ.get('DISCORD_BOT_TOKEN')

# Fallback: If not available in environment, read from .env file
if not token:
    env_path = '/opt/data/.env'  # Adjust if HERMES_HOME differs
    if os.path.exists(env_path):
        with open(env_path, 'r') as f:
            lines = f.readlines()
        for line in lines:
            if 'DISCORD_BOT_TOKEN=' in line:
                parts = line.split('=', 1)
                if len(parts) > 1:
                    token = parts[1].strip()
                    if token.startswith('export '):
                        token = token[4:].strip()
                break

if not token:
    raise ValueError("DISCORD_BOT_TOKEN not found in environment or .env file")

# Test endpoint to check bot status
test_url = "https://discord.com/api/v10/users/@me"
headers = {"Authorization": f"Bot {token}"}
response = requests.get(test_url, headers=headers)
if response.status_code != 200:
    raise RuntimeError(f"Bot token invalid or expired: {response.status_code}")
```

This dual approach ensures the token can be retrieved even when the execution environment has limited access to parent process environment variables.

### 2. Post Message to Channel
Use the Discord API directly:
```python
def post_to_discord(channel_id, content, token=None):
    if token is None:
        token = os.environ.get('DISCORD_BOT_TOKEN')
        if not token:
            raise ValueError("DISCORD_BOT_TOKEN not set")
    
    url = f"https://discord.com/api/v10/channels/{channel_id}/messages"
    headers = {
        "Authorization": f"Bot {token}",
        "Content-Type": "application/json"
    }
    payload = {"content": content[:2000]}
    
    response = requests.post(url, headers=headers, json=payload)
    response.raise_for_status()
    return response.json()
```

### 3. Handle Large Content
Discord has a 2000-character limit for message content. For longer content:
- Split into multiple messages (≤1800 chars each)
- Or send as a file attachment (use multipart/form-data with `file` parameter)

### 4. Error Handling\nCommon errors and resolutions:\n- **401 Unauthorized**: Invalid or missing token, bot not in guild\n- **403 Forbidden**: Bot lacks channel permissions, role hierarchy issue. **Note:** When using Python's `urllib` library instead of `requests`, Discord may reject requests due to missing standard HTTP headers (Accept-Encoding, Accept, Connection). See the `references/urllib-headers.md` file for details.\n- **TLS Fingerprinting Block**: In some environments (especially cron jobs or containerized setups), Discord/Cloudflare may block Python HTTP requests due to TLS fingerprinting. This occurs even with valid tokens and proper headers. The request appears to originate from a non-browser client. **Solution:** Use `curl` via subprocess (see below) or a library like `curl_cffi` that mimics a real browser's TLS fingerprint. For a complete technical analysis, see `references/cloudflare-1010-error.md`.\n- **404 Not Found**: Invalid channel ID\n- **429 Too Many Requests**: Rate limited; implement exponential backoff\n
### 5. Using curl (Recommended for Cron Jobs)
For reliable delivery in cron jobs and scripts, especially when encountering TLS fingerprinting blocks, use `curl` via subprocess. This bypasses Python's TLS fingerprint and is more robust.

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

### 6. Verify Access
Use the `verify_discord_curl.py` script (in this skill's `scripts/` directory) to test Discord API access using curl.

## Example Usage
```python
# Post watchlist to stock-news channel
content = """# 📋 Will Do Watchlist — 2026-05-04 08:02 ET

| Instrument | Last | Change | % |
|------------|------|--------|----|
| FLNC | $12.19 | +0.01 | +0.08% |
| EQR | $65.17 | -0.21 | -0.32% |
| ELF | $60.49 | -3.48 | -5.44% |
| JD | $29.96 | -0.36 | -1.19% |
| SMR | $12.14 | -0.32 | -2.57% |
| UUUU | $21.66 | +0.02 | +0.09% |
| OUST | $26.45 | -0.51 | -1.89% |
| SLNH | $1.58 | -0.08 | -4.82% |
| LMND | $56.66 | +0.02 | +0.04% |
| EOSE | $6.45 | -0.25 | -3.73% |

_Data powered by Yahoo Finance_"""

# Retrieve token with fallback to .env file
token = os.environ.get('DISCORD_BOT_TOKEN')
if not token:
    env_path = '/opt/data/.env'
    if os.path.exists(env_path):
        with open(env_path, 'r') as f:
            lines = f.readlines()
        for line in lines:
            if 'DISCORD_BOT_TOKEN=' in line:
                parts = line.split('=', 1)
                if len(parts) > 1:
                    token = parts[1].strip()
                    if token.startswith('export '):
                        token = token[4:].strip()
                break

if not token:
    raise ValueError("DISCORD_BOT_TOKEN not found")

post_to_discord(channel_id="1499338003334561843", content=content, token=token)
```

This example demonstrates the complete pattern: retrieving the token with .env fallback, then posting the message.

## Related Skills
- discord-bot-operations — for gateway-based delivery and permissions management
- cron-script-deployment — for cron job script deployment and troubleshooting

## References
- Discord API documentation: https://discord.com/developers/docs
- Hermes gateway configuration: ~/.hermes/config.yaml
- Channel directory: $HERMES_HOME/channel_directory.json
- urllib-headers.md — HTTP header requirements for urllib
- cloudflare-1010-error.md — Technical analysis of Cloudflare TLS blocks