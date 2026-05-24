---
name: hermes-script-daemon-lifecycle
description: Manage Hermes Python scripts as persistent daemons — deploy, monitor, debug, and clean up infinite-loop scripts without wrapper deadlocks or orphan accumulation.
triggers:
  - "deploy a hermes script as a daemon"
  - "hermes script is running multiple times"
  - "hermes daemon deadlocked"
  - "clean up orphaned hermes processes"
  - "wrapper and python both have while true"
  - "hermes script lifecycle management"
---

This skill covers the full operational lifecycle of long-running Hermes Python scripts: choosing the right daemonization strategy, detecting and resolving wrapper/double-loop deadlocks, monitoring health, and performing clean restarts.

## Core Principle

**Hermes Python scripts are self-daemonizing.** If a script contains `while True: … time.sleep(…)` in its `__main__`, it already manages its own polling cycle. Do NOT wrap it in an outer `while true` bash loop — that creates a deadlock where the wrapper waits forever for the Python process to exit.

✅ **Correct**: Run the Python script directly with nohup/systemd/cron
❌ **Wrong**: `while true; do python script.py; sleep 60; done` when script.py already has its own `while True`

## Quick-Start: Clean Deployment

```bash
# 1. Source environment
source /opt/data/.env

# 2. Run as nohup daemon (writes to log, survives terminal close)
nohup python3 -u /path/to/script.py > /path/to/logfile.log 2>&1 &

# 3. Or use hermectl if available
hermesctl start script.py
```

## Detecting Double-Loop Deadlock

**Symptom**: Multiple Python processes pile up, log stops updating, wrapper's `while true` loop spawns new instances each cycle.

**Diagnosis**:

```bash
# Step 1: List all script processes
ps aux | grep '[x]_script_name' | grep -v grep

# Step 2: Check parent PIDs (PPID)
# - PPID=1 or 7 (init/kthreadd) → orphaned (wrapper died, process reparented)
# - PPID=wrapper-PID → currently attached to wrapper

# Step 3: Examine process tree
ps -ef --forest | grep script_name

# Step 4: Read state file to see last successful cycle
cat ~/.hermes/state/script_state.json | jq .

# Step 5: Check log tail for last "Sleeping Ns" message
tail -20 /path/to/script.log | grep -i sleeping
```

**Classic deadlock pattern**:
```
Wrapper (while true):  python script.py | tee log; sleep 60
  → waits for python to exit
Script (while True):   poll(); sleep(300)
  → never exits
Result: wrapper blocks forever, no new cycles
```

## Cleaning Up Orphaned/Stuck Processes

When you find multiple accumulated Python instances (all `Ss` sleeping, PPID=7):

```bash
# Find all PIDs
PIDS=$(pgrep -f "script_name.py")

# Graceful shutdown first
kill -TERM $PIDS 2>/dev/null
sleep 2

# Force kill any survivors
for pid in $PIDS; do
  if ps -p $pid > /dev/null; then
    kill -9 $pid
    echo "Force-killed PID $pid"
  fi
done

# Verify cleanup
ps aux | grep '[x]_script_name' | grep -v grep
```

## Health Check

After cleanup/deploy, verify:

```bash
# Single daemon running?
ps ho pid,stat,etime,cmd | grep script_name.py

# Should show: Ss (sleeping, multi-thread), not R (running) or Z (zombie)
# Wait channel 'hrtime' = sleeping on timer (good)

# Log recent activity
tail -5 /path/to/script.log

# State file fresh?
stat ~/.hermes/state/script_state.json

# Recent output in vault?
find /opt/data/obsidian-vault -name "*.md" -mmin -10 | head
```

## Wrapper Anti-Pattern Checklist

| Situation | Use wrapper? | Use systemd/cron? | Use nohup direct? |
|-----------|--------------|-------------------|-------------------|
| Script has `while True` loop | ❌ Deadlock | ✅ Preferred | ✅ OK |
| Script runs once and exits | ✅ OK for interval | ✅ Better: cron @reboot + sleep loop | ✅ OK |
| Need automatic restart on crash | ❌ Manual | ✅ systemd `Restart=always` | ❌ Needs supervisor |
| Need log rotation | ❌ Manual | ✅ journald or logrotate | ❌ Manual |

**Key insight**: If the script's `__main__` contains `while True`, treat it as a *daemon* — start it once and let it loop internally. Never nest infinite loops.

## Common Pitfalls

1. **Wrapper + internal loop deadlock** (this session's issue)
   - Wrapper: `while true; do python script.py; sleep 60; done`
   - Script: `while True: work(); sleep(300)`
   - Fix: Remove wrapper, run `python script.py` once with nohup/systemd

2. **Orphan accumulation**
   - Wrapper dies (shell exit, terminal close), children reparent to init (PPID=7)
   - Multiple orphans pile up, all sleeping
   - Fix: Kill all PIDs, restart cleanly without wrapper

3. **Log file stops updating**
   - Cause: wrapper blocked on `wait()`, Python still running but output pipe broken
   - Check: wrapper process state (should be `S` not `Ss`), log file timestamp
   - Fix: kill wrapper, run Python directly

4. **Multiple concurrent pollers (no PID-file locking)**
   - Symptom: duplicate article saves, race conditions on state file, log spam
   - Root cause: script lacks instance coordination; repeated cron/supervisor launches spawn additional daemons
   - Detection:
     ```bash
     # Count instances
     pgrep -f "script_name.py" | wc -l
     # Should be 1
     ```
   - Fix patterns:
     a) **PID-file lock at startup** (preferred):
        ```python
        import fcntl, sys, os
        from pathlib import Path

        def acquire_lock(lock_path: Path) -> None:
            lock_path.parent.mkdir(parents=True, exist_ok=True)
            fp = lock_path.open('w')
            try:
                fcntl.lockf(fp, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fp.write(str(os.getpid()))
                fp.flush()
            except BlockingError:
                try:
                    other_pid = int(fp.read().strip() or 0)
                except:
                    other_pid = None
                log.error(f"Another instance already running (PID {other_pid})")
                sys.exit(1)
            return fp  # keep open for process lifetime

        # Call at start of main()
        lock_fp = acquire_lock(Path('/opt/data/home/.hermes/state/x_link_poller_v2.pid'))
        ```
     b) **Shell wrapper with PID guard** (if script cannot be modified):
        ```bash
        pidfile=/opt/data/home/.hermes/state/x_link_poller_v2.pid
        if [ -e "$pidfile" ] && kill -0 $(cat "$pidfile") 2>/dev/null; then
          echo "Already running PID $(cat $pidfile)"
          exit 1
        fi
        echo $$ > "$pidfile"
        trap 'rm -f "$pidfile"' EXIT
        python3 -u /opt/data/home/.hermes/scripts/x_link_poller_v2.py
        ```
   - Cleanup: kill all PIDs, remove stale PID file, restart with locking

5. **Platform-specific failures masked as daemon health**
   - Symptom: daemon logs "Saved 0 article(s)" repeatedly; state file updates but no vault output
   - Cause: one platform's auth/permission error blocks all content (log shows 403/409 but daemon continues)
   - Detection: monitor per-platform consecutive failure count (see "Platform Failure Monitoring" in Session Learnings)
   - Fix: resolve platform-specific issue; daemon remains healthy overall

## Session Learnings: X Link Poller v2 (2026-05-02)

## Session Learnings: X Link Poller v2 — Instance Leak & Platform Isolation (2026-05-04)

**Context**: Cron-triggered daemon with 300s sleep cycle. Discovered 5 concurrent instances accumulated due to missing PID-file lock after repeated launches.

**Discovery 1: Health check via state file mtime when log capture fails**  
Process `log` tool may return 0 lines even if daemon is healthy (buffering, pipe breaks). Use state file modification time:

```python
import os, datetime
from pathlib import Path

state_path = Path('/opt/data/home/.hermes/state/x_link_poller_state.json')
if state_path.exists():
    age = datetime.datetime.now() - datetime.datetime.fromtimestamp(state_path.stat().st_mtime)
    if age.total_seconds() < 320:  # less than poll cycle + grace
        log.info("State file recent — daemon is cycling (healthy)")
    else:
        log.error("State file stale — daemon may be hung or crashed")
```

**Discovery 2: Instance cleanup recipe** (used today)

```bash
# 1) Enumerate with start times to identify oldest (stale) instances
ps -eo pid,lstart,cmd | grep '[x]_link_poller_v2.py' | sort -k1 -n

# 2) Keep newest PID (highest number), terminate all older ones
old_pids=(10126 10261 10860 11301)  # replace with actual list
kill -TERM $old_pids
sleep 2
# Force-kill any that didn't exit
for pid in $old_pids; do
  if ps -p $pid > /dev/null; then kill -9 $pid; fi
done

# 3) Verify single instance remains
pgrep -f "x_link_poller_v2.py" | wc -l   # should print 1
```

**Discovery 3: Platform Failure Monitoring**  
Track per-platform consecutive failures to detect silent starvation (add inside poll loop):

```python
platform_stats = {
    'discord': {'consecutive_failures': 0, 'last_success': None},
    'telegram': {'consecutive_failures': 0, 'last_success': None},
    'slack':    {'consecutive_failures': 0, 'last_success': None},
}

# After each platform fetch block:
if messages_found:
    platform_stats[platform]['consecutive_failures'] = 0
    platform_stats[platform]['last_success'] = datetime.datetime.now().isoformat()
else:
    platform_stats[platform]['consecutive_failures'] += 1
    if platform_stats[platform]['consecutive_failures'] >= 3:
        log.error(f'{platform} failing consecutively — verify token/channelID/permissions')
        # Optional: send alert or update state for external monitoring
```

**Boundary condition**: A single platform's HTTP 403/409 does NOT kill the daemon; it logs an error and continues. Overall daemon health is separate from per-platform health. Always check per-platform stats, not just aggregate "Saved 0 articles".

**Discovery 4: Platform-specific error isolation matrix**

| Error Code | Platform | Root Cause | Remediation |
|------------|----------|------------|-------------|
| `HTTP 403 Forbidden` | Discord | Bot lacks "Read Message History" permission in channel | 1) Add permission in channel settings<br>2) Regenerate token if rotated<br>3) Verify channel ID is a text channel (not thread) |
| `HTTP 409 Conflict` | Telegram | Webhook active (mutually exclusive with long-poll) | `curl -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/deleteWebhook"` |
| `HTTP 403/404` | Slack | Token missing `channels:history` scope or wrong channel ID | Verify app scopes; confirm channel ID via `conversations.list` |

**Key lesson**: Daemon "healthy" ≠ "productive". Always drill into per-platform logs when aggregate saves are zero state file isn't advancing.

## Integration with Hermes

**Context**: Running the poller as a cron-triggered Hermes daemon on a 300-second poll cycle. Script is self-daemonizing (contains `while True: … time.sleep(300)`).

**Discovery 1: Terminal-based daemon launch required**  
`execute_code` has a hard 300s timeout and cannot host long-running processes. The correct approach is the `terminal` tool with daemon flags:

```python
terminal(
  command="python3 -u /opt/data/home/.hermes/scripts/x_link_poller_v2.py 2>&1",
  background=True,
  notify_on_complete=False,
  pty=False,
  workdir="/opt/data/home/.hermes"
)
```

**Why**: `pty=False` avoids pseudo-terminal buffering; `background=True` detaches; output streams are captured separately via `process` tool. Never use `execute_code` for infinite-loop scripts.

**Discovery 2: Output-capture fallback when process log is empty**  
The `process log` command may return 0 lines even when the daemon is healthy (buffering, pipe issues). Instead:

1. Check log files on disk: `/opt/data/home/.hermes/logs/x_link_poller_YYYYMMDD.log`
2. Check state file mtime: `stat ~/.hermes/state/x_link_poller_state.json`
3. If state mtime advanced since last check, daemon is cycling
4. Verify vault output: `find /opt/data/obsidian-vault/FACorreia/Raw -name "*.md" -mmin -10`

**Discovery 3: Platform-specific failure isolation (Discord 403 case)**  
Poller can report `HTTP 403 Forbidden` for a single platform while others work. This is NOT a script-wide failure.

**Diagnostic pattern**:
```bash
# 1) Read latest poller log lines
tail -50 /opt/data/home/.hermes/logs/x_link_poller_$(date +%Y%m%d).log | grep -E "ERROR|403|Forbidden"

# 2) Check token presence in environment
grep DISCORD_BOT_TOKEN /opt/data/.env

# 3) Verify state file updates despite errors
jq .processed_urls_count ~/.hermes/state/x_link_poller_state.json

# 4) Common causes matrix:
#    - Missing "Read Message History" permission in Discord channel
#    - Bot token regenerated (old token invalid)
#    - Channel ID is a thread (requires different endpoint)
#    - OAuth2 scope missing "bot" or "applications.commands"
```

**Remediation**: Regenerate Discord bot token, ensure bot role has `Read Message History` in channel, verify channel ID type. Restart poller after token update.

**Pattern: State-Vault Consistency Check**

When daemon writes to both state and vault, validate integrity:

```bash
python3 -c "
import json, re, pathlib
state = json.load(open(pathlib.Path.home() / '.hermes/state/x_link_poller_state.json'))
vault = pathlib.Path('/opt/data/obsidian-vault/FACorreia/Raw')
missing = []
for uid, info in state.get('processed_urls', {}).items():
  m = re.search(r'status.*?(\\d+)', info['url'])
  if m:
    tid = m.group(1)
    if not any(tid in f.name for f in vault.rglob('*.md')):
      missing.append(info['url'])
print(f'Missing from vault: {len(missing)}')
for u in missing[:5]: print(f'  {u}')
"
```

If >0 missing, reset state: `rm ~/.hermes/state/x_link_poller_state.json` — script re-fetches on next cycle.

**Pattern: Platform Failure Monitoring** (to be added to script)

Track per-platform success to detect silent starvation:

```python
platform_stats = {
  'discord': {'consecutive_failures': 0, 'last_success': None},
  'telegram': {'consecutive_failures': 0, 'last_success': None},
  'slack':    {'consecutive_failures': 0, 'last_success': None},
}

# After each platform fetch:
if messages_found:
  platform_stats[platform]['consecutive_failures'] = 0
  platform_stats[platform]['last_success'] = datetime.now().isoformat()
else:
  platform_stats[platform]['consecutive_failures'] += 1
  if platform_stats[platform]['consecutive_failures'] >= 3:
    log.error(f'{platform} failing consecutively — check token/channelID/permissions')
```

## Integration with Hermes

Hermes scripts typically:
- Source `/opt/data/.env` for credentials
- Write state to `~/.hermes/state/{script}_state.json`
- Write logs to `/opt/data/home/.hermes/logs/{script}_{%Y%m%d}.log`
- Save output to `/opt/data/obsidian-vault/FACorreia/Raw/{topic}/`

Follow this convention for new Hermes daemons.

## References

See `references/deadlock-diagnosis.md` for the full session transcript of this pattern's discovery and cleanup.
See `references/x-link-poller-v2-diagnostics.md` for a complete case study: multi-instance detection, state-vault integrity, platform failure isolation, and duplicate output prevention.
See `scripts/poller_healthcheck.py` — a ready-to-run diagnostic covering instance count, state freshness, vault output, log recency, and state-vault consistency.
See `references/discord-403-troubleshooting.md` for the specific diagnostic and remediation pattern when a Discord bot returns HTTP 403 Forbidden during polling (auth, permissions, channel-type issues).
See `references/systemd-hermes-service-template.md` for a production hermectl-compatible unit file.
See `templates/systemd-hermes-service.service` for the unit file template.
