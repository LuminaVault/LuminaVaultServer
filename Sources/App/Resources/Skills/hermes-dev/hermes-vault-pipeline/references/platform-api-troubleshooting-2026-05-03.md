# Platform API Troubleshooting — X Link Poller v2

**Skill:** `hermes-vault-pipeline`  
**Date:** 2026-05-03  
**Scope:** Diagnosing HTTP 403/409/401 errors in multi-platform content pollers

---

## Overview

The `x_link_poller_v2.py` script polls Discord, Telegram, and Slack for X/twitter/fixupx URLs. When platform API access is misconfigured, the poller logs HTTP errors and saves zero articles, starving the vault pipeline of source material.

This reference documents observed failure modes, root causes, and step-by-step fixes.

---

## Quick diagnostic command

```bash
python3 /opt/data/home/.hermes/scripts/x_link_poller_v2.py --diagnose-only
```

Output format:
```
=== X Link Poller v2 starting ===
Credentials → Discord:OK, Telegram:OK, Slack:OK, OpenRouter:OK
Polling discord...  Discord: HTTP 403 - Forbidden
Polling telegram... Telegram: HTTP 409 - Conflict
Polling slack...  Slack: OK (HTTP 200, ok=True)
=== Platform diagnostic complete ===
```

---

## Error catalog

### Discord — HTTP 403 Forbidden

**Full log line:**
```
2026-05-03 13:32:32,287 [ERROR] HTTP 403 fetching https://discord.com/api/v10/channels/1498025894751768776/messages?limit=50: Forbidden
2026-05-03 13:32:32,287 [ERROR] Discord 403 Forbidden on channel 1498025894751768776. Bot needs 'Read Message History' permission in this channel. Current: can SEND but cannot READ. Fix: add bot role → channel → Permissions → 'Read Message History'.
```

**Why this happens:**
- Discord bots require explicit permission to read message history
- Default bot roles often only allow sending messages
- Channel-specific overrides can also block the bot even if the role allows reads globally

**Fix procedure:**

1. Open Discord Server Settings → Roles
2. Select the bot's role (e.g., `Hermes#7076`)
3. Under "Text & Voice Permissions" enable:
   - ✅ **Read Message History**
   - ✅ **View Channel** (prerequisite)
4. If the channel `#hermes` has permission overrides:
   - Click the channel → ⚙️ Edit Channel → Permissions
   - Add the bot role or user and enable `Read Message History`
5. Save changes

**Verification:**
```bash
# Re-run diagnostic
python3 /opt/data/home/.hermes/scripts/x_link_poller_v2.py --diagnose-only
# Should print: Discord: OK (HTTP 200, <n> msgs)
```

**Common gotchas:**
- Bot must also have `View Channel` — without it, 403 persists even with Read History enabled
- Server-wide role permissions can be overridden per-channel; check both levels
- If the bot is in multiple servers, ensure it's in the correct one and channel ID matches

---

### Telegram — HTTP 409 Conflict

**Full log line:**
```
2026-05-03 13:27:31,656 [ERROR] HTTP 409 fetching https://api.telegram.org/bot8708552435:***/getUpdates?limit=100&timeout=5: Conflict
2026-05-03 13:27:31,657 [ERROR] Telegram 409 Conflict: Webhook is active. Long-polling and webhook cannot coexist. Fix: delete the webhook via curl -X POST 'https://api.telegram.org/bot<TOKEN>/deleteWebhook'
```

**Why this happens:**
- Telegram bots can receive updates via either **webhook** (push) or **long-polling** (`getUpdates`)
- Only one method can be active at a time; enabling a webhook blocks `getUpdates` with HTTP 409
- The Hermes poller uses long-polling; any prior webhook registration causes conflict

**Fix procedure (one-time):**

```bash
# Delete the active webhook
curl -X POST "https://api.telegram.org/bot<YOUR_BOT_TOKEN>/deleteWebhook"

# Optional: verify deletion
curl -s "https://api.telegram.org/bot<YOUR_BOT_TOKEN>/getWebhookInfo" | python3 -m json.tool
# Should return: {"ok":true,"result":{"url":"","has_custom_certificate":false,...}}
```

Where `<YOUR_BOT_TOKEN>` is the value from `TELEGRAM_BOT_TOKEN` in `/opt/data/.env`.

**Prevention:**
- Do not set `TELEGRAM_WEBHOOK_URL` in `.env` if you're using the poller
- If other Hermes components need webhook, split into separate bot tokens per purpose
- If webhook is required elsewhere, use a different bot for polling

**Verification:**
```bash
python3 /opt/data/home/.hermes/scripts/x_link_poller_v2.py --diagnose-only
# Should print: Telegram: OK (HTTP 200, ok=True, <n> updates)
```

---

### Slack — Various errors

#### 401 Unauthorized

**Symptom:**
```
Slack: HTTP 401 - Unauthorized
```

**Root cause:** Bot token invalid, expired, or revoked.

**Fix:** Slack workspace → Apps → Manage → Hermes (or your app) → OAuth & Permissions → "Reinstall to Workspace" or regenerate Bot Token.

#### 404 / channel_not_found

**Symptom:**
```
Slack: HTTP 200 but ok=false → error: "channel_not_found"
```

**Root cause:** Channel ID incorrect or bot not a member.

**Fix:**
1. Get correct channel ID: Right-click channel → Copy Link → last path segment is ID (e.g., `C0B0BDGEJTT`)
2. Ensure `SLACK_HOME_CHANNEL` env var matches
3. Invite bot to channel: `/invite @<botname>` in channel

#### not_authorized / missing_scope

**Symptom:**
```
Slack: HTTP 200 but ok=false → error: "not_authorized" or "missing_scope"
```

**Root cause:** Bot lacks `channels:history` scope.

**Fix:**
1. Slack workspace → Apps → Your App → OAuth & Permissions
2. Under "Bot Token Scopes" add: `channels:history`
3. Click "Reinstall to Workspace" to apply new scopes

**Verification:**
```bash
TOKEN=$(grep SLACK_BOT_TOKEN /opt/data/.env | cut -d= -f2)
CHANNEL=$(grep SLACK_HOME_CHANNEL /opt/data/.env | cut -d= -f2)
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://slack.com/api/conversations.history?channel=$CHANNEL&limit=1" \
  | python3 -m json.tool -c '.ok'
# Should print: true
```

---

## Environment validation checklist

Before running the poller, verify:

| Check | Command | Expected |
|-------|---------|----------|
| `.env` file readable | `cat /opt/data/.env \| grep -E "DISCORD|TELEGRAM|SLACK|OPENROUTER"` | Lines present with non-empty values |
| Discord token | `echo $DISCORD_BOT_TOKEN` | 70+ char string starting with `MT...` or `Mx...` |
| Telegram token | `echo $TELEGRAM_BOT_TOKEN` | `<numbers>:<string>` format |
| Slack token | `echo $SLACK_BOT_TOKEN` | `xoxb-` prefix |
| OpenRouter key | `echo $OPENROUTER_API_KEY` | `sk-or-` prefix |
| State dir writable | `touch /opt/data/home/.hermes/state/test.tmp && rm` | No error |
| Vault Raw dir writable | `touch /opt/data/obsidian-vault/FACorreia/Raw/test.tmp && rm` | No error |

If any check fails, fix environment before proceeding.

---

## Poller state and deduplication

The poller persists state to prevent re-processing identical URLs across restarts:

**State file:** `/opt/data/home/.hermes/state/x_link_poller_state.json`

Structure:
```json
{
  "discord_last_msg_id": "1234567890",
  "telegram_last_update_id": 987654321,
  "slack_last_ts": "1777741449.402309",
  "processed_urls": {
    "<sha256[:16]>": {
      "url": "https://x.com/user/status/123",
      "title": "...",
      "saved_at": "2026-05-02T11:00:30.641117"
    }
  }
}
```

**Manual reset (if you need to re-fetch everything):**
```bash
# Stop the poller first, then:
python3 -c "
import json
state = {'discord_last_msg_id': None, 'telegram_last_update_id': None, 'slack_last_ts': None, 'processed_urls': {}}
with open('/opt/data/home/.hermes/state/x_link_poller_state.json', 'w') as f:
    json.dump(state, f, indent=2)
print('State reset — next poll will fetch all accessible history')
"
```

**Caution:** Resetting state can cause duplicate files in `Raw/` if poller re-encounters old URLs. The poller uses URL hashes to prevent saving duplicates (skips if hash present).

---

## LLM classification fallback

The poller uses OpenRouter's `anthropic/claude-3-haiku` to classify articles into topics (AI, Dev/Swift, Stocks, Health, Tech, Business, News, XFeed).

**If OpenRouter fails** (API key invalid, quota exceeded), fallback is keyword-based classification using `TOPIC_KEYWORDS` in the script — less accurate but still functional.

**Check OpenRouter health:**
```bash
curl -s -H "Authorization: Bearer $OPENROUTER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"anthropic/claude-3-haiku","messages":[{"role":"user","content":"Hello"}],"max_tokens":5}' \
  "https://openrouter.ai/api/v1/chat/completions" | python3 -m json.tool -c '.choices[0].message.content'
# Should return "Hello" or similar short response
```

---

## Manual run and log inspection

```bash
# Run poller once (non-daemon) with verbose output
python3 -u /opt/data/home/.hermes/scripts/x_link_poller_v2.py

# Follow live daemon logs
tail -f /opt/data/home/.hermes/logs/x_link_poller_v2.log

# Check last compile result (if any articles were saved)
ls -lt /opt/data/obsidian-vault/FACorreia/Raw/*/ | head -20
```

---

## Recovery sequence checklist

When the pipeline is broken due to upstream poller failure:

1. [ ] Verify poller process is running (`ps aux | grep x_link_poller_v2`)
2. [ ] Check poller logs for HTTP error patterns
3. [ ] Run `--diagnose-only` to isolate platform
4. [ ] Apply platform-specific fix (permission, webhook, token, scope)
5. [ ] Re-run diagnostic until all platforms show "OK"
6. [ ] Manually trigger one poll cycle: stop daemon, run script once, restart daemon
7. [ ] Confirm new files appear in `Raw/{topic}/` within 5 minutes
8. [ ] Wait for automatic wiki compile (triggered by new files) or run compile manually
9. [ ] Verify `wiki/` contains newly compiled pages
10. [ ] If compile fails, jump to Step 3 (filesystem permissions) above

---

## Environment facts (specific to this deployment)

| Variable | Value (masked) | Purpose |
|----------|---------------|---------|
| `DISCORD_BOT_TOKEN` | `MTQ5ODAy...` | Discord bot authentication |
| `DISCORD_MONITOR_CHANNEL` | `1498025894751768776` | Channel ID for `#hermes` |
| `TELEGRAM_BOT_TOKEN` | `8708552435:***` | Telegram bot token |
| `TELEGRAM_HOME_CHANNEL` | `476978568` | Telegram chat/channel ID |
| `SLACK_BOT_TOKEN` | `xoxb-1021576...` | Slack bot token |
| `SLACK_HOME_CHANNEL` | `C0B0BDGEJTT` | Slack channel ID |
| `OPENROUTER_API_KEY` | `sk-or-...` | LLM classification (Claude Haiku) |

These are loaded from `/opt/data/.env` by the poller at startup.

---

## Related scripts

- `diagnose_platforms.py` (in `scripts/` dir) — standalone checker that returns exit code 0 if all platforms reachable
- `x_link_poller_v2.py` — main poller (infinite loop, 5-minute sleep between cycles)
