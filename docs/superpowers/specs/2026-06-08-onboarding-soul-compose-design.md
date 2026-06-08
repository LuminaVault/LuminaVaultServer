# Onboarding-Seeded SOUL.md — Design

**Date:** 2026-06-08
**Status:** Approved
**Scope:** LuminaVaultServer + LuminaVaultShared (iOS client onboarding UI is a separate client-repo task)

## Problem

On signup, `SOULDefaultTemplate.render()` writes a SOUL.md full of `<!-- TODO -->`
placeholder comments into the user's vault (and mirrors to `data/hermes/SOUL.md`).
Onboarding only flips a boolean `OnboardingState.soulConfiguredCompleted` — it never
writes persona content. Result: the agent runs on its factory/default voice even
after onboarding "completes," because the SOUL.md it reads every turn is still the
unfilled template.

Goal: the onboarding flow should **produce a real, filled SOUL.md** from the user's
onboarding answers.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Generation strategy | **Hybrid** — deterministic template fill now, LLM synthesis later | Lowest risk; SOUL is prompt-injection-scanned every load, so a deterministic body is safe and testable. LLM is a phase-2 upgrade behind one seam. |
| Inputs collected | agent name, tone, role, autonomy | Minimal set that meaningfully personalizes identity/voice/operations. |
| Render site | **Server** | Single source of truth, unit-testable, mirrors vault→hermes, and the phase-2 LLM upgrade slots in server-side with zero client change. |
| User preview | **Write-and-done** | Reuses the already-shipped Settings→Your Agent→Personality editor for later tweaks. Endpoint returns rendered markdown so client *can* show it, but no new onboarding editor UI. |

## Architecture

### Data flow

```
iOS onboarding (name, tone, role, autonomy picks)
  → POST /v1/soul/compose  { agentName, tone, role, autonomy }
  → SoulController.compose()
      → SOULComposer.render(req, username:, now:)  → filled markdown
      → SOULService.write(for: user, body:)         → vault file + mirror data/hermes/SOUL.md
      → achievements.enqueue(.soulConfigured)
  → 200 SoulResponse { markdown, updatedAt }
iOS then PATCHes onboarding soulConfiguredCompleted = true  (existing path, unchanged)
```

The compose endpoint is **single-purpose**: it renders + writes SOUL only. It does
NOT mutate onboarding flags. The client marks `soulConfiguredCompleted` via the
existing `PATCH /v1/onboarding`, keeping SOUL writes idempotent and re-runnable
(user can re-run onboarding or recompose without onboarding-state coupling).

## Components

### 1. LuminaVaultShared — new DTO (version bump 0.77.0 → 0.78.0)

```swift
public struct SoulComposeRequest: Codable, Sendable {
    public let agentName: String        // default "Hermes" applied client-side or server-side if empty
    public let tone: SoulTone
    public let role: SoulRole
    public let autonomy: SoulAutonomy
}

public enum SoulTone: String, Codable, Sendable {
    case warm, conciseTechnical, playful, coach
}
public enum SoulRole: String, Codable, Sendable {
    case assistant, coworker, coach, secondBrain
}
public enum SoulAutonomy: String, Codable, Sendable {
    case askFirst, suggest, act
}
```

Reuses the existing `SoulResponse { markdown, updatedAt }` for the reply.

> Decoder note: `AppRequestContext` uses a default `JSONDecoder` with **no**
> snake_case conversion (see prior incident `server_request_decoder_no_snakecase`).
> The client sends `convertToSnakeCase`. Enum raw values are single lowercase words
> (`warm`, `coach`, `act`) so they round-trip fine, but the camelCase field names
> (`agentName`, etc.) require the client to NOT snake-case this body, OR the DTO to
> declare explicit `CodingKeys`. **Add explicit `CodingKeys` to `SoulComposeRequest`**
> mapping snake_case wire names → camelCase properties, matching how other request
> DTOs in this codebase defend against the mismatch.

### 2. Server — `Sources/App/Auth/SOULComposer.swift` (new, sibling to `SOULDefaultTemplate.swift`)

```swift
enum SOULComposer {
    static let version = 1
    static func render(_ req: SoulComposeRequest, username: String, now: Date = Date()) -> String
}
```

- Emits the same `---` frontmatter block as `SOULDefaultTemplate` (`version`,
  `username`, `created_at`) for consistency with the existing file contract.
- Renders a **filled** SOUL using the section skeleton: identity → values → voice →
  operations → restrictions → failure protocol.
- Enum → prose mapping (deterministic), e.g.:
  - `tone`: `.warm` → "warm, encouraging, plain-spoken"; `.conciseTechnical` →
    "concise technical expert, no fluff, just facts"; `.playful` → "playful, light,
    occasional wit"; `.coach` → "direct coach — challenges and motivates".
  - `role`: `.assistant`/`.coworker`/`.coach`/`.secondBrain` → identity + relationship line.
  - `autonomy`: `.askFirst` → "confirm before any non-trivial action";
    `.suggest` → "propose actions, wait for go-ahead"; `.act` → "act on clear intent,
    report after".
- Target ≤ ~60 lines so it doesn't burn tokens every turn.
- **Phase-2 LLM seam:** `render` is the single swap point. A future
  `SOULComposer.renderLLM(...)` (or a strategy injected into the controller) replaces
  the deterministic body. Endpoint + DTO stay identical.

### 3. Server — `SoulController.compose()` (extend existing `SoulController`)

- New route: `router.post("compose", use: compose)` under `/v1/soul`, behind JWT,
  same per-route rate-limit as `put` (wired in `App+build.swift`).
- `compose(_:ctx:)`:
  1. `let user = try ctx.requireIdentity()`
  2. decode `SoulComposeRequest`
  3. `let body = SOULComposer.render(req, username: user.username)`
  4. `try service.write(for: user, body: body)` — reuses 64 KiB cap; on
     `SOULServiceError.tooLarge` throw `HTTPError(.contentTooLarge, …)` (mirror `put`)
  5. `achievements?.enqueue(tenantID:, event: .soulConfigured)`
  6. return `SoulResponse(markdown: body, updatedAt: service.updatedAt(for: user))`
- Wrap in `telemetry.observe("soul.compose")`.

### 4. openapi.yaml

- Add `POST /v1/soul/compose` with `SoulComposeRequest` request body + `SoulResponse`
  (200) and `413` for too-large. Add the three enums + request schema to components.
- Regenerate Bruno collection (`make bruno-regen`) for the new route.

## Error handling

- Too-large body → `413 Content Too Large` (reuse `put` path).
- Invalid/unknown enum value → `400` from decode failure (default Hummingbird behavior).
- Empty `agentName` → server defaults to `"Hermes"` in `SOULComposer.render`.
- Write/IO failure → propagated as `500` via existing `SOULService` error surface.

## Testing

- `SOULComposerTests`:
  - each `tone`/`role`/`autonomy` enum produces its expected section text
  - frontmatter present + well-formed (`version`, `username`, `created_at`)
  - output under 64 KiB cap and ≤ ~60 lines
  - empty agentName defaults to "Hermes"
- `SoulControllerTests` (compose):
  - POST compose → 200, `SoulResponse.markdown` == rendered body
  - vault file written AND `data/hermes/SOUL.md` mirror updated (assert via `SOULService` read path)
  - achievement `.soulConfigured` enqueued
  - oversized synthetic input → 413 (if reachable; otherwise covered by `put` tests)

> Note: repo `test` job has a known SIGILL flake (HER-310). Run targeted
> `swift test --filter SOULComposer` locally; verify build with
> `swift build; echo EXIT=$?` (not piped — see `feedback_verify_build_exit_code`).

## Out of scope

- iOS onboarding UI (picker screens, POST wiring) — separate LuminaVaultClient task.
- LLM synthesis (phase 2) — seam reserved, not built.
- Migrating existing users' placeholder SOULs — not backfilled.

## Files touched

- `LuminaVaultShared`: `SoulComposeRequest` + 3 enums; version → 0.78.0
- `Sources/App/Auth/SOULComposer.swift` (new)
- `Sources/App/Auth/SoulController.swift` (add `compose`)
- `Sources/App/App+build.swift` (route already grouped under `/v1/soul`; verify rate-limit)
- `Sources/AppAPI/openapi.yaml` (new route + schemas)
- `Package.swift` (repin LuminaVaultShared 0.78.0)
- Tests: `SOULComposerTests`, `SoulControllerTests`
