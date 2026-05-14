# HER-200 — Patterns to change in Hummingbird

Audit of structural concurrency / sendability / maintainability issues in
LuminaVaultServer. Tracked findings live as `// HER-200:` markers in the
source so `grep -rn 'HER-200:' Sources/ docs/` lists outstanding work.

## Status

| ID | Sev | Status |
|----|-----|--------|
| H1 EventBus reentrancy | HIGH | ✅ fixed (actor → final class + NSLock; sync register) |
| H2 LLMController detached | HIGH | ✅ fixed (Task.detached → structured Task + explicit error log) |
| H3 SkillRunner event loop | HIGH | ✅ fixed (Task → Task.detached(priority: .utility); cancellation via stopEventSubscriptions) |
| M1 User @unchecked Sendable | MEDIUM | ✅ documented (invariant comment; Swift-6 migration deferred) |
| M2 buildRouter god function | MEDIUM | 📝 deferred (own milestone; marker stays in source) |
| M3 In-memory rate limiter | MEDIUM | ✅ fixed (rateLimit.storageKind config + makeRateLimitStorage factory; Redis seam reserved) |
| M4 CronScheduler not run() | MEDIUM | ✅ fixed (appended to managedServices) |
| L1 WebSocket broadcast | LOW | ✅ fixed (16 KB size cap + JSON-with-type-field validation before fan-out) |
| L2 MemoryDTO.fromMemory throws | LOW | ✅ fixed (Memory.savedID accessor; fromMemory non-throwing) |

---

## HIGH

### H1 — Actor reentrancy / fire-and-forget subscriber registration
**Where:** `Sources/App/Skills/EventBus.swift:102`

`subscribe(eventType:)` is `nonisolated` and constructs the `AsyncStream`
synchronously, but the closure that registers the subscriber fires a
`Task { await self.register(...) }`. If the stream is dropped before that
task runs, the subscriber entry leaks (negligible in practice — the task
runs immediately — but still a smell).

**Fix:** Make `register` `nonisolated(unsafe)` (the actor map is the only
mutable state; an actor hop is overkill here) and call it directly inside
the stream factory closure. Same for `unregister` in `onTermination`.

---

### H2 — `LLMController.chat` fires detached tasks with no cancellation
**Where:** `Sources/App/LLM/LLMController.swift:58`, `:66`

```swift
Task.detached { try? await pushService.notifyLLMReply(...) }
Task.detached { await achievements.recordAndPush(...) }
```

Detached tasks survive the request handler's cancellation. If the client
disconnects mid-chat, these keep running. APNS is best-effort so detached
is debatable; `achievements.recordAndPush` may fan-out to LLM calls and
is more expensive to leak.

**Fix:** Switch to structured `Task { ... }` so cascading cancellation
applies. Use `Task.detached` only when the work must outlive the request
and document the reason inline.

---

### H3 — `SkillRunner.startEventSubscriptions` uses `Task` from non-async context
**Where:** `Sources/App/Skills/SkillRunner.swift:100`

```swift
let task = Task<Void, Never> { for await event in stream { ... } }
```

Called from `buildRouter` (non-async). `Task` inherits the top-level task
and its task-locals — surprising for a long-lived event loop. The
`eventSubscriptions` array stores tasks but nothing cancels them outside
explicit `stopEventSubscriptions()`.

**Fix:** `Task.detached` is more appropriate for indefinite event loops,
*provided* explicit cancellation propagation is wired (probably via the
existing `eventSubscriptions` teardown). Alternatively register as a
`Service` so `ServiceGroup` owns the lifecycle.

---

## MEDIUM

### M1 — `User` model is `@unchecked Sendable`
**Where:** `Sources/App/Models/User.swift:4`

Standard Fluent practice — model instances are reference types but the
convention is one fresh instance per request. `@unchecked Sendable` is a
compiler escape hatch, not a guarantee.

**Fix:** Document the invariant explicitly in a doc comment ("never cache
or reuse model instances across requests"). Real fix is Swift-6 strict
concurrency migration — out of scope for HER-200 itself.

---

### M2 — `App+build.swift` is an 842-line god function
**Where:** `Sources/App/App+build.swift` (whole file)

Single `buildRouter` builds every service, wires every controller,
mounts middleware, configures CORS / OTel / JWT / auth / LLM / skills /
health / admin / achievements / onboarding / account deletion / device
tokens / KB compile / WebSocket. Largest maintenance liability in repo.

**Fix:** Extract `buildAuthRoutes`, `buildSkillRoutes`, `buildMemoryRoutes`,
`buildAdminRoutes`, `buildLLMRoutes` etc. Each takes the shared
`RouterGroup<AppRequestContext>` (or returns a sub-router) and the
service bundle. Pure refactor — keep semantics identical.

---

### M3 — `MemoryPersistDriver` rate limiter is in-memory only
**Where:** `Sources/App/App+build.swift:306`

```swift
let rateLimitStorage = MemoryPersistDriver()
```

Single-replica only. Multi-replica deployments lose effective rate
limiting because each replica has its own bucket.

**Fix:** Add `rateLimitStorageKind` to `ConfigReader` (mirroring `smsKind`)
and a `makeRateLimitStorage()` factory. Start with `MemoryPersistDriver`,
add Redis-backed driver when needed. Surface the factory through
`ServiceContainer`.

---

### M4 — `CronScheduler` constructed but never run
**Where:** `Sources/App/App+build.swift:762`

```swift
_ = cronScheduler // HER-170 — surface to appServices for ServiceGroup lifecycle
```

Scheduler is constructed but never appended to the `appServices` array,
so `ServiceGroup` never calls `run()`. Currently a no-op because the skill
catalog is empty; once HER-169 lands this is a production bug — skills
register but never tick.

**Fix:** Append `cronScheduler` to `appServices` (alongside `fluent` and
`providerRegistry`). Verify `CronScheduler` conforms to `Service`; if
not, wrap it.

---

## LOW

### L1 — WebSocket broadcast has no tenant isolation check at this layer
**Where:** `Sources/App/App+build.swift:797`

```swift
await connectionManager.broadcast(tenantID: tenantID, message: message)
```

Every inbound message is broadcast to every connection for that tenant
without format validation at this layer. Presumably `ConnectionManager`
or a downstream validator handles it, but the broadcast site itself is
unfiltered.

**Fix:** Decide owner — either validate/whitelist message format at the
broadcast site, or document explicitly that `ConnectionManager.broadcast`
trusts the caller and add validation in `ConnectionManager` itself.

---

### L2 — `MemoryDTO.fromMemory` uses `try memory.requireID()`
**Where:** `Sources/App/Memory/MemoryController.swift:27`

Every DTO conversion can throw because `Fluent.Model.id` is optional.
Any `Memory` from a query has an ID, but the type system doesn't
guarantee it.

**Fix:** Add an internal `extension Memory { var savedID: UUID { ... } }`
that asserts (or returns a typed wrapper) for post-fetch instances. Keep
the throwing path for the pre-save case but separate the two flows.

---

## Where this levels up

- Break `buildRouter` into composable pieces (M2) — biggest delta from
  "works" to "team-maintainable".
- Swift-6 strict concurrency migration — `@unchecked Sendable` (M1) is a
  band-aid; proper actor/value-type Sendable conformance is the goal.
- Codify "fire-and-forget Task vs cascading cancellation" guidance in
  `AGENTS.md` (H2, H3 fixes set the precedent).
- Migrate the EventBus from "logs events" to "dispatches skills" — out of
  scope for HER-200 itself but HER-169 builds on this audit's H1 fix.

---

## How to work this ticket

Each finding ships as its own sub-PR. Suggested order:

1. H2 (LLMController detached) — single-file change, immediate hygiene win
2. M4 (CronScheduler wiring) — single-line fix once verified
3. H1 (EventBus reentrancy) — small scope, unblocks HER-169
4. M3 (Redis rate limiter factory) — when a second replica ships
5. H3 (SkillRunner Task lifecycle) — pair with HER-169 dispatch work
6. L1, L2 — opportunistic
7. M2 (god function refactor) — own milestone
8. M1 (Sendable migration) — own milestone
