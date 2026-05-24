# Discord 403 Forbidden — X Link Poller v2 (2026-05-02)

** Symptom**  
Poller logs show repeated `HTTP 403 Forbidden` when fetching Discord channel:

```
2026-05-02 16:51:09,341 [ERROR] HTTP 403 fetching https://discord.com/api/v10/channels/1498025894751768776/messages?limit=50: Forbidden
2026-05-02 16:51:09,395 [ERROR] Discord fetch error: HTTP Error 403: Forbidden
```

All other platforms (Telegram, Slack) succeed; OpenRouter LLM classification works.

---

## Diagnosis Flow

### 1. Verify credentials file is being read
```bash
# Check .env contains Discord token
grep DISCORD_BOT_TOKEN /opt/data/.env

# Verify token is loaded into process environment (if you can attach)
cat /proc/$(pgrep -f x_link_poller_v2.py)/environ | tr '\0' '\n' | grep DISCORD
```

### 2. Test token validity with a direct API call
```bash
# Replace $TOKEN from /opt/data/.env
TOKEN=$(grep DISCORD_BOT_TOKEN /opt/data/.env | cut -d= -f2- | tr -d '"')

# Fetch current user (validates token)
curl -s -H "Authorization: Bearer $TOKEN" \
     "https://discord.com/api/v10/users/@me" | jq .

# Expected: {"id":"123...","username":"bot_name",...}
# 403 means token invalid/revoked or missing 'bot' scope
```

### 3. Check channel accessibility
```bash
CHANNEL_ID=1498025894751768776

# Try to fetch channel info
curl -s -H "Authorization: Bearer $TOKEN" \
     "https://discord.com/api/v10/channels/$CHANNEL_ID" | jq .

# 403 here → bot lacks permission to view channel at all
```

### 4. Common causes & remediations

| Cause | How to confirm | Fix |
|-------|----------------|-----|
| **Bot token regenerated** | Direct API test (step 2) returns 403 | Generate new bot token in Discord Developer Portal; update `/opt/data/.env`; restart poller |
| **Missing Read Message History** | Channel info fetch succeeds but messages endpoint 403s | In Discord server settings → channel permissions → add bot role with `Read Message History` enabled |
| **Channel is a thread** | Channel type from channel info is `GUILD_PUBLIC_THREAD`/`GUILD_PRIVATE_THREAD` | Use parent channel ID instead, or switch to `GET /channels/{channel_id}/messages` (threads require different handling) |
| **OAuth2 scope mismatch** | Token was created without `bot` or `applications.commands` scope | Re-authorize with `scope=bot applications.commands`; regenerating token in correct environment usually fixes |
| **Bot not in server** | `GET /users/@me/guilds` doesn't list the server | Use OAuth2 URL with `permissions=...&scope=bot` to add bot to server |

### 5. Immediate remediation script
```bash
#!/bin/bash
# discord-403-fix.sh — regenerates token and restarts poller

ENV_FILE="/opt/data/.env"
OLD_TOKEN=$(grep DISCORD_BOT_TOKEN "$ENV_FILE" | cut -d= -f2- | tr -d '"')

echo "1) Visit Discord Developer Portal → Your App → Bot → Reset Token"
echo "   Copy the NEW token"
read -p "Paste new token here: " NEW_TOKEN

# Update .env (preserve line formatting)
sed -i "s/^DISCORD_BOT_TOKEN=.*/DISCORD_BOT_TOKEN=\"$NEW_TOKEN\"/" "$ENV_FILE"

# Restart poller
echo "2) Restarting X Link Poller v2 …"
pkill -TERM -f "x_link_poller_v2.py"
sleep 3
# Cron will automatically restart; or manual:
nohup python3 -u /opt/data/home/.hermes/scripts/x_link_poller_v2.py > /opt/data/home/.hermes/logs/x_link_poller_manual.log 2>&1 &

echo "3) Verifying …"
sleep 5
tail -20 /opt/data/home/.hermes/logs/x_link_poller_$(date +%Y%m%d).log | grep -E "Credentials|Polling|ERROR"
```

### 6. Monitoring after fix
```bash
# Watch next 3 poll cycles (~15 minutes)
tail -f /opt/data/home/.hermes/logs/x_link_poller_$(date +%Y%m%d).log | \
  grep --line-buffered -E "Polling discord|ERROR|Saved"
```

Expected healthy output:
```
INFO Polling discord...
INFO   Found N new X links
INFO Saved → /opt/data/... [classification]
```

No `HTTP 403` errors should appear. If they persist, re-check step 4's permission matrix.

---

## Prevention

Add pre-flight credential validation to the poller script itself:

```python
def validate_platform_token(name, token, test_endpoint):
  """Quick HEAD/GET to confirm token works before full poll cycle."""
  req = Request(test_endpoint, headers={"Authorization": f"Bearer {token}"})
  try:
    resp = urlopen(req, timeout=5)
    return resp.code == 200
  except HTTPError as e:
    if e.code == 403:
      log.error(f"{name} token invalid or lacks permissions (403). Check bot role/channel.")
    return False
```

Call at startup for each platform; fail-fast with clear guidance instead of logging repeated 403s every cycle.

---

## Related

- **Skill**: `hermes-script-daemon-lifecycle` — daemon deployment patterns
- **Skill**: `discord-bot-operations` — bot permission management
- **Log file**: `/opt/data/home/.hermes/logs/x_link_poller_YYYYMMDD.log`
- **State**: `~/.hermes/state/x_link_poller_state.json`
- **Env**: `/opt/data/.env` (DISCORD_BOT_TOKEN)
