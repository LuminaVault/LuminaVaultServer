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
    func `redis kind without url falls back to memory in test`() throws {
        let result = try makeRateLimitStorage(
            kind: "redis",
            redisURL: nil,
            environment: "test",
            logger: Self.logger
        )
        #expect(result.storage is MemoryPersistDriver<ContinuousClock>)
        #expect(result.managedService == nil)
    }

    @Test
    func `redis kind with url returns Valkey driver`() throws {
        let result = try makeRateLimitStorage(
            kind: "REDIS",
            redisURL: "redis://127.0.0.1:6379/1",
            environment: "production",
            logger: Self.logger
        )
        #expect(result.storage is ValkeyPersistDriver)
        #expect(result.managedService != nil)
    }

    @Test
    func `redis kind without url fails in production`() {
        #expect(throws: RateLimitStorageConfigurationError.missingRedisURL(environment: "production")) {
            _ = try makeRateLimitStorage(
                kind: "redis",
                redisURL: "",
                environment: "production",
                logger: Self.logger
            )
        }
    }

    @Test
    func `redis kind rejects unsupported scheme`() {
        #expect(throws: RateLimitStorageConfigurationError.unsupportedRedisScheme("rediss")) {
            _ = try makeRateLimitStorage(
                kind: "redis",
                redisURL: "rediss://cache.example.com:6379",
                environment: "production",
                logger: Self.logger
            )
        }
    }

    @Test
    func `RateLimitStorageKind enum maps known values`() {
        #expect(RateLimitStorageKind(raw: "memory") == .memory)
        #expect(RateLimitStorageKind(raw: "MEMORY") == .memory)
        #expect(RateLimitStorageKind(raw: "redis") == .redis)
        #expect(RateLimitStorageKind(raw: "garbage") == .memory)
    }
}
