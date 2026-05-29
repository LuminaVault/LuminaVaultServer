# HER-310 Fix — Achievements Worker (kill fire-and-forget DB tasks)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or
> superpowers:executing-plans. Steps use `- [ ]`. Authored without a local Swift build —
> the **docker/CI build is the verification loop**; build after each task.

**Goal:** Stop the `test` job (and prod) crashing with
`FluentKit/Databases.swift:190: Fatal error: No default database configured.` (signal 5).

**Root cause:** 6 controller hot-paths fire `Task.detached { await achievements.recordAndPush(...) }`.
`recordAndPush` calls `fluent.db()` (`AchievementsService.swift:82`). These detached tasks
outlive the request/test; when the (ephemeral, in tests) `Fluent` shuts down, the in-flight
task calls `.db()` on a torn-down `Fluent` → FluentKit `fatalError` → whole binary aborts.
Parallel test execution just makes it fire more often.

**Approach (option B):** introduce `AchievementsWorker: Service` that owns the app's
long-lived `AchievementsService` + an `AsyncStream` inbox. Handlers `enqueue(...)` —
**synchronous, no `Task`, no DB**. The worker drains the inbox on its own lifetime and is
registered in the ServiceGroup **after** `fluent` (so it shuts down **before** Fluent
closes — `appServices` starts `[fluent]`, ServiceGroup shuts down in reverse). No `.db()`
call can ever race a dead database again.

**Tech:** Swift 6, ServiceLifecycle (`Service`, `withGracefulShutdownHandler`), AsyncStream.

---

## File map
- Create `Sources/App/Achievements/AchievementsWorker.swift` — the Service.
- Modify `Sources/App/App+build.swift` (~:333) — build the worker wrapping
  `achievementsService`; append to the managed-services array; thread the worker into the
  6 write-path controllers (keep `achievementsService` for the read-only
  `/v1/achievements` endpoints).
- Modify the 6 call sites — replace `Task.detached { await achievements.recordAndPush(t,e) }`
  with `achievementsWorker.enqueue(tenantID: t, event: e)`:
  - `Memory/QueryController.swift:67,122`
  - `Memory/MemoryController.swift:142`
  - `Capture/LinkCaptureService.swift:105`
  - `KB/MemoryCompileController.swift:87`
  - `Auth/SoulController.swift:53`
  - `LLM/LLMController.swift:137` (currently `Task {`)
- Test `Tests/AppTests/Achievements/AchievementsWorkerTests.swift`.

---

## Task 1: Create `AchievementsWorker`

**Files:** Create `Sources/App/Achievements/AchievementsWorker.swift`; Test
`Tests/AppTests/Achievements/AchievementsWorkerTests.swift`.

- [ ] **Step 1: Write the failing test.**

```swift
@testable import App
import Logging
import ServiceLifecycle
import Testing

@Suite struct AchievementsWorkerTests {
    // Enqueue is non-blocking and never touches the DB. After the worker
    // runs and drains, the underlying service has processed the job.
    @Test func enqueueDrainsThroughService() async throws {
        try await withTestFluent(label: "achievements-worker") { fluent in
            // full migration stack so recordAndPush can write
            try await fluent.migrate()
            let svc = AchievementsService(fluent: fluent, logger: .init(label: "t"))
            let worker = AchievementsWorker(service: svc, logger: .init(label: "t"))

            let tenant = UUID()
            worker.enqueue(tenantID: tenant, event: .queryRan)   // sync, no await

            // Run the worker, then trigger graceful shutdown so run() returns.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await worker.run() }
                // let it drain, then finish the inbox
                try await Task.sleep(for: .milliseconds(200))
                worker.shutdownForTests()
                try await group.waitForAll()
            }

            let progress = try await svc.progress(for: tenant)
            #expect(!progress.isEmpty)   // queryRan recorded ≥1 row
        }
    }

    // Enqueue after the inbox is finished must NOT crash (no fatalError).
    @Test func enqueueAfterShutdownIsSafe() async {
        let fluentless = AchievementsService(fluent: .init(logger: .init(label: "t")), logger: .init(label: "t"))
        let worker = AchievementsWorker(service: fluentless, logger: .init(label: "t"))
        worker.shutdownForTests()                       // finish the stream
        worker.enqueue(tenantID: UUID(), event: .queryRan)  // dropped, no crash
    }
}
```
> ⚠ confirm: `AchievementEvent.queryRan` spelling + that `migrate()` is the helper used
> elsewhere (mirror an existing AchievementsServiceTests setup for the migration call).

- [ ] **Step 2: Run — fails (type missing).**
Run: `swift test --filter AchievementsWorkerTests` → FAIL: `AchievementsWorker` undefined.

- [ ] **Step 3: Implement the worker.**

```swift
import Foundation
import Logging
import ServiceLifecycle

/// HER-310 — achievement recording moved OFF controller hot-paths and OFF
/// fire-and-forget `Task.detached`. Handlers call `enqueue(...)` (synchronous,
/// no `Task`, no DB). This `Service` drains the inbox using the app's
/// long-lived `Fluent` and is registered AFTER `fluent` in the ServiceGroup,
/// so it stops draining BEFORE Fluent shuts down — no `.db()` call can race a
/// torn-down database (the old "No default database configured" crash).
///
/// `@unchecked Sendable`: all stored properties are immutable and themselves
/// Sendable (AsyncStream + its Continuation are Sendable; AchievementsService
/// is a value type of Sendable members). Marked explicitly because Swift does
/// not synthesize Sendable for classes.
final class AchievementsWorker: Service, @unchecked Sendable {
    struct Job: Sendable {
        let tenantID: UUID
        let event: AchievementEvent
    }

    private let service: AchievementsService
    private let stream: AsyncStream<Job>
    private let continuation: AsyncStream<Job>.Continuation
    private let logger: Logger

    init(service: AchievementsService, logger: Logger, bufferSize: Int = 256) {
        self.service = service
        self.logger = logger
        (self.stream, self.continuation) = AsyncStream<Job>.makeStream(
            bufferingPolicy: .bufferingNewest(bufferSize),
        )
    }

    /// Non-blocking. Safe to call from a request handler. Never spawns a Task,
    /// never touches the DB. Dropped (logged) if the buffer is full or the
    /// worker has already shut down.
    func enqueue(tenantID: UUID, event: AchievementEvent) {
        switch continuation.yield(Job(tenantID: tenantID, event: event)) {
        case .dropped:
            logger.warning("achievements inbox full; dropped \(event.rawValue)")
        case .terminated:
            logger.debug("achievements worker stopped; dropped \(event.rawValue)")
        default:
            break
        }
    }

    /// Test-only: end the inbox so `run()` returns without a ServiceGroup.
    func shutdownForTests() {
        continuation.finish()
    }

    func run() async throws {
        await withGracefulShutdownHandler {
            for await job in stream {
                await service.recordAndPush(tenantID: job.tenantID, event: job.event)
            }
        } onGracefulShutdown: { [continuation] in
            // Stop accepting; the for-await loop ends after in-flight job.
            continuation.finish()
        }
    }
}
```

- [ ] **Step 4: Run — passes.** `swift test --filter AchievementsWorkerTests` → PASS.
- [ ] **Step 5: Commit.**
```bash
git add Sources/App/Achievements/AchievementsWorker.swift Tests/AppTests/Achievements/AchievementsWorkerTests.swift
git commit -m "feat(achievements): lifecycle-managed worker draining an inbox (HER-310 groundwork)"
```

---

## Task 2: Wire the worker into the app + ServiceGroup

**Files:** Modify `Sources/App/App+build.swift` (around the `achievementsService`
construction, ~:333, inside the router builder that has the `managedServices: inout
[any Service]` array — same array seeded `[fluent]` at :189).

- [ ] **Step 1:** Right after `let achievementsService = AchievementsService(...)` (~:338):
```swift
// HER-310 — drain achievement writes through a lifecycle-managed worker so
// they never run as fire-and-forget tasks that touch Fluent after teardown.
let achievementsWorker = AchievementsWorker(
    service: achievementsService,
    logger: Logger(label: "lv.achievements.worker"),
)
managedServices.append(achievementsWorker)   // after `fluent` ⇒ shuts down before it
```
> ⚠ confirm the in-scope name of the managed-services array here (it's the `inout`
> param threaded from `appServices` at :189 — likely `managedServices`). Append to THAT.

- [ ] **Step 2:** Thread `achievementsWorker` into the 6 write-path controllers/services
  at their construction sites in this builder (they currently receive
  `achievements: achievementsService`). Add an `achievementsWorker: achievementsWorker`
  init parameter to each (keep `achievementsService` only where read endpoints need it —
  the `/v1/achievements` catalog/recent controller keeps `achievementsService`).

- [ ] **Step 3:** `swift build` → resolve any Sendable / init-signature errors. Expected
  clean once the 6 controllers accept the worker (Task 3 updates their bodies).
- [ ] **Step 4: Commit.**
```bash
git add Sources/App/App+build.swift
git commit -m "feat(achievements): construct + register AchievementsWorker (shuts down before Fluent)"
```

---

## Task 3: Replace the 6 fire-and-forget call sites

**Files:** the 6 listed files. Each currently has a line like:
```swift
Task.detached { await achievements.recordAndPush(tenantID: tenantID, event: .queryRan) }
```

- [ ] **Step 1:** In each controller, store the injected worker
  (`let achievementsWorker: AchievementsWorker`) and replace the detached call with:
```swift
achievementsWorker.enqueue(tenantID: tenantID, event: .queryRan)
```
  Per-site events (keep the existing event for each): `QueryController` ×2 `.queryRan`;
  `MemoryController` `.memoryUpserted`; `LinkCaptureService` `.vaultUploaded`;
  `MemoryCompileController` `.kbCompiled`; `SoulController` `.soulConfigured`;
  `LLMController` `.chatCompleted` (also drop its `Task {`).
  Remove the now-unused `achievements`/`AchievementsService` field from any controller that
  only used it for the fire-and-forget write.

- [ ] **Step 2:** `swift build` → clean.
- [ ] **Step 3:** Run the previously-crashing suites locally/CI:
  `swift test` (serial; default is `--no-parallel`). Expected: **no `No default database
  configured` fatalError, no signal 5.**
- [ ] **Step 4: Commit.**
```bash
git add Sources/App/Memory Sources/App/Capture Sources/App/KB Sources/App/Auth Sources/App/LLM
git commit -m "fix(achievements): enqueue to worker instead of Task.detached (fixes HER-310 SIGTRAP)"
```

---

## Verification
- `swift test` (serial) → green, no signal 5, no `No default database configured`.
- Optional stress: temporarily run `swift test --parallel` — should now ALSO survive
  (the crash was the detached-task race, not parallelism itself), confirming the real fix.
- Prod behaviour unchanged: achievements still record + push + publish
  `.achievementUnlocked`; only the *execution context* moved from a per-request detached
  task to the app-lifetime worker. Request latency drops slightly (enqueue is sync).

## Done-when
The `test` job is green and stays green → promote `test` to a required check in
`branch-protection-main.json` / `branch-protection-dev.json` (the long-blocked goal).

## Notes / risks
- `withGracefulShutdownHandler` requires the worker to be run by the ServiceGroup; the
  `app.test(.router)` harness runs the group, so the worker drains + stops before Fluent in
  tests too. ⚠ confirm `ServiceLifecycle` is importable in the App target (it is —
  `MeTodayCache` already uses `Service`).
- If `AchievementsService` turns out non-Sendable (e.g. a non-Sendable member), the
  `@unchecked Sendable` on the worker is the documented escape hatch (all access is through
  the serialized drain loop). Keep the comment explaining why.
