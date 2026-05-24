---
name: community-skill-evaluation
description: Pre-installation checklist and scoring system for evaluating community Hermes Agent skills for quality, compatibility, and risk.
---

# Community Skill Evaluation Checklist

Use this checklist before installing any community Hermes skill.

## Quick Scorecard

Rate each category 0–2 points (max 12). Score ≥8 = generally safe. <6 = investigate further.

| Category | Criteria | Points |
|---|---|---|
| **Skill Definition** | Has `SKILL.md` with valid frontmatter? | 0 / 2 |
| **Documentation** | README explains install, usage, dependencies? | 0 / 2 |
| **Activity** | Commit within last 6 months? | 0 / 2 |
| **License** | MIT, Apache-2.0, GPL (not proprietary)? | 0 / 2 |
| **Dependencies** | Minimal (≤5 pip packages, no heavy system deps)? | 0 / 2 |
| **Hermes Integration** | Imports `hermes_tools` or uses skill decorator? | 0 / 2 |

**Total:** ___ / 12

## Detailed Evaluation

### 1. Repository Health

- [ ] **Last commit** within 6 months? (Check GitHub "Commits" tab)
- [ ] **Open issues** are few (<10) and not all are bugs/incompatibilities
- [ ] **Pull requests** active (maintainer responds)
- [ ] **Stars/forks** indicate community adoption (optional)

### 2. Skill Format

- [ ] `SKILL.md` exists at **repo root** (not in `/docs/` or `/skill/`)
- [ ] Frontmatter YAML valid (`name`, `description`, `version`, `author`, `license`)
- [ ] Has `triggers` or `actions` section (not just description)
- [ ] If no SKILL.md → plan to create wrapper from template

### 3. Dependencies

**Python packages** (from `requirements.txt`, `pyproject.toml`, `setup.py`, or imports):
```bash
# Extract quickly:
grep -E "^import |^from " $(git ls-files '*.py') | sort -u
```
- [ ] Count ≤ 5 core packages
- [ ] No packages with known security issues (`safety check`)
- [ ] Packages maintained (not last updated 5+ years ago)

**System packages** (binaries, libraries):
- [ ] No more than 2 system deps (apt/brew install)
- [ ] Available on your OS (Debian/Ubuntu, macOS, etc.)
- [ ] Not GPU/driver-specific (CUDA, etc.)

**External services:**
- [ ] API keys optional (skill degrades gracefully without)
- [ ] No paid SaaS required to function
- [ ] Self-hostable if needed

### 4. Hermes Compatibility

- [ ] Targets Hermes v0.12.0+ (check SKILL.md `compatibility` field)
- [ ] Uses `hermes_tools` module (not hardcoded paths)
- [ ] Skill scripts accept CLI args (not interactive only)
- [ ] No hardcoded paths like `/Users/username/...` or `C:\Users\...`

### 5. Security & Privacy

- [ ] No `eval()` or `exec()` in Python code
- [ ] No shell-injection vulnerabilities (`subprocess` with unsanitized input)
- [ ] Credentials stored in env vars, not hardcoded
- [ ] No telemetry/analytics without consent
- [ ] No `sudo` calls in scripts

### 6. Data & Storage

- [ ] Uses `~/.hermes/` paths by default (not arbitrary locations)
- [ ] Respects `HERMES_ROOT` env var if set
- [ ] Database/SQLite files stored in standard locations
- [ ] No writes to `/etc/`, `/usr/`, or system dirs

### 7. License & Usage

- [ ] License allows personal/modified use (MIT, Apache, GPL ok)
- [ ] Not "All rights reserved" or custom restrictive license
- [ ] No "non-commercial only" (CLAUDE.md, personal use fine)
- [ ] Attribution required? (If yes, document)

---

## Decision Matrix

| Score | Action |
|---|---|
| 10–12 | ✅ Safe to install. Proceed. |
| 7–9 | ⚠️ Review dependencies first. Check security. |
| 4–6 | 🔴 High risk. Investigate issues before proceeding. |
| 0–3 | ❌ Do not install. Abandon. |

## Red Flags (Automatic Investigate)

- [ ] Last commit > 2 years ago (abandoned)
- [ ] Issues open > 1 year with no response (unmaintained)
- [ ] `SKILL.md` missing **and** no clear entrypoint script
- [ ] Requires paid API key with no free tier
- [ ] Crypto-mining, wallet addresses, or suspicious network calls
- [ ] Vague description like "awesome hermes stuff" with no docs

---

**Save this evaluation as:** `references/evaluation-2026-05-02.md` (date-stamped per skill)
