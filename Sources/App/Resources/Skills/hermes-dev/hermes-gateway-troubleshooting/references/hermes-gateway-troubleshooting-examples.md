# Hermes Gateway Troubleshooting Examples

This file contains real troubleshooting transcripts and command patterns from actual sessions.

## **Example 1: Discord/WhatsApp Transient Errors (May 10, 2026)**

### **Initial Evidence**
User submitted a screenshot showing:
- Discord error: `404 Not Found (error code: 10003): Unknown Channel`
- WhatsApp error: `Cannot connect to host 127.0.0.1:3000 ssl:default [Connect call failed ('127.0.0.1', 3000)]`

### **Diagnostic Steps Taken**

#### **Step 1: Analyze the Screenshot**
```bash
vision_analyze(image_url="/root/.hermes/image_cache/img_1a237218f02f.jpg", 
              question="Please analyze the terminal screenshot showing Hermes Agent errors. Focus on the error messages, traceback details, and any configuration information visible. What are the specific errors and their likely causes?")
```

**Findings:**
- Discord error originated at `gateway/platforms/discord.py`, line 1377
- WhatsApp error: connection failed to localhost:3000
- Command executed: `python -m hermes_cli.main gateway run --replace`

#### **Step 2: Check Current Service Status**
```bash
systemctl status hermes-gateway.service -n 50
cat /root/.hermes/gateway_state.json
```

**Findings:**
- Gateway running since 13:08:05 UTC
- Discord: connected
- WhatsApp: connected
- Slack: retrying (SLACK_BOT_TOKEN not set)

#### **Step 3: Verify WhatsApp Bridge**
```bash
netstat -tlnp | grep :3000
curl -v http://127.0.0.1:3000 2>&1 | head -20
```

**Findings:**
- Bridge process (PID 945335) running
- Bridge listening on port 3000
- HTTP server responding (404 Not Found, as expected)

#### **Step 4: Inspect Configuration**
```bash
find /root /opt/data -name "*.yaml" | grep -E "(config|hermes)" | head -5
cat /root/.hermes/state-snapshots/20260510-110311-pre-update/config.yaml | head -600
```

**Findings:**
- Discord configured with `require_mention: true`, `auto_thread: true`
- WhatsApp enabled with `unauthorized_dm_behavior: ignore`
- No explicit channel IDs in config - use channel_directory.json

#### **Step 5: Examine Channel Directory**
```bash
cat /root/.hermes/state-snapshots/20260510-110311-pre-update/channel_directory.json | head -200
```

**Findings:**
- Multiple Discord channels configured (IDs like 1245136372575244392, 1498009007099613285, etc.)
- WhatsApp DM configured (ID: 279379066273903@lid)
- Telegram DM configured (ID: 476978568)

#### **Step 6: Read Gateway Logs**
```bash
tail -100 /root/.hermes/logs/gateway.log
tail -100 /root/.hermes/logs/errors.log
journalctl -u hermes-gateway.service --since "13:00" -n 50 --no-pager
```

**Findings:**
- Discord error at 13:08:06 during gateway restart
- WhatsApp connected at 13:08:16
- No current errors after 13:10

#### **Step 7: Correlate Timeline**
- Screenshot time: 14:10 (from image analysis)
- Last log entry: 13:30:52
- Current time: 13:38
- **Conclusion**: Errors occurred ~40 minutes before screenshot was taken, during gateway restart window

#### **Step 8: Resolution**
- Both issues resolved automatically after gateway restart completed
- Current status: all platforms operational

### **Key Learning**
Transient errors during gateway restarts can appear in screenshots even after they've been resolved. Always check current service status and correlate timestamps.

## **Example 2: Slack Connection Failure**

### **Symptoms**
User reports Hermes not posting to Slack channel.

### **Diagnostic Steps**
1. Check gateway state: `slack` platform shows `retrying` with error `SLACK_BOT_TOKEN not set`
2. Check environment: `.env` file missing Slack token
3. Verify Slack bot configuration in config.yaml
4. Add token to `.env` and restart gateway

### **Fix**
```bash
echo "SLACK_BOT_TOKEN=xoxb-your-token-here" >> /root/.hermes/.env
systemctl restart hermes-gateway
```

## **Example 3: Nous API 502 Errors**

### **Symptoms**
Gateway logs show frequent warnings:
```
WARNING run_agent: API call failed (attempt 1/3) error_type=InternalServerError thread=asyncio_1:136527040476864 provider=nous base_url=https://inference-api.nousresearch.com/v1 model=arcee-ai/trinity-large-thinking summary=HTTP 502: Application failed to respond
```

### **Diagnosis**
- Check Nous API status (external)
- Review gateway retry configuration
- Consider adding fallback model provider

### **Mitigation**
Add fallback model in config.yaml:
```yaml
fallback_providers:
  - provider: openrouter
    model: deepseek/deepseek-v4-flash
    base_url: https://openrouter.ai/api/v1
```

## **Command Patterns Reference**

### **Quick Status Check**
```bash
# One-liner summary
echo "=== Hermes Gateway Status ===" && \
systemctl status hermes-gateway -n 5 && \
echo -e "\n=== Gateway State ===" && \
cat /root/.hermes/gateway_state.json && \
echo -e "\n=== Active Processes ===" && \
ps aux | grep hermes-gateway | grep -v grep
```

### **Log Correlation**
```bash
# Check all logs around a specific time
journalctl -u hermes-gateway --since "13:08" --until "13:12" -n 50
tail -n +$(grep -n "13:08" /root/.hermes/logs/gateway.log | head -1 | cut -d: -f1) /root/.hermes/logs/gateway.log | head -100
```

### **Platform Verification**
```bash
# Check if a specific platform is connected
python3 -c "import json; state = json.load(open('/root/.hermes/gateway_state.json')); print(f\"Discord: {state['platforms']['discord']['state']}\"); print(f\"WhatsApp: {state['platforms']['whatsapp']['state']}\"); print(f\"Telegram: {state['platforms']['telegram']['state']}\")"
```

## **Common Timestamp Issues**

### **Screenshot Time vs. System Time**
- Screenshots may show local time, while logs use UTC
- Always convert times to a common timezone for correlation
- Use `date -u` for UTC, `date` for local time

### **Log Rotation Detection**
If logs appear to stop suddenly:
```bash
# Check if log file was rotated
ls -la /root/.hermes/logs/gateway.log*
find /root/.hermes/logs -name "gateway.log*" -mtime 1

# Check if process still has old log file open
lsof -p $(pgrep -f hermes_cli.main) | grep gateway.log
```

### **Process Still Running But Logs Stopped**
This may indicate:
- Process hung or deadlocked
- Logging configuration changed
- Log file permissions changed
- Process moved to different logging destination (systemd journal)

## **Health Check Script**
See `scripts/hermes-gateway-healthcheck.sh` for automated verification.