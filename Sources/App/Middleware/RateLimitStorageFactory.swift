import Foundation
import Hummingbird
import Logging
import ServiceLifecycle

/// HER-200 M3 — rate-limit storage selector. `memory` is for single-process
/// dev/test. `redis` uses Valkey/Redis through `ValkeyPersistDriver` so
/// multiple API replicas share request buckets and short-lived auth/pairing
/// records.
enum RateLimitStorageKind: String {
    case memory
    case redis

    init(raw: String) {
        switch raw.lowercased() {
        case "redis": self = .redis
        default: self = .memory
        }
    }
}

enum RateLimitStorageConfigurationError: Error, Equatable, CustomStringConvertible {
    case missingRedisURL(environment: String)
    case invalidRedisURL(String)
    case unsupportedRedisScheme(String)
    case invalidRedisDatabase(String)

    var description: String {
        switch self {
        case .missingRedisURL(let environment):
            "RATE_LIMIT_STORAGE_KIND=redis requires REDIS_URL when LV_ENVIRONMENT=\(environment)"
        case .invalidRedisURL(let value):
            "invalid REDIS_URL: \(value)"
        case .unsupportedRedisScheme(let scheme):
            "unsupported REDIS_URL scheme: \(scheme)"
        case .invalidRedisDatabase(let database):
            "invalid REDIS_URL database number: \(database)"
        }
    }
}

struct RateLimitStorageFactoryResult {
    let storage: any PersistDriver
    let managedService: (any Service)?
}

/// Builds the `PersistDriver` used by every `RateLimitMiddleware` instance.
/// Centralises the construction site so the rate-limit storage decision is
/// one config key, not scattered `MemoryPersistDriver()` literals.
func makeRateLimitStorage(kind: String, logger: Logger) -> any PersistDriver {
    let result = try? makeRateLimitStorage(
        kind: kind,
        redisURL: nil,
        environment: "dev",
        logger: logger
    )
    return result?.storage ?? MemoryPersistDriver()
}

func makeRateLimitStorage(
    kind: String,
    redisURL: String?,
    environment: String,
    logger: Logger
) throws -> RateLimitStorageFactoryResult {
    switch RateLimitStorageKind(raw: kind) {
    case .memory:
        return RateLimitStorageFactoryResult(storage: MemoryPersistDriver(), managedService: nil)
    case .redis:
        guard let redisURL, !redisURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if environment == "dev" || environment == "test" {
                logger.warning("rateLimit.storageKind=redis requested without REDIS_URL; falling back to memory in \(environment)")
                return RateLimitStorageFactoryResult(storage: MemoryPersistDriver(), managedService: nil)
            }
            throw RateLimitStorageConfigurationError.missingRedisURL(environment: environment)
        }
        let configuration = try ValkeyPersistConfiguration(url: redisURL)
        let storage = ValkeyPersistDriver(
            configuration: configuration,
            logger: logger
        )
        logger.info("rateLimit.storageKind=redis using Valkey/Redis-backed PersistDriver")
        return RateLimitStorageFactoryResult(storage: storage, managedService: storage)
    }
}
