# P1 — Redis-Backed Stateless API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Build-environment caveat:** This plan was authored without a Swift toolchain to
> compile against. All code quoted from the *existing* codebase is exact. Code that calls
> the **RediStack / hummingbird-redis** library is written with the intended logic and the
> specific symbol named, marked `⚠ confirm API`. The executing engineer/agent MUST have a
> working `swift build` and verify those signatures against the resolved
> `hummingbird-redis` version before committing each task.

**Goal:** Make the Hummingbird API horizontally scalable by moving every piece of
in-process shared state (rate-limit counters, pre-auth OTP challenges, the `me/today`
cache) onto Redis, then run 2+ API replicas safely.

**Architecture:** Add a single shared `RedisConnectionPoolService` to the app. Back the
rate-limiter with HB's `RedisPersistDriver`. Re-implement `PreAuthChallengeStore` and
`MeTodayCache` against Redis (TTL keys + atomic ops) while keeping their existing public
method signatures so call sites are untouched. EventBus stays in-process — because the
cache store itself moves to Redis, an invalidation on any replica is a Redis `DEL` visible
to all.

**Tech Stack:** Swift 6, Hummingbird 2, `hummingbird-redis` (RediStack), ServiceLifecycle,
docker-compose.

---

## Scope

In: Redis dependency + lifecycle, rate-limit Redis driver, `PreAuthChallengeStore` →
Redis, `MeTodayCache` → Redis, 2-replica compose + a multi-replica integration test.
Out (later phases): K8s/Terraform/ArgoCD (P2+), ingestion queue (P3), Hermes operator
(P4+). The achievement-unlock cache lives inside `MeTodayCache`'s invalidation path, so no
separate component.

## File map

- Modify `Package.swift` — add `hummingbird-redis` package + `HummingbirdRedis` product.
- Create `Sources/App/Infra/RedisConnection.swift` — builds the shared
  `RedisConnectionPoolService` from config; single construction site.
- Modify `Sources/App/Middleware/RateLimitStorageFactory.swift` — implement the `.redis`
  branch.
- Modify `Sources/App/App+build.swift` — construct Redis service, pass its persist driver
  into `makeRateLimitStorage`, add the service to the `ServiceGroup`, inject the Redis
  client into the two stores.
- Create `Sources/App/Infra/RedisPreAuthChallengeStore.swift` — Redis-backed store.
- Modify `Sources/App/Auth/Phone/PhoneAuthController.swift` — extract the
  `PreAuthChallengeStore` API into a `protocol PreAuthChallengeStoring` both
  implementations conform to (keep the in-memory one for tests).
- Modify `Sources/App/Me/MeTodayCache.swift` — store entries in Redis instead of the
  in-actor dict; keep the `Service` + EventBus listener.
- Create `docker-compose.redis.yml` (or extend the existing compose) — `redis` service +
  `API_REPLICAS=2`.
- Tests under `Tests/AppTests/Infra/` and `Tests/AppTests/` per task.

---

## Task 1: Add Redis dependency + shared connection service

**Files:**
- Modify: `Package.swift` (dependencies + App target products)
- Create: `Sources/App/Infra/RedisConnection.swift`
- Test: `Tests/AppTests/Infra/RedisConnectionTests.swift`

- [ ] **Step 1: Add the package dependency.** In `Package.swift` `dependencies:` add:

```swift
.package(url: "https://github.com/hummingbird-project/hummingbird-redis.git", from: "2.0.0"),
```
And in the `App` executable target `dependencies:` add:
```swift
.product(name: "HummingbirdRedis", package: "hummingbird-redis"),
```

- [ ] **Step 2: Resolve + verify it builds.**

Run: `swift package resolve && swift build`
Expected: resolves `hummingbird-redis` + transitive `RediStack`; build succeeds.

- [ ] **Step 3: Write the failing test for the config→service factory.**

```swift
import Hummingbird
import HummingbirdRedis
import Testing
@testable import App

@Suite struct RedisConnectionTests {
    @Test func buildsServiceFromConfig() throws {
        let svc = try makeRedisService(
            url: "redis://127.0.0.1:6379",
            logger: .init(label: "test"),
        )
        #expect(svc != nil)  // type is RedisConnectionPoolService
    }
}
```

- [ ] **Step 4: Run it — fails (symbol missing).**

Run: `swift test --filter RedisConnectionTests`
Expected: FAIL — `makeRedisService` undefined.

- [ ] **Step 5: Implement `RedisConnection.swift`.**

```swift
import Hummingbird
import HummingbirdRedis
import Logging
import RediStack

/// Single construction site for the process-wide Redis pool. ⚠ confirm API:
/// `RedisConnectionPoolService` + `RedisConfiguration(url:)` are the
/// hummingbird-redis 2.x entry points; verify initializer labels against the
/// resolved version.
func makeRedisService(url: String, logger: Logger) throws -> RedisConnectionPoolService {
    let config = try RedisConfiguration(url: url, pool: .init(maximumConnectionCount: .maximumActiveConnections(8)))
    return RedisConnectionPoolService(config, logger: logger)
}
```

- [ ] **Step 6: Run test — passes.**

Run: `swift test --filter RedisConnectionTests`
Expected: PASS (with a local Redis on 6379; otherwise the construction still
succeeds — the pool connects lazily).

- [ ] **Step 7: Commit.**

```bash
git add Package.swift Package.resolved Sources/App/Infra/RedisConnection.swift Tests/AppTests/Infra/RedisConnectionTests.swift
git commit -m "feat(infra): add hummingbird-redis + shared RedisConnectionPoolService"
```

---

## Task 2: Wire Redis into the app lifecycle + config

**Files:**
- Modify: `Sources/App/App+build.swift` (config read, service construction, ServiceGroup)

- [ ] **Step 1: Add config keys near the existing readers (after the Postgres block, ~line 85).**

```swift
// P1 — Redis backs all shared state once >1 API replica runs. `redis.enabled`
// stays false in unit tests (each test gets in-memory drivers); compose/k8s set true.
let redisEnabled = reader.string(forKey: "redis.enabled", default: "false").lowercased() == "true"
let redisURL = reader.string(forKey: "redis.url", default: "redis://127.0.0.1:6379")
let redisService: RedisConnectionPoolService? = redisEnabled
    ? try makeRedisService(url: redisURL, logger: Logger(label: "lv.redis"))
    : nil
```

- [ ] **Step 2: Register the service in the ServiceGroup.** Find the `ServiceGroup`
  services array (~line 182-214) and add, only when present:

```swift
// add near the other services, conditionally
if let redisService { services.append(redisService) }   // ⚠ adapt to however the
// services array is assembled here (it may be a literal — convert to a built array).
```

- [ ] **Step 3: Build.**

Run: `swift build`
Expected: success. (No behaviour change yet — service is constructed + lifecycle-managed,
nothing consumes it.)

- [ ] **Step 4: Commit.**

```bash
git add Sources/App/App+build.swift
git commit -m "feat(infra): construct Redis service under ServiceGroup lifecycle (gated by redis.enabled)"
```

---

## Task 3: Redis-backed rate-limit PersistDriver

**Files:**
- Modify: `Sources/App/Middleware/RateLimitStorageFactory.swift`
- Modify: `Sources/App/App+build.swift:380` (pass the Redis client through)
- Test: `Tests/AppTests/RateLimitRedisStorageTests.swift`

Current factory (exact):
```swift
func makeRateLimitStorage(kind: String, logger: Logger) -> any PersistDriver {
    switch RateLimitStorageKind(raw: kind) {
    case .memory:
        return MemoryPersistDriver()
    case .redis:
        logger.warning("rateLimit.storageKind=redis requested but Redis driver not yet wired; falling back to memory")
        return MemoryPersistDriver()
    }
}
```

- [ ] **Step 1: Write the failing test (multi-instance counter sharing).**

```swift
import Hummingbird
import HummingbirdRedis
import Testing
@testable import App

@Suite struct RateLimitRedisStorageTests {
    // Requires a local Redis. Two drivers over the same Redis must share state.
    @Test func twoDriversShareCounter() async throws {
        let redis = try makeRedisService(url: "redis://127.0.0.1:6379", logger: .init(label: "t"))
        let a = makeRateLimitStorage(kind: "redis", redis: redis, logger: .init(label: "a"))
        let b = makeRateLimitStorage(kind: "redis", redis: redis, logger: .init(label: "b"))
        let key = "rl-test-\(UUID().uuidString)"
        try await a.set(key: key, value: 1, expires: .seconds(60))
        let seen = try await b.get(key: key, as: Int.self)   // ⚠ confirm PersistDriver API
        #expect(seen == 1)
    }
}
```

- [ ] **Step 2: Run — fails (signature mismatch: `redis:` param absent).**

Run: `swift test --filter RateLimitRedisStorageTests`
Expected: FAIL to compile — `makeRateLimitStorage` has no `redis:` parameter.

- [ ] **Step 3: Implement the `.redis` branch.**

```swift
func makeRateLimitStorage(
    kind: String,
    redis: RedisConnectionPoolService?,
    logger: Logger,
) -> any PersistDriver {
    switch RateLimitStorageKind(raw: kind) {
    case .memory:
        return MemoryPersistDriver()
    case .redis:
        guard let redis else {
            logger.warning("rateLimit.storageKind=redis but no Redis service (redis.enabled=false); using memory")
            return MemoryPersistDriver()
        }
        // ⚠ confirm API: hummingbird-redis exposes `RedisPersistDriver`.
        return RedisPersistDriver(redisConnectionPoolService: redis)
    }
}
```

- [ ] **Step 4: Update the call site `App+build.swift:380`.**

```swift
let rateLimitStorage = makeRateLimitStorage(
    kind: reader.string(forKey: "rateLimit.storageKind", default: "memory"),
    redis: redisService,
    logger: logger,
)
```

- [ ] **Step 5: Run test (local Redis up) — passes.**

Run: `docker run -d -p 6379:6379 redis:7 && swift test --filter RateLimitRedisStorageTests`
Expected: PASS — second driver reads the first's counter.

- [ ] **Step 6: Commit.**

```bash
git add Sources/App/Middleware/RateLimitStorageFactory.swift Sources/App/App+build.swift Tests/AppTests/RateLimitRedisStorageTests.swift
git commit -m "feat(ratelimit): Redis-backed PersistDriver for multi-replica rate limiting"
```

---

## Task 4: Extract `PreAuthChallengeStoring` protocol

**Files:**
- Modify: `Sources/App/Auth/Phone/PhoneAuthController.swift` (add protocol; conform the
  existing actor)
- Test: `Tests/AppTests/PreAuthChallengeStoreContractTests.swift`

- [ ] **Step 1: Add the protocol capturing the store's current surface.**

```swift
/// P1 — abstraction so the OTP store can be in-memory (tests) or Redis (multi-replica).
/// Mirrors the existing `PreAuthChallengeStore` API exactly.
protocol PreAuthChallengeStoring: Sendable {
    func issue(channel: String, destination: String, purpose: String, code: String) async -> (id: UUID, expiresAt: Date)
    func consume(destination: String, code: String) async -> (destination: String, purpose: String)?
    func consumeTyped(destination: String, code: String) async -> ConsumeOutcome
}
```

- [ ] **Step 2: Conform the existing actor.** Change `actor PreAuthChallengeStore {` to
  `actor PreAuthChallengeStore: PreAuthChallengeStoring {`. Its methods already match
  (they become `async` to callers via the protocol; actor methods satisfy `async`
  requirements).

- [ ] **Step 3: Change the controller + any holder to depend on `any PreAuthChallengeStoring`.**
  Wherever `PreAuthChallengeStore` is stored as a property type (PhoneAuthController,
  EmailMagicLinkController, App+build construction at `:395`), widen the type to
  `any PreAuthChallengeStoring`. Construction in `App+build.swift:395` stays
  `PreAuthChallengeStore()` for now.

- [ ] **Step 4: Write a contract test the in-memory store passes.**

```swift
import Testing
@testable import App

@Suite struct PreAuthChallengeStoreContractTests {
    @Test func issueThenConsumeRoundTrips() async {
        let store: any PreAuthChallengeStoring = PreAuthChallengeStore(lifetime: 60, maxAttempts: 5)
        let issued = await store.issue(channel: "sms", destination: "+15550001111", purpose: "login", code: "123456")
        #expect(issued.expiresAt > Date())
        let consumed = await store.consume(destination: "+15550001111", code: "123456")
        #expect(consumed?.purpose == "login")
    }

    @Test func wrongCodeReportsTyped() async {
        let store: any PreAuthChallengeStoring = PreAuthChallengeStore(lifetime: 60, maxAttempts: 5)
        _ = await store.issue(channel: "sms", destination: "+15550002222", purpose: "login", code: "111111")
        if case .wrongCode = await store.consumeTyped(destination: "+15550002222", code: "999999") {} else {
            Issue.record("expected .wrongCode")
        }
    }
}
```

- [ ] **Step 5: Run — passes; full build green.**

Run: `swift build && swift test --filter PreAuthChallengeStoreContractTests`
Expected: PASS.

- [ ] **Step 6: Commit.**

```bash
git add Sources/App/Auth Tests/AppTests/PreAuthChallengeStoreContractTests.swift
git commit -m "refactor(auth): extract PreAuthChallengeStoring protocol (no behaviour change)"
```

---

## Task 5: Redis-backed `PreAuthChallengeStore`

**Files:**
- Create: `Sources/App/Infra/RedisPreAuthChallengeStore.swift`
- Modify: `Sources/App/App+build.swift:395` (choose impl by `redis.enabled`)
- Test: `Tests/AppTests/Infra/RedisPreAuthChallengeStoreTests.swift`

Redis model: one hash per challenge `preauth:chal:<id>` with fields
`codeHash, attempts, channel, destination, purpose`, given a key TTL = `lifetime`. A
pointer key `preauth:dest:<destination>` → latest `<id>` (also TTL'd). `consumeTyped`
looks up the pointer, loads the hash, compares `sha256(code)`, increments `attempts`
(atomic via `HINCRBY`), burns on success/maxAttempts (`DEL`). Expiry is native key TTL →
missing key = `.expired` vs `.notFound` is disambiguated by the pointer: pointer present +
hash gone ⇒ `.expired`; no pointer ⇒ `.notFound`.

- [ ] **Step 1: Write failing tests (round-trip, TTL expiry, wrong code, lockout).**

```swift
import RediStack
import Testing
@testable import App

@Suite struct RedisPreAuthChallengeStoreTests {
    private func makeStore(lifetime: TimeInterval = 60) throws -> RedisPreAuthChallengeStore {
        let redis = try makeRedisService(url: "redis://127.0.0.1:6379", logger: .init(label: "t"))
        return RedisPreAuthChallengeStore(redis: redis, lifetime: lifetime, maxAttempts: 5)
    }

    @Test func roundTrip() async throws {
        let s = try makeStore()
        let dest = "+1555\(Int.random(in: 1000000...9999999))"
        _ = await s.issue(channel: "sms", destination: dest, purpose: "login", code: "424242")
        let c = await s.consume(destination: dest, code: "424242")
        #expect(c?.purpose == "login")
    }

    @Test func expiresViaTTL() async throws {
        let s = try makeStore(lifetime: 1)
        let dest = "+1555\(Int.random(in: 1000000...9999999))"
        _ = await s.issue(channel: "sms", destination: dest, purpose: "login", code: "424242")
        try await Task.sleep(for: .seconds(2))
        if case .expired = await s.consumeTyped(destination: dest, code: "424242") {} else {
            Issue.record("expected .expired after TTL")
        }
    }

    @Test func wrongCodeThenLockout() async throws {
        let s = try makeStore()
        let dest = "+1555\(Int.random(in: 1000000...9999999))"
        _ = await s.issue(channel: "sms", destination: dest, purpose: "login", code: "424242")
        for _ in 0..<5 { _ = await s.consumeTyped(destination: dest, code: "000000") }
        if case .lockedOut = await s.consumeTyped(destination: dest, code: "424242") {} else {
            Issue.record("expected .lockedOut after maxAttempts")
        }
    }
}
```

- [ ] **Step 2: Run — fails (type missing).**

Run: `swift test --filter RedisPreAuthChallengeStoreTests`
Expected: FAIL — `RedisPreAuthChallengeStore` undefined.

- [ ] **Step 3: Implement the Redis store** (reuse the existing `Self.sha256` hashing rule
  from `PreAuthChallengeStore` — copy that helper so hashes match).

```swift
import Crypto
import Foundation
import HummingbirdRedis
import Logging
import RediStack

/// P1 — Redis-backed OTP challenge store. Same contract as the in-memory
/// `PreAuthChallengeStore`; safe across API replicas. ⚠ confirm API: RediStack
/// command names (`hmset`, `hgetall`, `hincr`, `expire`, `delete`, `set`/`get`)
/// and their async signatures against the resolved RediStack version.
struct RedisPreAuthChallengeStore: PreAuthChallengeStoring {
    let redis: RedisConnectionPoolService
    let lifetime: TimeInterval
    let maxAttempts: Int

    private func chalKey(_ id: UUID) -> RedisKey { "preauth:chal:\(id.uuidString)" }
    private func destKey(_ d: String) -> RedisKey { "preauth:dest:\(d)" }

    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func issue(channel: String, destination: String, purpose: String, code: String) async -> (id: UUID, expiresAt: Date) {
        let id = UUID()
        let expiresAt = Date().addingTimeInterval(lifetime)
        let client = redis.pool   // ⚠ confirm accessor
        // burn prior outstanding challenge for this destination
        if let old = try? await client.get(destKey(destination), as: String.self).get(), let oldID = old {
            _ = try? await client.delete([chalKey(UUID(uuidString: oldID) ?? id)]).get()
        }
        let fields: [String: String] = [
            "codeHash": Self.sha256(code), "attempts": "0",
            "channel": channel, "destination": destination, "purpose": purpose,
        ]
        _ = try? await client.hmset(fields, in: chalKey(id)).get()
        _ = try? await client.expire(chalKey(id), after: .seconds(Int64(lifetime))).get()
        _ = try? await client.set(destKey(destination), to: id.uuidString).get()
        _ = try? await client.expire(destKey(destination), after: .seconds(Int64(lifetime))).get()
        return (id, expiresAt)
    }

    func consume(destination: String, code: String) async -> (destination: String, purpose: String)? {
        if case let .ok(dest, purpose) = await consumeTyped(destination: destination, code: code) {
            return (dest, purpose)
        }
        return nil
    }

    func consumeTyped(destination: String, code: String) async -> ConsumeOutcome {
        let client = redis.pool
        guard let ptr = try? await client.get(destKey(destination), as: String.self).get(), let idStr = ptr,
              let id = UUID(uuidString: idStr) else {
            return .notFound
        }
        let hash = (try? await client.hgetall(from: chalKey(id)).get()) ?? [:]
        guard !hash.isEmpty, let storedHash = hash["codeHash"]?.string else {
            return .expired   // pointer present but challenge key TTL'd out
        }
        let attempts = Int(hash["attempts"]?.string ?? "0") ?? 0
        if attempts >= maxAttempts { return .lockedOut }
        if storedHash == Self.sha256(code) {
            _ = try? await client.delete([chalKey(id), destKey(destination)]).get()
            return .ok(destination: hash["destination"]?.string ?? destination,
                       purpose: hash["purpose"]?.string ?? "")
        }
        let newAttempts = (try? await client.hincr(field: "attempts", in: chalKey(id)).get()) ?? (attempts + 1)
        return newAttempts >= maxAttempts ? .lockedOut : .wrongCode
    }
}
```

- [ ] **Step 4: Select the impl in `App+build.swift:395`.**

```swift
let preAuthStore: any PreAuthChallengeStoring = redisService.map {
    RedisPreAuthChallengeStore(redis: $0, lifetime: 60 * 5, maxAttempts: 5)
} ?? PreAuthChallengeStore()
```

- [ ] **Step 5: Run tests (local Redis) — pass; full build green.**

Run: `swift build && swift test --filter RedisPreAuthChallengeStoreTests`
Expected: PASS.

- [ ] **Step 6: Commit.**

```bash
git add Sources/App/Infra/RedisPreAuthChallengeStore.swift Sources/App/App+build.swift Tests/AppTests/Infra/RedisPreAuthChallengeStoreTests.swift
git commit -m "feat(auth): Redis-backed PreAuthChallengeStore for multi-replica OTP"
```

---

## Task 6: Move `MeTodayCache` storage to Redis

**Files:**
- Modify: `Sources/App/Me/MeTodayCache.swift`
- Test: `Tests/AppTests/MeTodayCacheRedisTests.swift`

Keep the `actor MeTodayCache: Service` shape and the EventBus listener (in-process events
still drive invalidation). Replace the in-actor `entries` dict with Redis keys
`metoday:<tenantID>` holding the encoded `Entry` (body+etag+generatedAt) with a TTL =
`ttl`. `get` reads the key (TTL handles expiry), `invalidate` is `DEL`, so a
`memoryUpserted` handled on ANY replica clears the shared key for all. When `redis` is nil
(tests/single-process), fall back to the existing in-memory dict.

- [ ] **Step 1: Add an optional Redis backend + encode/decode.** Add to the actor:

```swift
private let redis: RedisConnectionPoolService?   // nil ⇒ in-memory dict (unchanged path)

// Entry is Codable for Redis storage:
struct Entry: Codable { let body: Data; let etag: String; let generatedAt: Date }

private func key(_ t: UUID) -> RedisKey { "metoday:\(t.uuidString)" }
```
Extend `init` with `redis: RedisConnectionPoolService? = nil` and store it.

- [ ] **Step 2: Write failing test (cross-instance visibility).**

```swift
import Testing
@testable import App

@Suite struct MeTodayCacheRedisTests {
    @Test func putOnOneInstanceVisibleOnAnother() async throws {
        let redis = try makeRedisService(url: "redis://127.0.0.1:6379", logger: .init(label: "t"))
        let a = MeTodayCache(ttl: 300, eventBus: nil, logger: .init(label: "a"), redis: redis)
        let b = MeTodayCache(ttl: 300, eventBus: nil, logger: .init(label: "b"), redis: redis)
        let tid = UUID()
        await a.put(tenantID: tid, entry: .init(body: Data("x".utf8), etag: "e1", generatedAt: Date()))
        let got = await b.get(tenantID: tid)
        #expect(got?.etag == "e1")
        await a.invalidate(tenantID: tid)
        #expect(await b.get(tenantID: tid) == nil)
    }
}
```

- [ ] **Step 3: Run — fails (init has no `redis:` label / not Codable).**

Run: `swift test --filter MeTodayCacheRedisTests`
Expected: FAIL to compile.

- [ ] **Step 4: Implement the Redis paths in `get`/`put`/`invalidate`** (keep dict path
  when `redis == nil`).

```swift
func get(tenantID: UUID, now: Date = Date()) async -> Entry? {
    if let redis {
        guard let data = try? await redis.pool.get(key(tenantID), as: Data.self).get(), let data,
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        return entry   // TTL on the key handles expiry
    }
    guard let entry = entries[tenantID] else { return nil }
    guard now.timeIntervalSince(entry.generatedAt) < ttl else { entries.removeValue(forKey: tenantID); return nil }
    return entry
}

func put(tenantID: UUID, entry: Entry) async {
    if let redis, let data = try? JSONEncoder().encode(entry) {
        _ = try? await redis.pool.set(key(tenantID), to: data).get()
        _ = try? await redis.pool.expire(key(tenantID), after: .seconds(Int64(ttl))).get()
        return
    }
    entries[tenantID] = entry
}

func invalidate(tenantID: UUID) async {
    if let redis { _ = try? await redis.pool.delete([key(tenantID)]).get(); return }
    entries.removeValue(forKey: tenantID)
}
```
Note: `get`/`put`/`invalidate` become `async` — update the ~3 call sites in
`MeTodayController` / `MeTodayService` to `await` (they're already in async handlers).

- [ ] **Step 5: Construct with Redis in `App+build.swift:966`.**

```swift
let meTodayCache = MeTodayCache(ttl: 300, eventBus: eventBus, logger: meTodayLogger, redis: redisService)
```

- [ ] **Step 6: Run test + full build — green.**

Run: `swift build && swift test --filter MeTodayCacheRedisTests`
Expected: PASS.

- [ ] **Step 7: Commit.**

```bash
git add Sources/App/Me Tests/AppTests/MeTodayCacheRedisTests.swift Sources/App/App+build.swift
git commit -m "feat(me): back MeTodayCache with Redis so cache+invalidation work across replicas"
```

---

## Task 7: 2-replica compose + multi-replica integration test

**Files:**
- Create: `docker-compose.redis.yml` (or extend existing compose)
- Test: `Tests/AppTests/MultiReplicaRateLimitTests.swift` (in-process proxy for two
  app instances sharing one Redis)

- [ ] **Step 1: Add a `redis` service + 2 API replicas to compose.**

```yaml
services:
  redis:
    image: redis:7
    command: ["redis-server", "--save", "", "--appendonly", "no"]
    ports: ["6379:6379"]
  api:
    # existing build/image…
    environment:
      REDIS_ENABLED: "true"
      REDIS_URL: "redis://redis:6379"
      RATE_LIMIT_STORAGE_KIND: "redis"
    deploy:
      replicas: 2
    depends_on: [redis]
```

- [ ] **Step 2: Write a failing integration test — two app instances, one Redis, a rate
  limit triggered on instance A is enforced when the next request lands on instance B.**

```swift
import HummingbirdTesting
import Testing
@testable import App

@Suite struct MultiReplicaRateLimitTests {
    @Test func limitSharedAcrossInstances() async throws {
        // Build two apps with redis.enabled=true pointing at the same local Redis,
        // exhaust the per-route limit via app A, then assert app B returns 429.
        // Use the existing dbTestReader pattern + override redis.enabled/url.
        // (Fill with the project's app.test(.router) harness — mirror an existing
        //  rate-limit test in Tests/AppTests for exact setup.)
    }
}
```
> ⚠ This is the one test whose body depends on the repo's app-construction test harness
> (two `buildApplication` instances sharing config). Mirror an existing rate-limit test in
> `Tests/AppTests`; keep the assertion: A exhausts → B returns 429.

- [ ] **Step 3: Run — fails (limit not shared if anything regressed).**

Run: `docker compose -f docker-compose.yml -f docker-compose.redis.yml up -d redis && swift test --filter MultiReplicaRateLimitTests`
Expected: FAIL first (assertion or setup), then PASS once wired.

- [ ] **Step 4: Manual smoke — two replicas behind compose.**

Run: `docker compose -f docker-compose.yml -f docker-compose.redis.yml up --build`
Verify: both API replicas healthy; hammer an OTP route past its limit; confirm 429
regardless of which replica answers (check `lv.ratelimit` logs / response headers).

- [ ] **Step 5: Commit.**

```bash
git add docker-compose.redis.yml Tests/AppTests/MultiReplicaRateLimitTests.swift
git commit -m "feat(infra): 2-replica compose + multi-replica rate-limit integration test"
```

---

## Done-when (P1 exit criteria)
- `swift build` clean; `swift test` green locally on macOS (note HER-310 Linux SIGILL is
  unrelated and tracked separately).
- With `REDIS_ENABLED=true`, rate-limit + OTP challenges + me/today cache all survive a
  request landing on a different replica than the one that wrote them.
- `redis.enabled=false` preserves today's in-memory behaviour (tests unchanged).
- Ready for P2 (move this same image into the K3s cluster).
```
