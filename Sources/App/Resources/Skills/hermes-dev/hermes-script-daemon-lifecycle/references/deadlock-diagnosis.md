# Session Reference: Wrapper + Python Infinite Loop Deadlock

**Date**: 2026-05-02  
**Skill**: `hermes-script-daemon-lifecycle`  
**Script**: `x_link_poller_v2.py`  
**Detected by**: Process accumulation + stale logs + file timestamp mismatch

---

## Problem Manifestation

1. Multiple Python poller processes running simultaneously (5 found)
2. Log file stopped updating at 16:03 despite file saves at 16:44
3. Process tree showed:
   - One bash wrapper (PID 54374, PPID=1, `while true` loop)
   - One Python child of wrapper (PID 60198, PPID=54374)
   - Four orphan Python processes (PPID=7, reparented to init)
4. All orphan processes in `Ss` (sleeping) state, stuck on I/O
5. Wrapper blocked waiting for Python to exit; Python never exits (it has its own `while True` + `time.sleep(300)`)

## Root Cause

The wrapper script used:
```bash
while true; do
  echo "=== $(date) ===" >> $LOG
  python3 -u x_link_poller_v2.py 2>&1 | tee -a $LOG
  sleep 120
done
```

The Python script's `__main__`:
```python
if __name__ == "__main__":
  import time
  while True:
    try:
      main()
    except Exception as e:
      log.exception(e)
    log.info("Sleeping 300s before next poll cycle...")
    time.sleep(300)
```

**Deadlock**: Wrapper blocks on `python … | tee` waiting for child to exit. Child never exits because it loops internally. Wrapper never reaches `sleep 120` to spawn next cycle. All subsequent wrapper iterations die with the parent shell.

## Diagnosis Commands

```bash
# 1. Count processes
ps aux | grep '[x]_link_poller' | grep -v grep

# 2. Show parent-child relationships
ps -eo ppid,pid,stat,cmd | grep poller | grep -v grep
# PPID=7 (init/kthreadd) = orphaned (wrapper died)
# PPID=wrapper-PID = actively attached

# 3. Check process tree
ps -ef --forest | grep poller

# 4. Verify log staleness vs file mtime
stat /opt/data/home/.hermes/logs/x_link_poller_$(date +%Y%m%d).log
find /opt/data/obsidian-vault/FACorreia/Raw -name "*X*" -mmin -10 | wc -l
# Files saved recently but log hasn't updated → daemon blocked

# 5. Read state file to see last successful cycle
cat ~/.hermes/state/x_link_poller_state.json | jq '.processed_urls | length'
# Compare against vault file count

# 6. Check wait channel (should be hrtime if sleeping on timer)
ps -p <PID> -o pid,stat,wchan,cmd
# Wchan 'hrtime' = good (sleeping on high-res timer)
# Wchan 'pipe' or 'futex' = stuck on I/O or lock
```

## Resolution Steps

1. **Kill wrapper first** (the blocker):
   ```bash
   kill -TERM <wrapper-pid>  # e.g., 54374
   sleep 1
   kill -9 <wrapper-pid> 2>/dev/null  # if still alive
   ```

2. **Kill orphaned Python children** (no longer supervised):
   ```bash
   # Find all script PIDs
   pkill -f "x_link_poller_v2.py"  # or manual list
   # OR:
   for pid in <pid-list>; do
     kill -TERM $pid 2>/dev/null
   done
   sleep 2
   # Force-kill any remaining
   pkill -9 -f "x_link_poller_v2.py"
   ```

3. **Verify cleanup**:
   ```bash
   ps aux | grep '[x]_link_poller' | grep -v grep
   # Should return empty
   ```

4. **Restart cleanly** (no wrapper!):
   ```bash
   source /opt/data/.env
   nohup python3 -u /opt/data/home/.hermes/scripts/x_link_poller_v2.py \
     > /opt/data/home/.hermes/logs/x_link_poller_$(date +%Y%m%d).log 2>&1 &
   # Or better: use hermectl/systemd
   ```

5. **Confirm health**:
   ```bash
   # Single process
   ps ho pid,stat,etime,cmd | grep poller
   # Recent log
   tail -5 /opt/data/home/.hermes/logs/x_link_poller_*.log
   # If shows "Sleeping 300s", it's in proper daemon loop
   ```

## Prevention

**Do**:
- Run self-daemonizing scripts directly (no outer `while true`)
- Use `nohup`, `disown`, `screen`, `tmux`, or systemd for persistence
- Let the script's internal loop control its cadence
- Monitor with a single `ps | grep` check

**Don't**:
- Nest `while true` inside `while true`
- Assume `sleep` after a backgrounded process means it'll respawn (it won't)
- Leave wrappers running after Python process dies (they become useless zombies)

## Systemd Unit Template (for production)

```ini
[Unit]
Description=Hermes X Link Poller v2
After=network.target

[Service]
Type=simple
User=1000
WorkingDirectory=/opt/data/home/.hermes
EnvironmentFile=/opt/data/.env
ExecStart=/usr/bin/python3 -u /opt/data/home/.hermes/scripts/x_link_poller_v2.py
StandardOutput=append:/opt/data/home/.hermes/logs/x_link_poller_%Y%m%d.log
StandardError=inherit
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Then:
```bash
systemctl --user daemon-reload
systemctl --user enable --now x-link-poller.service
```

This replaces both the wrapper and manual nohup with proper supervisor.

---

## Related Signals in This Session

- **Log timestamp mismatch**: Files updated at 16:44, log last entry 16:03 → poller blocked
- **Multiple PPIDs**: Orphans revealed by PPID=7 vs wrapper-child PPID=54374
- **Wrapper lingering**: Bash `while true` sat idle after Python children died
- **Single clean daemon**: After cleanup, one `Ss` process with `wchan=hrtime` = healthy
