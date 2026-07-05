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
///
/// Audit S4 — the Redis-backed driver is still unimplemented. In-memory storage is
/// correct for a single replica, but if an operator deploys multiple replicas and
/// sets `rateLimit.storageKind=redis` expecting shared counters, a silent fallback
/// to per-process memory would let a caller bypass every limit by spreading requests
/// across replicas. So outside dev we FAIL LOUD rather than degrade silently.
func makeRateLimitStorage(kind: String, isProduction: Bool, logger: Logger) -> any PersistDriver {
    switch RateLimitStorageKind(raw: kind) {
    case .memory:
        return MemoryPersistDriver()
    case .redis:
        let message = "rateLimit.storageKind=redis requested but the Redis PersistDriver is not yet wired. "
            + "In-memory storage is per-process and does NOT share counters across replicas — "
            + "rate limits would be bypassable in a multi-replica deploy."
        if isProduction {
            fatalError(message + " Refusing to boot; implement the Redis driver or set rateLimit.storageKind=memory.")
        }
        logger.warning("\(message) Falling back to memory (dev only).")
        return MemoryPersistDriver()
    }
}
