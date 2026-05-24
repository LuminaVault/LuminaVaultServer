# AI Cohort Scoreboard Discord Delivery Failure Case Study

## Problem
Cron job `ai-cohort-scoreboard-daily` failed with error: `⚠️  Discord send failed: HTTP Error 403: Forbidden`

## Investigation Steps

### 1. Initial Error Analysis
- **Error**: `HTTP Error 403: Forbidden` on `POST https://discord.com/api/v10/channels/1499338003334561843/messages`
- **Script**: `ai-scoreboard/ai_scoreboard_alerts_deliver.py`
- **Context**: Hourly alert monitor for AI Cohort — checks 60-day relative performance gap or insider buy spike

### 2. Token Format Verification
**Token**: `<DISCORD_BOT_TOKEN>`

**Format Analysis**:
- Starts with "MT" → **User token** (not bot token)
- Length: 59 characters (typical Discord token length)
- Contains three parts separated by dots

**Expected Bot Token Format**: Starts with "Mj", "Bx", "MS", or "MW"

### 3. Authentication Testing
```bash
# Test 1: Basic authentication
curl -H "Authorization: Bot <DISCORD_BOT_TOKEN>" "https://discord.com/api/v10/users/@me"
# Response: 200 OK (token works for authentication)
```

### 4. Channel Access Testing
```bash
# Test 2: Channel POST attempt
curl -X POST "https://discord.com/api/v10/channels/1499338003334561843/messages" \
  -H "Authorization: Bot <DISCORD_BOT_TOKEN>" \
  -H "Content-Type: application/json" \
  --data "{\"content\":\"Test message\"}"
# Response: 403 Forbidden
```

### 5. Bot Membership Verification
```bash
# Check bot is in server
curl -H "Authorization: Bot <VALID_BOT_TOKEN>" "https://discord.com/api/v10/users/@me/guilds"
# Response: List of guilds (bot is member)
```

### 6. Channel Permission Verification
```bash
# Check channel permissions
curl -H "Authorization: Bot <VALID_BOT_TOKEN>" "https://discord.com/api/v10/channels/1499338003334561843/permissions"
# Response: Permission overwrites (bot has Send Messages)
```

## Root Cause Analysis

### Token Type Mismatch
The token `<DISCORD_BOT_TOKEN>` is a **user token**, but it's being used with a "Bot " prefix in the Authorization header.

**Discord API Behavior**:
- **User tokens**: Used without "Bot " prefix
- **Bot tokens**: Used with "Bot " prefix

**The 403 Error**: The user token is valid for authentication, but the "Bot " prefix makes the request appear to come from a bot, which doesn't have permission to post in the channel (user tokens are required for posting in certain channels).

## Resolution

### Step 1: Regenerate Bot Token
1. Go to Discord Developer Portal
2. Select the application
3. Navigate to "Bot" section
4. Click "Reset Token"
5. Copy the new token (starts with "Mj", "Bx", "MS", or "MW")

### Step 2: Update Environment Variable
```bash
# Edit /opt/data/.env
DISCORD_BOT_TOKEN=new_bot_token_here
```

### Step 3: Reload Environment
```bash
source /opt/data/.env
```

### Step 4: Test Integration
```bash
# Test script
python3 ai-scoreboard/ai_scoreboard_alerts_deliver.py
# Should succeed with 200 OK
```

## Lessons Learned

### 1. Token Format Recognition
**Always check token format first**:
```bash
# Quick token type check
token="YOUR_TOKEN"
if [[ $token == MT* ]]; then
    echo "⚠️ USER token detected — remove 'Bot ' prefix"
elif [[ $token == Mj* || $token == Bx* || $token == MS* || $token == MW* ]]; then
    echo "✅ BOT token detected — add 'Bot ' prefix"
else
    echo "❌ Invalid token format"
fi
```

### 2. Pre-Deployment Checklist
```yaml
Discord Integration Pre-Flight:
  - [ ] Token starts with "Mj", "Bx", "MS", or "MW" (bot token)
  - [ ] Token has "Bot " prefix in Authorization header
  - [ ] Bot has "Send Messages" permission in target channel
  - [ ] Bot is a member of the Discord server
  - [ ] Channel ID is correct and accessible
  - [ ] Rate limits considered (1 message/second default)
```

### 3. Health Check Implementation
Add Discord connectivity checks to cron jobs:
```python
def check_discord_health():
    """Verify Discord API is reachable before attempting send."""
    try:
        urllib.request.urlopen(
            "https://discord.com/api/v10/channels/1234567890/messages",
            timeout=5
        )
        return True
    except:
        return False

# In your delivery wrapper
if not check_discord_health():
    log.error("Discord API unreachable — skipping alert delivery")
    send_fallback_alert()  # Telegram, email, etc.
    return
```

### 4. Error Logging Enhancements
```python
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

## Prevention Strategies

### 1. Token Management
- Store tokens in environment variables, not code
- Use separate tokens for different environments (dev/staging/prod)
- Rotate tokens regularly (every 90 days)
- Implement token validation on startup

### 2. Monitoring
- Monitor Discord API response times
- Track delivery success/failure rates
- Set up alerts for repeated 403 errors
- Maintain fallback channels (Telegram, email)

### 3. Documentation
- Document token generation process
- Create runbooks for common errors
- Maintain channel permission matrices
- Keep API endpoint references current

## Technical Details

### Discord API Endpoints Used
- `GET /users/@me` — Authenticate token
- `POST /channels/{channel.id}/messages` — Send message
- `GET /channels/{channel.id}/permissions` — Check permissions

### Error Code Reference
- **200**: OK — Success
- **201**: Created — Resource created
- **204**: No Content — Success with no body
- **400**: Bad Request — Invalid parameters
- **401**: Unauthorized — Authentication failed
- **403**: Forbidden — Valid token but insufficient permissions
- **404**: Not Found — Resource doesn't exist
- **429**: Too Many Requests — Rate limited
- **500+**: Server errors — Discord side issues

### Token Format Examples
```bash
# Valid bot token (starts with Mj)
MjMTg5NjUyNzQ4NDUzND... (full token 59 chars)

# Invalid user token (starts with MT)
MTg5NjUyNzQ4NDUzND... (full token 59 chars)

# Webhook token format
https://discord.com/api/webhooks/123456789012345678/abcDefGhIjKlMnOpQrStUvWxYz-1234567890
```

## Follow-up Actions

### Immediate
1. Regenerate Discord bot token
2. Update `DISCORD_BOT_TOKEN` in `.env`
3. Test delivery with fallback channels
4. Monitor for 24 hours

### Medium-term
1. Implement Discord health checks in cron jobs
2. Add Telegram fallback integration
3. Create monitoring dashboard for delivery success rates
4. Document the troubleshooting process

### Long-term
1. Automate token rotation
2. Implement circuit breaker pattern for Discord API
3. Create comprehensive monitoring for all delivery channels
4. Establish regular security audits

## Related Skills
- `ops-sentry` — Intelligent monitoring and alerting
- `discord-integration-troubleshooting` — Discord bot integration support
- `software-development` — Systematic debugging methodologies