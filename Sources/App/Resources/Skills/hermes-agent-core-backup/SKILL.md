---
name: hermes-agent-core-backup
description: Use when setting up automated daily backups for a Hermes agent installation, restoring agent state after a server failure, or performing a manual backup before major configuration changes.
---

# Hermes Agent Core — Daily Backup

## Overview

Automated daily backup system for any Hermes agent installation. Compresses all critical agent state — config, memories, skills, scripts, generated data, and secrets — into a timestamped ZIP and pushes it to a private remote repository.

> **Security requirement:** The backup repository MUST be private. The `.hermes/.env` file containing API keys is included in the archive.

---

## When to Use

- First-time setup of a new Hermes agent (run once to wire up automation)
- Before major configuration changes (run manually)
- After a server failure or machine migration (restore procedure)
- When you want to verify that backups are running correctly

---

## What Gets Backed Up

| Path | Contents |
|------|----------|
| `.hermes/config.yaml` | Agent base configuration |
| `.hermes/state.db*` | SQLite state database |
| `.hermes/memories/` | Long-term memory, profiles, rules |
| `.hermes/skills/` | All custom workflows and skills |
| `.hermes/scripts/` | Custom scripts (including this backup script) |
| `.hermes/.env` | API keys — **repo must be private!** |
| `$DATA_DIR/` | Generated assets, blog posts, images (configurable) |

---

## Setup

### Step 1 — Create the backup script

Save the following to `~/.hermes/scripts/backup_hermes.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# ── USER CONFIG — edit these values ──────────────────────────────────
AGENT_NAME="yourname"                                   # used in ZIP filename
HERMES_DIR="$HOME/.hermes"                              # root of Hermes install
BACKUP_LOCAL="$HOME/hermes_backups"                     # local staging directory
REMOTE_REPO="git@github.com:YOUR_USER/hermes_backups.git"  # PRIVATE repo URL
DATA_DIR="$HERMES_DIR/data"                             # generated-data dir (adjust or remove)
# ─────────────────────────────────────────────────────────────────────

DATE=$(date +%Y_%m_%d)
ZIP_FILE="$BACKUP_LOCAL/backup_${AGENT_NAME}_${DATE}.zip"

mkdir -p "$BACKUP_LOCAL"

# Initialize git repo on first run
if [ ! -d "$BACKUP_LOCAL/.git" ]; then
  git -C "$BACKUP_LOCAL" init
  git -C "$BACKUP_LOCAL" remote add origin "$REMOTE_REPO"
fi

# Build archive
zip -r "$ZIP_FILE" \
  "$HERMES_DIR/config.yaml" \
  "$HERMES_DIR/state.db"* \
  "$HERMES_DIR/memories/" \
  "$HERMES_DIR/skills/" \
  "$HERMES_DIR/scripts/" \
  "$DATA_DIR/" \
  "$HERMES_DIR/.env" 2>/dev/null || true

# Commit and push
git -C "$BACKUP_LOCAL" add "$ZIP_FILE"
git -C "$BACKUP_LOCAL" commit -m "backup: ${AGENT_NAME} ${DATE}"
git -C "$BACKUP_LOCAL" push origin main

echo "Backup complete: $ZIP_FILE"
```

Make it executable:

```bash
chmod +x ~/.hermes/scripts/backup_hermes.sh
```

### Step 2 — Schedule with cron (runs daily at 01:00)

```bash
crontab -e
```

Add this line:

```
0 1 * * * /bin/bash ~/.hermes/scripts/backup_hermes.sh >> ~/.hermes/scripts/backup.log 2>&1
```

Verify the schedule was saved:

```bash
crontab -l
```

### Step 3 — First manual run (verify it works)

```bash
bash ~/.hermes/scripts/backup_hermes.sh
```

Check the remote repo — a ZIP file named `backup_YOURNAME_YYYY_MM_DD.zip` should appear.

---

## Manual Backup

Run any time before making major changes:

```bash
bash ~/.hermes/scripts/backup_hermes.sh
```

---

## Restore

Use this procedure after a server failure or when migrating to a new machine.

> **Stop Hermes before restoring** — restoring to a running agent can cause data corruption.

```bash
# 1. Clone the backup repository
git clone git@github.com:YOUR_USER/hermes_backups.git ~/hermes_backups_restore

# 2. Unzip the most recent backup
#    Replace YOURNAME and YYYY_MM_DD with the actual values
unzip ~/hermes_backups_restore/backup_YOURNAME_YYYY_MM_DD.zip -d ~/restore_temp

# 3. Restore to ~/.hermes/ (Hermes must NOT be running)
cp -r ~/restore_temp/.hermes/ ~/.hermes/

# 4. Restart Hermes
```

---

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Backup repo is public | `.env` contains API keys — the repo **must** be private |
| `DATA_DIR` path is wrong | Check your actual data folder; update or remove the variable |
| Cron never fires | Run `crontab -l` to confirm entry; verify cron service is active (`systemctl status cron`) |
| Push fails silently | Check `~/.hermes/scripts/backup.log`; verify SSH key is authorized on remote |
| ZIP contains empty paths | Run the script manually and check `zip` output for warnings |
| Restore overwrites good data | Always restore to a temp dir first, then selectively copy |

---

## Adapting for Different Layouts

If your Hermes installation uses different paths, update `HERMES_DIR` and `DATA_DIR` at the top of the script. To exclude the data directory entirely, remove the `"$DATA_DIR/"` line from the `zip` command.

For GitLab or Gitea, change `REMOTE_REPO` to point to your self-hosted instance. The rest of the script is unchanged.
