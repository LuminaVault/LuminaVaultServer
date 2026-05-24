# Cron Script Debugging — Session Notes

## Case: x-link-poller v2 Syntax Failure

**Date:** 2026-05-02  
**Script:** `/opt/data/home/.hermes/scripts/x_link_poller_v2.py`  
**Cron Job ID:** `faf8329b351b`  
**Schedule:** `*/15 * * * *` (every 15 minutes)

---

## Symptoms

- Manual trigger via `hermes cron run faf8329b351b` succeeded (job queued)
- `hermes cron tick` produced no output and no output file under `/opt/data/cron/output/faf8329b351b/`
- Script appeared to parse incorrectly; subsequent checks revealed malformed Python syntax

---

## Root Cause

The script contained two redaction-induced syntax errors from Hermes credential masking:

### 1. Malformed OpenRouter Assignment (line 28)

**Observed in file:**
```python
OPENROUTER_API_KEY=os.get...EY")
```

**Problem:** Assignment without spaces around `=`, and truncated `os.getenv` call. This is not valid Python — it would raise `SyntaxError: invalid syntax`.

**Fix:**
```python
OPENROUTER_API_KEY = os.getenv("OPENROUTER_API_KEY", "").strip()
```

### 2. Malformed `PLATFORM_TOKENS` Dictionary (lines 50–54)

**Observed in file:**
```python
PLATFORM_TOKENS=***
    "discord":  (os.getenv("DISCORD_BOT_TOKEN") or "").strip(),
    "telegram": (os.getenv("TELEGRAM_BOT_TOKEN") or "").strip(),
    "slack":    (os.getenv("SLACK_BOT_TOKEN") or "").strip(),
}
```

**Problem:**
- The `***` placeholder concatenated directly to `PLATFORM_TOKENS=` with no space or newline between
- Missing opening `{` before the dict literal
- Result: `SyntaxError: invalid syntax` at import time

**Fix:**
```python
PLATFORM_TOKENS = {
    "discord": (os.getenv("DISCORD_BOT_TOKEN") or "").strip(),
    "telegram": (os.getenv("TELEGRAM_BOT_TOKEN") or "").strip(),
    "slack": (os.getenv("SLACK_BOT_TOKEN") or "").strip(),
}
```

---

## Redaction Artifact Pattern

Hermes masks real credential values in script files with `***` placeholders. In properly formatted Python, this appears on its own line:

```python
PLATFORM_TOKENS = {
    "discord": (os.getenv("DISCORD_BOT_TOKEN") or "").strip(),  # <- real logic on separate lines
    ...
}
```

When the original assignment is compressed (no newline after `=***`), the mask corrupts the syntax:

```
PLATFORM_TOKENS=***    "discord": ...
```

**Detection:** `python3 -m py_compile /opt/data/home/.hermes/scripts/<script>.py`  
**Always validate after editing or deploying a new script.**

---

## Hermes Cron Execution Flow

1. **Job definition**: Stored in `/opt/data/cron/jobs.json` (in the Hermes-controlled data dir)
2. **Trigger**: `hermes cron run <job_id>` marks job as ready
3. **Tick**: `hermes cron tick` (or daemon background thread) calls `_run_job_script(script_path)`
4. **Script path resolution**: Must be inside `HERMES_HOME/scripts/`; relative paths are resolved there
5. **Execution**: `subprocess.run([sys.executable, str(path)], ...)`
6. **Output capture**: stdout/stderr are redacted then saved to `/opt/data/cron/output/<job_id>/<timestamp>.md`
7. **Delivery**: If job has a `deliver` target, output is sent to that platform

**Important:** The cron job **does NOT** see the environment of the Hermes gateway process. Instead, the Hermes CLI/gateway injects credentials into the subprocess environment automatically from the configured credential store. You do not need to `source` a `.env` file manually.

---

## Credential Resolution

| Token | Source |
|-------|--------|
| `DISCORD_BOT_TOKEN` | Hermes credentials store (populated via `hermes gateway setup`) |
| `TELEGRAM_BOT_TOKEN` | Hermes credentials store |
| `SLACK_BOT_TOKEN` | Hermes credentials store |
| `OPENROUTER_API_KEY` | `/opt/data/.env` (managed by Hermes config) |

Scripts read via `os.getenv()` — no manual dotenv loading required.

---

## Key Commands Reference

```bash
# List all cron jobs
/opt/hermes/.venv/bin/hermes cron list

# Trigger a specific job now
/opt/hermes/.venv/bin/hermes cron run faf8329b351b

# Execute all due jobs immediately
/opt/hermes/.venv/bin/hermes cron tick

# Check cron daemon status
/opt/hermes/.venv/bin/hermes cron status

# View recent output
ls -lt /opt/data/cron/output/faf8329b351b/
cat /opt/data/cron/output/faf8329b351b/YYYY-MM-DD_HH-MM-SS.md

# Validate script syntax
python3 -m py_compile /opt/data/home/.hermes/scripts/x_link_poller_v2.py

# Inspect job definition
cat /opt/data/cron/jobs.json | python3 -c "import json,sys; [print(j['id'],j['name']) for j in json.load(sys.stdin)['jobs'] if j['id']=='faf8329b351b']"
```

---

## Vault & State Paths (from script)

- State file: `~/.hermes/state/x_link_poller_state.json` (deduplication)
- Vault raw: `/opt/data/obsidian-vault/FACorreia/Raw/{topic}/`
- Compile script: `/opt/data/obsidian-vault/FACorreia/scripts/compile_wiki.py`

---

## Multi-Location Scripts — Synchronization Pitfall

**Case:** `ai-scoreboard/ai_scoreboard_alerts_deliver.py` exists in both
`HERMES_HOME/scripts/` and `/opt/data/scripts/` (container-managed mirror).

**Symptoms:**
- One copy has your latest fix; the other still fails
- `hermes cron run <job_id>` triggers the version in `HERMES_HOME/scripts/`
- Manual testing from `/opt/data/scripts/` appears to work (inconsistent results)
- Git shows one file clean, the other dirty — developer confusion

**Root cause:** Hermes cron execution resolves `script` relative to `HERMES_HOME/scripts/` (see `_run_job_script` in `cron.py`). If you also maintain a copy under `/opt/data/scripts/` (which the Docker image syncs/copies), changes made to only one location will not affect the other.

**Recommended patterns:**
1. **Single source of truth:** Store the script only in `HERMES_HOME/scripts/`; disable the mirror or make it a symlink.
2. **Deployment sync step:** After editing, copy to both:
   ```bash
   cp ~/.hermes/scripts/ai-scoreboard/ai_scoreboard_alerts_deliver.py \
      /opt/data/scripts/ai-scoreboard/ai_scoreboard_alerts_deliver.py
   ```
3. **Edit in-place at runtime location:** Only edit `HERMES_HOME/scripts/...` and verify with `hermes cron run <job_id>`.

**Detection:**
```bash
# Compare both locations
diff -u ~/.hermes/scripts/ai-scoreboard/ai_scoreboard_alerts_deliver.py \
        /opt/data/scripts/ai-scoreboard/ai_scoreboard_alerts_deliver.py
```

If diff is non-empty, sync them before expecting cron jobs to use your latest changes.

---


## Related Topics

- `hermes-server-monitoring` — general cron job health checks and alert delivery
- `hermes-agent-skill-authoring` — authoring hermest itself (SKILL.md conventions)
- `autonomous-ai-agents/hermes-agent` — configuring and extending the agent
