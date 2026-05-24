---
name: hermes-gateway-troubleshooting
displayName: Hermes Gateway Troubleshooting
version: 1.0.0
description: Systematic diagnosis of Hermes Gateway platform issues across Discord, WhatsApp, Slack, and other messaging platforms.
---

# Hermes Gateway Troubleshooting

A systematic approach to diagnosing Hermes Gateway issues across Discord, WhatsApp, Slack, and other platforms. This skill captures the methodology used to investigate the transient errors shown in the May 10, 2026 screenshot.

## **Trigger Conditions**
Use this skill when:
- Hermes Gateway produces platform-specific errors (Discord, WhatsApp, Slack, etc.)
- Multiple error sources conflict (screenshot vs. current state)
- Need to correlate logs across different time ranges
- Investigating service connectivity issues (bridge services, API calls)
- Diagnosing intermittent or transient failures

## **Step-by-Step Methodology**

### **1. Analyze Error Evidence**
Start with whatever evidence is available (screenshot, error message, user report).

```bash
# For images: use vision_analyze to extract error details
vision_analyze(image_url, question="Please analyze the terminal screenshot showing Hermes Agent errors. Focus on the error messages, traceback details, and any configuration information visible. What are the specific errors and their likely causes?")
```

Document:
- Exact error messages and stack traces
- Timestamp from screenshot/status bar
- Platform(s) affected
- Error codes and HTTP status codes

### **2. Check Current Service Status**
Verify which components are running.

```bash
# Check gateway service status
systemctl status hermes-gateway.service

# Check individual platform connections via gateway state
cat /root/.hermes/gateway_state.json 2>/dev/null || cat /root/.hermes/state-snapshots/*/gateway_state.json | tail -20
```

Look for:
- `state` field for each platform (connected, retrying, disconnected)
- `error_code` and `error_message` fields
- `updated_at` timestamps to determine freshness

### **3. Verify Platform Dependencies**
Check that required services are running.

```bash
# Check WhatsApp bridge (port 3000)
netstat -tlnp | grep :3000 || ss -tlnp | grep :3000
curl -v http://127.0.0.1:3000 2>&1 | head -20

# Check other platform-specific services as needed
```

### **4. Inspect Configuration Files**
Locate and examine Hermes configuration.

```bash
# Find config files
find /root /opt/data -name "*.yaml" -o -name "*.yml" | grep -E "(config|hermes)" | head -10

# Read the most recent config
cat /root/.hermes/state-snapshots/*/config.yaml | head -600
```

Key sections to review:
- `discord:` settings (channel_prompts, require_mention, auto_thread)
- `whatsapp:` settings (enabled, unauthorized_dm_behavior)
- `slack:` settings (SLACK_BOT_TOKEN presence)
- `gateway:` timeout and retry configurations

### **5. Examine Channel Directory**
Identify valid channel IDs and their types.

```bash
# Find channel directory
find /root/.hermes/state-snapshots -name "channel_directory.json" | tail -1
cat /root/.hermes/channel_directory.json 2>/dev/null || cat /root/.hermes/state-snapshots/*/channel_directory.json | head -200
```

Look for:
- Platform-specific channel lists
- Channel IDs, names, types (channel, dm, thread)
- Guild/Server information for Discord

### **6. Read Gateway Logs Systematically**
Check logs in chronological order, correlating timestamps.

```bash
# Recent gateway logs
tail -100 /root/.hermes/logs/gateway.log

# Errors log
tail -100 /root/.hermes/logs/errors.log

# Systemd journal for gateway
journalctl -u hermes-gateway.service --since "2 hours ago" -n 50 --no-pager
```

Critical timestamps to match:
- Screenshot time (from image analysis)
- Last log entry time
- Current system time
- Platform `updated_at` fields

### **7. Check Process Activity**
Verify the gateway is still running and active.

```bash
# Check if gateway process is alive
ps aux | grep hermes-gateway | grep -v grep

# Check what files the process has open
lsof -p $(pgrep -f "hermes_cli.main gateway run") | grep -E "log|gateway|errors"
```

### **8. Correlate Findings**
Build a timeline of events:

1. Screenshot time → what was happening then?
2. Last successful log entry → what was working?
3. Current status → what's working now?
4. Error patterns → are they isolated, recurring, or ongoing?

### **9. Common Fixes**
Based on typical root causes:

#### **Discord "Unknown Channel" Errors**
- **Fix**: Verify bot permissions in Discord server
- **Check**: Bot has "View Channel" permission for the channel ID in use
- **Verify**: Channel ID is correct and channel still exists
- **Action**: Re-invite bot if necessary, update channel ID in configuration

#### **WhatsApp Connection Errors**
- **Fix**: Ensure WhatsApp bridge is running
- **Check**: Bridge service on port 3000 is listening
- **Verify**: Bridge mode matches configuration (self-chat vs bot)
- **Action**: Restart bridge if needed: `systemctl restart hermes-whatsapp-bridge`

#### **Slack Connection Errors**
- **Fix**: Set SLACK_BOT_TOKEN in environment
- **Check**: `.env` file or environment variables contain valid token
- **Verify**: Bot is invited to the correct Slack workspace
- **Action**: Add token and restart gateway

### **10. Document Resolution**
When issue is resolved:
- Update user on current status
- Note any configuration changes made
- Suggest monitoring for recurrence
- Recommend preventive measures (e.g., fallback providers)

## **Pitfalls to Avoid**

1. **Don't trust a single log source** - correlate gateway.log, errors.log, and systemd journal
2. **Watch for log rotation** - current log may have been recently created
3. **Timestamp awareness** - screenshots may be from different time periods
4. **Process vs. logs mismatch** - a running process may have stopped logging
5. **Configuration drift** - check multiple config snapshots for recent changes

## **Verification Steps**
Before declaring success:
- [ ] All affected platforms show connected state in gateway_state.json
- [ ] No recent error entries in logs for the affected platforms
- [ ] Service dependencies are running (bridge services, API connections)
- [ ] Configuration files contain valid settings
- [ ] User confirms resolution of original issue

## **References**
- `references/hermes-gateway-troubleshooting-examples.md` - Contains transcript examples and command patterns
- `references/hermes-error-timestamp-handling.md` - Guidelines for handling timestamps from screenshots
- `scripts/hermes-gateway-healthcheck.sh` - Automated health check script