# System Skill Catalog (as of 2026-04-30)

Quick-reference table of system-installed skill locations for manual copying or debugging.

## Quick Index

| Skill | Category | Source Path | Needs Copy? |
|-------|----------|-------------|-------------|
| `node-inspect-debugger` | software-development | `/opt/hermes/skills/software-development/node-inspect-debugger` | No (builtin) |
| `webhook-subscriptions` | devops | `/opt/hermes/skills/devops/webhook-subscriptions` | No (builtin) |
| `jupyter-live-kernel` | data-science | `/opt/hermes/skills/data-science/jupyter-live-kernel` | No (builtin) |
| `dspy` | mlops (research) | `/opt/hermes/skills/mlops/research/dspy` | No (builtin) |
| `weights-and-biases` | mlops (evaluation) | `/opt/hermes/skills/mlops/evaluation/weights-and-biases` | No (builtin) |
| `defuddle` | openclaw-imports | `/opt/data/skills/openclaw-imports/defuddle` | **Yes** |
| `rss-digest-generator` | research | `/opt/data/skills/research/rss-digest-generator` | **Yes** |
| `llm-wiki` | knowledge-base | `/opt/hermes/skills/research/llm-wiki` | No (builtin) |
| `claude-design` | creative | `/opt/hermes/skills/creative/claude-design` | No (builtin) |
| `popular-web-designs` | creative | `/opt/hermes/skills/creative/popular-web-designs` | No (builtin) |
| `superpowers` (umbrella) | umbrella | `/opt/data/skills/superpowers` | **Yes** (for customization) |
| `multi-source-analysis` | software-development | `/opt/data/skills/software-development/multi-source-analysis` | **Yes** |

## Discovery Commands

```bash
# Find any skill by name anywhere under /opt
find /opt -type d -name "<skill-name>" 2>/dev/null

# List all system skills (catalog)
ls -1 /opt/hermes/skills/*/  # built-in
ls -1 /opt/data/skills/*/    # extended system catalog
```

## Copy Pattern

**Built-in** (in `/opt/hermes/skills/`): Usually don't need to copy — they're auto-available as `builtin` source. Copy only if you want to customize or guarantee availability without system dependency.

**Extended system** (in `/opt/data/skills/`): Copy to `~/.hermes/skills/` to make them user-local:
```bash
cp -r /opt/data/skills/category/skill-name ~/.hermes/skills/
```

**After copying:** Ensure `SKILL.md` has `category:` field, then verify:
```bash
hermes skills list --source local | grep <skill-name>
```

## Umbrella Reference Skills

Some umbrellas (e.g., `superpowers`, `multi-source-analysis`) organize sub-skills in `references/`. Each sub-skill is a standalone skill in the registry and needs its own `category:` frontmatter.

Example:
```
superpowers/
├── SKILL.md                   # category: umbrella
├── references/
│   ├── superpowers-brainstorming/
│   │   └── SKILL.md           # category: superpowers  ← required
│   └── superpowers-debugging/
│       └── SKILL.md
```

When copying an umbrella, copy the entire directory so all references are preserved.
