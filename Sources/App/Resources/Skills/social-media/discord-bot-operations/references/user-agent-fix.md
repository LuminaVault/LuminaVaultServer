# User-Agent Fix for Discord API 403 Errors

## Problem
The watchlist_poster.py script was failing to post to Discord with HTTP 403 Forbidden errors, even though the Discord bot token was valid and the script worked for some channels but not others.

## Root Cause
Discord API rejects requests from Python's `urllib.request` and `requests` libraries due to missing User-Agent header. The generic User-Agent from these libraries can trigger Discord's anti-bot measures, resulting in 403 errors.

## Solution
Added a custom User-Agent header to the HTTP request headers.

## Patch Applied
**File**: `/opt/data/home/.hermes/scripts/ai-scoreboard/watchlist_poster.py`

**Change**: Added `'User-Agent': 'HermesBot/1.0'` to the headers dictionary in the `send_discord` function.

**Code snippet**:
```python
req = urllib.request.Request(
    f'https://discord.com/api/v10/channels/{channel_id}/messages',
    data=payload.encode(),
    headers={
        'Authorization': f'Bot {token}',
        'Content-Type': 'application/json',
        'User-Agent': 'HermesBot/1.0'  # <-- Added this line
    }
)
```

## Verification
After applying the patch, the script successfully posted to both target channels:
- Channel 1499338003334561843 (Stock News) - ✓ Posted
- Channel 1498815493757341896 (Stock Alerts) - ✓ Posted

## Key Learning
When using Python's `urllib` or `requests` to interact with Discord API, **always include a User-Agent header**. This is separate from TLS fingerprinting issues and can cause 403 errors even with valid tokens.

## References
- This fix was discovered during the Will Do Watchlist cron job on 2026-05-06.
- Related skill: `discord-bot-operations` (now includes a section on User-Agent requirements).