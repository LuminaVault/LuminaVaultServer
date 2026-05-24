# Discord 403 Error: Missing Bot Token Case Study

## Incident Summary
- **Date:** 2026-05-05
- **Script:** `ai-scoreboard/ai_scoreboard_alerts_deliver.py`
- **Error:** `HTTP Error 403: Forbidden`
- **Root Cause:** Missing `DISCORD_BOT_TOKEN` environment variable

## Symptoms
The script exited with code 1 and printed:
```
⚠️ Discord send failed: HTTP Error 403: Forbidden
```

## Investigation Steps

### 1. Verify script logic
The script reads the token from environment:
```python
token = os.environ.get('DISCORD_BOT_TOKEN')
```

### 2. Check environment files
- Primary expected location: `/opt/data/.env`
- Actual content found:
  ```
  STOCKPLAN_PROMO_DRY_RUN=true
  ```
- No `DISCORD_BOT_TOKEN` present.

### 3. Check alternative locations
- `/opt/data/home/.hermes/scripts/.env` (same content)
- System environment variables (none set)
- `/opt/data/.env.gateway` (template, not configuration)

### 4. Confirm token absence
```bash
echo $DISCORD_BOT_TOKEN  # returned empty
grep DISCORD_BOT_TOKEN /opt/data/.env  # no match
```

### 5. Validate hypothesis
The script would attempt to make an HTTP request without proper Authorization header, which Discord rejects with 403.

## Resolution
Add the token to `/opt/data/.env`:
```
DISCORD_BOT_TOKEN=MTQ5OD...3L0w  # (actual token from auth.json)
```

## Key Learnings
- A missing token produces the same 403 error as permission issues or invalid tokens.
- Always check environment variables first when encountering 403 from Discord API.
- The `.env` file at `/opt/data/.env` is the canonical location for Hermes Discord integration.
- Lock file existence (`/opt/data/.local/state/hermes/gateway-locks/discord-bot-token-*.lock`) indicates the gateway was previously running but doesn't guarantee the token is still in the environment.

## Prevention
- Ensure `.env` contains all required tokens during initial setup.
- Consider adding a validation script that checks for required environment variables on startup.
- Document the expected `.env` format in setup guides.

## References
- Main SKILL.md (this file)
- `discord-permission-troubleshooting.md` for broader 403 diagnosis