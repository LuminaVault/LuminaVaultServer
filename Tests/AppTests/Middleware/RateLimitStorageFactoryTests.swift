@testable import App
import Hummingbird
import Logging
import Testing

/// HER-200 M3 — rate-limit storage factory routing.
struct RateLimitStorageFactoryTests {
    private static let logger = Logger(label: "test.ratelimit")

    @Test
    func `memory kind returns MemoryPersistDriver`() {
        let storage = makeRateLimitStorage(kind: "memory", isProduction: true, logger: Self.logger)
        #expect(storage is MemoryPersistDriver<ContinuousClock>)
    }

    @Test
    func `unknown kind defaults to memory`() {
        let storage = makeRateLimitStorage(kind: "etcd", isProduction: true, logger: Self.logger)
        #expect(storage is MemoryPersistDriver<ContinuousClock>)
    }

    @Test
    func `empty kind defaults to memory`() {
        let storage = makeRateLimitStorage(kind: "", isProduction: true, logger: Self.logger)
        #expect(storage is MemoryPersistDriver<ContinuousClock>)
    }

    @Test
    func `redis kind falls back to memory in dev until driver lands`() {
        // Audit S4 — outside dev, requesting redis without a wired driver is a
        // fatalError (can't be exercised in-process). In dev it warns + falls back
        // to memory so a misset env var doesn't crash local boot.
        let storage = makeRateLimitStorage(kind: "redis", isProduction: false, logger: Self.logger)
        #expect(storage is MemoryPersistDriver<ContinuousClock>)
    }

    @Test
    func `kind matching is case insensitive`() {
        let storage = makeRateLimitStorage(kind: "REDIS", isProduction: false, logger: Self.logger)
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
