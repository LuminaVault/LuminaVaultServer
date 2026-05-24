# Cloudflare 1010 Error with Python HTTP Libraries

## Problem Summary
When using Python's `urllib` or `requests` libraries to send HTTP requests to Discord's API, the requests may be rejected with HTTP 403 Forbidden and error code **1010** (Access denied). This occurs even with valid bot tokens and proper channel permissions.

## Root Cause
Cloudflare's anti-bot protection uses TLS fingerprinting to distinguish between real browsers and automated clients. Python's standard HTTP libraries (`urllib`, `requests`) present a TLS client hello fingerprint that differs from legitimate browsers, triggering an automatic block.

## Symptoms
- `urllib.request.urlopen()` returns 403 with `error code: 1010`
- `requests.post()` returns 403 with similar Cloudflare block messages
- `curl` works perfectly with the same token and channel
- The block is consistent and immediate (no retries succeed)

## Diagnostic Confirmation
To verify this specific issue (as opposed to other 403 causes):

```python
import os
import urllib.request
import json

# Load token from .env or environment
env_path = '/opt/data/.env'
if os.path.isfile(env_path):
    with open(env_path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'): 
                continue
            if '=' in line:
                k, _, v = line.partition('=')
                if k and k not in os.environ: 
                    os.environ[k] = v.strip()

token = os.environ.get('DISCORD_BOT_TOKEN')
channel = '1499338003334561843'  # Test channel

try:
    payload = json.dumps({'content': 'Test'}).encode()
    req = urllib.request.Request(
        f'https://discord.com/api/v10/channels/{channel}/messages',
        data=payload,
        headers={'Authorization': f'Bot {token}', 'Content-Type': 'application/json'}
    )
    resp = urllib.request.urlopen(req, timeout=15)
    print(f"✓ Success: {resp.status}")
except urllib.error.HTTPError as e:
    print(f"✗ HTTP Error: status={e.code}, reason={e.reason}")
    print(f"Response: {e.read().decode('utf-8')}")
except Exception as e:
    print(f"✗ Error: {type(e).__name__}: {e}")
```

If this produces `error code: 1010`, it's the TLS fingerprint block.

## Solution
**Use `curl` via subprocess** for Discord API calls. This completely bypasses the TLS fingerprint issue because curl presents a browser-like fingerprint.

```python
import subprocess
import json

def post_to_discord_curl(channel_id, content, token=None):
    if token is None:
        token = os.environ.get('DISCORD_BOT_TOKEN')
        if not token:
            raise ValueError("DISCORD_BOT_TOKEN not set")
    
    url = f"https://discord.com/api/v10/channels/{channel_id}/messages"
    payload = json.dumps({"content": content[:2000]}).encode()
    
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
    
    if 'HTTP/1.1 403' in result.stdout or '403' in result.stderr:
        raise RuntimeError(f"Discord 403: {result.stderr}")
    
    return result.stdout
```

## Alternative Approaches
1. **Use a library that mimics browser TLS fingerprints** (e.g., `curl_cffi`)
2. **Configure a system-wide proxy** that handles TLS fingerprinting
3. **Whitelist the server IP** in Cloudflare firewall (requires admin access)
4. **Use the Hermes gateway** instead of direct API calls (bypasses the issue entirely)

## Why curl Works
`curl` presents a TLS fingerprint that matches real browsers, so Cloudflare's checks pass. The Python subprocess call inherits the system's TLS configuration, avoiding the fingerprint detection.

## Prevention
For any cron job or script that needs to send Discord alerts:
- Always test with `curl` first to verify bot access
- If `curl` works but Python HTTP fails, it's a TLS fingerprint block
- Use the curl workaround in the script itself
- Consider using the Hermes `send_message` tool if available

## Related Issues
- **Missing HTTP headers (403)**: See `urllib-headers.md` for header-related 403 errors
- **Invalid token or permissions (401/403)**: Standard Discord authentication errors
- **Rate limiting (429)**: Requires exponential backoff

## Technical Deep Dive
Cloudflare's TLS fingerprinting (known as "JA3" or "JA3D") creates a hash of the TLS client hello parameters. Python's `ssl` module generates a fingerprint that is statistically different from browsers, triggering the block. This is a known issue with automated tools and is not specific to Discord.