#!/bin/bash
# Hermes Gateway Health Check Script
# Automated verification of Hermes Gateway status and platform connectivity

set -e

echo "=== Hermes Gateway Health Check ==="
echo "Timestamp: $(date)"
echo "Hostname: $(hostname)"
echo ""

# 1. Check Gateway Service Status
echo "Service Status:"
if systemctl is-active --quiet hermes-gateway; then
    echo "✓ Hermes Gateway service is running"
else
    echo "✗ Hermes Gateway service is NOT running"
    exit 1
fi

# 2. Check Gateway Process
GATEWAY_PID=$(pgrep -f "hermes_cli.main gateway run")
if [ -n "$GATEWAY_PID" ]; then
    echo "✓ Gateway process found (PID: $GATEWAY_PID)"
else
    echo "✗ Gateway process not found"
    exit 1
fi

# 3. Check Platform Connectivity
echo ""
echo "Platform Status:"
GATEWAY_STATE="/root/.hermes/gateway_state.json"
if [ -f "$GATEWAY_STATE" ]; then
    python3 -c "
import json, sys
try:
    with open('$GATEWAY_STATE', 'r') as f:
        state = json.load(f)
    print('Discord:  ' + state['platforms']['discord']['state'])
    print('Telegram: ' + state['platforms']['telegram']['state'])
    print('WhatsApp: ' + state['platforms']['whatsapp']['state'])
    print('Slack:    ' + state['platforms']['slack']['state'])
except Exception as e:
    print(f'Error reading gateway state: {e}')
    sys.exit(1)
"
else
    echo "⚠ Cannot read gateway state file"
fi

# 4. Check WhatsApp Bridge
echo ""
echo "WhatsApp Bridge:"
if ss -tlnp | grep -q ':3000'; then
    echo "✓ Bridge listening on port 3000"
    # Check if bridge is responding
    if curl -s http://127.0.0.1:3000 2>&1 | grep -q "404 Not Found"; then
        echo "✓ Bridge HTTP server responding"
    else
        echo "⚠ Bridge HTTP response unusual"
    fi
else
    echo "✗ WhatsApp bridge not listening on port 3000"
fi

# 5. Check Log Activity
echo ""
echo "Log File Status:"
for LOG in /root/.hermes/logs/gateway.log /root/.hermes/logs/errors.log; do
    if [ -f "$LOG" ]; then
        MOD_TIME=$(stat -c %y "$LOG" | cut -d. -f1)
        echo "  $LOG - last modified: $MOD_TIME"
        # Check if log is being written to
        if lsof -p $(pgrep -f hermes_cli.main) 2>/dev/null | grep -q "$LOG"; then
            echo "         ✓ Process has file open for writing"
        else
            echo "         ⚠ Process does not have file open"
        fi
    else
        echo "  $LOG - MISSING"
    fi
done

# 6. Check for Recent Errors
echo ""
echo "Recent Errors (last 50 lines of errors.log):"
if [ -f "/root/.hermes/logs/errors.log" ]; then
    tail -50 /root/.hermes/logs/errors.log | grep -E "ERROR|WARNING" | head -20
else
    echo "No errors.log file found"
fi

# 7. Check Memory Usage
echo ""
echo "Resource Usage:"
ps aux --sort=-%mem | grep hermes-gateway | head -3

# 8. Final Summary
echo ""
echo "=== Health Check Summary ==="
DISCORD_STATUS=$(python3 -c "import json; s=json.load(open('/root/.hermes/gateway_state.json')); print(s['platforms']['discord']['state'])" 2>/dev/null || echo "UNKNOWN")
TELEGRAM_STATUS=$(python3 -c "import json; s=json.load(open('/root/.hermes/gateway_state.json')); print(s['platforms']['telegram']['state'])" 2>/dev/null || echo "UNKNOWN")
WHATSAPP_STATUS=$(python3 -c "import json; s=json.load(open('/root/.hermes/gateway_state.json')); print(s['platforms']['whatsapp']['state'])" 2>/dev/null || echo "UNKNOWN")

if [[ "$DISCORD_STATUS" == "connected" && "$TELEGRAM_STATUS" == "connected" && "$WHATSAPP_STATUS" == "connected" ]]; then
    echo "✓ All platforms operational"
    exit 0
else
    echo "⚠ Some platforms not connected"
    exit 1
fi