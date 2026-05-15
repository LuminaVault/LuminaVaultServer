import Foundation
import Logging
import LuminaVaultShared
import ServiceLifecycle

/// HER-206 — in-memory per-tenant cache for `GET /v1/me/today` payloads.
/// TTL is 5 minutes (matches the `Cache-Control: max-age=300` we set on
/// the response); on `memoryUpserted` / `achievementUnlocked` the entry
/// for the publishing tenant is dropped so the next widget refresh sees
/// the change within 1 second (ticket acceptance criterion).
///
/// Conforms to `Service` so `ServiceGroup` keeps the EventBus listener
/// task alive for the application's lifetime — `run()` blocks on two
/// concurrent `AsyncStream` consumers and only exits on graceful
/// shutdown. Single-process for now; HER-148-style multi-replica scale
/// would need Redis pub/sub before this cache makes sense across nodes.
actor MeTodayCache: Service {
    /// Cached envelope. We store the encoded JSON bytes + a derived ETag
    /// so the controller can return `304 Not Modified` without
    /// re-serialising. `generatedAt` is what the response embedded —
    /// driving TTL off it keeps eviction simple.
    struct Entry: Sendable {
        let body: Data
        let etag: String
        let generatedAt: Date
    }

    private let ttl: TimeInterval
    private let eventBus: EventBus?
    private let logger: Logger
    private var entries: [UUID: Entry] = [:]

    init(ttl: TimeInterval = 300, eventBus: EventBus?, logger: Logger) {
        self.ttl = ttl
        self.eventBus = eventBus
        self.logger = logger
    }

    func get(tenantID: UUID, now: Date = Date()) -> Entry? {
        guard let entry = entries[tenantID] else { return nil }
        guard now.timeIntervalSince(entry.generatedAt) < ttl else {
            entries.removeValue(forKey: tenantID)
            return nil
        }
        return entry
    }

    func put(tenantID: UUID, entry: Entry) {
        entries[tenantID] = entry
    }

    func invalidate(tenantID: UUID) {
        entries.removeValue(forKey: tenantID)
    }

    func invalidateAll() {
        entries.removeAll()
    }

    func cachedTenantCount() -> Int { entries.count }

    func run() async throws {
        guard let eventBus else {
            try await gracefulShutdown()
            return
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self, eventBus, logger] in
                for await event in eventBus.subscribe(eventType: .memoryUpserted) {
                    guard let self else { return }
                    await self.invalidate(tenantID: event.tenantID)
                    logger.debug("me.today cache invalidated by memory_upserted tenant=\(event.tenantID)")
                }
            }
            group.addTask { [weak self, eventBus, logger] in
                for await event in eventBus.subscribe(eventType: .achievementUnlocked) {
                    guard let self else { return }
                    await self.invalidate(tenantID: event.tenantID)
                    logger.debug("me.today cache invalidated by achievement_unlocked tenant=\(event.tenantID)")
                }
            }
            try await gracefulShutdown()
            group.cancelAll()
        }
    }
}
