# Community Skill Wrapper Examples

This document captures three real-world wrapper skills created during the GitTrend article ingestion session (2026-05-02). Use these as templates for similar projects.

---

## Example 1 — `community-backup`

**Wraps:** `art-solutions/hermes-agent-backup-skill`
**Upstream skill file:** `hermes-agent-core-backup.md` (note: not named `SKILL.md`)
**Type:** Operational maintenance — daily git backups of Hermes state

### Why a wrapper?
The upstream project is a single markdown skill file (not a directory with SKILL.md). It needs to be copied directly to `~/.hermes/skills/`. The wrapper Skill `community-backup` exists purely to:
- Document the setup process
- Provide a setup script (`setup-hermes-backup.sh`)
- Offer trigger phrases even though the real work is in the upstream `.md` file

### Installation
```bash
# Real skill file (upstream .md) goes directly:
cp hermes-agent-core-backup.md ~/.hermes/skills/

# Wrapper (this skill) provides setup script:
cp -r community-backup ~/.hermes/skills/
cp ~/.hermes/scripts/setup-hermes-backup.sh ~/.hermes/scripts/
~/.hermes/scripts/setup-hermes-backup.sh
```

### Key insight
Some community projects distribute **single-file skills** (`.md` with embedded bash). Install by copying the `.md` directly; the wrapper is just for convenience.

---

## Example 2 — `community-telepath`

**Wraps:** `eren23/telepath`
**Upstream:** Full Python project; no SKILL.md
**Type:** Memory-aware visualization via Kimi K2 (Moonshot AI)

### Why a wrapper?
Upstream is a standalone Python script that reads Hermes memory and calls Moonshot API. It doesn't integrate directly with Hermes skill system. Wrapper:
- Documents `MOONSHOT_API_KEY` prerequisite
- Provides `setup-telepath.sh` to clone + install `openai` Python package
- Points to upstream for actual usage

### Installation
```bash
~/.hermes/scripts/setup-telepath.sh
# Creates:
#   ~/telepath/            (cloned repo)
#   ~/.telepath/config.yaml
# Installs: python3 -m pip install openai python-dotenv
```

### Usage pattern
After setup, you run the upstream script manually:
```bash
cd ~/telepath && python3 telepath.py "visualize my time"
```
The wrapper doesn't call it automatically — it's a documentation skill.

---

## Example 3 — `community-music-lite`

**Wraps:** `KaleLjl/music-skill`
**Upstream:** Full Python project; has SKILL.md but requires heavy deps (`mido`, `pyfluidsynth`, `basic-pitch`) + system `fluidsynth` binary
**Type:** MIDI music toolkit (analyze, instrument swap, render to WAV)

### Why a wrapper (lite version)?
Full installation requires:
- System package: `fluidsynth` (apt/dnf/brew)
- Hermes venv pip (blocked — no pip in minimal venv)
- Clone large repo with many scripts

The `community-music-lite` wrapper is a **stub** that:
- Documents the full setup via `setup-music-skill-full.sh`
- Provides basic information without requiring dependencies
- Can be replaced by the full `music-skill` once deps are installed

### Installation options

**Option A — Just the wrapper (no deps, always works):**
```bash
cp -r community-music-lite ~/.hermes/skills/
# No setup script needed — pure documentation
```

**Option B — Full installation (requires system access):**
```bash
~/.hermes/scripts/setup-music-skill-full.sh
# Installs fluidsynth via apt/dnf/brew
# Bootstraps pip into /opt/hermes/.venv/ (if possible)
# Clones full music-skill repo to ~/music-skill-full
# Adds `music_skill_path` to ~/.hermes/config.yaml
```

---

## Common Pattern: Three-Part Wrapper

| Part | Purpose | Location |
|---|---|---|
| **SKILL.md** | Documentation + prerequisites + usage examples | `~/.hermes/skills/<wrapper-name>/` |
| **Setup script** | Automated install (clone, apt, pip, config, cron) | `~/.hermes/scripts/setup-<wrapper>.sh` |
| **Vault note** | Session context + links + decisions | `Raw/Dev/YYYY-MM-DD — Community Skills — Installation Summary.md` |

---

## Pitfalls Encountered (2026-05-02 Session)

1. **Path assumption trap:** Assumed Hermes home is `/root/.hermes/` on host, but the Docker volume actually maps to `/opt/data/home/.hermes/`. Always check `docker-compose.yml` volumes first.
2. **Venv pip locked:** `/opt/hermes/.venv/bin/pip` doesn't exist; `get-pip.py` bootstrap fails due to permission denied on site-packages. Fall back to `python3 -m pip install --user` (system Python user site-packages).
3. **Skill naming variant:** Upstream `hermes-agent-backup-skill` uses `hermes-agent-core-backup.md` as the skill filename (not `SKILL.md`). Check for any `*.md` file that might be the skill definition.
4. **Nitter down:** Multiple X article fetches failed because all nitter instances were unreachable; relied solely on `r.jina.ai` which sometimes returns login page HTML for protected articles.
5. **Setup script location:** Created scripts in `/opt/data/home/.hermes/scripts/` but needed to copy them to `/root/.hermes/scripts/` for actual execution. Remember: **staging area ≠ runtime area**.

---

## Quick Reference Table

| Wrapper Skill | Upstream Repo | Real Skill File | Setup Script | Dependencies |
|---|---|---|---|---|
| `community-backup` | art-solutions/hermes-agent-backup-skill | `hermes-agent-core-backup.md` | `setup-hermes-backup.sh` | git, SSH keys |
| `community-telepath` | eren23/telepath | N/A (Python script) | `setup-telepath.sh` | `openai`, `MOONSHOT_API_KEY` |
| `community-music-lite` | KaleLjl/music-skill | `music-skill/SKILL.md` (full) | `setup-music-skill-full.sh` | `fluidsynth`, `mido`, `pyfluidsynth`, `basic-pitch` |

---

*Captured during GitTrend X article ingestion — 2026-05-02*
