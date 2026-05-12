# LuminaVault Server — Architecture Map

Reading order: this file is a tour, not a spec. Each section names the
feature, the Linear ticket(s) it ships under, the files that make it
work, and the route or hot-path that exercises it. Use this when you
want to find where something lives without grepping the whole repo.

The areas covered here are the ones built and modified during the
2026-05-11 → 2026-05-12 session. Pre-existing surfaces (Auth, Hermes
gateway, Vault uploads, KB compile, Memory CRUD) are linked from
the call-graph notes but documented in their own files / commits.

---

## Cross-cutting building blocks

These types are referenced by everything below. Read them first if
the rest looks unfamiliar.

| Concern            | File                                                                | What it does                                                                                       |
| ------------------ | ------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| Request context    | `Sources/App/Auth/AppRequestContext.swift`                          | Carries the authenticated `User` and `ctx.requireIdentity()` accessor used by every protected route. |
| Tenant model       | `Sources/App/Models/TenantModel.swift`                              | `protocol TenantModel: Model` — every per-user table conforms so queries partition by `tenant_id`.    |
| Vault filesystem   | `Sources/App/Services/VaultPathService.swift`                       | `tenantRoot(for:)`, `rawDirectory(for:)`, `skillsDirectory(for:)` — canonical filesystem layout.   |
| Rate limit         | `Sources/App/Middleware/RateLimitMiddleware.swift`                  | `RateLimitPolicy` constants live here; new endpoints pick one (`userOrIPKey` or `ipKey`).            |
| App wiring         | `Sources/App/App+build.swift`                                       | Single entry point. Migrations registered, services constructed, router groups mounted in order.   |
| Service container  | `Sources/App/Services/ServiceContainer.swift`                       | Read-once config struct passed into `buildRouter`.                                                  |
| Push delivery      | `Sources/App/Services/APNSNotificationService.swift`                | Per-user APNS fanout. Public methods: `notifyLLMReply`, `notifyNudge`, `notifyDigest`, `notifyAchievement`. |

Filesystem layout the server assumes:

```
<vault.rootPath>/
  tenants/
    <tenantID>/
      raw/                       # vault uploads (HER-87)
      skills/<name>/SKILL.md     # per-tenant vault skills (HER-168)
```

Built-in skills ship inside the App bundle:

```
Bundle.module.resourceURL/
  Skills/<name>/SKILL.md         # source: Sources/App/Resources/Skills/<name>/SKILL.md
```

`Package.swift` copies `Resources/Skills` verbatim via `.copy(...)`
so the subdirectory tree is preserved.

---

## 1. Skills runtime (HER-148 umbrella)

The skills runtime is the largest sub-system added across this and
prior sessions. It is split across seven tickets; HER-167, HER-168,
and HER-191 are session work — the rest were merged earlier and are
listed for context.

### 1.1 Manifest parsing — HER-167

| File                                                  | Purpose                                                                                                                                                   |
| ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Sources/App/Skills/SkillManifest.swift`              | `SkillManifest` value type + `SkillManifestError` cases + `SkillManifestParser` (Yams-backed).                                                            |
| `Tests/AppTests/Skills/SkillManifestTests.swift`      | 13 cases: all 8 builtin manifests parse; body strip; `allowed-tools` shape coverage; 7 negative cases (missing fields, invalid enum values, bad frontmatter). |

What to study:
- `SkillManifestParser.parse(source:contents:)` splits `---`-delimited
  frontmatter from the body, decodes via `YAMLDecoder` into a private
  `RawManifest`, validates required fields (`name`, `description`,
  `metadata.capability`), maps to public `SkillManifest`.
- `parseOverride` closure lets tests inject a synthetic parser
  (HER-168's `SkillCatalogTests` uses this).
- `StringOrArray` private decoder accepts both
  `allowed-tools: session_search vault_read` and
  `allowed-tools: [session_search, vault_read]`.

### 1.2 Catalog discovery + dedup — HER-168

| File                                                  | Purpose                                                                                            |
| ----------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `Sources/App/Skills/SkillCatalog.swift`               | `actor SkillCatalog`: per-call scan of builtin + vault dirs; merge with `vault > builtin` precedence. |
| `Sources/App/Services/VaultPathService.swift`         | `skillsDirectory(for:)` resolves `<rootPath>/tenants/<tenantID>/skills`.                            |
| `Tests/AppTests/Skills/SkillCatalogTests.swift`       | 7 cases: empty / discovery / vault overrides builtin / tenant isolation / hot reload / mismatch reject / parse-failure skip. |

What to study:
- `manifests(for: tenantID)` does NOT cache. Every call walks the
  filesystem. Acceptable because catalogs are tiny (≤20 entries per
  tenant). Lets `skill add` / `skill remove` take effect without a
  server restart.
- The dictionary-overlay pattern (`builtins` first, then `vault`
  overlay by `name`) is what guarantees vault precedence.
- The `manifest.name == dir.lastPathComponent` guard prevents a vault
  skill from shadowing a builtin by lying about its `name` in the
  frontmatter.
- Parse / read failures are logged at `warning` and skipped — one
  broken SKILL.md never aborts the rest of the scan.

### 1.3 Built-in skills (Synthesis Intelligence) — HER-189, HER-190, HER-191

| File                                                                      | Skill                | Linear  |
| ------------------------------------------------------------------------- | -------------------- | ------- |
| `Sources/App/Resources/Skills/pattern-detector/SKILL.md`                  | Recurring themes     | HER-189 |
| `Sources/App/Resources/Skills/contradiction-detector/SKILL.md`            | Belief conflicts     | HER-190 |
| `Sources/App/Resources/Skills/belief-evolution/SKILL.md`                  | Stance over time     | HER-191 |
| `Tests/AppTests/Skills/PatternDetectorTests.swift` etc                    | Fixture + prompt contract tests |

What to study:
- The `SKILL.md` frontmatter format is the canonical contract — every
  field is parsed by `SkillManifestParser` and consumed by
  `SkillCatalog`.
- Each skill declares `metadata.capability`, `daily_run_cap`, output
  kinds. `daily_run_cap` is enforced by `SkillRunCapGuard.swift`
  (HER-193).
- The body of each `SKILL.md` is the LLM prompt the runner injects
  when the skill fires. For HER-191 specifically, the body documents:
  topic-required validation, `[[memory:<uuid>]]` citation format,
  minimum 3 anchors, mandatory `Current view` anchor, closing
  `Pattern` paragraph, and the `timelineEntries` structured response.

### 1.4 Catalog + runner + scheduler — HER-169, HER-170, HER-171, HER-193

These pieces existed before this session but are listed so the call
graph reads cleanly.

| File                                                  | Linear  | Purpose                                                                                          |
| ----------------------------------------------------- | ------- | ------------------------------------------------------------------------------------------------ |
| `Sources/App/Skills/SkillRunner.swift`                | HER-169 | Actor that drives the Hermes agent loop for a single skill invocation. Currently stub-throws.    |
| `Sources/App/Skills/CronScheduler.swift`              | HER-170 | `Service` lifecycle task: ticks every minute, dispatches scheduled skills.                       |
| `Sources/App/Skills/EventBus.swift`                   | HER-171 | In-process pub/sub. Producers: `MemoryController`, `VaultController` etc. Consumer: `SkillRunner`. |
| `Sources/App/Skills/SkillRunCapGuard.swift`           | HER-193 | Per-skill / per-tier daily run cap. Read from `metadata.daily_run_cap` in each manifest.         |
| `Sources/App/Skills/SkillsController.swift`           | HER-148 | `POST /v1/skills/:name/run` route. Currently scaffold-only — handler returns 501 until HER-169.  |

Migrations backing this surface:

| File                                                       | Linear  | Schema                                          |
| ---------------------------------------------------------- | ------- | ----------------------------------------------- |
| `Sources/App/Migrations/M19_CreateSkillsState.swift`       | HER-168 | `skills_state` runtime state per tenant + skill. |
| `Sources/App/Migrations/M20_CreateSkillRunLog.swift`       | HER-168 | `skill_run_log` audit + cost attribution.       |
| `Sources/App/Migrations/M26_AddSkillsStateDailyRunCap.swift` | HER-193 | Per-day counter column.                         |

### 1.5 LLM-side slash command + context router — HER-172

| File                                                           | Purpose                                                                                                       |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `Sources/App/Skills/ContextRouter.swift`                       | Detects slash commands in `/v1/llm/chat` requests and redirects them to `SkillsController`-style dispatch.    |
| `Sources/App/Skills/ContextRouterSelector.swift`               | Entitlement gate (subscription tier check) for the router.                                                    |
| Middleware wired in `App+build.swift` on the `/v1/llm` group   |                                                                                                               |

---

## 2. Achievements — HER-196

Self-contained retention surface. Counters increment from existing
controller hot-paths; per-unlock APNS push fires fire-and-forget.

### 2.1 Schema + model

| File                                                                  | Purpose                                                                                                              |
| --------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `Sources/App/Migrations/M28_CreateAchievementProgress.swift`          | Creates `achievement_progress` table: `id`, `tenant_id` FK CASCADE, `achievement_key`, `progress_count`, `unlocked_at`. `UNIQUE (tenant_id, achievement_key)`. Index on `(tenant_id, unlocked_at DESC) WHERE unlocked_at IS NOT NULL`. |
| `Sources/App/Models/AchievementProgress.swift`                        | Fluent `Model` conforming to `TenantModel`. Public fields mirror the migration.                                      |

### 2.2 Catalog (code-defined)

| File                                                                  | Purpose                                                                                                        |
| --------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `Sources/App/Achievements/AchievementCatalog.swift`                   | `enum AchievementEvent`, `enum AchievementArchetypeKey`, `struct SubAchievement`, `struct AchievementCatalog`. `.current` is the static catalog: 4 archetypes (lightbringer / shadowlord / reignmaker / soulseeker) × 4 sub-achievements each. `catalogVersion` lets iOS detect new entries without a template fetch. |

Each sub-achievement names an `AchievementEvent`. The mapping:

| Archetype     | Sub-achievements (event → threshold)                                                                                                   |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| lightbringer  | first-spark (memoryUpserted ≥ 1), kindled-mind (≥10), illuminator (≥50), lightbearer (≥200)                                            |
| shadowlord    | shadow-touched (soulConfigured ≥ 1), deep-listener (chatCompleted ≥ 5), night-walker (≥25), umbral-sovereign (≥100)                    |
| reignmaker    | first-edict (queryRan ≥ 1), tactician (≥10), strategist (kbCompiled ≥ 5), regent (queryRan ≥ 100)                                      |
| soulseeker    | first-relic (vaultUploaded ≥ 1), collector (≥10), cartographer (spaceCreated ≥ 3), soulkeeper (vaultUploaded ≥ 100)                    |

### 2.3 Service + endpoints

| File                                                                  | Purpose                                                                                                              |
| --------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `Sources/App/Achievements/AchievementsService.swift`                  | `record(tenantID:event:)` — atomic-ish increment + unlock detection. Returns newly unlocked subs. `recordAndPush(tenantID:event:)` — controller hot-path entry: records, fans out push, swallows errors. |
| `Sources/App/Achievements/AchievementsController.swift`               | `GET /v1/achievements` (catalog joined to per-user progress); `GET /v1/achievements/recent?limit=N` (newest-first unlock feed). |
| `Sources/App/Middleware/RateLimitMiddleware.swift`                    | New `achievementsByUser` policy (60/min/userOrIP).                                                                    |
| `Sources/App/Services/APNSNotificationService.swift`                  | New `.achievement` push category + `notifyAchievement(userID:key:label:)` method.                                    |

### 2.4 Controller hooks (fire-and-forget)

Each call site adds a `Task.detached { await achievements.recordAndPush(...) }` at the success path. Field is `let achievements: AchievementsService?` on the controller struct — optional so existing constructors keep working without forcing the dependency on call sites that do not need it.

| Controller                                                          | Hook event               |
| ------------------------------------------------------------------- | ------------------------ |
| `Sources/App/Memory/MemoryController.swift::upsert`                 | `.memoryUpserted`        |
| `Sources/App/LLM/LLMController.swift::chat`                         | `.chatCompleted`         |
| `Sources/App/KB/KBCompileController.swift::compile`                 | `.kbCompiled`            |
| `Sources/App/Memory/QueryController.swift::query`                   | `.queryRan`              |
| `Sources/App/Vault/VaultController.swift::upload`                   | `.vaultUploaded`         |
| `Sources/App/Auth/SoulController.swift::put`                        | `.soulConfigured`        |

`.spaceCreated` is declared in `AchievementEvent` and covered by `soulseeker.cartographer`, but `SpacesController` does not yet emit it. Follow-up.

### 2.5 Wiring

`Sources/App/App+build.swift`:
- `M28_CreateAchievementProgress()` appended to migrations list.
- `achievementsService` constructed right after `pushService`.
- Threaded into the 6 controllers above as the new `achievements:` arg.
- `AchievementsController` mounted under `router.group("/v1/achievements")` behind `jwtAuthenticator` + `RateLimitMiddleware(policy: .achievementsByUser, ...)`.

### 2.6 Tests

| File                                                                  | Coverage                                                                                                                                                          |
| --------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Tests/AppTests/Achievements/AchievementsServiceTests.swift`          | Catalog deterministic JSON + structural invariants (4 archetypes, 3-5 subs each, every `AchievementEvent` covered). DB-gated (Postgres): `record` idempotent on `unlocked_at`, tenant counter partitioning, multi-step threshold crossing in a single burst. |
| `Tests/AppTests/Achievements/AchievementsFlowTests.swift`             | `/v1/achievements` and `/v1/achievements/recent` 401 unauth checks. Proves jwtAuthenticator is wired end-to-end.                                                  |
| `LuminaVaultCollection/Achievements/{List,Recent}.bru`                | Bruno requests with response-shape assertions. (Separate repo: `LuminaVaultCollection`.)                                                                          |

DB-gated tests need `docker compose up -d postgres`. Same gating as `TenantIsolationTests`.

---

## 3. How requests flow (call graphs)

### 3.1 Memory upsert

```
POST /v1/memory/upsert  →  jwtAuthenticator
                        →  RateLimitMiddleware(.captureByUser)
                        →  MemoryController.upsert
                              ├─ HermesMemoryService.upsert(tenantID:profileUsername:content:)
                              ├─ MemoryUpsertResponse returned to client
                              └─ Task.detached  →  AchievementsService.recordAndPush(.memoryUpserted)
                                                       ├─ AchievementProgress row(s) updated
                                                       └─ APNSNotificationService.notifyAchievement (per newly unlocked)
```

### 3.2 Achievements read

```
GET /v1/achievements         →  jwtAuthenticator
                              →  RateLimitMiddleware(.achievementsByUser)
                              →  AchievementsController.list
                                    ├─ AchievementsService.progress(for: tenantID)
                                    └─ Joined with AchievementCatalog.current → DTO
```

### 3.3 Skill invocation (currently scaffold)

```
POST /v1/skills/:name/run    →  jwtAuthenticator
                              →  RateLimitMiddleware(.skillRunByUser)
                              →  SkillsController.runSkill   (HER-148 scaffold returns 501)
                                    └─ HER-169 will:
                                         ├─ SkillCatalog.manifest(named:, for:)        (HER-167 parser, HER-168 catalog)
                                         ├─ SkillRunCapGuard.checkAndIncrement          (HER-193)
                                         ├─ SkillRunner.run(skill:tenantID:tier:...)
                                         └─ skill_run_log row written
```

### 3.4 LLM chat (slash-command capable)

```
POST /v1/llm/chat            →  jwtAuthenticator
                              →  RateLimitMiddleware(.chatByUser)
                              →  ContextRouterMiddleware              (HER-172, gated by users.context_routing)
                                    └─ If body starts with `/<skill-name>` → routes to SkillsController dispatch
                              →  LLMController.chat
                                    ├─ HermesLLMService.chat
                                    ├─ Task.detached APNSNotificationService.notifyLLMReply
                                    └─ Task.detached AchievementsService.recordAndPush(.chatCompleted)   (HER-196)
```

---

## 4. Migrations index

Append to `App+build.swift` in numeric order. All migrations must be
idempotent (`CREATE TABLE IF NOT EXISTS`, etc).

| #   | File                                                                  | Purpose                                                                |
| --- | --------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| 19  | `M19_CreateSkillsState.swift`                                         | Skills runtime state per tenant + skill.                               |
| 20  | `M20_CreateSkillRunLog.swift`                                         | Skill run audit + cost attribution.                                    |
| 26  | `M26_AddSkillsStateDailyRunCap.swift`                                 | Per-tenant per-skill per-day counter.                                  |
| 27  | `M27_AddUserTimezone.swift`                                           | User timezone column used by `CronScheduler`.                          |
| 28  | `M28_CreateAchievementProgress.swift`                                 | Per-tenant achievement counters + unlock timestamps.                    |
| 29  | `M29_CreateUserHermesConfig.swift`                                    | Per-tenant BYO Hermes endpoint config (HER-197).                       |

(Numbers <19 are pre-session; see the file list in `Sources/App/Migrations/`.)

---

## 5. Where to look when X breaks

| Symptom                                              | Start here                                                                          |
| ---------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Built-in skill not loading                           | Bundle inspection: `Sources/App/Resources/Skills/<name>/SKILL.md`. Then `SkillCatalog.loadDirectory`. |
| Vault skill not appearing                            | Check `<vault.rootPath>/tenants/<tenantID>/skills/<name>/SKILL.md` on disk. Logs from `SkillCatalog` will say `parse failed` or `name/dir mismatch`. |
| SKILL.md parse error                                 | Run `SkillManifestParser().parse(...)` against the file in isolation; error case names the missing field. |
| Skill never fires                                    | Currently expected — `SkillRunner` is the HER-169 stub. Returns 501.                |
| Achievement counter not advancing                    | `AchievementsService.recordAndPush` swallows errors at `warning` log level. Search logs for `achievements record failed`. |
| Achievement push not arriving                        | APNS gated by `apns.enabled` config + presence of a `DeviceToken` row. `APNSNotificationService.notify` logs each fan-out. |
| Catalog endpoint returns 401                         | Expected without `Authorization: Bearer <jwt>`. JWT middleware mounted on the group. |
| Rate-limit policy doesn't fit                        | `Sources/App/Middleware/RateLimitMiddleware.swift` — every new route picks one from the `static let` constants. |

---

## 6. Conventions noted during the session

These are not rules — just patterns the codebase consistently uses.
Worth mirroring in new work.

- Fire-and-forget side effects use `Task.detached { ... }` after the
  user-facing response is constructed, never before. The detached task
  must not throw — wrap in `try?` or catch internally. Pattern is
  best-illustrated by `LLMController.chat` (APNS push) and the six
  `recordAndPush` hooks added in HER-196.
- Controllers declare new optional dependencies as `let foo: FooService?`
  so existing constructors don't break. `App+build.swift` is the single
  point that threads the real instance in. Tests construct nothing
  directly; they exercise routes via `HummingbirdTesting`.
- Service-layer types are `struct ... : Sendable` when they hold only
  value-or-reference-by-design state, `actor` when they protect mutable
  state across tasks. `SkillCatalog` is an actor; `AchievementsService`
  is a struct (its Fluent `db()` is reentrant-safe).
- Tests that touch the database mirror `TenantIsolationTests`: a
  per-test `withFluent` helper, all migrations registered explicitly
  (don't share state across tests), and the comment block reminds the
  reader to `docker compose up -d postgres` first.
- Migrations must be idempotent in both `prepare` and `revert`. They
  always do `CREATE TABLE IF NOT EXISTS` / `DROP TABLE IF EXISTS` and
  drop named indexes the same way.

---

## 7. Open follow-ups

- HER-169 lands the real `SkillRunner` and flips `SkillsController` from 501.
- HER-189 / HER-190 / HER-191 SKILL.md prompts are scaffolded; their
  E2E fixture tests will go live once HER-169 wires the runner.
- `SpacesController.create` should emit `.spaceCreated` so
  `soulseeker.cartographer` can ever unlock.
- `AchievementCatalog.current` content (labels, thresholds) wants a
  product pass before launch. The `catalogVersion` bump on any edit
  lets iOS surface "new achievement available" without a template fetch.
- Concurrency edge case in `AchievementsService.record`: two events
  racing on the same `(tenant_id, achievement_key)` can lose one
  counter increment. Unlock contract is preserved because both writers
  see the same pre-threshold value and at most one observes the
  crossing. Harden with a Postgres `INSERT ... ON CONFLICT DO UPDATE`
  upsert if it ever shows up in production.
