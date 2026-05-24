# urllib Headers Issue with Discord API

## Problem Summary
When using Python's `urllib.request` library to send HTTP requests to Discord's API, the requests may be rejected with a 403 Forbidden status even when the bot token is valid and the bot has proper channel permissions.

## Root Cause
`urllib.request` does not automatically include standard HTTP headers that Discord expects. Specifically, it's missing:
- `Accept-Encoding: gzip, deflate`
- `Accept: */*`
- `Connection: keep-alive`

Discord's API appears to reject requests lacking these headers, while requests sent via the `requests` library (which includes these headers by default) work correctly.

## Solution
When using `urllib.request` to interact with Discord's API, explicitly set these headers in the request:

```python
import urllib.request
import json

url = "https://discord.com/api/v10/channels/1499338003334561843/messages"
payload = json.dumps({"content": "Test message"}).encode()

req = urllib.request.Request(
    url,
    data=payload,
    headers={
        'Authorization': f'Bot {token}',
        'Content-Type': 'application/json',
        'User-Agent': 'python-requests/2.33.1',  # Optional but helpful
        'Accept-Encoding': 'gzip, deflate',
        'Accept': '*/*',
        'Connection': 'keep-alive'
    }
)

with urllib.request.urlopen(req, timeout=15) as resp:
    print(f"Status: {resp.status}")
```

## Alternative Approaches
1. **Use the `requests` library**: It handles these headers automatically and is generally more robust for HTTP interactions.
2. **Create a wrapper function** that sets the required headers whenever using `urllib`.

## Technical Verification
Testing confirmed:
- `urllib` without these headers → 403 Forbidden
- `urllib` with these headers → 200 OK
- `requests` library (with default headers) → 200 OK

## When This Occurs
This issue is most likely to appear in:
- Cron jobs that use direct urllib calls to Discord API
- Scripts that don't have access to the Hermes gateway
- Custom Python scripts that need to send Discord alerts

## Recommendation
For new code, prefer the `requests` library for HTTP interactions with Discord. For existing code using `urllib`, add the missing headers as shown above.