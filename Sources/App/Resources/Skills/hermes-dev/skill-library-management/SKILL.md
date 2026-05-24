---
name: skill-library-management
description: Install, organize, and maintain Hermes skill libraries across system and user locations. Covers skill discovery, copying, metadata validation, registration troubleshooting, and reference sub-skill handling.
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [skills, installation, maintenance, catalog, registry, troubleshooting]
    related_skills: [hermes-dev, hermes-agent-skill-authoring]
---

# Skill Library Management

Systematic approach to installing, validating, and maintaining Hermes agent skills across system-wide and user-specific locations.

## When to Use

Use this skill when:

- Setting up Hermes on a new machine and need to populate user skills
- Installing skills from system repositories to user collection
- Skills exist on disk but don't appear in `hermes skills list`
- Organizing skill categories and reference sub-skills
- Troubleshooting missing or disabled skills
- Understanding builtin vs local skill distinction
- Backing up or migrating skill collections

## Skill Source Locations

### System Skills (Read-Only)
```
/opt/hermes/skills/          # Built-in skills (shipped with Hermes)
  ├── autonomous-ai-agents/
  ├── caveman-tools/
  ├── creative/
  ├── data-science/
  ├── development/
  ├── devops/
  ├── hermes-dev/
  ├── knowledge-base/
  ├── mcp/
  ├── media/
  ├── mlops/
  ├── note-taking/
  ├── obsidian-extensions/
  ├── openclaw-imports/
  ├── product-strategy/
  ├── productivity/
  ├── research/
  ├── smart-home/
  ├── social-media/
  ├── software-development/
  ├── stock-trading/
  ├── superpowers/
  └── swift-development/

/opt/data/skills/            # Additional system skills (extended catalog)
  └── [same structure as above]
```

### User Skills (Writable)
```
~/.hermes/skills/            # User's personal skill collection
  ├── caveman-tools/         # Copied from system or custom-created
  ├── my-custom-skill/       # User-written skills
  └── superpowers/           # Umbrella with references/ subdirectory
```

## Installation Workflow

### Step 1: Discover Available Skills
```bash
# List all skills (system + user)
hermes skills list --source all

# List only system/builtin skills
hermes skills list --source hub

# List only user-installed skills
hermes skills list --source local

# Search for a specific skill
hermes skills search <name>
```

### Step 2: Identify Source Location
```bash
# Find where a skill lives in system
find /opt/hermes/skills /opt/data/skills -type d -name "<skill-name>" 2>/dev/null

# Example output:
# /opt/data/skills/software-development/multi-source-analysis
```

### Step 3: Copy to User Directory
```bash
# Copy entire skill directory (with references/, scripts/, etc.)
cp -r /opt/data/skills/category/skill-name ~/.hermes/skills/

# Or use Python/shutil for cross-platform
# (see templates/install_skill.py for reusable script)
```

### Step 4: Validate SKILL.md Frontmatter
**Critical:** SKILL.md **must** include a `category:` field for local registration.

**Before (won't register):**
```yaml
---
name: my-skill
description: "Does something useful"
version: 1.0.0
---
```

**After (will register):**
```yaml
---
name: my-skill
category: software-development   # ← REQUIRED for local skills
description: "Does something useful"
version: 1.0.0
---
```

**Common categories:** `software-development`, `devops`, `data-science`, `mlops`, `research`, `creative`, `productivity`, `stock-trading`, `swift-development`, `superpowers`, `hermes-dev`, `knowledge-base`, etc.

**Fix missing category:**
```bash
# Edit SKILL.md and insert category: <category> after the name: line
# Or use the automated fix from the skill installation routine
```

### Step 5: Verify Registration
```bash
# Check local skills list
hermes skills list --source local | grep <skill-name>

# Should show: │ skill-name │ category │ local │ local │ enabled │

# If missing, run:
hermes skills check  # Validates all local skills
```

## Umbrella Skills & Reference Sub-Skills

Some skills (e.g., `superpowers`, `multi-source-analysis`) are **umbrella skills** that organize multiple **reference sub-skills** under `references/`.

**Structure:**
```
superpowers/
├── SKILL.md                    # Umbrella frontmatter (category: umbrella)
├── references/
│   ├── superpowers-brainstorming/
│   │   └── SKILL.md            # Individual sub-skill (needs category!)
│   ├── superpowers-debugging/
│   │   └── SKILL.md
│   └── ...
└── README.md
```

**Rule:** Every `references/*/SKILL.md` must have its own `category:` field (typically the same as the umbrella, e.g., `superpowers`).

**Installation:** Copy the entire umbrella directory; all reference sub-skills are auto-discovered.

## Troubleshooting

### Skill exists on disk but not in `hermes skills list`

**Diagnosis:**
```bash
# 1. Check SKILL.md has category field
grep '^category:' ~/.hermes/skills/<skill>/SKILL.md

# 2. Validate frontmatter format (must start with ---, end with ---)
head -10 ~/.hermes/skills/<skill>/SKILL.md

# 3. Check file permissions (should be readable by hermes user)
ls -la ~/.hermes/skills/<skill>/SKILL.md
```

**Fix:** Add `category: <appropriate-category>` after the `name:` line. Rerun `hermes skills list`.

### Builtin skill shows in `--source all` but not `--source local`

**This is correct.** Built-in skills are `builtin` source, not `local`. They're available but not counted as user-installed.

To use them: simply invoke by name (no installation needed).

### Skill shows "disabled" status

**Check:** `hermes skills config <skill-name>` or `hermes skills enable <skill-name>`.

### Duplicate skill names across sources

If you have a local skill with the same name as a builtin, your local version **shadows** the builtin. Verify with:
```bash
hermes skills list --source all | grep <skill-name>
```
The `Source` column shows which one is active.

## Backup & Migration

Export your user skill collection:
```bash
tar -czf hermes-skills-backup-$(date +%Y%m%d).tar.gz ~/.hermes/skills/
```

Restore on new machine:
```bash
tar -xzf hermes-skills-backup.tar.gz -C ~/
# Ensure permissions: chown -R $(whoami) ~/.hermes/skills
```

## Reference

- **Skill authoring guide:** `hermes-agent-skill-authoring` skill
- **Built-in skill locations:** `/opt/hermes/skills/`
- **User skill location:** `~/.hermes/skills/`
- **Skill registry:** `~/.hermes/skills/registry.json` (auto-generated)

## Pitfalls

- **Missing category in SKILL.md** → Skill won't register locally. Always add it.
- **Copying only SKILL.md without directory contents** → Skill may miss `references/`, `scripts/`, `templates/`. Copy entire directory.
- **Editing system skill files directly** → Changes lost on update. Copy to user dir first, then modify.
- **Assuming builtin = local** → Builtins appear in `--source all` but not `--source local`. They're already available; no copy needed.
- **Reference sub-skills without SKILL.md** → Umbrella skill loads but sub-skill stays unregistered. Every `references/*/` directory needs its own SKILL.md with category.

---

## Reference: System Skill Catalog

*Quick directory listing of known system skill locations as of 2026-04-30.*

| Skill | System Path | Category |
|-------|-------------|----------|
| `node-inspect-debugger` | `/opt/hermes/skills/software-development/node-inspect-debugger` | software-development |
| `webhook-subscriptions` | `/opt/hermes/skills/devops/webhook-subscriptions` | devops |
| `jupyter-live-kernel` | `/opt/hermes/skills/data-science/jupyter-live-kernel` | data-science |
| `dspy` | `/opt/hermes/skills/mlops/research/dspy` | mlops |
| `weights-and-biases` | `/opt/hermes/skills/mlops/evaluation/weights-and-biases` | mlops |
| `defuddle` | `/opt/data/skills/openclaw-imports/defuddle` | openclaw-imports |
| `rss-digest-generator` | `/opt/data/skills/research/rss-digest-generator` | research |
| `llm-wiki` | `/opt/hermes/skills/research/llm-wiki` | knowledge-base |
| `claude-design` | `/opt/hermes/skills/creative/claude-design` | creative |
| `popular-web-designs` | `/opt/hermes/skills/creative/popular-web-designs` | creative |
| `superpowers` (umbrella) | `/opt/data/skills/superpowers` | umbrella |
| `multi-source-analysis` | `/opt/data/skills/software-development/multi-source-analysis` | software-development |

See `references/system-catalog.md` for the full catalog.
