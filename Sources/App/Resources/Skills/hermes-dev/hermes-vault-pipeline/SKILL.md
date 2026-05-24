---
name: hermes-vault-pipeline
description: Deploy, diagnose, and recover the Hermes daily vault pipeline — permission mismatches, UID/GID ownership issues, compile failures, healthcheck reporting, and external content source (platform API) troubleshooting for Obsidian vault ingestion
license: MIT
---

# Hermes Vault Pipeline Skill

## When to use

Deploy, operate, or troubleshoot the daily Obsidian vault ingestion pipeline. Use when:

- The daily vault pipeline (`daily_vault_pipeline.py`) fails to compile the vault
- Diagnosing `PermissionError`, `OSError`, or filesystem access issues during compilation
- Understanding and fixing UID/GID mismatches between the Hermes agent and vault data
- Interpreting truncated tool output and recovering full error transcripts
- Setting up or repairing scheduled cron execution of the pipeline
- Verifying pipeline health after deployment changes
- **External content source failures** (X/Twitter pollers, RSS feeds, web scrapers) due to platform API permissions, webhook conflicts, or credential issues
- Diagnosing why content-insertion scripts (e.g. `x_link_poller_v2.py`) report HTTP 403/409/401 errors when fetching from Discord, Telegram, Slack, or other platforms

**Do NOT use for:**
- Writing new pipeline steps (use `hermes-agent-skill-authoring`)
- One-off vault manual fixes without understanding systemic cause

## Prerequisites

- Know the vault root path (typically `/opt/data/obsidian-vault`)
- Know the compiled skill paths (`knowledge-base/scripts/kb-compile/compile_wiki.py`, `kb-healthcheck/lint_wiki.py`)
- Python 3 available
- Read access to the vault directory tree
- For external platform diagnosis: platform bot tokens available in environment (`.env` file) and knowledge of target channels/chat IDs

## Core workflow

### Step 1 — Understand the execution context

First, know which user the cron/agent runs as:

```bash
# If running from cron, whoami is determined by the crontab entry
# Typical Hermes cron runs as UID 1000 (the agent user), not the vault owner
id -u  # prints real UID
id -g  # prints real GID
```

The vault itself is typically owned by a different user (e.g., `hermes` UID 10000):

```bash
ls -la /opt/data/obsidian-vault/FACorreia
# Expected output: drwxr-xr-x ... hermes hermes
stat -c '%U:%G' /opt/data/obsidian-vault/FACorreia/wiki  # owner of wiki dir
```

**Common mismatch:** Agent/user UID 1000 → vault owned by UID 10000 (`hermes`). This causes `PermissionError` on `unlink()` during compilation because the wiki directory is not writable by the agent.

### Step 2 — Check for upstream content source failures

Before blaming the vault compiler, verify that upstream pollers are actually producing content:

```bash
# Check if poller is running as a daemon
ps aux | grep x_link_poller_v2

# Check poller state (last successful fetch)
cat /opt/data/home/.hermes/state/x_link_poller_state.json | python3 -m json.tool

# Check poller logs (most recent cycle)
tail -n 50 /opt/data/home/.hermes/logs/x_link_poller_v2.log

# Check Raw/ directory for recent files (last 24h)
find /opt/data/obsidian-vault/FACorreia/Raw -type f -mmin -1440 -exec ls -lt {} \;
```

**If poller found zero new articles** → proceed to external platform diagnosis (new section below).  
**If poller saved articles but compile still empty** → proceed to filesystem permission diagnosis (Step 3 below).

### Step 3 — Diagnose external platform API access (NEW)

When content pollers report `HTTP 403`, `HTTP 409`, or `HTTP 401` errors, the failure is at the platform API level, not the vault.

#### 3.1 Run connectivity diagnostic script

A diagnostic script is provided with this skill:

```bash
python3 /opt/data/home/.hermes/scripts/x_link_poller_v2.py --diagnose-only
```

Expected output shows green checkmarks for all platforms. Any red errors require platform-specific fixes below.

#### 3.2 Discord 403 Forbidden (Read Message History)

**Symptom in logs:**
```\nHTTP 403 fetching https://api.discord.com/api/v10/channels/<channel>/messages?limit=50: Forbidden\nDiscord 403 Forbidden on channel <channel>. Bot needs 'Read Message History' permission in this channel. Current: can SEND but cannot READ.\n```

**Root cause:** Bot role lacks `Read Message History` permission in the monitored channel.

**Fix:**
1. Server Settings → Roles → select bot role (e.g., `Hermes`)
2. Under "Text & Voice Permissions" enable **Read Message History**
3. Also ensure the bot role has `View Channel` permission for that channel
4. If channel has overrides, check the channel's permission overrides explicitly allow the bot

**Verification:**
```bash
# Re-run diagnostic — Discord should now show OK
python3 /opt/data/home/.hermes/scripts/x_link_poller_v2.py --diagnose-only
```

#### 3.3 Telegram 409 Conflict (Webhook active)

**Symptom in logs:**
```\nHTTP 409 fetching https://api.telegram.org/bot<token>/getUpdates?limit=100&timeout=5: Conflict\nTelegram 409 Conflict: Webhook is active. Long-polling and webhook cannot coexist.\n```

**Root cause:** A webhook is registered on the bot, blocking `getUpdates` long-poll.

**Fix (one-time):**
```bash
curl -X POST "https://api.telegram.org/bot<YOUR_BOT_TOKEN>/deleteWebhook"
# Or, if you need to keep webhook elsewhere, stop the poller from Telegram
```

**Verification:**
```bash
# After deletion, run diagnostic again
python3 /opt/data/home/.hermes/scripts/x_link_poller_v2.py --diagnose-only
# Should show "Telegram: OK" and potentially return recent updates
```

**Prevention:** Set `TELEGRAM_WEBHOOK_URL=` (empty) in `.env`, or ensure only one ingestion method uses the bot.

#### 3.4 OBSIDIAN_VAULT_PATH points to wrong location (local vs VPS)

**Symptom:**  
- Poller or pipeline reports `FileNotFoundError` when trying to access the vault  
- Content is saved to a local path like `/Users/fernando_idwell/Developer/Vaults/FACorreia` instead of the VPS vault  
- After fixing `.env`, the old path persists in running containers  

**Root cause:** The `OBSIDIAN_VAULT_PATH` environment variable was set to a local development vault path and not updated when deploying to the VPS. This causes all content ingestion to write to the wrong location, and the pipeline may fail to find or compile the vault.

**Fix:**

1. **Update `.env` file** with the correct VPS vault path:
   ```bash
   OBSIDIAN_VAULT_PATH=/opt/data/home/obsidian-vault/FACorreia
   OBSIDIAN_VAULT_NAME=FACorreia
   ```

2. **Restart Hermes containers** to pick up the new environment:
   ```bash
   docker restart hermes-webui
   ```

3. **Verify the change**:
   ```bash
   docker exec hermes-webui printenv | grep OBSIDIAN_VAULT_PATH
   # Should output: /opt/data/home/obsidian-vault/FACorreia
   ```

4. **Check for stale state** - If old files exist in the wrong location, they may need to be cleaned up or merged.

**Prevention:**  
- Use environment-specific `.env` files (e.g., `.env.vps`, `.env.local`)  
- Document the correct path in deployment documentation  
- Consider using a symlink or mount point that works across environments  

#### 3.5 Slack token or channel errors

**Symptom:** `Slack: HTTP 200 but ok=false` or `Slack: HTTP 403`

- **`invalid_auth`** → Bot token expired/revoked. Regenerate in Slack App → OAuth & Permissions → Bot User Tokens  
- **`channel_not_found`** → Channel ID wrong or bot not invited. Invite bot to channel: `/invite @<botname>`  
- **`not_authorized`** → Bot lacks `channels:history` scope. Add scope in Slack App → OAuth & Permissions → Scopes → "Bot Token Scopes" → `channels:history`, reinstall app.  

**Verification:**
```bash
# Manual test
TOKEN=$(grep SLACK_BOT_TOKEN /opt/data/.env | cut -d= -f2)\nCHANNEL=$(grep SLACK_HOME_CHANNEL /opt/data/.env | cut -d= -f2)\ncurl -s -H \"Authorization: Bearer $TOKEN\" \"https://slack.com/api/conversations.history?channel=$CHANNEL&limit=1\" | python3 -m json.tool\n# Should return {\"ok\": true, ...}\n```

### Step 4 — Diagnose the permission barrier (vault filesystem)

Once content sources are healthy and producing articles but compile still fails, examine filesystem permissions:

```python
import os

file_path = '/opt/data/obsidian-vault/FACorreia/wiki/...'\nwiki_dir = os.path.dirname(file_path)

# Check ownership
st = os.stat(wiki_dir)
print(f\"Wiki dir owner: uid={st.st_uid} gid={st.st_gid}\")

# Check if current process can write
print(f\"os.access(W_OK): {os.access(wiki_dir, os.W_OK)}\")

# Test direct write
import pathlib
test = pathlib.Path(wiki_dir) / '.perm_test.tmp'\ntry:
    test.write_text('test')
    test.unlink()
    print(\"Write test: SUCCESS\")
except Exception as e:
    print(f\"Write test: FAILED — {e}\")
```

Typical finding: `os.access(W_OK)` returns `False` because neither UID nor GID match, and mode `0755` denies write to "others".

#### Recovery options (in order of safety)

**Option A — Run as the vault owner (preferred if sudo/runuser available)**

```bash\n# As root: switch to vault owner before running pipeline\nrunuser -u hermes -- python3 /opt/data/home/.hermes/scripts/daily_vault_pipeline.py\n\n# Or via sudo if configured:\nsudo -u hermes python3 /opt/data/home/.hermes/scripts/daily_vault_pipeline.py\n```\n\n**Why:** The `hermes` user (UID 10000) owns the vault files.\n\n**Cron configuration:** Install cron in `hermes` user's crontab or wrap with `runuser` in root's crontab.

**Option B — Group-based access (medium-term fix)**

```bash\n# Create a shared group or add agent user to 'hermes'\ngroupadd vaultops\nusermod -aG vaultops hermes           # vault owner in group\nusermod -aG vaultops <agent_user>    # agent user joins group\n\n# Change wiki directory's group and enable group-write\nchgrp vaultops /opt/data/obsidian-vault/FACorreia/wiki\nchmod 0775 /opt/data/obsidian-vault/FACorreia/wiki\nchmod g+s /opt/data/obsidian-vault/FACorreia/wiki  # setgid: new files inherit group\n```\n\nVerify: `ls -ld /opt/data/obsidian-vault/FACorreia/wiki` → `drwxrwsr-x ... vaultops vaultops`

**Option C — Make vault globally writable (insecure; last resort)**

```bash\nchmod -R o+w /opt/data/obsidian-vault/FACorreia/wiki\n# or\nchmod 0777 /opt/data/obsidian-vault/FACorreia/wiki\n```\n\n**Warning:** Any local user can modify vault. Use only in isolated environments.

**Option D — Change vault ownership to agent user (disruptive)**

```bash\nchown -R <agent_user>:<agent_group> /opt/data/obsidian-vault/FACorreia\n```\n\n**Warning:** Breaks other processes running as `hermes`. Only in single-user deployments.

#### Option E — Symbolic link workaround (if permissions immutable)

```bash\nmkdir -p /opt/data/home/.hermes/vault_work\nln -s /opt/data/home/.hermes/vault_work/wiki /opt/data/obsidian-vault/FACorreia/wiki.tmp\n# Modify compile script to use wiki.tmp instead of wiki/\n```\n\nFragile; prefer Options A–D.

### Step 5 — Re-run the pipeline and verify

```bash\npython3 /opt/data/home/.hermes/scripts/daily_vault_pipeline.py\n```\n\nExpected flow:\n```\n=== Step 1: Compiling vaults ===\n  [FACorreia] compile: OK\n  [Norviq] compile: OK\n\n=== Step 2: Healthcheck ===\n  [FACorreia] healthcheck: OK\n\n=== Step 3: Generating trends report ===\n  Report saved: /opt/data/home/.hermes/output/daily/trends-2026-05-02.md\n```\n\n### Step 6 — Healthcheck and validation

Even with compile success, run healthcheck explicitly:

```bash\npython3 /opt/data/skills/knowledge-base/scripts/kb-healthcheck/lint_wiki.py --root /opt/data/obsidian-vault/FACorreia\n```\n\nLook for:
- Duplicate titles (auto-renamed)
- Broken internal links
- Orphan pages

### Step 7 — Persistent cron recovery

Ensure cron entry uses correct user and environment:

```bash\n# Preferred: install in hermes user's crontab\nsudo crontab -u hermes -e\n# Add:\n0 8 * * * /usr/bin/python3 /opt/data/home/.hermes/scripts/daily_vault_pipeline.py >> /opt/data/home/.hermes/logs/pipeline.log 2>&1\n```\n\nOr, as root, use `runuser`:

```bash\n# In root's crontab:\n0 8 * * * runuser -u hermes -- /usr/bin/python3 /opt/data/home/.hermes/scripts/daily_vault_pipeline.py >> /root/vault_pipeline.log 2>&1\n```\n\n## External platform diagnosis reference

New section added 2026-05-03 — covers platform API permission and webhook issues that prevent content from reaching the vault.

For full error patterns, environment checks, and per-platform fix recipes, see:
- **references/platform-api-troubleshooting-2026-05-03.md** — complete diagnostic checklist for Discord/Telegram/Slack API errors in poller scripts
- **scripts/diagnose_platforms.py** — automated connectivity checker for all configured platforms

Quick HTTP status mapping:

| Status | Platform | Typical cause | One-line fix |
|--------|----------|---------------|--------------|
| 403 Forbidden | Discord | Bot missing 'Read Message History' | Grant permission in channel overrides |
| 409 Conflict | Telegram | Webhook active, blocks long-poll | `curl -X POST /bot<token>/deleteWebhook` |
| 401 Unauthorized | Slack/Telegram | Token invalid/revoked | Regenerate bot token in platform developer console |
| 404 Not Found | Discord/Telegram/Slack | Channel/chat ID incorrect or bot not joined | Verify channel ID env var; invite bot to channel |

## Multi-source link poller operational patterns

The `multi_link_poller.py` script (distinct from `x_link_poller_v2.py`) ingests explicit X/Twitter and GitHub URLs via command-line arguments and feeds them into `Raw/`. It is typically used for back-filling or manual runs. For full operational details, see `references/multi_source_link_poller_operational-2026-05-03.md`.

### Argparse flag ordering

The script defines `--limit` then `--urls`. URLs **must** appear after the `--urls` flag:

```bash\n# ✅ Correct\npython3 multi_link_poller.py --limit 50 --urls https://x.com/foo https://github.com/bar/repo\n\n# ❌ Incorrect — URLs between --limit and --urls trigger \"unrecognized arguments\"\npython3 multi_link_poller.py --limit 50 https://x.com/foo --urls   # fails\n```

### Vault root resolution — two locations

On this deployment, two vault roots exist:

| Root | Resolved from | Usage |
|------|---------------|-------|
| `/opt/data/home/obsidian-vault/FACorreia` | `Path.home()` (agent's `$HOME`) | Used by scripts without explicit root override |
| `/opt/data/obsidian-vault/FACorreia` | hard-coded path (canonical) | Used by skill wrappers and cron pipelines |

**Implication:** Content saved by `multi_link_poller.py` goes to the `$HOME`-relative vault. The canonical vault's compile script does not see these files unless you run compile against both roots. When debugging missing notes, check both `Raw/` trees.

**Helper script:** `scripts/extract_urls_from_vault.py` scans both vault roots (configurable by `--vault`) and emits unprocessed URLs for re-polling.

### Compile-trigger fallback limitations

After saving content, `multi_link_poller.py` tries to auto-trigger a compile but only searches:
1. `VAULT_ROOT/scripts/compile_wiki.py`
2. `$HOME/.hermes/scripts/compile_wiki.py`
3. `/opt/data/home/.hermes/scripts/compile_wiki.py`

It **misses** the canonical compile script at `/opt/data/obsidian-vault/FACorreia/scripts/compile_wiki.py`. The script will print "compile not found — will compile on next scheduled pipeline." even though a working compile exists.

**Manual run (recommended after manual poll):**
```bash\npython3 /opt/data/obsidian-vault/FACorreia/scripts/compile_wiki.py --root /opt/data/obsidian-vault/FACorreia\n```

### Network resilience

GitHub API (`api.github.com`) may time out intermittently, while X fetches via `r.jina.ai/http://…` are generally reliable. The poller currently skips URLs on GitHub fetch failure with no retry. If you encounter repeated GitHub timeouts, either:
- Retry with exponential backoff (modify script or re-run manually)
- Use `--diagnose-only` on poller to verify `requests` connectivity
- Temporary workaround: wait and re-run the entire poller session

**Auth-wall detection on X:** uses two thresholds: ≥2 auth-phrase hits in body OR body < 100 chars. Both cause skip — these are real paywall/login pages.

### Pitfalls

| Symptom | Root cause | Fix |
|---------|------------|-----|
| `PermissionError: unlink(...)` | Agent UID ≠ vault owner UID | Use Option A (run as vault owner) or Option B (shared group) |
| `PermissionError: unlink(...)` but UID matches | ACL or immutable flag blocking delete | Check `lsattr` for 'i' attribute; remove with `chattr -i` |
| Pipeline runs but produces zero pages | `Raw/` missing or no `.md` files | Verify `Raw/` exists and contains markdown notes |
| Compile succeeds but healthcheck fails | Duplicate titles or broken links | Review `Reports/kb-healthcheck-*.md` |
| Cron job never runs | PATH/environment differs from interactive shell | Use absolute paths (`/usr/bin/python3`) and set `PATH` in crontab |
| Error output truncated in agent display | Agent tool capture limits stdout/stderr to ~1500 chars | Use `subprocess.run(stdout=PIPE, stderr=STDOUT)` and print whole buffer |
| **Poller log: HTTP 403 (Discord)** | **Bot lacks 'Read Message History'** | **Grant permission in Discord role/channel** |
| **Poller log: HTTP 409 (Telegram)** | **Webhook active, conflicts with long-poll** | **Delete webhook via Telegram API** |
| **Poller log: HTTP 401 (Slack)** | **Token invalid or scope missing** | **Regenerate token, add `channels:history` scope, reinstall app** |

## Recovery decision tree

```\nPipeline fails → PermissionError on unlink?\n├─ YES → Are you able to run as 'hermes' user?\n│  ├─ YES → Use Option A (runuser/sudo -u hermes)\n│  └─ NO → Can you modify group membership?\n│     ├─ YES → Use Option B (shared group + chmod g+s)\n│     └─ NO → Is this an isolated/test environment?\n│        ├─ YES → Use Option C (chmod o+w) — insecure but works\n│        └─ NO → Use Option D (chown to agent user) — breaks other processes\n└─ NO → Is content production failing upstream?\n   ├─ YES → Check poller logs; run diagnostic script\n   │  → Identify platform error (403/409/401); apply platform-specific fix\n   │  └─ YES → Verify poller produces files to Raw/ before re-running compile\n   └─ NO → Error is not permission-related → Examine full stdout via subprocess.PIPE\n      → Check Raw/ structure, Python syntax errors, missing dependencies\n```\n\n## File layout expectations\n\n```\n/opt/data/obsidian-vault/FACorreia/\n├── Raw/           # source markdown notes (ingested)\n├── wiki/          # compiled output (auto-generated)\n├── Reports/       # healthcheck reports\n└── ...            # other vault files (Setup, Clippings, etc.)\n```\n\n**Compile script contract:**\n- Deletes all existing `wiki/*.md` before recompiling (`unlink()` is the failure point)\n- Writes new compiled pages to `wiki/`\n- Logs ingestion count to `wiki/log.md`\n\nIf `wiki/` is not writable, the first `unlink()` fails and aborts the whole pipeline.\n\n**Content source scripts** (feeding into `Raw/`):\n- `x_link_poller_v2.py` — X/Twitter/fixupx link poller with LLM classification\n- `daily_vault_pipeline.py` — orchestrator that may call external fetchers\n\nState is persisted per-source to prevent duplicate ingestion.\n\n## Related skills\n\n- `knowledge-base/kb-compile` — the compile script reference\n- `knowledge-base/kb-healthcheck` — the healthcheck script reference\n- `hermes-remote-deploy` — deploying scripts and cron to remote servers (centralized monitoring pattern)\n- `hermes-server-monitoring` — operating the server resource monitor\n\n## See also\n\n- `/opt/data/home/.hermes/scripts/daily_vault_pipeline.py` — the pipeline orchestrator\n- `/opt/data/skills/knowledge-base/scripts/kb-compile/compile_wiki.py` — compiler\n- `/opt/data/skills/knowledge-base/scripts/kb-healthcheck/lint_wiki.py` — linter\n- `/opt/data/home/.hermes/scripts/x_link_poller_v2.py` — X link poller reference\n- `/opt/data/home/.hermes/state/x_link_poller_state.json` — poller state (deduplication)\n- Vault docs: `/opt/data/obsidian-vault/Setup/` for vault layout notes