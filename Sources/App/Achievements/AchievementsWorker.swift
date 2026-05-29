import Foundation
import Logging
import ServiceLifecycle

/// HER-310 — achievement recording moved OFF controller hot-paths and OFF
/// fire-and-forget `Task.detached`. Handlers call `enqueue(...)` (synchronous,
/// no `Task`, no DB). This `Service` drains the inbox using the app's
/// long-lived `AchievementsService`/`Fluent` and is registered AFTER `fluent`
/// in the ServiceGroup, so it stops draining BEFORE Fluent shuts down — no
/// `.db()` call can race a torn-down database (the old
/// `FluentKit/Databases.swift:190: Fatal error: No default database configured`
/// crash / signal 5).
///
/// Shape mirrors `MeTodayCache` (actor + `Service` + `gracefulShutdown()`).
actor AchievementsWorker: Service {
    struct Job {
        let tenantID: UUID
        let event: AchievementEvent
    }

    private let service: AchievementsService
    private let stream: AsyncStream<Job>
    private nonisolated let continuation: AsyncStream<Job>.Continuation
    private nonisolated let logger: Logger

    init(service: AchievementsService, logger: Logger, bufferSize: Int = 256) {
        self.service = service
        self.logger = logger
        (stream, continuation) = AsyncStream<Job>.makeStream(
            bufferingPolicy: .bufferingNewest(bufferSize),
        )
    }

    /// Non-blocking. Safe to call from a request handler — never spawns a
    /// `Task`, never touches the DB. Dropped (logged) when the buffer is full
    /// or the worker has already shut down.
    nonisolated func enqueue(tenantID: UUID, event: AchievementEvent) {
        switch continuation.yield(Job(tenantID: tenantID, event: event)) {
        case .dropped:
            logger.warning("achievements inbox full; dropped \(event.rawValue)")
        case .terminated:
            logger.debug("achievements worker stopped; dropped \(event.rawValue)")
        default:
            break
        }
    }

    /// Test-only: end the inbox so `run()` returns without a ServiceGroup
    /// driving graceful shutdown.
    nonisolated func shutdownForTests() {
        continuation.finish()
    }

    func run() async throws {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await self?.drain()
            }
            group.addTask { [continuation] in
                try? await gracefulShutdown()
                // Stop accepting; the drain loop ends after the buffered jobs.
                continuation.finish()
            }
            await group.next()
            group.cancelAll()
        }
    }

    /// Actor-isolated drain — `service`/`stream` are touched through actor
    /// isolation (not captured into a `@Sendable` closure), so this compiles
    /// regardless of whether `AchievementsService` is `Sendable`.
    private func drain() async {
        for await job in stream {
            await service.recordAndPush(tenantID: job.tenantID, event: job.event)
        }
    }
}
