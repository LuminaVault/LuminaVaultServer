# LuminaVaultServer — Agent Instructions

These rules apply to every agent (Claude, Codex, etc.) working in this repo. They are non-negotiable unless the user explicitly overrides them in-session.

## 1. Swift 6 Concurrency

- Target Swift 6 language mode with strict concurrency checking. Do not silence warnings with `@unchecked Sendable` or `nonisolated(unsafe)` unless there is a documented reason in a code comment.
- Prefer structured concurrency: `async let`, `TaskGroup`, `withThrowingTaskGroup`. Avoid detached `Task { ... }` for fire-and-forget work — it loses cancellation and error propagation.
- Use `actor` for shared mutable state. Use `Sendable` types across isolation boundaries. Mark protocol requirements `Sendable` when conformers cross actors.
- Hummingbird/Fluent lifecycle code must shut down via the structured `withTestFluent` helper or `ServiceGroup`. Never use `defer { Task { try? await x.shutdown() } }` — the detached shutdown races teardown and SIGTRAPs.
- New types default to `struct` + `Sendable`. Reach for `class` only when reference semantics are required.

## 2. Bruno Collection — Backend Is The Source

- `Sources/AppAPI/openapi.yaml` is the **single source of truth** for the API contract.
- The Bruno collection in the sibling repo `../LuminaVaultCollection/LuminaVaultServer/` (override: `LUMINAVAULT_COLLECTION_PATH`) is **generated**, not authored. Regenerate via `make bruno-regen` (which calls `scripts/generate-bruno.sh`).
- Do not hand-edit generated Bruno `.bru` files. If a request is wrong, fix `openapi.yaml` and regenerate.
- Manual top-level Bruno directories (e.g., custom collections outside `LuminaVaultServer/`) are preserved by the script — leave those alone.
- When adding or changing an endpoint: update `openapi.yaml` first, then run `make bruno-regen`, then commit both in the same change.

## 3. LuminaVaultShared — Single Source for DTOs

- All wire-format DTOs shared between client and server live in `LuminaVaultShared/Sources/LuminaVaultShared/APIDTOs.swift` (the sibling repo).
- Do **not** duplicate DTOs in `LuminaVaultServer` or `LuminaVaultClient`. If a server-only or client-only model is required, name and locate it so the boundary is obvious (e.g., `internal struct ...Row` for DB rows, `...ViewState` for UI-only).
- When adding a new DTO: add it to `LuminaVaultShared` first, bump the shared package, then consume in server + client.
- If you find duplicate DTO definitions, treat it as a bug: consolidate into `LuminaVaultShared` and delete the duplicates.

## 4. Guided onboarding — the server owns the three latches

- The cross-platform contract is `LuminaVaultShared/docs/guided-start.md` (the
  sibling repo). Read it before touching anything under `Sources/App/Onboarding`
  or any of the three latches. iOS, web and a future Android client all read
  that one document, so a change here that is not in it is a change three
  clients will disagree about.
- `firstCaptureCompleted`, `firstKBCompileCompleted` and `firstQueryCompleted`
  are latched **server-side only**. A client must never set them. That is what
  lets two devices show the same progress without talking to each other, and it
  is why the clients poll.
- `guidedStartDismissedAt` is the one two-way field on the onboarding row. The
  seven completion flags stay one-way and reject `false`.
- Latches go through `OnboardingLatches`, which is deliberately non-throwing: a
  latch failing must never fail the user action that triggered it.

## How To Apply

- Before opening a PR that touches API shape: confirm `openapi.yaml` updated, `make bruno-regen` run, DTO present in `LuminaVaultShared`.
- Before merging concurrency-sensitive code: build with strict concurrency and ensure no new warnings.
