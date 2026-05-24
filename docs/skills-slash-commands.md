# LuminaVaultServer — Skills and Slash Commands

## Built-in skill packaging

Built-in skills live at:

```text
Sources/App/Resources/Skills/<skill-name>/SKILL.md
```

`Package.swift` copies `Resources/Skills` into the App target resource bundle with `.copy("Resources/Skills")`. Docker builds compile the Swift package, so these built-in skills are embedded in the API image automatically. No production Docker Compose bind mount is required for built-in skills.

Changing a built-in skill requires rebuilding and redeploying the API image:

```bash
docker compose -f docker-compose.production.yml up -d --build api
```

Do not mount a developer machine's `.codex/skills` directory into production. Only vetted app skills should ship in this resource tree.

## Runtime invocation

The Skills HTTP surface is under `POST /v1/skills`:

- `POST /v1/skills/{name}/run` runs a catalog skill directly.
- `POST /v1/skills/slash` accepts a raw chat command and dispatches deterministically before any chat LLM call.

Slash aliases:

| Command | Dispatch |
|---|---|
| `/kb-compile` | Existing `KBCompileService` via `KBCompileController` |
| `/kb-ingest` | Alias for `/kb-compile` |
| `/patterns [topic]` | `pattern-detector` skill |
| `/pattern-detector [topic]` | `pattern-detector` skill |
| `/contradict [topic]` | `contradiction-detector` skill |
| `/contradiction-detector [topic]` | `contradiction-detector` skill |
| `/beliefs <topic>` | `belief-evolution` skill; returns usage help without a topic |
| `/<skill-name> [input]` | Generic skill lookup by manifest name |

`/kb-compile` and `/kb-ingest` intentionally use the existing KB compile endpoint path internally because that flow already handles vault row resolution, onboarding state, achievements, and idempotent no-op behavior.

## Custom skill follow-up

`SkillCatalog` currently loads built-ins from the App resource bundle. Its documented future source is tenant vault skills under:

```text
<vaultRoot>/tenants/<tenantID>/skills/<skill-name>/SKILL.md
```

Until vault scanning is implemented, user-authored runtime skills will not appear in `GET /v1/skills` or generic slash dispatch.
