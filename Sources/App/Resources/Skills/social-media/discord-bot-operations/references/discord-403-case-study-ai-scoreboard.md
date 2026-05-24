# AI Scoreboard Discord 403 Error Case Study

## Incident Details
- **Date:** 2026-05-06
- **Script:** `ai-scoreboard/ai_scoreboard_alerts_deliver.py`
- **Cron Job:** `ai-cohort-alerts-hourly`
- **Error:** `HTTP Error 403: Forbidden` when sending Discord messages
- **Exit Code:** 1 (failure)

## Error Transcript

```
Script exited with code 1
stderr:
⚠️ Discord send failed: HTTP Error 403: Forbidden
```

## Investigation Findings

### 1. Discord Configuration Analysis

**Environment Variables (from /opt/data/.env):**
```
DISCORD_BOT_TOKEN=MTQ5OD...3L0w  (72 characters)
DISCORD_ALLOWED_USERS=184264928281100288
DISCORD_HOME_CHANNEL=1498025894751768776
DISCORD_MONITOR_CHANNEL=1498025894751768776
DISCORD_ALERT_CHANNEL_ID=1499362823342653471
```

**Script Configuration:**
- Channel ID used: `1499338003334561843` (hardcoded)
- This channel ID does NOT match any ID in the .env configuration

### 2. Token Validation

**Token length check:**
```bash
grep DISCORD_BOT_TOKEN /opt/data/.env | cut -d'=' -f2 | tr -d '\\\"' | wc -c
# Output: 72 characters
```

**Expected token length:** 59 characters (Discord bot tokens are exactly 59 chars)

**Test with curl:**
```bash
curl -H \"Authorization: Bot <TOKEN>\" https://discord.com/api/v10/users/@me
# Expected: 200 OK with user info
# Actual: 403 Forbidden
```

**Test with curl on channel endpoint:**
```bash
curl -H \"Authorization: Bot <TOKEN>\" https://discord.com/api/v10/channels/<CHANNEL_ID>
# Expected: 200 OK with channel info
# Actual: 403 Forbidden
```

**Conclusion:** Token is present but invalid/expired. Both curl and Python fail with 403, ruling out TLS fingerprinting issues.

### 3. Channel ID Mismatch

**Script target channel:** `1499338003334561843`
**.env channel IDs:**
- `1498025894751768776` (DISCORD_HOME_CHANNEL)
- `1499362823342653471` (DISCORD_ALERT_CHANNEL_ID)

The script's hardcoded channel ID does not match any configured channel ID, which could cause delivery failures even if the token were valid. This highlights the importance of using consistent channel IDs across scripts and configuration.

### 3. Channel ID Mismatch

**Script target channel:** `1499338003334561843`
**.env channel IDs:**
- `1498025894751768776` (DISCORD_HOME_CHANNEL)
- `1499362823342653471` (DISCORD_ALERT_CHANNEL_ID)

The script's hardcoded channel ID does not match any configured channel ID, which could cause delivery failures even if the token were valid.

## Root Causes

1. **Invalid Discord bot token** - Token is 72 characters (should be 59) and returns 403 on API calls
2. **Channel ID inconsistency** - Script uses hardcoded channel ID that doesn't match configuration
3. **Missing token validation** - No checks for token length or validity before attempting API calls

## Resolution Steps

### Immediate Actions:

1. **Regenerate Discord bot token:**
   - Go to Discord Developer Portal → Application → Bot → Reset Token
   - Copy the new 59-character token

2. **Update .env file:**
   ```bash
   sed -i 's/DISCORD_BOT_TOKEN=.*/DISCORD_BOT_TOKEN=new_59_char_token/' /opt/data/.env
   ```

3. **Verify token length:**
   ```bash
   grep DISCORD_BOT_TOKEN /opt/data/.env | cut -d'=' -f2 | tr -d '\"' | wc -c
   # Should output: 59
   ```

4. **Standardize channel IDs:**
   - Update script to read channel ID from configuration instead of hardcoding
   - Ensure all channel IDs in .env are consistent with script usage

5. **Test the fix:**
   ```bash
   # Test token with curl
   curl -H "Authorization: Bot new_token_here" https://discord.com/api/v10/users/@me
   
   # Test script manually
   cd /opt/data/home/.hermes/scripts/ai-scoreboard
   python3 ai_scoreboard_alerts_deliver.py
   ```

## Key Learnings

- **Discord bot tokens are exactly 59 characters.** Longer tokens indicate corruption or incorrect copying.
- **Always validate token length** during setup and when diagnosing 403 errors.
- **Use configuration variables for channel IDs** instead of hardcoding to avoid mismatches.
- **Check both token validity AND channel configuration** when encountering Discord 403 errors.
- **Test with curl first** to distinguish between token issues (both curl and Python fail) and TLS fingerprinting (curl works, Python fails).

## Prevention

- Add token length validation to deployment checklists
- Store tokens securely and avoid manual editing of .env files
- Use Hermes gateway for Discord integration to avoid raw HTTP issues
- Periodically verify token health using verification script (`scripts/verify_discord_access.py`)
- Standardize channel ID configuration across all scripts

## References
- Main SKILL.md (this file)
- `discord-permission-troubleshooting.md` for channel-specific issues
- `discord-403-invalid-token-case-study.md` for invalid token scenario
- `discord-403-missing-token-case-study.md` for missing token scenario