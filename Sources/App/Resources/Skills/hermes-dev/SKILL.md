---
name: hermes-dev
description: Comprehensive toolkit for developing, deploying, monitoring, and maintaining the Hermes agent infrastructure. Covers remote deployment, server monitoring, skill authoring conventions, and TUI command debugging.
license: MIT
version: 1.0.0
author: Hermes Agent
metadata:
  hermes:
    tags: [hermes, devops, monitoring, skill-authoring, debugging]
    related_skills: [hermes-remote-deploy, hermes-server-monitoring, hermes-agent-skill-authoring, debugging-hermes-tui-commands]
---

# Hermes Development & Operations Umbrella

Consolidated guidance for all Hermes-internal workflows: deploying to new servers, operating resource monitoring, authoring skills correctly, and debugging the TUI slash command stack.

## When to Use

Load this umbrella when you are working on the Hermes system itself rather than using Hermes to solve user problems. Typical triggers:
- "Set up monitoring on a new server"
- "Why isn't my slash command showing up in the TUI?"
- "How do I write a well-structured SKILL.md?"
- "Fix a cron job that stopped delivering"

## Included Skills

### hermes-remote-deploy

Deploys the full Hermes monitoring and backup stack to a remote server (SSH key setup, script copy, cron installation, path adaptation). Supports both self-monitoring (remote cron) and centralized monitoring (cron on Hermes host). Use first when adding any new host to the fleet.

Reference: `${CLAUDE_SKILL_DIR}/references/hermes-remote-deploy/SKILL.md`

### hermes-server-monitoring

Operates and troubleshoots the monitoring system once deployed. Use for checking resource usage, validating cron jobs, diagnosing delivery failures (Discord/Telegram), and fixing script-level environment issues (dotenv, permissions).

Reference: `${CLAUDE_SKILL_DIR}/references/hermes-server-monitoring/SKILL.md`

### hermes-agent-skill-authoring

Author in-repo SKILL.md files following Hermes conventions (frontmatter, structure, size limits). Use when committing reusable workflows to the agent's skill tree.

Reference: `${CLAUDE_SKILL_DIR}/references/hermes-agent-skill-authoring/SKILL.md`

### debugging-hermes-tui-commands

Debug slash command issues in the TUI across three layers: Python command registry, TUI gateway JSON-RPC, and Ink frontend. Use when commands don't appear in autocomplete, behave differently between CLI and TUI, or persist config without applying.

Reference: `${CLAUDE_SKILL_DIR}/references/debugging-hermes-tui-commands/SKILL.md`

### hermes-config-yaml-editing

Safe techniques for reading, modifying, and writing the Hermes config.yaml file without introducing YAML errors or duplicates. Covers full-file replacement, targeted patching, and verification procedures.

Reference: `${CLAUDE_SKILL_DIR}/references/hermes-config-yaml-editing/SKILL.md`

## Quick Reference

| Skill | Primary Use | Typical Trigger |
|-------|-------------|-----------------|
| `hermes-remote-deploy` | Initial server setup | "Set up monitoring on new server" |
| `hermes-server-monitoring` | Day-to-day ops & troubleshooting | "Why isn't alert firing?" |
| `hermes-agent-skill-authoring` | Writing reusable skills | "Create a new skill in the repo" |
| `debugging-hermes-tui-commands` | Slash command issues | "Command not showing in TUI" |

## In-Session Reference

- `hermes-dev/references/provider-adapter-pattern.md` — Step-by-step for adding new LLM providers (Gemini, OpenAI, Anthropic etc.) to the routed dispatcher. Includes DTO consolidation rules, model-routing architecture, conditional registration pattern, and error-classification standards.
- `hermes-dev/references/cron-script-environment-patterns.md` — cron job execution flow, credential injection, syntax error patterns, and manual verification commands (from x-link-poller v2 debugging).
- `hermes-dev/references/cron-script-debugging.md` — detailed cron debugging session notes and diagnostic command library.
- `hermes-dev/references/discord-token-validator.md` — diagnose Discord bot token health using the `/users/@me` probe; interpret 200/401/403 responses and recovery steps.
## Protected Configuration Files & Manual Updates

Certain configuration files are protected to prevent accidental modification by the agent. Direct edits via Hermes tools (e.g., `patch`, `write_file`) are blocked for these files:

- `~/.hermes/.env` — Main agent environment configuration
- `/opt/data/.env` — Legacy/script environment (often contains tokens)
- Any file under `~/.hermes/` with sensitive content (API keys, tokens)

**Why protected?** To safeguard credentials and prevent the agent from corrupting its own configuration.

### Proper Procedure for Updating Credentials

When you need to update API keys or other credentials:

1. **Edit manually** using a terminal text editor:
   ```bash
   nano ~/.hermes/.env
   ```
   Make your changes, save, and exit.

2. **Sync the second location** if applicable (many systems use `/opt/data/.env` as well):
   ```bash
   sudo cp ~/.hermes/.env /opt/data/.env
   ```
   or edit it separately.

3. **Restart the Hermes gateway** to reload the updated configuration:
   ```bash
   hermes gateway restart
   ```
   This ensures all child processes inherit the new environment variables.

4. **Verify** the changes took effect:
   ```bash
   hermes env | grep LINEAR_API_KEY
   ```
   or check with `printenv LINEAR_API_KEY`.

### Two-Storage Reality

Many Hermes installations maintain two `.env` files:
- `~/.hermes/.env` — Loaded by the Hermes agent gateway on startup; used by the agent core and skills.
- `/opt/data/.env` — Traditionally used by legacy cron scripts and some external tools.

**Best Practice:** Keep both files in sync. The recommended approach is to store all credentials in `~/.hermes/.env` and ensure cron scripts either:
- Rely on scheduler injection (preferred), or
- Explicitly load `~/.hermes/.env` or `/opt/data/.env` at runtime.

### Testing API Keys Without Restarting

If you want to test a new API key without restarting the agent:
- Use the terminal to make a direct API call (if permitted by your setup).
- Or update the .env file, restart the gateway, then use the relevant skill (e.g., `linear`) to perform operations.

### Using `skill_manage` for Skill Configuration

For configuring skill-specific settings, use `skill_manage` to edit skill files or create support files. Do not edit system-wide config files directly via Hermes tools — they are protected for safety.

### Documentation Reference

See also: `hermes-dev/references/cron-script-environment-patterns.md` for details on environment injection and the two-storage model.

## User Preference for Agent Initiative

When the user explicitly asks you to "debug and fix" a problem (e.g., "I want YOU to do the commands, not me"), they are granting you permission to take autonomous action. In such cases:

- **Do not ask for confirmation** for each diagnostic command or fix step.
- **Proceed directly** to run the necessary commands to identify and resolve the issue.
- **Report results** after each action so the user stays informed.
- **Only pause** if you encounter a decision point that requires user judgment (e.g., choosing between two equally viable solutions, or when a fix might have side effects).

This preference applies specifically when the user has handed you full responsibility for a task with phrases like "fix this" or "just make it work."

## Hermes WebUI Configuration Pitfalls

### Missing HERMES_WEBUI_STATE_DIR

**Error Pattern**: The WebUI container enters a restart loop with logs showing:
```
!! ERROR: HERMES_WEBUI_STATE_DIR not set
!! Exiting script
```

**Cause**: The environment variable `HERMES_WEBUI_STATE_DIR` is required by the WebUI initialization script to determine where to store sessions, workspaces, and other state. It's often missing from the `.env` file even when other `HERMES_WEBUI_*` variables are present.

**Fix**: Add the following line to your `~/.hermes/.env` file (adjust the path if your setup uses a different state location):

```bash
HERMES_WEBUI_STATE_DIR=/home/hermeswebui/.hermes/webui-mvp
```

**Note**: This path should be within the volume that's mounted into the container (typically `${HOME}/.hermes:/home/hermeswebui/.hermes`). The default value referenced in the code is `~/.hermes/webui-mvp`.

**Verification**: After updating the `.env` file, restart the WebUI service:
```bash
docker-compose down && docker-compose up -d
```

Then check the container status:
```bash
docker-compose ps hermes-webui
```

If the container stays up and shows "healthy" in the logs, the issue is resolved.

### Additional WebUI Troubleshooting Tips

- **Port Configuration**: The WebUI typically runs on port 8787 (configurable via `HERMES_WEBUI_PORT`). Ensure your reverse proxy (e.g., nginx-proxy-manager) forwards to the correct internal port.
- **State Directory Permissions**: The state directory must be writable by the `hermeswebui` user (UID 1024 in most setups). The volume mount `${HOME}/.hermes:/home/hermeswebui/.hermes` should handle this.
- **Dependency Checks**: The WebUI requires all Hermes agent dependencies to be installed. If the container fails to start with import errors, verify that `/opt/hermes-agent` is properly mounted and contains the necessary modules.

When cron jobs fail to deliver to Discord with HTTP 403, the bot token is likely revoked, regenerated, or the bot app has been disabled. A quick probe confirms:

**One-liner:**
```bash
curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bot $DISCORD_BOT_TOKEN" \
  https://discord.com/api/v10/users/@me
```

Return codes:
- `200` — token valid
- `401` — token is invalid (wrong, malformed, never valid)
- `403` — token was valid but is now **revoked/disabled**; generate a fresh token in the Discord Developer Portal

**Python probe** (useful when testing from inside Hermes):
```python
import urllib.request
req = urllib.request.Request(
    'https://discord.com/api/v10/users/@me',
    headers={'Authorization': f'Bot {os.environ[\"DISCORD_BOT_TOKEN\"]}'}
)
try:
    urllib.request.urlopen(req, timeout=10)
    print("✓ Token valid")
except urllib.error.HTTPError as e:
    print(f"✗ HTTP {e.code} — {'revoked/disabled' if e.code==403 else 'invalid'}")
```

If you get 403:
1. Go to <https://discord.com/developers/applications> → select bot → **Bot** → **Reset Token**
2. Update the token in `~/.hermes/.env` (or `/opt/data/.env` if your scripts read from there)
3. Restart Hermes gateway (`hermes gateway restart`) so child processes inherit the new token
4. Re-run the failing cron job: `hermes cron run <job_id>`

See also: `hermes-dev/references/discord-token-validator.md`.

## Script Path Consistency Pitfall

Cron jobs that reference scripts via **absolute paths** or **prefixed relative paths** (e.g., `'ai-scoreboard/ai_scoreboard_alerts.py'`) fail when the script actually resides in the same directory as the wrapper. This manifests as `FileNotFoundError` and exit code 2.

**Two locations to check:**
- `./ai-scoreboard/` (relative to `HERMES_HOME/scripts/`)
- `/opt/data/scripts/ai-scoreboard/` (container-managed sync location)

Symptom: The script file exists but `subprocess.run([sys.executable, 'ai-scoreboard/...'])` fails because the working directory is `HERMES_HOME/scripts/`, not project root.

**Fix pattern:** Always pass the plain filename when the wrapper and target script share a directory.

```python
# WRONG — adds an extra path component that doesn't exist
subprocess.run([sys.executable, 'ai-scoreboard/ai_scoreboard_alerts.py'], ...)

# CORRECT — works when both files are in the same directory
subprocess.run([sys.executable, 'ai_scoreboard_alerts.py'], ...)
```

If you maintain **two copies** of the deliver script (one in `HERMES_HOME/scripts/ai-scoreboard/` and one in `/opt/data/scripts/ai-scoreboard/`), ensure both are kept in sync. Prefer consolidating to a single canonical location and aliasing/cron-job-symlinking rather than maintaining divergent duplicates.

**Verification:**
```bash
# Check both locations
ls -la ~/.hermes/scripts/ai-scoreboard/ai_scoreboard_alerts_deliver.py
ls -la /opt/data/scripts/ai-scoreboard/ai_scoreboard_alerts_deliver.py

# Run directly from its directory
cd ~/.hermes/scripts/ai-scoreboard
python3 ai_scoreboard_alerts_deliver.py
```

## Cron Script Debugging & Credential Injection

Hermes cron jobs execute Python scripts with credentials injected at runtime via environment variables. The gateway loads credentials from `~/.hermes/.env` and passes them into the job's process environment before invocation. However, scripts may also explicitly load alternative env files if needed.

### Common Pitfall — Malformed Token Placeholders

When scripts are authored or modified, Hermes redacts live credential values from the file content, replacing them with `***` tokens. If the script contains inline assignments (e.g., `OPENROUTER_API_KEY=os.getenv(...)` compacted onto one line without proper spacing), the redaction can produce invalid Python syntax:

```python
# BEFORE — broken
OPENROUTER_API_KEY=os.get...)
PLATFORM_TOKENS=***
    "discord":  (os.getenv("DISCORD_BOT_TOKEN") or "").strip(),
    ...
```

This causes `SyntaxError` on import, preventing the cron job from running at all.

### Fix Pattern

Always use full assignment statements with proper spacing:

```python
# AFTER — correct
OPENROUTER_API_KEY = os.getenv("OPENROUTER_API_KEY", "").strip()

PLATFORM_TOKENS = {
    "discord": (os.getenv("DISCORD_BOT_TOKEN") or "").strip(),
    "telegram": (os.getenv("TELEGRAM_BOT_TOKEN") or "").strip(),
    "slack": (os.getenv("SLACK_BOT_TOKEN") or "").strip(),
}
```

Validate with: `python3 -m py_compile /opt/data/home/.hermes/scripts/<script>.py`

### Triggering & Verification

- Run immediately: `hermes cron run <job_id>` → `hermes cron tick`
- Check job status: `hermes cron status` or inspect `/opt/data/cron/output/<job_id>/`
- Job state lives in: `/opt/data/cron/jobs.json`
- Scripts must reside within `HERMES_HOME/scripts/` (enforced by `_run_job_script`)

### Environment Resolution

Cron jobs run with these environment variables automatically injected by the gateway **provided they exist in `~/.hermes/.env`**:
- Platform tokens: `DISCORD_BOT_TOKEN`, `TELEGRAM_BOT_TOKEN`, `SLACK_BOT_TOKEN`
- API keys: `OPENROUTER_API_KEY`, etc.
- Home channels: `DISCORD_HOME_CHANNEL`, `TELEGRAM_HOME_CHANNEL`, `SLACK_HOME_CHANNEL`
- Derived from the main Hermes config and credentials store — do NOT hardcode.

**Two-Storage Reality:** Many installations maintain a separate `/opt/data/.env` for legacy scripts. If `~/.hermes/.env` is missing platform tokens, your cron script will run with empty env. Two ways to fix:

#### Pattern A — Rely on Scheduler Injection (Recommended)
Ensure all required tokens are present in `~/.hermes/.env`. The scheduler loads this file on every job run and injects the variables automatically. No code changes needed in your script.

#### Pattern B — Explicit Dotenv Loading (Self-Contained Scripts)
If you prefer to keep credentials in `/opt/data/.env` or your script should work regardless of scheduler configuration, add explicit dotenv loading at the top of your script:

```python
from pathlib import Path
import os

def _load_dotenv(env_path: Path = Path("/opt/data/.env")) -> None:
    """Load platform credentials from the Hermes managed env file."""
    if not env_path.exists():
        return
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line:
            key, _, val = line.partition("=")
            key = key.strip()
            # Strip quotes and export prefix
            val = val.strip().strip('"\'')
            if key.startswith("export "):
                key = key[7:].strip()
            os.environ[key] = val

_load_dotenv()
```

This pattern is used by `portfolio_threshold_alerts.py` and makes the script resilient to missing `~/.hermes/.env`.

**Diagnostic:** Check both locations when a cron job runs but platform delivery silently fails:
```bash
ls -la ~/.hermes/.env          # Scheduler loads this (may not exist)
ls -la /opt/data/.env          # Traditional env file (often contains tokens)
grep -E "TELEGRAM|DISCORD|SLACK" ~/.hermes/.env /opt/data/.env
```

See also: `hermes-dev/references/cron-script-environment-patterns` for detailed comparison and migration checklist.

See also: `hermes-dev/references/cron-script-debugging` for detailed examples.
