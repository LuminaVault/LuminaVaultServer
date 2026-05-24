# Discord Bot Token Validation — Quick Reference

**Purpose:** Determine whether a Discord bot token is valid, revoked, or misconfigured using the Discord API.

---

## One-Liner Probing

```bash
# Bash + curl
TOKEN="YOUR_TOKEN"
curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bot $TOKEN" \
  https://discord.com/api/v10/users/@me
```

```python
# Python
import urllib.request, json
token = "YOUR_TOKEN"
req = urllib.request.Request(
    'https://discord.com/api/v10/users/@me',
    headers={'Authorization': f'Bot {token}'}
)
try:
    resp = urllib.request.urlopen(req, timeout=10)
    data = json.loads(resp.read())
    print(f"✓ Valid — bot user: {data['username']}#{data['discriminator']}")
except urllib.error.HTTPError as e:
    print(f"✗ HTTP {e.code}")
```

---

## HTTP Code Interpretation

| Code | Meaning | Action |
|------|---------|--------|
| **200** | Token is valid and bot is active | ✅ Good to use |
| **401** | Invalid token (wrong format, never valid, or malformed) | ❌ Replace token entirely |
| **403** | Token was once valid but now rejected | 🔴 **Revoked or disabled** — bot app deleted, token regenerated, or bot removed from guild with no API access. **Generate a fresh token.** |

**Why 403 vs 401 matters:** A 401 means "you are not authorized to make this call at all" — the token string is wrong. A 403 means "you are authenticated but forbidden" — the token was valid but the underlying bot object is no longer usable. Both require a new token, but 403 tells you the previous token was **correct at some point** and then became invalid.

---

## Common 403 Scenarios

1. **Token regenerated** in Discord Developer Portal — old token instantly invalid
2. **Bot application deleted or suspended** by Discord
3. **Bot removed from all guilds** and lacked the `applications.commands` scope to make user endpoint calls (rare — `/users/@me` usually works even without guilds)
4. **Two-factor enforcement** or account lockout applied to the bot owner's account (if using user tokens — not applicable for bot tokens)

---

## Full Validation Script (Python)

```python
#!/usr/bin/env python3
import os, sys, urllib.request, json

def validate_discord_token(token: str) -> tuple[bool, str]:
    """Return (is_valid, message)."""
    req = urllib.request.Request(
        'https://discord.com/api/v10/users/@me',
        headers={'Authorization': f'Bot {token}'}
    )
    try:
        resp = urllib.request.urlopen(req, timeout=10)
        data = json.loads(resp.read())
        return True, f"Bot: {data['username']}#{data['discriminator']} (ID: {data['id']})"
    except urllib.error.HTTPError as e:
        body = e.read().decode('utf-8', errors='replace') if e.fp else ''
        if e.code == 401:
            return False, "Invalid token — wrong token format or never issued"
        elif e.code == 403:
            return False, f"Token revoked/disabled — {body[:100]}"
        else:
            return False, f"Unexpected HTTP {e.code}: {body[:100]}"
    except Exception as e:
        return False, f"Network/parse error: {e}"

if __name__ == '__main__':
    token = os.environ.get('DISCORD_BOT_TOKEN') or sys.argv[1] if len(sys.argv) > 1 else None
    if not token:
        print("Usage: DISCORD_BOT_TOKEN=$TOKEN python3 validate_token.py")
        sys.exit(2)
    ok, msg = validate_discord_token(token)
    print(msg)
    sys.exit(0 if ok else 1)
```

---

## After Obtaining a New Token

1. Update the token in your `.env` or credential store (Hermes: `hermes config set DISCORD_BOT_TOKEN <new-token>`)
2. **Restart the Hermes gateway** (`hermes gateway restart`) so subprocesses inherit the fresh environment
3. Verify bot presence in target Discord server and channel permissions (Send Messages, Read Message History)
4. Run a test alert: `hermes cron run <job_id>` and inspect output in `/opt/data/cron/output/<job_id>/`

---

## Related

- `hermes-dev` — Cron job debugging and credential injection patterns
- `hermes-server-monitoring` — Cron job health checks and delivery verification
