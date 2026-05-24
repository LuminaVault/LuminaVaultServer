---
name: ops-sentry
description: Build log monitoring systems that avoid duplicate alerts and false positives. Use when creating cron-based monitoring, log error tracking, or alert deduplication.
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [monitoring, alerts, error-tracking, deduplication]
---

# Ops Sentry - Intelligent Monitoring

Use this skill to build monitoring systems that provide timely, actionable alerts without noise. Focuses on deduplication, context-aware thresholds, and intelligent escalation.

## Core Principles

1. **Alert on anomalies, not raw data** - Detect meaningful deviations
2. **Deduplicate relentlessly** - Same issue, one alert
3. **Context is everything** - Include relevant state, not just error codes
4. **Escalate intelligently** - Priority-based routing, not everything to everyone
5. **Enable self-healing** - Where possible, include remediation steps

## Monitoring Architecture

### Data Collection Layer
```
[Source] → [Parser] → [Enricher] → [Store] → [Evaluator] → [Notifier]
```

### Key Components

#### 1. Source Adapters
- **Log files**: tail -F, journalctl, syslog
- **Metrics**: Prometheus, CloudWatch, custom scripts
- **Business events**: user signups, transaction volumes
- **Synthetic checks**: HTTP endpoints, cron job outputs

#### 2. Enrichment Engine
Add context to raw events:
```python
enricher = {
    "job_name": "morning_brief",
    "expected_duration": "300s",
    "last_success": "2026-05-04T07:00:00",
    "failure_count_24h": 2,
    "impact_users": ["telegram:home", "discord:alerts"],
    "sla": "99.5%"
}
```

#### 3. State Management
Track event state across time:
- **Active issues**: currently open alerts
- **Recent history**: last 24h events for pattern detection
- **Recovery status**: ongoing vs resolved
- **Noise filter**: suppress known transient issues

### Intelligent Alerting Rules

#### Threshold-Based Alerts
```yaml
alerts:
  - name: "high-error-rate"
    metric: "error_count"
    condition: "> 5/min"
    duration: "5m"
    context:
      - "expected_rate: < 1/min"
      - "business_hours: true"
      - "severity: p2"
```

#### Pattern-Based Alerts
- **Consecutive failures**: 3 failed jobs in a row
- **Duration spikes**: Job taking 2x normal time
- **Regression**: Performance drop compared to similar period
- **Anomaly detection**: Statistical outliers

#### Dependency-Aware Alerts
Don't alert on dependent services if root cause is upstream:
```
service_A → service_B → service_C
```
If service_A fails, alert on service_A only, not its dependents.

### Deduplication Strategies

#### 1. Time-Based Windowing
- Same error in same job: 1 alert per 15 minutes
- Different errors in same job: separate alerts
- After 3 alerts in 1 hour, escalate to summary

#### 2. Content-Based Deduplication
- Same error message → one alert
- Similar stack trace → grouped
- Different error types → separate

#### 3. Hierarchical Suppression
```
[Service] → [Instance] → [Job]
```
Alert on service level, suppress instance-level duplicates.

### Escalation Matrix

```
Priority 1 (Critical):
- Immediate SMS + phone call
- Every 5 minutes until acknowledged
- Escalate to backup after 15 minutes

Priority 2 (High):
- Telegram/Discord immediate
- Email summary after resolution
- Escalate after 30 minutes

Priority 3 (Medium):
- Telegram/Discord within 1 hour
- Email summary
- No escalation

Priority 4 (Low):
- Digest only (daily summary)
- No immediate notification
```

### Alert Formatting

#### Critical Error
```markdown
🚨 [CRITICAL] [Job Name] Failed - Immediate Action Required
**🕒 Timestamp:** 2026-05-04 07:05 UTC
**📉 Impact:** Morning briefing not delivered to 5 channels
**🔍 Root Cause:** Yahoo Finance API timeout (5 consecutive failures)
**🛠️ Recovery:** Switched to Alpha Vantage backup - running now
**👥 On-Call:** @oncall (auto-notified)
**⏱️ ETA:** 5 minutes
**👉 Action:** Monitor delivery status
```

#### Warning
```markdown
⚠️ [WARNING] [Job Name] Performance Degradation
**🕒 Timestamp:** 2026-05-04 07:05 UTC
**📉 Impact:** Job taking 3x normal duration (290s vs 90s)
**🔍 Cause:** Network latency to data source
**🛠️ Recovery:** Auto-retry in progress
**⏱️ ETA:** 2 minutes
**👉 Watch:** Next status update at 07:07
```

#### Info/Maintenance
```markdown
ℹ️ [INFO] Scheduled Maintenance - Saturday 2-4 AM UTC
**🕒 Timestamp:** 2026-05-04 07:05 UTC
**🛠️ Work:** System updates and cleanup
**📉 Impact:** Brief interruption expected (<5 min)
**✅ Status:** In progress
**👉 No action needed**
```

## Discord Integration

Discord is a key channel for real-time alerting and team communication. This section covers Discord bot token validation, common error resolutions, channel configuration, and integration testing.

### Discord Bot Token Validation

Discord tokens come in several formats. Recognizing the type is crucial for proper authentication:

```
Token Types:
  - Bot Token: Starts with \"Mj\", \"Bx\", \"MS\", or \"MW\"
    - Format: `Mj[...]....`
    - Usage: `Authorization: Bot <token>`
  - User Token: Starts with \"MT\"
    - Format: `MT[...]....`
    - Usage: `Authorization: <token>` (no \"Bot \" prefix)
  - Webhook Token: Starts with \"https://discord.com/api/webhooks/\" followed by ID and token
```

**Validation Procedure:**

```bash
# 1. Check token format
token=\"YOUR_TOKEN_HERE\"
if [[ $token == MT* ]]; then
    echo \"⚠️ WARNING: This appears to be a USER token, not a BOT token.\"
    echo \"User tokens require NO 'Bot ' prefix in Authorization header.\"
fi

# 2. Test Discord API connectivity
curl -H \"Authorization: Bot $token\" \"https://discord.com/api/v10/users/@me\" 2>&1 | grep -i \"401\\|unauthorized\"

# 3. Verify token works with channel POST
curl -X POST \"https://discord.com/api/v10/channels/CHANNEL_ID/messages\" \
  -H \"Authorization: Bot $token\" \
  -H \"Content-Type: application/json\" \
  --data \"{\\\"content\\\":\\\"Test\\\"\" 2>&1 | grep -E \"200|403|401\"
```

### Common Error Resolutions

#### **401 Unauthorized**
**Meaning**: Authentication failed — token invalid, expired, or incorrect prefix.

**Causes:**
1. Using user token with \"Bot \" prefix (or vice versa)
2. Token has been revoked or regenerated
3. Token contains extra whitespace or formatting issues
4. Using incorrect token type for the operation

**Fix:**
- Verify token format matches usage
- Regenerate token in Discord Developer Portal
- Ensure proper \"Bot \" prefix for bot tokens
- Check for copy-paste errors

#### **403 Forbidden**
**Meaning**: Token is valid but request is denied due to permissions.

**Subtypes:**
- **403 Forbidden (Read Message History)**: Bot lacks Read Message History permission in channel
- **403 Forbidden (Send Messages)**: Bot lacks Send Messages permission
- **403 Forbidden (General)**: Bot not in server or channel, or missing required roles

**Fix:**
- Review bot permissions in Discord Server Settings → Roles
- Ensure bot has \"Send Messages\" permission for posting alerts
- Add \"Read Message History\" if needed for context
- Verify bot is added to the server with appropriate scopes

### Channel Configuration Best Practices

#### Environment Variable Setup

```bash
# In /opt/data/.env
DISCORD_BOT_TOKEN=your_valid_bot_token_here
DISCORD_HOME_CHANNEL=1498025894751768776    # Main channel for regular messages
DISCORD_ALERT_CHANNEL_ID=1499362823342653471 # Dedicated channel for alerts
```

#### Script Configuration

Scripts should use environment variables consistently:

```python
# Good practice
token = os.environ.get('DISCORD_BOT_TOKEN')
home_channel = os.environ.get('DISCORD_HOME_CHANNEL', 'default_channel_id')
alert_channel = os.environ.get('DISCORD_ALERT_CHANNEL_ID', 'default_alert_id')
```

#### Channel ID Management
- **Never hardcode channel IDs** — use environment variables
- Maintain a mapping of channel purposes to IDs
- Document channel purposes in README.md

### Testing Discord Integration

#### Pre-deployment Checklist

```yaml
Pre-flight Check:
  - [ ] Discord bot token is valid and not expired
  - [ ] Bot has \"Send Messages\" permission in target channel
  - [ ] Bot is a member of the Discord server
  - [ ] Channel ID is correct and accessible
  - [ ] Rate limits considered (1 message/second default)
  - [ ] Token format matches usage (Bot prefix vs no prefix)
```

#### Integration Test Script

```python
#!/usr/bin/env python3
\"\"\"Discord Integration Test — Validates bot connectivity and permissions.\"\"\"

import os
import sys
import json
import urllib.request

def test_discord(token, channel_id):
    \"\"\"Comprehensive Discord integration test.\"\"\"
    
    # Test 1: Authentication
    try:
        req = urllib.request.Request(
            \"https://discord.com/api/v10/users/@me\",
            headers={\"Authorization\": f\"Bot {token}\"}
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            if resp.status == 200:
                print(\"✓ Authentication: SUCCESS\")
            else:
                print(f\"✗ Authentication: FAILED (HTTP {resp.status})\")
                return False
    except Exception as e:
        print(f\"✗ Authentication: FAILED ({e})\")
        return False
    
    # Test 2: Channel Access
    try:
        test_msg = {\"content\": \"Discord integration test — please ignore\"}
        payload = json.dumps(test_msg).encode()
        req = urllib.request.Request(
            f\"https://discord.com/api/v10/channels/{channel_id}/messages\",
            data=payload,
            headers={
                \"Authorization\": f\"Bot {token}\",
                \"Content-Type\": \"application/json\"
            }
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            if resp.status in (200, 204):
                print(\"✓ Channel Access: SUCCESS\")
            else:
                print(f\"✗ Channel Access: FAILED (HTTP {resp.status})\")
                return False
    except Exception as e:
        print(f\"✗ Channel Access: FAILED ({e})\")
        return False
    
    print(\"\\n✅ ALL CHECKS PASSED — Discord integration is working!\")
    return True

if __name__ == \"__main\":
    token = os.getenv(\"DISCORD_BOT_TOKEN\")
    channel = os.getenv(\"DISCORD_ALERT_CHANNEL_ID\", \"1499362823342653471\")
    
    if not token:
        print(\"ERROR: DISCORD_BOT_TOKEN environment variable not set!\")
        sys.exit(1)
    
    test_discord(token, channel)
```

### Monitoring and Alerting

#### Discord Health Checks

Implement regular Discord connectivity checks in cron jobs:

```python
# In your delivery wrapper
def check_discord_health():
    \"\"\"Verify Discord is reachable before attempting send.\"\"\"
    try:
        # Simple connectivity test
        urllib.request.urlopen(
            \"https://discord.com/api/v10/channels/1234567890/messages\",
            timeout=5
        )
        return True
    except:
        return False

# Before sending alert
if not check_discord_health():
    log.error(\"Discord API unreachable — skipping alert delivery\")
    # Consider fallback channels (Telegram, Slack, email)
    send_fallback_alert()
    return

# Proceed with Discord send
```

#### Error Logging Best Practices

```python
# Log detailed Discord errors for debugging
try:
    # Discord API call
    pass
except urllib.error.HTTPError as e:
    log.error(f\"Discord HTTP {e.code}: {e.reason}\")
    if e.code == 401:
        log.error(\"Invalid or missing bot token — check DISCORD_BOT_TOKEN\")
    elif e.code == 403:
        log.error(\"Permission denied — check bot roles/permissions\")
    elif e.code == 429:
        log.error(\"Rate limited — implement exponential backoff\")
except urllib.error.URLError as e:
    log.error(f\"Discord connection failed: {e.reason}\")
```

### References

#### Discord API Error Codes
- **200**: OK — Success
- **201**: Created — Resource created
- **204**: No Content — Success with no body
- **400**: Bad Request — Invalid parameters
- **401**: Unauthorized — Authentication failed
- **403**: Forbidden — Valid token but insufficient permissions
- **404**: Not Found — Resource doesn't exist
- **429**: Too Many Requests — Rate limited
- **500+**: Server errors — Discord side issues

#### Token Format Examples
```bash
# Valid bot token (starts with Mj)
MjMTg5NjUyNzQ4NDUzND... (full token 59 chars)

# Invalid user token (starts with MT)
MTg5NjUyNzQ4NDUzND... (full token 59 chars)

# Webhook token format
https://discord.com/api/webhooks/123456789012345678/abcDefGhIjKlMnOpQrStUvWxYz-1234567890
```

#### Channel Permission Checklist
- [ ] Bot has \"Send Messages\" permission
- [ ] Bot has \"Read Message History\" if needed
- [ ] Bot is not blocked by channel-specific overrides
- [ ] Bot role has appropriate permissions
- [ ] Bot is a member of the server
- [ ] Channel ID is correct and exists
```

### Self-Healing Patterns

#### 1. Automatic Retry with Backoff
```python
def run_with_retry(job, max_attempts=3):
    for attempt in range(max_attempts):
        result = job.execute()
        if result.success:
            return result
        time.sleep(2 ** attempt)  # Exponential backoff
    return result  # Return failure for alert
```

#### 2. Fallback Data Sources
```yaml
data_sources:
  primary: yahoo_finance
  backup: alpha_vantage
  tertiary: IEX Cloud

switch_on_failure:
  - condition: primary_timeout > 30s
    action: switch_to(backup)
  - condition: backup_error_rate > 10%
    action: rotate_to(tertiary)
```

#### 3. Graceful Degradation
When primary feature fails, fall back to simplified version:
- Full report → Summary report → Status only
- Real-time data → Cached data → No data

### Monitoring Checklist

#### Daily Health Checks
- [ ] All cron jobs completed successfully
- [ ] Error rate < 1% across all systems
- [ ] Data freshness < 5 minutes
- [ ] Delivery channels responsive
- [ ] Storage < 80% capacity
- [ ] Memory/CPU trends normal

#### Weekly Reviews
- [ ] Alert noise ratio (< 5% duplicate alerts)
- [ ] Mean time to acknowledge (MTTA) < 5 min
- [ ] Mean time to resolve (MTTR) < 30 min
- [ ] False positive rate < 2%
- [ ] System performance trends

#### Monthly Audits
- [ ] Alert rule effectiveness
- [ ] Escalation matrix tuning
- [ ] New failure modes identified
- [ ] Documentation updates

### Implementation Tips

1. **Start simple**: One alert, one channel, clear message
2. **Measure before optimizing**: Track current failure rates
3. **Gradual rollout**: Add alerts one at a time, monitor response
4. **Document everything**: Runbooks for each alert type
5. **Review weekly**: Adjust thresholds based on actual data

### Common Pitfalls

- **Alert fatigue**: Too many alerts → ignored alerts
- **Missing context**: Error code without explanation
- **No clear action**: Alert that can't be acted upon
- **Poor timing**: Non-urgent alerts at 3 AM
- **Duplicate noise**: Same alert from multiple sources
- **Missing escalation**: Critical alerts with no follow-up

### Getting Started Script

```python
# ops_sentry.py - Minimal monitoring setup
import json
import time
from datetime import datetime

class Sentry:
    def __init__(self, config_path):
        with open(config_path) as f:
            self.config = json.load(f)
        self.state = self.load_state()
    
    def check_job(self, job_name, result):
        """Evaluate job result and decide on alert"""
        if not result.success:
            # Deduplicate: only alert if this specific error hasn't been seen recently
            if self.should_alert(job_name, result.error):
                self.send_alert(job_name, result.error)
                self.record_alert(job_name, result.error)
        
        # Update state
        self.update_job_state(job_name, result)
        self.save_state()
    
    def should_alert(self, job_name, error_message):
        """Intelligent deduplication logic"""
        key = f"{job_name}:{error_message}"
        last_alert = self.state.get(key, {"timestamp": 0})
        
        # Don't alert more than once per 15 minutes
        if time.time() - last_alert["timestamp"] < 900:
            return False
        
        # Don't alert if similar error pattern exists
        if self.similar_error_recent(job_name, error_message, window=3600):
            return False
        
        return True

if __name__ == "__main__":
    sentry = Sentry("sentry_config.json")
    # Integrate with your cron jobs
```

### Configuration File Example
```yaml
# sentry_config.yaml
alerts:
  - name: "market_brief_failure"
    job: "morning_brief"
    condition: "exit_code != 0"
    threshold: "3 consecutive failures"
    priority: 2
    channels: ["telegram:home", "discord:alerts"]
    message_template: "cron_error"
    recovery_action: "switch_data_source"
    
  - name: "high_latency"
    metric: "job_duration"
    condition: "> 300s"
    duration: "5m"
    priority: 1
    channels: ["sms:+15551234567", "telegram:oncall"]
    message_template: "performance_warning"
```

### Testing Your Monitoring

1. **Simulate failures** with `exit 1` in cron jobs
2. **Test alert delivery** at different times of day
3. **Verify deduplication** with repeated failures
4. **Check escalation** paths work correctly
5. **Measure response times** from alert to acknowledgment

### When to Use This Skill

- Building new monitoring systems
- Refining noisy alert configurations
- Setting up cron-based health checks
- Creating intelligent notification workflows
- Reducing alert fatigue while maintaining coverage