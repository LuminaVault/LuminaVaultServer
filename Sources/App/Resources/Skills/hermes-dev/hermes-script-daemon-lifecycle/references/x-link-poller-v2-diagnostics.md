# X Link Poller v2 — Session Diagnostics (2026-05-02)

## Problem

After launching the poller via cron, logs showed no activity after initial startup message. Process was running but silent.

## Diagnosis Steps

### 1. Check basic connectivity

```bash
curl -s -o /dev/null -w '%{http_code}' -m 10 \
  "https://discord.com/api/v10/channels/1498030416496558150/messages?limit=50"
# → 403 (auth failure)

curl -s -o /dev/null -w '%{http_code}' -m 10 \
  "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getUpdates?limit=100&timeout=5"
# → 200 (OK, takes ~5s due to long-poll timeout)

curl -s -o /dev/null -w '%{http_code}' -m 10 \
  "https://slack.com/api/conversations.history?channel=C0B0BDGEJTT&limit=50"
# → 200 (OK)
```

Discord returning 403 meant the bot token lacked channel read permissions.

### 2. Check process state and output

```bash
# Check if process alive and its state
ps -p 62764 -o state,etime,cmd
# → S  (sleeping, not crashed)

# No stdout captured by Hermes process manager
# Restart with explicit log capture
python3 -u /opt/data/home/.hermes/scripts/x_link_poller_v2.py 2>&1 | tee /tmp/x_poller_v2.log &
```

Resulting log revealed:
```
INFO === X Link Poller v2 starting ===
INFO Credentials → Discord:OK, Telegram:OK, Slack:OK, OpenRouter:OK
INFO Polling discord...
ERROR HTTP 403 fetching ...: Forbidden
INFO No messages on discord
INFO Polling telegram...
INFO No messages on telegram
INFO Polling slack...
INFO === Poll done. Saved 0 article(s) ===
INFO Sleeping 300s before next poll cycle...
```

### 3. Check environment loading

Verified `.env` at `/opt/data/.env` contains all 4 required tokens. Script's `load_hermes_env()` reads it correctly. The 403 was not a credential loading issue but a Discord server permission issue.

### 4. Check vault vs state mismatch

```python
from pathlib import Path
import json, re

state = json.loads(Path.home().joinpath('.hermes/state/x_link_poller_state.json').read_text())
vault = Path('/opt/data/obsidian-vault/FACorreia/Raw')

for uid, info in state['processed_urls'].items():
  tweet_id = re.search(r'status[/:](\d+)', info['url']).group(1)
  if not any(tweet_id in f.name for f in vault.rglob('*.md')):
    print(f"MISSING: {info['url']}  title={info['title'][:50]}")
```

Output: 8 of 9 state URLs missing from vault.
- 7 were `"X Article (Protected)"` (auth wall, r.jina.ai returned placeholder)
- 2 were fixupx.com shares

The Edward Sanchez article (20499071...) existed twice (AI + Dev/Swift) due to dual-topic classification.

### 5. Check for multiple poller instances

```bash
ps aux | grep x_link_poller_v2.py | grep -v grep
# → 3 distinct PIDs all sleeping (Ss)
```

Caused by cron launching the script repeatedly while previous cycles were still running (cron interval < script's 300s sleep). No wrapper deadlock — just overlapping cron-triggered runs.

## Fixes Applied

1. **Killed duplicate instances**: `pkill -f x_link_poller_v2.py` (x3), then restarted single clean daemon.
2. **Created this reference** to document the detection pattern.
3. **Discord 403 requires separate fix**: update bot token or channel permissions outside this script.

## Key Learnings

- **Never assume** API credentials are valid — add explicit HTTP status logging per platform.
- **State-vault divergence** is real: files deleted/moved but state not cleared. Periodic integrity check recommended (weekly).
- **Duplicate topic classification** saves same URL twice. Mitigation: check filesystem for filename collision before write.
- **Self-daemonizing scripts should still guard against concurrent instances** if launched from cron. Add PID-file or process-count check at startup.

## Reusable Commands

```bash
# Current poller status (single PID expected)
pgrep -f "x_link_poller_v2.py" | xargs -r ps -o pid,ppid,stat,etime,cmd -p

# Force cleanup all instances (use carefully)
pkill -TERM -f "x_link_poller_v2.py"; sleep 2; pkill -9 -f "x_link_poller_v2.py"

# State-vault integrity scan
python3 -c "$(cat <<'PY'
import json, re, pathlib
state = json.load(open(pathlib.Path.home() / '.hermes/state/x_link_poller_state.json'))
vault = pathlib.Path('/opt/data/obsidian-vault/FACorreia/Raw')
missing = []
for uid, info in state.get('processed_urls', {}).items():
  tid_match = re.search(r'status[/:](\d+)', info['url'])
  if not tid_match: continue
  tid = tid_match.group(1)
  if not any(tid in f.name for f in vault.rglob('*.md')):
    missing.append(info['url'])
print(f'State-vault mismatch: {len(missing)} missing files')
for u in missing[:10]: print(f'  {u}')
PY
)"

# Reset state if vault was reorganized (forces re-fetch)
rm ~/.hermes/state/x_link_poller_state.json
```

## Follow-Up Actions

- [ ] Fix Discord bot token/permissions to restore primary data source
- [ ] Add `os.getpid()` write to `/tmp/x_link_poller_v2.pid` for single-instance lock
- [ ] Add state-vault integrity check to weekly maintenance script
- [ ] Deduplicate output by checking `RAW_VAULT/{topic}/` for filename collisions pre-save
- [ ] Add per-platform success counters to detect silent failures (e.g., Discord 0 messages for >10 cycles)

## Session Learnings: X Link Poller v2 — Re-deploy & Deep-Dive (2026-05-03)

**Context**: Poller had been running silently since May 2 with zero articles saved. After killing all instances and restarting fresh, full platform diagnostics were captured.

### Discovery 4: Telegram 409 Conflict ≠ Webhook (Initial False Positive)

**Symptom**: Poller logs `HTTP 409 Conflict: terminated by other getUpdates request; make sure that only one bot instance is running`

**First hypothesis** (from 2026-05-02 diagnostics): Webhook conflicts with long-poll.
```bash
curl -X POST 'https://api.telegram.org/bot<TOKEN>/deleteWebhook'
```

**Actual finding**: Webhook was already deleted (`url: ""`). The 409 persisted across restarts even after explicit `deleteWebhook(drop_pending=True=False)` and 20s cooldown.

**Root cause**: **Another distinct process** using the same `TELEGRAM_BOT_TOKEN` was continuously holding a long-poll session. Telegram does not permit two simultaneous `getUpdates` calls for the same bot — whichever instance called `getUpdates` first owns the update stream; subsequent callers receive 409.

**Detection pattern**:
```python
import requests

token = "<TELEGRAM_BOT_TOKEN>"

# Test 1: Check webhook status (irrelevant if already deleted)
r = requests.get(f"https://api.telegram.org/bot{token}/getWebhookInfo", timeout=10)
print(r.json()['result']['url'])  # "" if no webhook

# Test 2: Attempt a fresh getUpdates with short timeout
r = requests.get(f"https://api.telegram.org/bot{token}/getUpdates",
                 params={'limit': 5, 'timeout': 2}, timeout=10)
data = r.json()
if not data.get('ok') and data.get('error_code') == 409:
    print("CONFLICT: Another getUpdates holder is active")
```

**Diagnostic hunt for the conflicting process**:
```bash
# Find any Python process that might source the same .env
ps aux | grep '[p]ython'  # look for unrelated Hermes subagents

# Check recent Hermes sandbox processes (short-lived)
ps aux | grep hermes_sandbox

# Audit Hermes scripts directory for other Telegram users
grep -r "TELEGRAM_BOT_TOKEN" /opt/data/home/.hermes/scripts/
```

**In this session**: The conflict was traced to transient Hermes subagents (short-lived `/tmp/hermes_sandbox_*/script.py` processes). These are spawned by Hermes for isolated skill execution and inherit the parent environment including the Telegram token. When any subagent calls `getUpdates` (e.g., a social media skill), it blocks the poller.

**Resolution path**:
1. **Stop all Telegram-using processes** including subagents: `pkill -f "x_link_poller_v2.py"` and wait for any subagents to naturally exit.
2. **Wait for Telegram session to fully clear** (updates lock times out ~30–60s after the holder exits).
3. **Verify** with a direct `getUpdates` call returns `ok=True`.
4. **Restart poller as single daemon**.

**Mitigation going forward**: Ensure the poller is the **only long-running Telegram client** for this bot token. If other skills need Telegram access, they should use the bot token *short-lived* (fetch then exit) or coordinate via a shared message bus.

---

### Discovery 5: Discord 403 — Permission vs Token (Channel-Specific Diagnosis)

**Symptom**: `HTTP 403 Forbidden` on Discord API call: `GET /channels/{channel_id}/messages`

**Initial confusion**: Script reports `Credentials → Discord:OK`, suggesting token present, but API returns 403.

**Key distinction**: Discord OAuth2 scopes are granted at the **application level**, but permissions are enforced at the **server + channel level**.

**Diagnostic sequence**:
1. **Verify token loads from `.env`**:
   ```python
   # Script does this automatically via load_hermes_env()
   # Check the actual channel ID being used:
   import os
   channel = os.getenv("DISCORD_MONITOR_CHANNEL", "1498030416496558150")
   print(f"Target channel: {channel}")
   ```
   Important: Channel IDs in `.env` with `export` prefix ARE read correctly; `os.getenv()` strips `export` automatically.

2. **Check bot role permissions in Discord server**:
   - Server Settings → Roles → Find your bot's role
   - Ensure role has: **"View Channel"** + **"Read Message History"**
   - **Channel-level overrides** → #hermes channel → Permissions → Add bot role → `Read Message History: ✓`

3. **Common misconfigurations**:
   - Bot can *send* messages (has `Send Messages`) but cannot *read* (`Read Message History` missing)
   - Bot token was regenerated — old token still in `.env` (would cause 401, not 403)
   - Channel is a **thread** — requires `GET /channels/{thread_id}/messages` with different permissions

**Current configuration** (this session):
```
DISCORD_BOT_TOKEN: MTQ5OD...  (valid format)
DISCORD_MONITOR_CHANNEL: 1498025894751768776  (home channel ID)
```
Status: bot token present and well-formed, but server permission **"Read Message History"** not granted → 403.

**Remediation** (external to script):
- Add bot role to #hermes channel with `Read Message History` enabled
- After fix, poller will automatically succeed on next cycle (state file updated on next successful fetch)

---

### Discovery 6: Slack API Works but Content May Be Empty

**Symptom**: Slack API returns `ok=True`, 5 messages, but 0 contain X URLs.

**Diagnostic**: This is a content-level issue, not a connectivity/credentials problem. The Slack home channel (`C0B0BDGEJTT`) simply has no recent X URLs.

**Pattern**: Always log per-platform message counts and URL extraction results:
```python
messages = fetch_slack_messages()
x_urls = extract_x_urls_from(messages)
log.info(f"Slack: {len(messages)} msgs, {len(x_urls)} X URLs")
```

This distinguishes "broken API" from "quiet channel".

---

### Discovery 7: Single-Instance Enforcement Pattern (Telegram-Specific)

Because Telegram strictly enforces single `getUpdates` holder, the poller should:
1. **Write a PID file** on startup: `open('/tmp/x_link_poller_v2.pid','w').write(str(os.getpid()))`
2. **On startup**, check for existing PID file and verify if that process is still alive and owns the Telegram session (by directly attempting `getUpdates` — if it returns 409, another holder exists regardless of PID file).
3. **If conflict detected**, exit with clear message: "Telegram session held by another process — check for concurrent Hermes subagents."

**Proactive check before polling**:
```python
def ensure_telegram_available():
    """Return True if we can acquire the getUpdates lock; False otherwise."""
    try:
        r = requests.get(f"https://api.telegram.org/bot{TOKEN}/getUpdates",
                         params={'limit': 1, 'timeout': 1}, timeout=5)
        return r.json().get('ok', False)
    except:
        return False
```

If `False`, skip Telegram this cycle and retry next cycle rather than logging an error and continuing.

---

### Discovery 8: Log Capture Best Practice from Session

**Issue**: `process.log` tool returned 0 lines even when daemon healthy; `process.wait()` timed out after 300s.

**Pattern**: When launching a self-daemonizing script, **immediately tee output to a file** and watch the file:
```bash
terminal(
  background=True,
  notify_on_complete=False,
)
# Then: tail -f /tmp/x_poller_current.log
```

For post-run inspection:
```python
from pathlib import Path
log = Path('/tmp/x_poller_current.log')
if log.exists():
    print(log.read_text().splitlines()[-20:])
```

**Why**: The `process` tool tracks the initial shell wrapper's stdout, but when using `| tee`, only the wrapper's output is captured; the Python process writes directly to the log file.

---

### Updated Follow-Up Actions

- [ ] **Discord**: Grant bot role "Read Message History" in #hermes (channel permissions override)
- [ ] **Telegram**: Audit Hermes for concurrent `getUpdates` users; ensure poller is sole long-running Telegram client
- [ ] **State-vault integrity**: Deploy weekly scan script (`healthcheck-hermes-daemon.py` extended to cross-check)
- [ ] **Deduplication**: Add filename collision check before `save_to_vault()`
- [ ] **Platform monitoring**: Track per-platform consecutive failures; alert on >=3
- [ ] **PID file**: Add `/tmp/x_link_poller_v2.pid` to detect stale lock
- [ ] **Proactive Telegram availability**: Wrap Telegram fetch in `ensure_telegram_available()` guard
- [ ] **Logging**: Add per-platform message and URL counts to cycle summary

---

## Artifacts

- State file: `~/.hermes/state/x_link_poller_state.json`
- Vault raw: `/opt/data/obsidian-vault/FACorreia/Raw/`
- Script: `/opt/data/home/.hermes/scripts/x_link_poller_v2.py`
- Log: `/tmp/x_poller_launch.log` (this session's capture)
