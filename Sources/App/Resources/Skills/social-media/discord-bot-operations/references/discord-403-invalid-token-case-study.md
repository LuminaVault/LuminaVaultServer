# Discord 403 Error: Invalid Bot Token Case Study

## Incident Summary
- **Date:** 2026-05-06
- **Script:** `ai-scoreboard/ai_scoreboard_alerts_deliver.py`
- **Error:** `HTTP Error 403: Forbidden` on all Discord API calls
- **Root Cause:** Bot token present but invalid/expired

## Symptoms
The script failed with:
```
⚠️ Discord send failed: HTTP Error 403: Forbidden
```

Investigation revealed:
1. Token was present in `/opt/data/.env`
2. **All** Discord API endpoints returned 403 Forbidden:
   - `GET https://discord.com/api/v10/users/@me` (bot info)
   - `GET https://discord.com/api/v10/users/@me/guilds` (guilds list)
   - `GET https://discord.com/api/v10/channels/<CHANNEL_ID>` (channel info)
   - `POST https://discord.com/api/v10/channels/<CHANNEL_ID>/messages` (message send)
3. Both Python (`urllib`) and `curl` attempts failed with 403
4. No Cloudflare error codes (1010) were observed

## Investigation Steps

### 1. Verify token presence
```bash
grep DISCORD_BOT_TOKEN /opt/data/.env
# Output: DISCORD_BOT_TOKEN=MTQ5OD...3L0w
```

### 2. Test token with curl (basic endpoint)
```bash
curl -H "Authorization: Bot <TOKEN>" https://discord.com/api/v10/users/@me
# Expected: 200 OK with user info
# Actual: 403 Forbidden
```

### 3. Test token with curl (channel endpoint)
```bash
curl -H "Authorization: Bot <TOKEN>" https://discord.com/api/v10/channels/<CHANNEL_ID>
# Expected: 200 OK with channel info
# Actual: 403 Forbidden
```

### 4. Compare with TLS fingerprinting case
- In TLS fingerprinting blocks, `curl` works but Python fails
- Here, **both** curl and Python fail → token itself is invalid

### 5. Check Discord Developer Portal
- Token may have been revoked
- Token may have expired (some tokens have short lifetimes)
- Bot may have been removed from the server
- Token may have been typed incorrectly in .env

## Resolution
1. **Regenerate token** in Discord Developer Portal:
   - Go to Application → Bot → Reset Token
   - Copy the new token

2. **Update .env file**:
   ```bash
   sed -i 's/DISCORD_BOT_TOKEN=.*/DISCORD_BOT_TOKEN=new_token_here/' /opt/data/.env
   ```

3. **Restart Hermes gateway** (if running):
   ```bash
   hermes gateway restart
   ```

4. **Verify fix**:
   ```bash
   # Test with curl
   curl -H "Authorization: Bot new_token_here" https://discord.com/api/v10/users/@me
   # Should return 200 OK
   
   # Test script manually
   cd /opt/data/home/.hermes/scripts/ai-scoreboard
   python3 ai_scoreboard_alerts_deliver.py
   ```

## Key Learnings
- **403 Forbidden from Discord API** can have multiple root causes:
  - Missing token → 403 on all endpoints (no Authorization header)
  - Invalid/expired token → 403 on all endpoints (invalid credentials)
  - Permission issues → 403 only on specific channels, but bot info/guilds may work
  - TLS fingerprinting → 403 only on Python requests, curl works

- **Diagnostic hierarchy**:
  1. Check token presence in .env
  2. Test token with curl on basic endpoint (`users/@me`)
  3. If curl fails → token invalid → regenerate
  4. If curl succeeds but Python fails → TLS fingerprinting → switch to curl or use fingerprint-mimicking library

- **Prevention**:
  - Store tokens securely and rotate periodically
  - Add token validation to deployment checklists
  - Use Hermes gateway for Discord integration to avoid raw HTTP issues
  - Monitor Discord bot health via the verification script (`scripts/verify_discord_access.py`)

## References
- Main SKILL.md (this file)
- `discord-permission-troubleshooting.md` for channel-specific issues
- `discord-403-missing-token-case-study.md` for missing token scenario