#!/bin/bash
# Crypto alert wrapper — checks exit code and sends Discord alert if threshold breached

OUTPUT=$(python3 /opt/data/home/.hermes/scripts/crypto_alert.py 2>&1)
EXIT_CODE=$?

if [ $EXIT_CODE -eq 1 ]; then
    # Load Discord bot token from hermes .env and EXPORT for subprocesses
    if [ -f /opt/data/.env ]; then
        source /opt/data/.env
        export DISCORD_BOT_TOKEN
    fi

    if [ -z "$DISCORD_BOT_TOKEN" ]; then
        echo "ERROR: DISCORD_BOT_TOKEN not set in /opt/data/.env" >&2
        exit 1
    fi

    # Discord channel ID (as specified)
    CHANNEL_ID="1498815544898617505"

    # Send via Discord Bot API using Python
    echo "$OUTPUT" | python3 -c "
import sys, os, json, urllib.request
token = os.getenv('DISCORD_BOT_TOKEN')
channel_id = '$CHANNEL_ID'
message = sys.stdin.read()
url = f'https://discord.com/api/v10/channels/{channel_id}/messages'
headers = {
    'Authorization': f'Bot {token}',
    'Content-Type': 'application/json',
    'User-Agent': 'HermesCryptoAlert/1.0 (+https://hermes.dev)'
}
payload = {'content': message}
data = json.dumps(payload).encode('utf-8')
req = urllib.request.Request(url, data=data, headers=headers, method='POST')
try:
    with urllib.request.urlopen(req, timeout=15) as resp:
        pass  # Success
except urllib.error.HTTPError as e:
    body = e.read().decode() if e.read() else 'no body'
    print(f'Discord API HTTP {e.code}: {body}', file=sys.stderr)
except Exception as e:
    print(f'Failed to send Discord message: {e}', file=sys.stderr)
"
fi

# Always exit with the original exit code for monitoring
exit $EXIT_CODE
