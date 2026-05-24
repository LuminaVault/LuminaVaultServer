---
name: discord-bot-operations
category: social-media
description: Manage Discord bot access, permissions, multi-channel publishing, and aggregated content delivery for automated reporting workflows
triggers:
  - discord bot access check
  - discord channel permissions
  - 403 errors from Discord API
  - publishing large digests to Discord
  - multi-source content aggregation for Discord
---

## Overview
Covers the full lifecycle of getting content from multiple scrapers into Discord channels: verifying bot membership/permissions, diagnosing 403 errors, aggregating outputs from different data sources, handling Discord’s message size limits, and publishing to the correct channel IDs.

## When to Use
- Bot reports `403: bot lacks access to channel` or cannot deliver to a Discord target
- Need to confirm a channel is reachable before enabling a scheduled job
- You must combine outputs from multiple scripts (movies + anime + TV + news) into a single digest
- Content exceeds Discord’s 2000-character text limit and requires file attachments
- Setting up or debugging multi-platform delivery (Discord + Telegram + Slack)

## Procedure

### 0. Prerequisites

Before any bot operations, ensure:
- The bot has been **invited to the target guild(s)** via OAuth2 URL with `bot` scope
- The bot's role includes `View Channel` and `Send Messages` permissions in each target channel
- The bot token is valid and not rate-limited

### 1. Verify Bot Guild & Channel Access
Do this whenever a Discord target fails or after a new bot invite:
1. Confirm the bot is a **member of the guild** (visible in the server’s member list).
2. Check the bot’s **role permissions** in that specific channel (channel → Edit Channel → Permissions):
   - Must have **View Channel** allowed
   - Must have **Send Messages** allowed
   - Ensure no explicit deny overrides these
3. Validate **role hierarchy**: the bot’s role must be above any role that denies View/Send.
4. Run a **diagnostic test**: send a short test message to the channel. Success = access confirmed.

> Tip: If the user says they have administrator privileges but the bot still fails, the bot may simply not be in the guild yet. Generate an OAuth2 invite (scopes: `bot`; permissions: `Send Messages`, `View Channel`) and add it, then re-test.

### 2. Diagnose 403 Errors
If delivery fails with 403:
1. Re-run the diagnostic test from step 1.4.
2. If test fails → membership/permissions issue (fix via steps 1.1–1.4.).
3. If test succeeds → the failure was transient or targeted the wrong channel ID; double-check the job’s `deliver` value.

**Additional checks:**
- **Missing token:** Verify that `DISCORD_BOT_TOKEN` is set in the environment (typically `$HERMES_HOME/.env`). A missing token will cause an unauthenticated request, resulting in 403 Forbidden. Check with: `echo $DISCORD_BOT_TOKEN` or `grep DISCORD_BOT_TOKEN $HERMES_HOME/.env`.
- **Invalid token:** If the token is present but delivery still fails, test the token directly: `curl -H "Authorization: Bot <TOKEN>" https://discord.com/api/v10/users/@me`. A 401/403 response indicates an invalid token.
- **Cloudflare blocking:** See the dedicated section on TLS fingerprinting issues if curl works but Python HTTP libraries fail.

### 3. Aggregate Multi-Source Content
When a single digest must cover multiple domains (e.g., movies + anime + TV):
1. **Identify the right scrapers**:
   - Movies (theatrical): `daily_cinema_chatter.py` → saves `~/movie_digest_today.md`
   - Anime (seasonal): `mal_seasonal_scraper.py` → saves to `~/obsidian-vault/FACorreia/Raw/Anime/Seasonal/<season> Seasonal Anime & Movies.md`
   - TV (seasonal): `tvshows_seasonal_scraper.py` → saves to `~/obsidian-vault/FACorreia/Raw/TV/Seasonal/<season> TV Shows.md`
   - News: `news_digest.py` or `daily_stock_news.py` as needed
2. **Run each scraper** to generate fresh data.
3. **Collect outputs**: read the saved markdown files.
4. **Merge** into a single structured digest with clear section headings.
5. Keep total content concise; if >2000 chars, plan to send as file attachment.

### 4. Publish to Discord — Message Formatting Strategy

Choose the delivery format based on content size and user preference:

**Option A — Single File Attachment (simple, for very large content)**
1. If content ≤ 2000 characters → send directly with `send_message`.
2. If content > 2000 chars:
   - Send a short intro message explaining the digest and sources.
   - Attach the full digest as a `.md` or `.txt` file using `MEDIA:/path/to/file`.
   - *Note: This forces a download to view content — consider multi-post instead.*

**Option B — Multi-Post Sequential Delivery (PREFERRED for large digests)**
*User preference: inline formatting with full digest attached only on final post. Matches Slack delivery style.*

1. **Split content into batches** ≤ 1800 chars each (leaves room for "Part X of Y" header; safe margin below Discord's 2000-char limit).
   - Keep logical section boundaries (by ticker, category, or topic).
   - Number parts: "Part 1 of N", "Part 2 of N", etc.
2. **Send intro first** — brief summary + sources + part count.
3. **Send each batch** sequentially as plain text messages.
4. **On final batch**, also attach the full digest file:
   - Send batch text message
   - Follow immediately with `MEDIA:/path/to/full_digest.md`

> Example sequence for a 9-part digest:
> - Message 1: Intro "📈 Daily Stock Digest — Part 1 of 9..."
> - Messages 2–9: Batch content
> - Message 10 (final): "Part 9 of 9 — summary... [attached full MD]"

**Why this format?**
- Keeps content readable inline without forcing downloads.
- Maintains searchability in Discord's chat history.
- Final attachment preserves a clean, versioned full record.
- Matches the pattern used successfully for `news_digest.py` outputs (~2178 chars).

### 5. Cross-Platform Format Parity
When the same digest is delivered to multiple platforms (Discord + Slack + Telegram):
- Use **identical content structure** across all platforms.
- Prefer multi-post delivery on Discord (handles long content better).
- Slack can use single-file or multi-post depending on channel preferences.
- Maintain consistent heading levels, bullet styles, and source attribution.

## Pitfalls
- **Discord message size limit** (2000 chars for plain text). Always use file attachments for longer digests.
- **Channel overrides**: A channel can deny View/Send even if the server-wide permission allows it. Always test the specific channel.
- **Role hierarchy matters**: If a restrictive role sits above the bot's role, the bot cannot override channel permissions.
- **Stale seasonal data**: Running a seasonal scraper out-of-season may return empty or fallback results. Check logs.
- **Duplicate jobs**: Multiple cron jobs may produce overlapping content (e.g., `daily-stock-news` vs `daily-stock-news-triple`). Consolidate to avoid spam.
- **Bot not fully initialized**: After an OAuth2 invite, wait ~10 seconds before testing; Discord can take a moment to propagate permissions.
- **Wrong channel ID**: Double-check IDs; a single digit off routes to a different (possibly private) channel and returns 403.
- **Intentional non-zero exits in alert pipelines**: Some detector scripts use exit code `1` to mean "alert found" rather than "transport failed". Treat that as success only when the script produced valid alert output and the wrapper contract says so.
- **Broken cron wrapper path**: If the job path is missing, add a thin compatibility wrapper at the expected location before rewriting the cron spec. It restores service faster and avoids churn.
- **Runtime env drift**: Delivery scripts may run under a different user or `HERMES_HOME` than the authoring shell. Load env from multiple Hermes `.env` locations and support `export KEY=...` lines.
#### 12. User-Agent Requirement for urllib/requests

**Symptoms**  
- HTTP 403 Forbidden errors when sending Discord messages using Python's `urllib.request` or `requests` libraries  
- The same token works when using `curl` or when a User-Agent header is present  
- Errors occur even though the token is valid and other channels work fine  

**Root Cause**  
Discord's API may reject requests from Python's standard library `urllib` or `requests` due to missing or non-browser-like User-Agent strings. These libraries present a generic User-Agent that Discord's WAF may flag as non-standard traffic, resulting in 403 Forbidden responses. This is similar to, but distinct from, TLS fingerprinting issues.

**Investigation Steps**  
1. **Test with curl** to confirm the token and channel are valid:  
   ```bash
   curl -X POST https://discord.com/api/v10/channels/<CHANNEL_ID>/messages \
     -H "Authorization: Bot <TOKEN>" \
     -H "Content-Type: application/json" \
     -d '{"content":"test"}'
   ```  
   If curl succeeds but Python fails, the issue is likely the User-Agent.

2. **Check the Python script** for missing User-Agent headers.

**Recommended Solutions**  
**Option 1: Add a User-Agent header (Recommended)**  
Add a `User-Agent` header to your request to mimic a browser or bot client:  
```python
headers={
    'Authorization': f'Bot {token}',
    'Content-Type': 'application/json',
    'User-Agent': 'HermesBot/1.0'  # or 'Mozilla/5.0' for generic browser
}
```  
This simple fix often resolves 403 errors immediately.

**Option 2: Use a library that mimics curl's fingerprint**  
Libraries like `curl_cffi` or `undetected-chromedriver` can mimic browser TLS fingerprints, but they add complexity.

**Prevention**  
- Always include a User-Agent header when making Discord API requests with Python's `urllib` or `requests`.  
- Use a consistent User-Agent string across all scripts (e.g., `HermesBot/1.0`).  
- Add token validation and User-Agent checks to deployment checklists.  
- Consider using the Hermes gateway for Discord integration to avoid raw HTTP issues.

**Symptoms**  
- HTTP 403 Forbidden errors when sending Discord messages using Python's `urllib` or `requests` libraries  
- Error messages like "⚠️ Discord send failed: HTTP Error 403: Forbidden"  
- The same token and channel work when using `curl`  
- Often accompanied by Cloudflare error code 1010 in the response  

**Root Cause**  
Discord uses Cloudflare as a WAF which employs TLS fingerprinting to detect and block non-browser traffic. Python's standard library `urllib` and `requests` have distinctive TLS fingerprints that Cloudflare recognizes and challenges, resulting in 403 Forbidden responses. `curl` presents a more browser-like fingerprint and passes Cloudflare's checks.

**Investigation Steps**  
1. **Test with curl** to confirm the issue:  
   ```bash
   curl -X POST https://discord.com/api/v10/channels/<CHANNEL_ID>/messages \
     -H "Authorization: Bot <TOKEN>" \
     -H "Content-Type: application/json" \
     -d '{"content":"Test"}'
   ```  
   If curl succeeds but Python fails, Cloudflare blocking is the cause.

2. **Check Python script** for use of `urllib.request` or `requests`. Look for patterns like:  
   ```python
   import urllib.request
   # or
   import requests
   ```

3. **Verify token and channel** are correct by making a direct API call with the same Python code to a non-Cloudflare endpoint (e.g., `https://discord.com/api/v10/users/@me`). If this also returns 403, the token may be invalid. If it works, the issue is specific to the Discord messages endpoint.

**Recommended Solutions**  
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

#### 10. Token Length Validation

**Symptoms**
- Discord API returns `HTTP Error 403: Forbidden` on all endpoints
- Bot token appears in `.env` but is longer than expected (e.g., 72 characters instead of 59)
- Both `curl` and Python HTTP libraries fail with 403

**Root Cause**
Discord bot tokens have a fixed length of **59 characters**. A token that is significantly longer indicates:
- The token is malformed or corrupted
- The token may be an older format or include extra whitespace/quotes
- The token may have been incorrectly copied from the Discord Developer Portal

**Investigation Steps**
1. **Check token length**:
   ```bash
   grep DISCORD_BOT_TOKEN /opt/data/.env | cut -d'=' -f2 | tr -d '\"' | wc -c
   # Expected: 59
   # Actual: 72 (or other length)
   ```
2. **Compare with known-good token format**:
   - Valid tokens start with `Mj`, `Bx`, `MS`, or `MW`
   - They consist of base64-encoded characters (A-Z, a-z, 0-9, /, +)
   - They do NOT contain spaces or newlines
3. **Test token directly**:
   ```bash
   curl -H "Authorization: Bot <TOKEN>" https://discord.com/api/v10/users/@me
   # Expected: 200 OK with user info
   # Actual: 403 Forbidden (invalid token)
   ```

**Resolution**
1. **Regenerate token** in Discord Developer Portal:
   - Go to Application → Bot → Reset Token
   - Copy the new 59-character token
2. **Update .env file**:
   ```bash
   sed -i 's/DISCORD_BOT_TOKEN=.*/DISCORD_BOT_TOKEN=new_59_char_token/' /opt/data/.env
   ```
3. **Verify token length**:
   ```bash
   grep DISCORD_BOT_TOKEN /opt/data/.env | cut -d'=' -f2 | tr -d '\"' | wc -c
   # Should output: 59
   ```

**Prevention**
- Store tokens securely and avoid manual editing of `.env` files
- Add token validation to deployment checklists
- Use Hermes gateway for Discord integration to avoid raw HTTP issues
- Periodically verify token health using the verification script (`scripts/verify_discord_access.py`)

#### 11. Channel ID Configuration Consistency

**Symptoms**
- Discord API returns `HTTP Error 403: Forbidden` when sending messages
- The token is valid and `curl` works, but Python script fails
- Different scripts use different channel IDs for the same purpose
- Some scripts hardcode channel IDs instead of reading from configuration

**Root Cause**
Inconsistent channel ID usage across scripts and configuration files can cause:
- Messages sent to wrong channels (resulting in 403 if bot lacks access)
- Confusion about which channel is the correct target
- Maintenance difficulties when channel IDs change

**Investigation Steps**
1. **List all channel IDs in use** across scripts:
   ```bash
   grep -r "channel.*id\|channel_id" /opt/data/home/.hermes/scripts/ --include="*.py"
   ```
2. **Compare with .env configuration**:
   ```bash
   grep DISCORD_.*CHANNEL /opt/data/.env
   ```
3. **Check channel_directory.json** for the actual channel names and IDs:
   ```bash
   cat /opt/data/channel_directory.json | jq '.channels[] | {id: .id, name: .name}'
   ```
4. **Identify mismatches** between hardcoded IDs and configured IDs.

**Resolution**
1. **Standardize on configuration variables**:
   - Modify scripts to read channel IDs from environment variables or configuration files
   - Example:
     ```python
     channel_id = os.environ.get('DISCORD_STOCK_CHANNEL_ID', 'default_id')
     ```
2. **Update .env with consistent IDs**:
   - Ensure all channel IDs in `.env` match the intended targets
   - Document the purpose of each channel ID variable
3. **Remove hardcoded IDs** from scripts where possible.

**Prevention**
- Use centralized configuration management for channel IDs
- Document channel ID variables in `.env` with comments
- Add validation to check that required channel IDs are set before running scripts
- Consider using channel names instead of IDs when possible (via Hermes gateway)
## References
- `references/discord-permission-troubleshooting.md` — detailed 403 diagnosis, OAuth2 scopes, role hierarchy, override resolution
- `references/content-scripts-inventory.md` — catalog of available scrapers with paths, outputs, and schedules
- `references/channel-id-mapping.md` — user's Discord channel IDs and their purposes
- `references/facorreia-channel-mapping.md` — **actual channel IDs discovered from live channel_directory.json** for the FACorreia guild; up-to-date mapping of channel names → snowflake IDs
- `scripts/verify_discord_access.py` — one-shot script to test bot access across all configured channels
- `scripts/batch_digest_for_discord.py` — batching utility: splits long markdown into Discord-safe sequential parts (≤1800 chars each), preserves section boundaries; ideal for multi-post digest delivery with final attachment
- `references/self-delivering-discord-403.md` — session notes on self-delivering alert scripts, direct Discord 403 diagnosis, token/channel validation, and `deliver=origin/local` routing.

## Configuration Notes
- **Token location:** `DISCORD_BOT_TOKEN` is typically set in `$HERMES_HOME/.env` (e.g., `/opt/data/.env`) and read by the gateway at runtime. The token is NOT stored in `~/.hermes/config.yaml`.
- **Channel directory:** Populated by the running gateway at `$HERMES_HOME/channel_directory.json` (e.g., `/opt/data/channel_directory.json`). This file is created/refreshed by the gateway on startup and every 5 minutes. It will not exist if the gateway is not running.
- **Gateway config:** Primary user config is `~/.hermes/config.yaml`, but platform credentials are read from `$HERMES_HOME/.env` and `$HERMES_HOME/config.yaml` as fallback. `HERMES_HOME` defaults to `/opt/data` in Docker installs.
- Store channel IDs in environment variables or a local config file to avoid hardcoding.
- Standardize digest format (Markdown with H2/H3 headings, bullet lists, and source attribution) for consistency across all content types.
- When adding scrapers, follow the existing pattern: write to a known file path, log clearly, and exit 0 on success.

## Discovered Channel IDs (FACorreia guild)
These were found in `channel_directory.json` during a live run:
- `1498025894751768776` → `#hermes` (home channel for general digests)
- `1499338003334561843` → `#stock-news`
- `1499331939469889656` → `#tv-anime-and-movies`
- `1498815493757341896` → `#stock-alerts`
- `1499908671847661578` → `#swift`
- `1499908914500862123` → `#golang`
  *(Use these as defaults when targeting the user's server.)*
