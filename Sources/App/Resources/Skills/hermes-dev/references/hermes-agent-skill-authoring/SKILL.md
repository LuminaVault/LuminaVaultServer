---
name: hermes-agent-skill-authoring
category: hermes-dev
description: "Author in-repo SKILL.md: frontmatter, validator, structure."
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [skills, authoring, hermes-agent, conventions, skill-md]
    related_skills: [writing-plans, requesting-code-review]
---

# Authoring Hermes-Agent Skills (in-repo)

## Overview

There are two places a SKILL.md can live:

1. **User-local:** `~/.hermes/skills/<maybe-category>/<name>/SKILL.md` — personal, not shared. Created via `skill_manage(action='create')`.
2. **In-repo (this skill is about this case):** `/home/bb/hermes-agent/skills/<category>/<name>/SKILL.md` — committed, shipped with the package. Use `write_file` + `git add`. `skill_manage(action='create')` does NOT target this tree.

## When to Use

- User asks you to add a skill "in this branch / repo / commit"
- You're committing a reusable workflow that should ship with hermes-agent
- You're editing an existing skill under `/home/bb/hermes-agent/skills/` (use `patch` for small edits, `write_file` for rewrites; `skill_manage` still works for patch on in-repo skills, but not for `create`)
- User requests broadening of agent capabilities across all domains (not just project-specific) — install foundational skills (data science, ML ops, research, creative, etc.) to make the agent universally capable.

## Required Frontmatter

Source of truth: `tools/skill_manager_tool.py::_validate_frontmatter`. Hard requirements:

- Starts with `---` as the first bytes (no leading blank line).
- Closes with `\n---\n` before the body.
- Parses as a YAML mapping.
- `name` field present.
- `description` field present, ≤ **1024 chars** (`MAX_DESCRIPTION_LENGTH`).
- Non-empty body after the closing `---`.

**Additionally for LOCAL skills:** `category` field is required for the skill to appear in `hermes skills list --source local`. The validator does not enforce this, but the skill registry filters by category and skills without a `category` value are silently excluded from local listings. Peer skill shape:

```yaml
---
name: my-skill-name               # lowercase, hyphens, ≤64 chars (MAX_NAME_LENGTH)
category: software-development   # or devops, data-science, etc. — REQUIRED for local skills
description: Use when <trigger>. <one-line behavior>.
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [short, descriptive, tags]
    related_skills: [other-skill, another-skill]
---
```

`version` / `author` / `license` / `metadata` are NOT enforced by the validator, but every peer has them — omit and your skill sticks out.

## Size Limits

- Description: ≤ 1024 chars (enforced).
- Full SKILL.md: ≤ 100,000 chars (enforced as `MAX_SKILL_CONTENT_CHARS`, ~36k tokens).
- Peer skills in `software-development/` sit at **8-14k chars**. Aim for that range. If you're pushing past 20k, split into `references/*.md` and reference them from SKILL.md.

## Peer-Matched Structure

Every in-repo skill follows roughly:

```
# <Title>

## Overview
One or two paragraphs: what and why.

## When to Use
- Bulleted triggers
- "Don't use for:" counter-triggers

## <Topic sections specific to the skill>
- Quick-reference tables are common
- Code blocks with exact commands
- Hermes-specific recipes (tests via scripts/run_tests.sh, ui-tui paths, etc.)

## Common Pitfalls
Numbered list of mistakes and their fixes.

## Verification Checklist
- [ ] Checkbox list of post-action verifications

## One-Shot Recipes (optional)
Named scenarios → concrete command sequences.
```

Not every section is mandatory, but `Overview` + `When to Use` + actionable body + pitfalls are the minimum for the skill to feel like a peer.

## Directory Placement

```
skills/<category>/<skill-name>/SKILL.md
```

Categories currently in repo (confirm with `ls skills/`): `autonomous-ai-agents`, `creative`, `data-science`, `devops`, `dogfood`, `email`, `gaming`, `github`, `leisure`, `mcp`, `media`, `mlops/*`, `note-taking`, `productivity`, `red-teaming`, `research`, `smart-home`, `social-media`, `software-development`.

Pick the closest existing category. Don't invent new top-level categories casually.

## Workflow

1. **Survey peers** in the target category:
   ```
   ls skills/<category>/
   ```
   Read 2-3 peer SKILL.md files to match tone and structure.
2. **Check validator constraints** in `tools/skill_manager_tool.py` if unsure.
3. **Draft** with `write_file` to `skills/<category>/<name>/SKILL.md`.
4. **Validate locally**:
   ```python
   import yaml, re, pathlib
   content = pathlib.Path("skills/<category>/<name>/SKILL.md").read_text()
   assert content.startswith("---")
   m = re.search(r'\n---\s*\n', content[3:])
   fm = yaml.safe_load(content[3:m.start()+3])
   assert "name" in fm and "description" in fm
   assert len(fm["description"]) <= 1024
   assert len(content) <= 100_000
   ```
5. **Git add + commit** on the active branch.
5. **Note:** the CURRENT session's skill loader is cached — `skill_view` / `skills_list` will not see the new skill until a new session. This is expected, not a bug.

## Skill Bootstrap & Installation (System → User)

When you need a skill that exists system-wide but is not installed in your user-local skill directory:

### Bootstrap Workflow

```bash
# 1. Locate the skill in the system installation
find /opt/hermes/skills -type d -name "<skill-name>" 2>/dev/null
find /opt/data/skills -type d -name "<skill-name>" 2>/dev/null

# 2. Copy to your user-local skills directory
cp -r /opt/hermes/skills/<category>/<skill-name> ~/.hermes/skills/

# 3. Verify SKILL.md has required frontmatter (especially `category:`)
#    If missing, patch it now (see Pitfalls below)

# 4. Check registration
hermes skills list --source local | grep <skill-name>
```

### Category Resolution & Validation

System skills are organized in `<category>/<skill-name>/` directories (e.g., `/opt/hermes/skills/data-science/jupyter-live-kernel/`). When copying a skill to user-local:

1. Determine the correct `category` value from the system path's parent directory name.
2. Open the copied `SKILL.md` and ensure the frontmatter includes `category: <that-category>`.
   - If the field is missing, add it immediately after the `name:` line.
3. For **reference sub-skills** (skills that live inside an umbrella's `references/` directory, e.g., `superpowers/references/superpowers-brainstorming/`), set `category` to the umbrella's category (commonly `superpowers`).
4. Verify registration:
   ```bash
   hermes skills list --source local | grep <skill-name>
   ```
   If the skill does not appear, re-check the `category` field and file location.

> **Note:** Built-in skills accessible via `--source all` do not require bootstrapping unless you need them in local listings or want to edit them without sudo.

### Why This Happens

Hermes ships many skills built-in under `/opt/hermes/skills/` but they are not automatically copied to `~/.hermes/skills/`. The built-in skills are accessible via `--source all` but won't appear in `--source local` unless bootstrapped. User-local skills take precedence in loading order and are editable without sudo.

### When to Bootstrap vs. Use Built-In Direct

- **Bootstrap** when: you want the skill to appear in local listings, be editable without sudo, or persist across system updates.
- **Use built-in directly** when: you just need the functionality and don't need to modify it (references to built-in skills resolve fine).

## Cross-Referencing Other Skills

`metadata.hermes.related_skills` unions both trees (`skills/` in-repo and `~/.hermes/skills/`) at load time. You CAN reference a user-local skill from an in-repo skill, but it won't resolve for other users who clone the repo fresh. Prefer referencing only in-repo skills from in-repo skills. If a frequently-referenced skill lives only in `~/.hermes/skills/`, consider promoting it to the repo.

## Editing Existing In-Repo Skills

- **Small fix (typo, added pitfall, tightened trigger):** `skill_manage(action='patch', name=..., old_string=..., new_string=...)` works fine on in-repo skills.
- **Major rewrite:** `write_file` the whole SKILL.md. `skill_manage(action='edit')` also works but requires supplying the full new content.
- **Adding supporting files:** `write_file` to `skills/<category>/<name>/references/<file>.md`, `templates/<file>`, or `scripts/<file>`. `skill_manage(action='write_file')` also works and enforces the references/templates/scripts/assets subdir allowlist.
- **Always commit** the edit — in-repo skills are source, not runtime state.

## Common Pitfalls

1. **Using `skill_manage(action='create')` for an in-repo skill.** It writes to `~/.hermes/skills/`, not the repo tree. Use `write_file` for in-repo creation.

2. **Missing `category` field in local SKILL.md frontmatter.** The validator does not require `category`, but the skill registry filters local skills by category. Skills without a `category` value fail to register and will not appear in `hermes skills list --source local`, even though the file exists. Always include `category: <category-name>` in the frontmatter. Fix: prepend `category: software-development` (or appropriate category) to the frontmatter YAML. Additionally, reference sub-skills (those inside an umbrella's `references/` directory) must set `category` to the umbrella's category (e.g., `superpowers`) to register.

3. **Leading whitespace before `---`.** The validator checks `content.startswith("---")`; any leading blank line or BOM fails validation.

3. **Description too generic.** Peer descriptions start with "Use when ..." and describe the *trigger class*, not the one task. "Use when debugging X" > "Debug X".

4. **Forgetting the author/license/metadata block.** Not validator-enforced, but every peer has it; omitting makes the skill look half-finished.

5. **Writing a skill that duplicates a peer.** Before creating, `ls skills/<category>/` and open 2-3 peers. Prefer extending an existing skill to creating a narrow sibling.

6. **Expecting the current session to see the new skill.** It won't. The skill loader is initialized at session start. Verify in a fresh session or via `skill_view` using the exact path.

7. **Linking to skills that don't exist in-repo.** `related_skills: [some-user-local-skill]` works for you but breaks for other clones. Prefer only in-repo links.

## Verification Checklist

- [ ] File is at `skills/<category>/<name>/SKILL.md` (not in `~/.hermes/skills/`)
- [ ] Frontmatter starts at byte 0 with `---`, closes with `\n---\n`
- [ ] `name`, `description`, `version`, `author`, `license`, `metadata.hermes.{tags, related_skills}` all present
- [ ] Name ≤ 64 chars, lowercase + hyphens
- [ ] Description ≤ 1024 chars and starts with "Use when ..."
- [ ] Total file ≤ 100,000 chars (aim for 8-15k)
- [ ] Structure: `# Title` → `## Overview` → `## When to Use` → body → `## Common Pitfalls` → `## Verification Checklist`
- [ ] `related_skills` references resolve in-repo (or are explicitly OK to be user-local)
- [ ] `git add skills/<category>/<name>/ && git commit` completed on the intended branch
