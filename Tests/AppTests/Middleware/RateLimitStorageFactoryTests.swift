@testable import App
import Hummingbird
import Logging
import Testing

/// HER-200 M3 / audit S-01 — rate-limit storage factory routing.
struct RateLimitStorageFactoryTests {
    private static let logger = Logger(label: "test.ratelimit")

    @Test
    func `memory kind returns MemoryPersistDriver without a managed service`() throws {
        let storage = try makeRateLimitStorage(kind: "memory", redisURL: "", logger: Self.logger)
        #expect(storage.kind == .memory)
        #expect(storage.driver is MemoryPersistDriver<ContinuousClock>)
        #expect(storage.service == nil)
    }

    @Test
    func `unknown kind defaults to memory`() throws {
        let storage = try makeRateLimitStorage(kind: "etcd", redisURL: "", logger: Self.logger)
        #expect(storage.driver is MemoryPersistDriver<ContinuousClock>)
    }

    @Test
    func `empty kind defaults to memory`() throws {
        let storage = try makeRateLimitStorage(kind: "", redisURL: "", logger: Self.logger)
        #expect(storage.driver is MemoryPersistDriver<ContinuousClock>)
    }

    @Test
    func `memory kind ignores a stray REDIS_URL`() throws {
        let storage = try makeRateLimitStorage(kind: "memory", redisURL: "redis://valkey:6379", logger: Self.logger)
        #expect(storage.kind == .memory)
        #expect(storage.service == nil)
    }

    @Test
    func `redis kind builds the Valkey driver and exposes it as a managed service`() throws {
        let storage = try makeRateLimitStorage(kind: "redis", redisURL: "redis://valkey:6379/2", logger: Self.logger)
        #expect(storage.kind == .redis)
        let driver = try #require(storage.driver as? ValkeyPersistDriver)
        #expect(driver.address == "valkey:6379")
        #expect(storage.service != nil)
        #expect((storage.service as? ValkeyPersistDriver) === driver)
    }

    @Test
    func `redis kind accepts the valkey scheme and surrounding whitespace`() throws {
        let storage = try makeRateLimitStorage(kind: "redis", redisURL: "  valkey://cache.internal:6380 \n", logger: Self.logger)
        let driver = try #require(storage.driver as? ValkeyPersistDriver)
        #expect(driver.address == "cache.internal:6380")
    }

    @Test
    func `redis kind without REDIS_URL throws a descriptive configuration error`() {
        #expect(throws: RateLimitStorageConfigurationError.missingRedisURL) {
            try makeRateLimitStorage(kind: "redis", redisURL: "", logger: Self.logger)
        }
        #expect(RateLimitStorageConfigurationError.missingRedisURL.description.contains("REDIS_URL"))
        #expect(RateLimitStorageConfigurationError.missingRedisURL.description.contains("RATE_LIMIT_STORAGE_KIND"))
    }

    @Test
    func `redis kind with an unsupported scheme throws`() {
        #expect(throws: RateLimitStorageConfigurationError.unsupportedRedisScheme("http")) {
            try makeRateLimitStorage(kind: "redis", redisURL: "http://valkey:6379", logger: Self.logger)
        }
    }

    @Test
    func `redis kind with a malformed URL throws`() {
        #expect(throws: RateLimitStorageConfigurationError.invalidRedisURL("redis://")) {
            try makeRateLimitStorage(kind: "redis", redisURL: "redis://", logger: Self.logger)
        }
    }

    @Test
    func `kind matching is case insensitive`() throws {
        let storage = try makeRateLimitStorage(kind: "REDIS", redisURL: "redis://valkey:6379", logger: Self.logger)
        #expect(storage.kind == .redis)
    }

    @Test
    func `RateLimitStorageKind enum maps known values`() {
        #expect(RateLimitStorageKind(raw: "memory") == .memory)
        #expect(RateLimitStorageKind(raw: "MEMORY") == .memory)
        #expect(RateLimitStorageKind(raw: "redis") == .redis)
        #expect(RateLimitStorageKind(raw: "garbage") == .memory)
    }
}
