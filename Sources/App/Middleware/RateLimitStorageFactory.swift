import Foundation
import Hummingbird
import Logging
import ServiceLifecycle

/// HER-200 M3 — seam for swapping rate-limit storage when a second replica
/// ships. `memory` (the default) uses `MemoryPersistDriver` so single-process
/// dev/test keeps working. `redis` selects the Valkey/Redis-backed
/// `ValkeyPersistDriver` so every replica shares one counter set.
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

/// Result of `makeRateLimitStorage`. `driver` is what every
/// `RateLimitMiddleware` reads; `service`, when present, must be registered
/// with the application's `ServiceGroup` so the backing connection is
/// opened, readiness-checked, and closed with the process.
struct RateLimitStorage {
    let kind: RateLimitStorageKind
    let driver: any PersistDriver
    let service: (any Service)?
}

/// Builds the `PersistDriver` used by every `RateLimitMiddleware` instance.
/// Centralises the construction site so the rate-limit storage decision is
/// one config key, not scattered `MemoryPersistDriver()` literals.
///
/// Audit S-01 — `redis` used to `fatalError` outside dev because the driver
/// was never wired. It now builds `ValkeyPersistDriver` from `REDIS_URL`; a
/// missing or malformed URL throws a descriptive
/// `RateLimitStorageConfigurationError` so the operator sees the offending
/// keys instead of a crash trace. Reachability is verified by the driver's
/// `run()` readiness probe once the `ServiceGroup` starts, and a failed probe
/// stops the boot with a thrown error rather than a silent in-memory fallback
/// (which would let a caller bypass every limit by spreading requests across
/// replicas).
func makeRateLimitStorage(kind rawKind: String, redisURL: String, logger: Logger) throws -> RateLimitStorage {
    let kind = RateLimitStorageKind(raw: rawKind)
    switch kind {
    case .memory:
        logger.info("rate-limit storage: memory (per-process)", metadata: [
            "config": "RATE_LIMIT_STORAGE_KIND=memory",
        ])
        return RateLimitStorage(kind: .memory, driver: MemoryPersistDriver(), service: nil)
    case .redis:
        let trimmedURL = redisURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            logger.error("rate-limit storage: RATE_LIMIT_STORAGE_KIND=redis but REDIS_URL is empty")
            throw RateLimitStorageConfigurationError.missingRedisURL
        }
        let configuration: ValkeyPersistConfiguration
        do {
            configuration = try ValkeyPersistConfiguration(url: trimmedURL)
        } catch {
            logger.error("rate-limit storage: REDIS_URL rejected", metadata: [
                "config": "RATE_LIMIT_STORAGE_KIND=redis, REDIS_URL",
                "error": "\(error)",
            ])
            throw error
        }
        let driver = ValkeyPersistDriver(configuration: configuration, logger: logger)
        logger.info("rate-limit storage: valkey (shared across replicas)", metadata: [
            "config": "RATE_LIMIT_STORAGE_KIND=redis, REDIS_URL",
            "address": "\(configuration.displayAddress)",
        ])
        return RateLimitStorage(kind: .redis, driver: driver, service: driver)
    }
}
