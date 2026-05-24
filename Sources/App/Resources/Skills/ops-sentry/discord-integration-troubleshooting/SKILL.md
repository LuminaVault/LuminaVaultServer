---
name: discord-integration-troubleshooting
description: Discord bot integration troubleshooting, token validation, and error resolution for Hermes agents
trigger: discord-api-errors, missing-discord-token, cron-discord-failures
scope: discord, bot-authentication, channel-permissions, error-resolution
---

# Discord Integration Troubleshooting

## Overview
Comprehensive Discord bot integration support for Hermes agents — token validation, channel configuration, permission troubleshooting, and common error resolution.

## Trigger Conditions
- Discord API errors (401, 403, 404, 500)
- Missing or invalid `DISCORD_BOT_TOKEN`
- Channel permission issues
- Bot authentication failures
- Cron job Discord delivery failures

## Token Validation Procedure

### 1. Token Format Recognition
Discord tokens come in several formats. Recognizing the type is crucial for proper authentication:

```yaml
Token Types:
  - Bot Token: Starts with "Mj", "Bx", "MS", or "MW"
    - Format: `Mj[...]....`
    - Usage: `Authorization: Bot <token>`
  - User Token: Starts with "MT"
    - Format: `MT[...]....`
    - Usage: `Authorization: <token>` (no "Bot " prefix)
  - Webhook Token: Starts with "https://discord.com/api/webhooks/" followed by ID and token
```

### 2. Validation Procedure
```bash
# 1. Check token format
token=YOUR_TOKEN_HERE
if [[ $token == MT* ]]; then
    echo "⚠️ WARNING: This appears to be a USER token, not a BOT token."
    echo "User tokens require NO 'Bot ' prefix in Authorization header."
fi

# 2. Test Discord API connectivity
curl -H "Authorization: Bot $token" "https://discord.com/api/v10/users/@me" 2>&1 | grep -i "401\|unauthorized"

# 3. Verify token works with channel POST
curl -X POST "https://discord.com/api/v10/channels/CHANNEL_ID/messages" \
  -H "Authorization: Bot $token" \
  -H "Content-Type: application/json" \
  --data "{\"content\":\"Test message\"}" 2>&1 | grep -E "200|403|401"
```

## Common Error Resolutions

### **401 Unauthorized**
**Meaning**: Authentication failed — token invalid, expired, or incorrect prefix.

**Causes**:
1. Using user token with "Bot " prefix (or vice versa)
2. Token has been revoked or regenerated
3. Token contains extra whitespace or formatting issues
4. Using incorrect token type for the operation

**Fix**:
- Verify token format matches usage
- Regenerate token in Discord Developer Portal
- Ensure proper "Bot " prefix for bot tokens
- Check for copy-paste errors

### **403 Forbidden**
**Meaning**: Token is valid but request is denied due to permissions.

**Subtypes**:
- **403 Forbidden (Read Message History)**: Bot lacks Read Message History permission in channel
- **403 Forbidden (Send Messages)**: Bot lacks Send Messages permission
- **403 Forbidden (General)**: Bot not in server or channel, or missing required roles

**Fix**:
- Review bot permissions in Discord Server Settings → Roles
- Ensure bot has "Send Messages" permission for posting alerts
- Add "Read Message History" if needed for context
- Verify bot is added to the server with appropriate scopes

## Channel Configuration Best Practices

### Environment Variable Setup
```bash
# In /opt/data/.env
DISCORD_BOT_TOKEN=your_v...8776    # Main channel for regular messages
DISCORD_ALERT_CHANNEL_ID=1499362823342653471 # Dedicated channel for alerts
```

### Script Configuration
Scripts should use environment variables consistently:
```python
# Good practice
token = os.environ.get('DISCORD_BOT_TOKEN')
home_channel = os.environ.get('DISCORD_HOME_CHANNEL', 'default_channel_id')
alert_channel = os.environ.get('DISCORD_ALERT_CHANNEL_ID', 'default_alert_id')
```

### Channel ID Management
- **Never hardcode channel IDs** — use environment variables
- Maintain a mapping of channel purposes to IDs
- Document channel purposes in README.md

## Testing Discord Integration

### Pre-deployment Checklist
```yaml
Pre-flight Check:
  - [ ] Discord bot token is valid and not expired
  - [ ] Bot has "Send Messages" permission in target channel
  - [ ] Bot is a member of the Discord server
  - [ ] Channel ID is correct and accessible
  - [ ] Rate limits considered (1 message/second default)
  - [ ] Token format matches usage (Bot prefix vs no prefix)
```

### Integration Test Script
```python
#!/usr/bin/env python3
"""Discord Integration Test — Validates bot connectivity and permissions."""

import os
import sys
import json
import urllib.request

def test_discord(token, channel_id):
    """Comprehensive Discord integration test."""
    
    # Test 1: Authentication
    try:
        req = urllib.request.Request(
            "https://discord.com/api/v10/users/@me",
            headers={"Authorization": f"Bot {token}"}
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            if resp.status == 200:
                print("✓ Authentication: SUCCESS")
            else:
                print(f"✗ Authentication: FAILED (HTTP {resp.status})")
                return False
    except Exception as e:
        print(f"✗ Authentication: FAILED ({e})")
        return False
    
    # Test 2: Channel Access
    try:
        test_msg = {"content": "Discord integration test — please ignore"}
        payload = json.dumps(test_msg).encode()
        req = urllib.request.Request(
            f"https://discord.com/api/v10/channels/{channel_id}/messages",
            data=payload,
            headers={
                "Authorization": f"Bot {token}",
                "Content-Type": "application/json"
            }
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            if resp.status in (200, 204):
                print("✓ Channel Access: SUCCESS")
            else:
                print(f"✗ Channel Access: FAILED (HTTP {resp.status})")
                return False
    except Exception as e:
        print(f"✗ Channel Access: FAILED ({e})")
        return False
    
    print("\n✅ ALL CHECKS PASSED — Discord integration is working!")
    return True

if __name__ == "__main__":
    token = os.getenv("DISCORD_BOT_TOKEN")
    channel = os.getenv("DISCORD_ALERT_CHANNEL_ID", "1499362823342653471")
    
    if not token:
        print("ERROR: DISCORD_BOT_TOKEN environment variable not set!")
        sys.exit(1)
    
    test_discord(token, channel)
```

## Monitoring and Alerting

### Discord Health Checks
Implement regular Discord connectivity checks in cron jobs:
```python
# In your delivery wrapper
def check_discord_health():
    """Verify Discord is reachable before attempting send."""
    try:
        # Simple connectivity test
        urllib.request.urlopen(
            "https://discord.com/api/v10/channels/1234567890/messages",
            timeout=5
        )
        return True
    except:
        return False

# Before sending alert
if not check_discord_health():
    log.error("Discord API unreachable — skipping alert delivery")
    # Consider fallback channels (Telegram, Slack, email)
    send_fallback_alert()
    return

# Proceed with Discord send
```

### Error Logging Best Practices
```python
# Log detailed Discord errors for debugging
try:
    # Discord API call
    pass
except urllib.error.HTTPError as e:
    log.error(f"Discord HTTP {e.code}: {e.reason}")
    if e.code == 401:
        log.error("Invalid or missing bot token — check DISCORD_BOT_TOKEN")
    elif e.code == 403:
        log.error("Permission denied — check bot roles/permissions")
    elif e.code == 429:
        log.error("Rate limited — implement exponential backoff")
except urllib.error.URLError as e:
    log.error(f"Discord connection failed: {e.reason}")
```

## References
- [Discord API Error Codes](https://discord.com/developers/docs/topics/rate-limits#http-exceptions)
- [Discord Bot Token Documentation](https://discord.com/developers/docs/topics/oauth2)
- [Ops-Sentry Discord Integration Skill](https://hermes-agent.nousresearch.com/skills/ops-sentry/discord-integration)

## Related Skills
- `ops-sentry` (umbrella skill)
- `social-media` (Discord-related skills)
- `software-development` (troubleshooting methodologies)