---
name: hermes-config-yaml-editing
description: Safe techniques for reading, modifying, and writing the Hermes config.yaml file without introducing YAML errors or duplicates
license: MIT
version: 1.0.0
author: Hermes Agent
metadata:
  hermes:
    tags: [hermes, devops, configuration, yaml]
    related_skills: [hermes-dev, debugging-hermes-tui-commands]
---

# Hermes Config YAML Editing

Safe, repeatable patterns for modifying the main Hermes configuration file (`~/.hermes/config.yaml`). Covers reading, patching, and full-file replacement techniques to avoid common pitfalls like malformed YAML, duplicate sections, and partial updates.

## When to Use

Load this skill whenever you need to:

- Modify the Hermes agent configuration (config.yaml)
- Add or remove model aliases
- Change default models or providers
- Update fallback provider settings
- Adjust any YAML-based configuration

## Key Principles

1. **Always read the full file context** before making changes. Pagination (`offset`/`limit`) can hide duplicates or structural issues.
2. **Prefer full-file writes** for complex multi-line edits. Patching is error-prone for large sections.
3. **Validate YAML structure** after modifications. Hermes will fail to start if the config is invalid.
4. **Check for duplicates** after any patch operation — overlapping changes can leave duplicate keys.

## Safe Editing Patterns

### Pattern A: Full-File Replacement (Recommended for Complex Edits)

Best for: Adding multiple model aliases, reorganizing sections, or when you need to see the entire file.

```python
# 1. Read the entire file
config = read_file(path='~/.hermes/config.yaml', limit=None)

# 2. Make your modifications in memory (parse as YAML, edit, re-serialize)
# OR use string replacement with careful attention to indentation

# 3. Write the entire file back
write_file(path='~/.hermes/config.yaml', content=modified_config, mode='w')
```

**Advantages**: No risk of partial updates or duplicates. You control the entire structure.

### Pattern B: Targeted Patching (Use with Caution)

Best for: Simple key changes (e.g., changing a single value). Avoid for multi-line section replacements.

```python
# Example: Change default model
patch(
    path='~/.hermes/config.yaml',
    action='replace',
    old_string='default: arcee-ai/trinity-large-thinking',
    new_string='default: moonshotai/kimi-k2.6'
)
```

**Critical**: Ensure `old_string` is unique. If the same value appears elsewhere, the patch may affect the wrong location.

### Pattern C: Block Replacement for Sections

When you need to replace an entire section (e.g., model_aliases), use a unique block of text:

```python
# Read the current section to get the exact text
section = read_file(path='~/.hermes/config.yaml', offset=463, limit=30)

# Then patch using the exact block as old_string
patch(
    path='~/.hermes/config.yaml',
    action='replace',
    old_string=section,
    new_string=new_section
)
```

**Warning**: This approach is fragile if the file has already been modified. Prefer full-file writes.

## Step-by-Step Workflow

For any config edit, follow these steps:

1. **Read the full file** with `read_file(path, limit=None)` to understand current structure.
2. **Identify the exact change** needed. If adding new content, locate the proper insertion point.
3. **Choose the right pattern**:
   - Simple value change → Pattern B
   - Adding a few lines → Pattern B with careful indentation
   - Adding/removing multiple aliases or reorganizing → Pattern A
4. **Execute the change**.
5. **Verify the file** by reading it back and checking for:
   - Proper indentation (2 spaces per level)
   - No duplicate keys
   - Valid YAML syntax (you can try parsing with Python's `yaml.safe_load`)
6. **Test Hermes operation** (if possible) by running a simple command: `hermes config --check` or just observe that Hermes starts without config errors.

## Common Pitfalls & Fixes

### Pitfall 1: Duplicate Sections After Patching

**Symptom**: After a patch, you see the same section repeated (e.g., two `session_reset` blocks).

**Cause**: The `old_string` didn't match exactly, so only part of the old section was replaced, leaving remnants.

**Fix**: Use full-file replacement (Pattern A) to clean up. Read the entire file, remove duplicates manually, and write back the complete corrected file.

```python
full = read_file(path='~/.hermes/config.yaml', limit=None)
# Clean up duplicates in memory
cleaned = remove_duplicate_sections(full)
write_file(path='~/.hermes/config.yaml', content=cleaned)
```

### Pitfall 2: Malformed YAML from Incorrect Indentation

**Symptom**: Hermes fails to start with a YAML parse error.

**Cause**: YAML is indentation-sensitive. Mixing tabs and spaces or inconsistent levels breaks parsing.

**Fix**: Always use 2-space indentation. When copying from existing sections, preserve the exact indentation style.

### Pitfall 3: Partial Reads Hiding Issues

**Symptom**: You miss duplicate sections or structural problems because you only read a snippet.

**Cause**: Using `offset`/`limit` pagination gives an incomplete view.

**Fix**: Always read the full file (`limit=None`) when making structural changes.

### Pitfall 4: Overwriting Protected Files

**Symptom**: Patch or write operations fail on certain files.

**Cause**: Some config files are protected to prevent accidental modification (e.g., `~/.hermes/.env`).

**Fix**: Edit protected files manually using a text editor, then restart Hermes to apply changes.

## Verification Commands

After any config change, run these checks:

```bash
# 1. Check file syntax (if your system has yamllint)
yamllint ~/.hermes/config.yaml

# 2. Try to parse with Python (if PyYAML is available)
python3 -c "import yaml; yaml.safe_load(open('~/.hermes/config.yaml'))"

# 3. Verify Hermes can read the config
hermes config --check  # if this command exists

# 4. Look for obvious errors in the file
cat ~/.hermes/config.yaml | grep -A5 -B5 "error"
```

## References

- `hermes-dev/references/cron-script-environment-patterns.md` — Environment injection details
- `hermes-dev/references/cron-script-debugging.md` — Debugging cron jobs (relevant for config-driven scheduling)

## User Preference for Agent Initiative

When the user explicitly asks you to "debug and fix" a config problem, they grant permission for autonomous action. In such cases:

- Proceed directly with diagnostic commands and fixes
- Report results after each action
- Only pause for decisions requiring user judgment

This preference applies when the user says "fix this" or similar phrases granting full responsibility.