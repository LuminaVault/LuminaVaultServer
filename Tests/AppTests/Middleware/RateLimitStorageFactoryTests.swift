@testable import App
import Hummingbird
import Logging
import Testing

/// HER-200 M3 — rate-limit storage factory routing.
struct RateLimitStorageFactoryTests {
    private static let logger = Logger(label: "test.ratelimit")

    @Test
    func `memory kind returns MemoryPersistDriver`() {
        let storage = makeRateLimitStorage(kind: "memory", logger: Self.logger)
        #expect(storage is MemoryPersistDriver<ContinuousClock>)
    }

    @Test
    func `unknown kind defaults to memory`() {
        let storage = makeRateLimitStorage(kind: "etcd", logger: Self.logger)
        #expect(storage is MemoryPersistDriver<ContinuousClock>)
    }

    @Test
    func `empty kind defaults to memory`() {
        let storage = makeRateLimitStorage(kind: "", logger: Self.logger)
        #expect(storage is MemoryPersistDriver<ContinuousClock>)
    }

    @Test
    func `redis kind falls back to memory until driver lands`() {
        // Behaviour today: redis is reserved for the future Redis-backed
        // driver. Until it lands, asking for redis logs a warning and falls
        // back to memory — so a misset env var doesn't crash the boot.
        let storage = makeRateLimitStorage(kind: "redis", logger: Self.logger)
        #expect(storage is MemoryPersistDriver<ContinuousClock>)
    }

    @Test
    func `kind matching is case insensitive`() {
        let storage = makeRateLimitStorage(kind: "REDIS", logger: Self.logger)
        #expect(storage is MemoryPersistDriver<ContinuousClock>)
    }

    @Test
    func `RateLimitStorageKind enum maps known values`() {
        #expect(RateLimitStorageKind(raw: "memory") == .memory)
        #expect(RateLimitStorageKind(raw: "MEMORY") == .memory)
        #expect(RateLimitStorageKind(raw: "redis") == .redis)
        #expect(RateLimitStorageKind(raw: "garbage") == .memory)
    }
}
