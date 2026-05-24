# Hermes Error Timestamp Handling

Guidelines for working with timestamps from different sources (screenshots, logs, system time) during troubleshooting.

## **Timestamp Sources and Formats**

### **1. Screenshot Timestamps**
- Usually show local time in user's timezone
- May include date or be time-only
- Format varies by device/OS
- **Example**: `14:10` (from iPhone screenshot)

### **2. Log Timestamps**
- Hermes logs use ISO 8601 format with timezone
- Example: `2026-05-10 13:08:06,884`
- Includes year, month, day, hour, minute, second, millisecond, timezone offset
- Stored in UTC (typically)

### **3. System Time**
- `date` command shows local time
- `date -u` shows UTC
- File modification times are in local time

## **Time Zone Conversion**

### **Determine Timezone Offsets**
```bash
# Check current timezone
timedatectl status | grep "Time zone"

# Get UTC offset
date +%z

# Convert local to UTC
date -d "14:10" +%s  # seconds since epoch
date -u -d @$(date -d "14:10" +%s) +%H:%M
```

### **Common Conversions**
- UTC is often 4-8 hours behind local time (depending on DST)
- Screenshot at 14:10 local → likely 18:10-22:10 UTC
- Always verify with current timezone setting

## **Correlation Workflow**

### **Step 1: Extract Screenshot Time**
From image analysis or user report, get the time shown.

```python
# Example: extract from vision_analyze output
screenshot_time = "14:10"  # local time
```

### **Step 2: Get Current System Time**
```bash
current_time=$(date +%H:%M)  # local
current_time_utc=$(date -u +%H:%M)  # UTC
```

### **3. Compare with Log Timestamps
Convert all times to a common format (seconds since epoch or UTC).

```bash
# Convert local screenshot time to UTC seconds
screenshot_epoch=$(date -u -d "2026-05-10 $screenshot_time" +%s)

# Get current epoch time
current_epoch=$(date +%s)

# Calculate time difference
time_diff=$((current_epoch - screenshot_epoch))
```

### **4. Interpret the Difference**
- **Negative difference**: screenshot time is in the future (possible timezone mismatch)
- **Positive difference**: screenshot is from past
- **Large positive difference** (>1 hour): significant events may have occurred since

## **Practical Example from This Session**

- Screenshot time: **14:10** (local)
- Current system time: **13:38** (local)
- Wait, that doesn't make sense! Screenshot time is later than current time.

### **Resolution:**
The screenshot was likely taken earlier and the system clock has changed, OR the screenshot was from a different session. Actually, the current time is 13:38, and the last log entry was at 13:30:52. The screenshot showing 14:10 appears to be from a future time or different timezone.

**Key Insight**: When timestamps conflict, trust the log file modification times and systemd journal entries as ground truth. The screenshot time may be inaccurate or from a different context.

## **Troubleshooting Timestamp Issues**

### **Symptom**: Logs appear to stop at a certain time, but process is still running.
**Check**:
```bash
# Verify current time
date

# Check if logs were rotated
ls -la /root/.hermes/logs/gateway.log*

# Check if process still has old log file open
lsof -p $(pgrep -f hermes_cli.main) | grep gateway.log

# Check file modification times
stat /root/.hermes/logs/gateway.log
```

### **Symptom**: Screenshot time doesn't match log times.
**Action**:
1. Determine timezone of screenshot (usually local)
2. Convert all times to UTC for comparison
3. Look for gaps in log coverage
4. Consider that screenshot may have been taken earlier/later than thought

### **Symptom**: Gateway running but no new log entries for hours.
**Check**:
```bash
# Is the process still alive?
ps aux | grep hermes-gateway | grep -v grep

# Is it still writing to logs?
lsof -p $(pgrep -f hermes_cli.main) | grep -E "gateway|errors"

# Has it switched to systemd journal?
journalctl -u hermes-gateway --since "2 hours ago" | tail -20
```

## **Best Practices**

1. **Always note the timezone** when recording screenshot times
2. **Use UTC for log correlation** to avoid timezone confusion
3. **Check multiple log sources** (file logs + systemd journal)
4. **Verify process activity** with `ps` and `lsof`
5. **Document timestamp assumptions** in your investigation notes

## **Common Pitfalls**

- ❌ Assuming screenshot time is current time
- ❌ Forgetting timezone conversions
- ❌ Trusting a single log file as complete record
- ❌ Not verifying that the process is still running
- ✅ Always cross-reference with systemd journal and file modification times

## **Quick Reference Table**

| Source | Format | Timezone | Reliability |
|--------|--------|----------|-------------|
| Screenshot | Local time (e.g., 14:10) | User's device timezone | Medium |
| Hermes logs | ISO 8601 (e.g., 2026-05-10 13:08:06,884) | UTC | High |
| Systemd journal | RFC 3339 (e.g., 2026-05-10T13:08:06Z) | UTC | High |
| File timestamps | Local time | System timezone | Medium |
| `date` command | Local time | System timezone | High |

## **When Timestamps Conflict**

If you encounter contradictory timestamp information:

1. **Trust the logs** - they have precise millisecond resolution and known timezone
2. **Check system clock** - is it accurate? `timedatectl status`
3. **Look for log rotation** - new log file may have different timestamps
4. **Consider the context** - was the screenshot taken during an incident or later?
5. **Document the discrepancy** - note it in your findings

## **Example: Converting Screenshot Time to UTC**

Given:
- Screenshot time: 14:10 (local, assumed Eastern Daylight Time, UTC-4)
- Current UTC offset: -4 hours (EDT)

Calculation:
- Local 14:10 → UTC 18:10 (14 + 4)
- If current UTC time is 17:38, then screenshot was taken about 32 minutes ago

But if the current local time is 13:38, then:
- Local 14:10 is in the future by 32 minutes
- This indicates either:
  - Screenshot time is from a different day
  - Device timezone is different
  - Screenshot is not from current session

**Resolution**: In this case, the screenshot was from a previous incident that occurred at 14:10 on a different day, not from the current time. The gateway had since recovered, but the screenshot captured the problem state.

## **Tools for Timestamp Handling**

```bash
# Convert local time to UTC
date -u -d "14:10" +"%Y-%m-%d %H:%M:%S UTC"

# Convert UTC to local
date -d "2026-05-10 18:10:00 UTC" +"%Y-%m-%d %H:%M:%S"

# Get current time in seconds since epoch
date +%s

# Calculate difference between two times
dateDiff() { expr \( $(date -d "$1" +%s) - $(date -d "$2" +%s) \) / 60; }

# Check timezone
timedatectl | grep "Time zone"
```

## **Summary**
Timestamp correlation is critical when troubleshooting based on screenshots or historical evidence. Always:
1. Extract all available time information
2. Convert to a common timezone (preferably UTC)
3. Cross-reference with log file modification times and systemd journal
4. Document any discrepancies and their likely causes