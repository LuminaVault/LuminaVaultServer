---
name: x-social-monitor-auth-troubleshooting
description: Diagnose and fix X/Twitter API v2 authentication issues — token validation, scope mismatches, refresh flows, 401/403/402 error handling, and credential storage conflicts for the x-social-monitor ecosystem.
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos]
prerequisites: {}
metadata:
  hermes:
    tags: [twitter, x, authentication, oauth, troubleshooting, credentials]
    related_skills: [x-social-monitor, xurl]
---

# X Social Monitor — Auth Troubleshooting

Reference skill for diagnosing X API v2 authentication failures in `x-social-monitor` scripts (`tweet_monitor.py`, `stockplan_promotion.py`).

**Symptoms:**
- `HTTP 401 Unauthorized` on user lookup or tweet fetch
- `HTTP 403 Forbidden` on token refresh or POST
- Errors: `{"title":"Unauthorized"}`, `{"code":99,"message":"Unable to verify your credentials","label":"authenticity_token_error"}`
- Tokens "look valid" (length ~100 chars) but API rejects all calls

---

## Two Credential Stores — Sync Required

**`.twitter_creds`** (JSON, 0600) — loaded by `tweet_monitor.py` at runtime:
```json
{
  "BEARER_TOKEN": "...",
  "ACCESS_TOKEN": "...",
  "REFRESH_TOKEN": "..."
}
```

**`.xurl`** (YAML) — xurl CLI credential store & refresh token holder:
```yaml
apps:
  x-hermes:
    client_id: "..."
    client_secret: "..."
    oauth2_tokens:
      fatc88:
        oauth2:
          access_token: "..."
          refresh_token: "..."
          expiration_time: "1777407136"
```

**Both must be updated simultaneously** after re-auth. If only one is updated, the other will fail. Prefer using `xurl auth` to refresh both automatically; if that fails, manually copy tokens across both files.

---

## Authentication Flow in Scripts

### `auth_headers()` logic in `tweet_monitor.py`:

```python
BEARER_TOKEN = ...  # App-only token from .twitter_creds or $TWITTER_BEARER_TOKEN
ACCESS_TOKEN = ...  # User OAuth2 token from .twitter_creds or $TWITTER_ACCESS_TOKEN
USE_USER_AUTH = ACCESS_TOKEN and "YOUR_" not in ACCESS_TOKEN
AUTH_TOKEN = ACCESS_TOKEN if USE_USER_AUTH else BEARER_TOKEN

def auth_headers():
    return {"Authorization": f"Bearer {AUTH_TOKEN}", "User-Agent": "HermesTweetMonitor/1.0"}
```

**Implications:**
- If `ACCESS_TOKEN` is set and not a placeholder, user token is used (better rate limits)
- Both tokens are sent as `Bearer` in `Authorization` header
- `ACCESS_TOKEN` must be an **OAuth2 User Access Token** (not OAuth1 legacy token)
- `BEARER_TOKEN` must be an **OAuth2 App Bearer Token** with `tweet.read` scope

---

## Error Matrix & Fixes

### 401 Unauthorized

| Cause | Diagnosis | Fix |
|-------|-----------|-----|
| Expired token | Check `expiration_time` in `.xurl`; compare to now | Refresh via `xurl auth` or re-auth from Twitter Dev Portal |
| Wrong token type used | Script uses `ACCESS_TOKEN` as Bearer; if `ACCESS_TOKEN` is OAuth1 (legacy), 401 occurs | Regenerate OAuth2 tokens (not OAuth1) from dev.twitter.com |
| Scope missing | No `tweet.read` on Bearer token | Regenerate with `tweet.read` scope |
| Token mistyped / placeholder | Credential contains "YOUR_BEARER_TOKEN_HERE" | Replace with real token |

**Quick test:**
```bash
# Validate bearer token without running script
curl -H "Authorization: Bearer $TWITTER_BEARER_TOKEN" \
  "https://api.twitter.com/2/users/by/username/fatc88"
```

### 403 Forbidden on Refresh

| Error | Cause | Fix |
|-------|-------|-----|
| `{"code":99,"label":"authenticity_token_error"}` | Refresh token invalid/expired, or client_id/secret mismatch | Full re-auth via Twitter Dev Portal. Generate new OAuth2 credentials pair (client_id + client_secret + tokens). |

**What happened here:** Refresh attempted with expired refresh token expired 3 days ago, using client_id/secret from `.xurl`. The token endpoint rejected it. Must do full OAuth2 re-auth.

### 402 CreditsDepleted

Not an auth error — app-only Bearer token exhausted its monthly credit quota. Fixes:
- Upgrade Twitter dev project to paid tier
- Reduce `FOLLOWING_SAMPLE_SIZE` or set `TWITTER_FETCH_FOLLOWING=false` to conserve credits
- Switch to User Access Token (has separate quota)

---

## Token Format Recognition

**OAuth2 Bearer (App):** 112-char URL-safe base64; starts with `AAAA...` (alphanumeric)

**OAuth2 User Access Token:** ~91-char URL-safe base64; starts with `S3R3...` (custom format)

**Refresh Token:** Same format as access token but longer-lived.

**OAuth1 Legacy Token (DO NOT USE):** Colon-separated `token:secret` pairs. **Will fail if used as Bearer.**

If your token contains a colon (`:`), it is OAuth1. Discard and generate OAuth2.

---

## Pre-Flight Checklist Before Deploying Cron

Before any cron job is enabled, verify:

1. **Token freshness** — `.xurl` `expiration_time` > now + 1 day
2. **Token type** — No colons in tokens; length ≈ 91–112 chars; starts with letter (not `oauth2:`)
3. **Scope validation** — Bearer token has `tweet.read`; User token has `tweet.write` (if posting)
4. **Storage sync** — `.twitter_creds` and `.xurl` contain identical `access_token` and `refresh_token` values (copy if needed)
5. **Single test run** — `python3 ~/.hermes/scripts/tweet_monitor.py` prints digest without error
6. **Output dir** — `~/.hermes/output/` exists and is writable

---

## Recovery Procedure

### If tokens expired or broken:

1. Go to https://developer.twitter.com → Project & Apps → Your App → Keys & Tokens
2. Under "OAuth 2.1", generate new **Client ID** and **Client Secret**
3. Generate new **Access Token & Secret** (OAuth 2.0, User context) — select scopes `tweet.read` and `tweet.write`
4. Generate new **Bearer Token** (App-only) — scope `tweet.read`
5. Update `.twitter_creds` with all four values
6. Update `.xurl`:
   - `client_id` and `client_secret`
   - `oauth2_tokens.fatc88.oauth2.access_token`
   - `oauth2_tokens.fatc88.oauth2.refresh_token`
   - `expiration_time` (Unix timestamp, ~30 days from now)
7. Run `xurl auth validate` (if available) or test with script

### If refresh fails (403):

Ignore refresh token. It is tied to the old client_id/secret. After step 6 above, discard old refresh token and rely on manual re-auth every ~30 days. Consider setting calendar reminder.

### If using `xurl` CLI to refresh:

```bash
# Refresh access token (auto-updates .xurl)
xurl auth refresh --user fatc88

# If that fails, do full re-auth:
xurl auth login --client-id <id> --client-secret <secret>
```

---

## Debugging Script Enhancements

To add better diagnostics to `tweet_monitor.py` for future incidents:

1. **Print token age / expiry before first API call:**
   ```python
   print(f"Using {'user' if USE_USER_AUTH else 'app'} token: {AUTH_TOKEN[:20]}...")
   if os.path.exists(".xurl"):
       exp = yaml.safe_load(open(".xurl"))['apps']['x-hermes']['oauth2_tokens']['fatc88']['oauth2']['expiration_time']
       print(f"Token expires in {(int(exp) - time.time())/86400:.1f} days")
   ```

2. **Pre-flight endpoint probe:**
   ```python
   resp = make_request("GET", "/2/users/by/username/fatc88")
   if resp.get("status", 200) != 200:
       print(f"❌ Pre-flight auth failed: {resp}")
       sys.exit(1)
   ```

3. **Dual-storage validation at startup:**
   ```python
   def validate_token_consistency():
       creds = json.load(open(CRED_FILE))
       xurl = yaml.safe_load(open(Path.home() / ".xurl"))
       x_tok = xurl['apps']['x-hermes']['oauth2_tokens']['fatc88']['oauth2']['access_token']
       if creds.get("ACCESS_TOKEN") != x_tok:
           print("⚠️  ACCESS_TOKEN differs from .xurl — update both to avoid confusion")
   ```

---

## Cron Job Recovery Monitoring

After fixing credentials, verify cron execution:

```bash
# Check Hermes cron job history
hermes cron list

# Inspect latest output
cat ~/.hermes/output/tweet_digest_$(date +%Y-%m-%d).md

# Check Slack delivery logs (if integrated)
# Slack should show the digest channel message; if empty, cron capture failed
```

Expected output: digest contains at least header + 1 matching tweet section. If empty but script exits 0 → no matching tweets in last 2 days (expand `TOPICS`).

---

## Scope Summary Table

| Token | Type | Required Scope | Used For |
|-------|------|----------------|----------|
| `BEARER_TOKEN` | App Bearer (OAuth2) | `tweet.read` | Fetching timelines & search results |
| `ACCESS_TOKEN` | User OAuth2 | `tweet.read` + `tweet.write` | Fetching (if chosen) + POSTing promotions |
| `REFRESH_TOKEN` | OAuth2 | N/A | Exchange for new access token (requires matching client_id/secret) |

**Note:** If `ACCESS_TOKEN` is absent or placeholder, script falls back to `BEARER_TOKEN` for read-only. If both present with valid scopes, user token preferred.

---

## Future-Proofing

- Store tokens in Hermes memory with `store` so they're injected as env vars rather than file-bound
- Add expiry monitoring: `if time.time() > exp - 86400: send_alert("Token expiring in 24h")`
- Consider switching to `xurl` CLI as the API layer (it manages refresh automatically)

---

**Last updated:** 2026-05-01 (post-401/403 failure investigation)
**Related:** [x-social-monitor](x-social-monitor), [xurl](xurl)
