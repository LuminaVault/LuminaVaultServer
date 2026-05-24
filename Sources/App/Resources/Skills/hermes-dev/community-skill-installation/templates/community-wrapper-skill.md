---
name: community-wrapper-skill
description: Minimal SKILL.md wrapper for community Hermes projects that lack native skill definitions. Copy, customize, and place in ~/.hermes/skills/
---

# Community Wrapper Skill Template

Use this template to wrap any Hermes-related Python script as a chat-triggerable skill.

## Setup

1. Copy this file to `~/.hermes/skills/<your-skill-name>/SKILL.md`
2. Create `scripts/` directory alongside it
3. Place your Python entrypoint script in `scripts/`
4. Adjust `triggers` and `invoke` commands below

## Template

```yaml
---
name: my-community-skill
description: "Brief description of what this skill does"
version: 0.1.0
author: Your Name
license: MIT
dependencies: []  # Python packages needed (if any)
metadata:
  hermes:
    tags: [category, tags, here]
    required_env_vars: []  # e.g. ["API_KEY", "DATA_DIR"]
    related_skills: []
---

# My Community Skill

## What it does

Explain the skill's purpose and capabilities.

## Quick Start

```
# In Hermes chat:
user: <trigger phrase>
hermes: [skill activates]
```

## Actions

| Action | Trigger | What it does |
|---|---|---|
| `main-action` | `<trigger phrase>` | Brief description |

## Configuration

List any required environment variables or setup steps.

**Important:** Avoid patterns that trigger Hermes security scanner (DANGEROUS verdict):
- Don't auto-modify `~/.hermes/config.yaml` — document manual edits instead
- Don't use `crontab -e`/`crontab -l` in skill actions — provide a separate setup script
- Don't `git clone` from skill actions — clone manually before installing

If your skill needs cron or config changes, create a **separate setup script** (`scripts/setup-<skill>.sh`) and document it here. The skill itself should be pure invocation.

## Dependencies

- Python packages: `package1`, `package2`
- System packages: `apt-get install foo`
- External services: API keys, URLs, etc.

## Verification

```bash
# Test script directly
python3 ~/.hermes/skills/my-community-skill/scripts/main.py --help

# Test via Hermes chat
echo "<trigger phrase>" | hermes chat --
```
```

## Notes

- Keep `invoke` paths absolute or relative to skill directory
- Use `{{args}}` placeholder to receive user's message arguments
- For async/long-running tasks, use `delegate_task` from `hermes_tools`
