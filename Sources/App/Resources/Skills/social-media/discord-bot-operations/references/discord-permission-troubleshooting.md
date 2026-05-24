# Discord Permission Troubleshooting

## 403 “bot lacks access to channel” — Universal Diagnostic

### Quick Diagnosis Flowchart

```
Start: Discord API returns 403 Forbidden
       │
       ↓
Is the error consistent across ALL endpoints?
       │───────────────┬───────────────┐
       YES              NO              NO
       │                │               │
       ↓                ↓               ↓
INVALID/EXPIRED         │           TLS FINGERPRINTING
TOKEN OR CLOUDflare     │           (Python only, curl works)
BLOCKING                │               │
       │                │               │
       ↓                ↓               ↓
[Go to TOKEN SECTION]   │           [Go to TLS SECTION]
       │                │               │
       ↓                ↓               ↓
Test with curl on basic   │           Test with curl
endpoint (users/@me)      │           Test with Python
       │                │               │
       ↓                ↓               ↓
If curl fails →          │           If curl works but
INVALID TOKEN            │           Python fails → TLS block
       │                │               │
       ↓                ↓               ↓
Regenerate token         │           Use curl workaround
       │                │               │
       └───────┬────────┴───────┬───────┘
               │                │
               └──────┬─────────┘
                      │
                      ↓
             [Go to PERMISSION SECTION]
```

### Step-by-step

1. **Test the channel directly**  
   Send a one-line test message to the exact channel ID. If it fails, proceed.

2. **Confirm bot membership**  
   - In Discord, open the server’s member list and search for the bot.  
   - If missing, the bot was never invited or was kicked. Generate an OAuth2 invite and add it.

3. **Check channel permissions for the bot’s role**  
   - Channel → Edit Channel → Permissions  
   - Select the bot’s role (or @everyone if bot inherits from there)  
   - Ensure **View Channel** = ✔️ Allow (not ❌ Deny)  
   - Ensure **Send Messages** = ✔️ Allow (not ❌ Deny)

4. **Inspect role hierarchy**  
   - Server Settings → Roles  
   - The bot’s role must be **higher** than any role that denies View/Send. Discord evaluates permissions top-down; a lower role cannot override a higher role’s restrictions.

5. **Check channel overrides**  
   - A channel-specific override can deny View/Send even if the server-wide setting allows it. Look for a red ❌ Deny next to View Channel or Send Messages for the bot’s role in that channel.

6. **Wait and re-test**  
   After an invite, wait ~10 seconds for Discord to propagate the new membership before testing again.

### Common Gotchas

| Symptom | Likely cause |
|---------|--------------|
| 403 on one channel but others work | Channel-specific permission override (View/Send denied for bot’s role in that channel) |
| 403 on every channel | Bot not in guild, or role lacks server-wide Send Messages/View Channel permissions |
| Bot appears in member list but still 403 | Bot’s role is **below** a role that explicitly denies View/Send |
| 403 immediately after invite | Discord’s permission propagation delay — wait 10–30 seconds |
| 403 only in specific category channels | Category-level overrides cascade to channels; check category permissions too |

### OAuth2 Invite Link Builder
```
https://discord.com/api/oauth2/authorize?client_id=<BOT_CLIENT_ID>&permissions=2048&scope=bot
```
- `permissions=2048` = Send Messages (add `+1024` for View Channel = 3072 total)
- Better: use the OAuth2 page in the Discord Developer Portal to visually select both permissions and generate the link.

### Role Hierarchy Rule
> A role cannot grant permissions that are denied by a **higher** role.  
If `@everyone` denies View Channel and the bot’s custom role is below `@everyone`, the bot will never see the channel — regardless of its own role settings. Move the bot’s role **above** all restrictive roles.

### Verifying Fixes
After any change:
1. Re-run the diagnostic test message.
2. If it succeeds, re-run the original failing job to confirm it delivers.
3. If still failing, re-check for typos in channel ID and ensure the bot didn’t get accidentally removed.

---

## Token & Authentication Issues (403 on ALL endpoints)

### Symptoms
- 403 Forbidden on **every** Discord API call (users/@me, guilds, channels, messages)
- Both `curl` and Python HTTP libraries fail
- No Cloudflare error codes (1010) observed
- Token appears in `.env` file but is rejected

### Diagnostic Steps

1. **Verify token presence**
   ```bash
   grep DISCORD_BOT_TOKEN /opt/data/.env
   ```

2. **Test token with curl on basic endpoint**
   ```bash
   curl -H "Authorization: Bot <TOKEN>" https://discord.com/api/v10/users/@me
   ```
   - Expected: 200 OK with user info
   - If 403 → token is invalid/expired

3. **Compare with TLS fingerprinting case**
   - In TLS fingerprint blocks, `curl` works but Python fails
   - Here, **both** curl and Python fail → token itself is invalid

4. **Check Discord Developer Portal**
   - Token may have been revoked
   - Token may have expired (some tokens have short lifetimes)
   - Bot may have been removed from the server
   - Token may have been typed incorrectly in `.env`

### Resolution
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

### Prevention
- Store tokens securely and rotate periodically
- Add token validation to deployment checklists
- Use Hermes gateway for Discord integration to avoid raw HTTP issues
- Monitor Discord bot health via the verification script (`scripts/verify_discord_access.py`)

---

## TLS Fingerprinting Block (403 on Python only)

### Symptoms
- HTTP 403 Forbidden errors when sending Discord messages using Python's `urllib` or `requests` libraries
- Error messages like `⚠️ Discord send failed: HTTP Error 403: Forbidden`
- The same token and channel work when using `curl`
- Often accompanied by Cloudflare error code 1010 in the response

### Root Cause
Discord uses Cloudflare as a WAF which employs TLS fingerprinting to detect and block non-browser traffic. Python's standard library `urllib` and `requests` have distinctive TLS fingerprints that Cloudflare recognizes and challenges, resulting in 403 Forbidden responses. `curl` presents a more browser-like fingerprint and passes Cloudflare's checks.

### Investigation Steps
1. **Test with curl** to confirm the issue:
   ```bash
   curl -X POST https://discord.com/api/v10/channels/<CHANNEL_ID>/messages \
     -H "Authorization: Bot <TOKEN>" \
     -H "Content-Type: application/json" \
     --data '{"content":"Test"}'
   ```
   If curl succeeds but Python fails, Cloudflare blocking is the cause.

2. **Check Python script** for use of `urllib.request` or `requests`. Look for patterns like:
   ```python
   import urllib.request
   # or
   import requests
   ```

3. **Verify token and channel** are correct by making a direct API call with the same Python code to a non-Cloudflare endpoint (e.g., `https://discord.com/api/v10/users/@me`). If this also returns 403, the token may be invalid. If it works, the issue is specific to the Discord messages endpoint.

### Recommended Solutions

**Option 1: Switch to curl via subprocess (Recommended)**
Replace `urllib` or `requests` with a `curl` call in the script:
```python
import subprocess
import json

try:
    payload = json.dumps({'content': output[:2000]})
    cmd = [
        'curl', '-X', 'POST',
        f'https://discord.com/api/v10/channels/{channel}/messages',
        '-H', f'Authorization: Bot {token}',
        '-H', 'Content-Type: application/json',
        '--data', payload
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
    if result.returncode != 0 or 'message' in result.stdout:
        print(f"⚠️ Discord send failed: {result.stderr}", file=sys.stderr)
    else:
        print("✓ Alert sent to Discord", file=sys.stderr)
except Exception as e:
    print(f"⚠️ Discord send failed: {e}", file=sys.stderr)
```

**Option 2: Use a library that mimics curl's fingerprint**
Libraries like `curl_cffi` or `undetected-chromedriver` can mimic browser TLS fingerprints, but they add complexity.

**Option 3: Whitelist the server IP in Cloudflare**
Requires Discord server admin access and is generally not recommended due to security implications.

**Prevention**
- Test Discord API calls from the production environment early
- Consider using Hermes gateway for Discord integration to avoid these issues
- When building custom integrations, use curl or robust HTTP libraries with proper headers
