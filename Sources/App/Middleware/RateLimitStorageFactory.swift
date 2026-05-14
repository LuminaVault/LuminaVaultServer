import Foundation
import Hummingbird
import Logging

/// HER-200 M3 — seam for swapping rate-limit storage when a second replica
/// ships. `memory` (the default) uses `MemoryPersistDriver` so single-process
/// dev/test keeps working. `redis` is reserved for the Redis-backed driver;
/// asking for it today logs a warning and falls back to memory so a misset
/// env var doesn't crash the boot.
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

/// Builds the `PersistDriver` used by every `RateLimitMiddleware` instance.
/// Centralises the construction site so the rate-limit storage decision is
/// one config key, not scattered `MemoryPersistDriver()` literals.
func makeRateLimitStorage(kind: String, logger: Logger) -> any PersistDriver {
    switch RateLimitStorageKind(raw: kind) {
    case .memory:
        return MemoryPersistDriver()
    case .redis:
        // HER-200 M3 follow-up — Redis-backed PersistDriver lands when a
        // second replica ships. Don't crash the boot today; degrade to
        // memory with a loud warning so the misconfiguration is visible.
        logger.warning("rateLimit.storageKind=redis requested but Redis driver not yet wired; falling back to memory")
        return MemoryPersistDriver()
    }
}
