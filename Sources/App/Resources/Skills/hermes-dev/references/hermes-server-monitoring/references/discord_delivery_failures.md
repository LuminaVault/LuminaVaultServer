# Discord Delivery Failures

When a cron job fails to deliver messages to Discord, the error is typically silent (exit code 1) or shows up in `last_delivery_error`. Follow this systematic approach:

## 1. Verify Discord Bot Token Validity

Test the token with Discord's API to ensure it's valid and the bot is authenticated:

```python
import urllib.request, json
req = urllib.request.Request(
    "https://discord.com/api/v10/users/@me",
    headers={"Authorization": f"Bot {DISCORD_BOT_TOKEN}"}
)
try:
    with urllib.request.urlopen(req, timeout=10) as response:
        if response.status == 200:
            data = json.loads(response.read().decode())
            print(f"✓ Token valid - user: {data.get('username')}")
        else:
            print(f"✗ Token test returned HTTP {response.status}")
except Exception as e:
    print(f"✗ Token test failed: {e}")
```

**Note:** A 403 Forbidden response indicates the token is invalid, expired, or the bot has been removed from the server. This is different from the Discord gateway connection, which uses separate credentials and can be connected even when the bot token is invalid.

## 2. Check Channel Permissions and ID

Even with a valid token, the bot needs:
- **"Send Messages" permission** in the target channel
- **Guild membership** - the bot must be a member of the server containing the channel

Verify the channel exists and the bot has access:
- Use the channel ID from your script or .env (e.g., `DISCORD_ALERT_CHANNEL_ID`)
- Check that the bot is invited to the server with the correct scopes (`bot`, `applications.commands`)

## 3. Align Channel IDs

Mismatched channel IDs between your script and .env can cause delivery failures. Ensure consistency:

- Check what channel ID your script uses (often hardcoded)
- Check .env for `DISCORD_ALERT_CHANNEL_ID` or similar
- Use the same channel ID across all configurations
- Consider making the channel ID configurable via .env instead of hardcoding

## 4. Check Script Path Containment

Ensure the script passes the cron containment check:

```python
from pathlib import Path
scripts_dir = Path('/opt/data/scripts').resolve()
path = Path('your_script.py').resolve()
try:
    path.relative_to(scripts_dir)
    print('✓ Script within allowed directory')
except ValueError:
    print('✗ Script OUTSIDE allowed directory - fix required')
```

If the script is outside the allowed directory, either:
- Copy the script into `/opt/data/scripts/` (recommended)
- Update the job's workdir to point to the correct location
- Restructure so the canonical script location is within `$HERMES_HOME/scripts`

## 5. Review Cron Job Configuration

Check for common configuration issues:
- **Workdir incorrect** - The job's workdir should point to where the script resides
- **Duplicate jobs** - Multiple jobs with same schedule and deliver target cause conflicts
- **Script ownership** - The script should be owned by `hermes:hermes` and executable (755)

## 6. Test Manually

Run the script directly from the intended workdir to verify it works:

```bash
cd /opt/data/scripts/ai-scoreboard
python3 ai_scoreboard_alerts.py
# Should exit 0 (healthy) or 1 (alert triggered)
```

Then test the delivery wrapper:

```bash
cd /opt/data/scripts/ai-scoreboard
python3 ai_scoreboard_alerts_deliver.py
# Should send message to Discord or report error
```

## 7. Check Gateway Status

While the gateway uses different credentials, it's good to verify overall Discord connectivity:

```bash
hermes gateway status
# Should show discord: connected
```

If the gateway is down, platform delivery will fail regardless of bot token status.

## 8. Review Logs

Check cron output and Hermes logs for additional error details:

```bash
ls /opt/data/cron/output/ | grep <job_id>
cat /opt/data/cron/output/<job_id>/latest.md
```

## Related Issues

- **Telegram API format error** — If Telegram returns `HTTP 400: Bad Request: message text is empty`, the payload is likely JSON-encoded. Use `application/x-www-form-urlencoded` format instead.
- **Script blocked by containment policy** — If the cron job fails with `Blocked: script path resolves outside the scripts directory`, the script's resolved path is outside `$HERMES_HOME/scripts/`. See `references/hermes-cron-containment-policy.md` for diagnostics and fixes.