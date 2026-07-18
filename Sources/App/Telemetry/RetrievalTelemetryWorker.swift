import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import ServiceLifecycle

/// Which grounding path issued the retrieval.
enum RetrievalSourcePath: String, Sendable {
    case localReply = "local_reply"
    case query
    case agenticSearch = "agentic_search"
}

/// Immutable value describing one pgvector retrieval. This is what crosses the
/// worker's actor boundary — never the `RetrievalTelemetryEvent` model class.
struct RetrievalTelemetrySample: Sendable {
    let tenantID: UUID
    let sourcePath: RetrievalSourcePath
    let spaceID: UUID?
    let hitCount: Int
    let topDistance: Double?
    let meanDistance: Double?
    let limitRequested: Int

    /// Derive a sample from the hits a `semanticSearch` returned. `top` is the
    /// closest (min) cosine distance, `mean` the average; both nil when empty.
    /// Accepts the search results' `Float` distances and widens to `Double`.
    static func from(
        tenantID: UUID,
        distances: [Float],
        source: RetrievalSourcePath,
        spaceID: UUID?,
        limit: Int
    ) -> RetrievalTelemetrySample {
        let widened = distances.map(Double.init)
        let top = widened.min()
        let mean = widened.isEmpty ? nil : widened.reduce(0, +) / Double(widened.count)
        return RetrievalTelemetrySample(
            tenantID: tenantID,
            sourcePath: source,
            spaceID: spaceID,
            hitCount: widened.count,
            topDistance: top,
            meanDistance: mean,
            limitRequested: limit
        )
    }
}

/// Drains retrieval samples off the chat hot path and persists them, mirroring
/// `AchievementsWorker`: an `actor` + `Service` fed by an `AsyncStream`, drained
/// on the app's long-lived `Fluent`, registered AFTER `fluent` in the
/// ServiceGroup so it stops draining BEFORE the database shuts down (the
/// `.db()`-on-torn-down-DB / signal-5 fix).
///
/// `enqueue` is the ONLY thing a request handler calls: synchronous, no `Task`,
/// no DB, never throws. Telemetry loss (buffer full / worker stopped) is
/// tolerated and logged — a chat must never fail for telemetry.
actor RetrievalTelemetryWorker: Service {
    private let fluent: Fluent
    private let stream: AsyncStream<RetrievalTelemetrySample>
    private nonisolated let continuation: AsyncStream<RetrievalTelemetrySample>.Continuation
    private nonisolated let logger: Logger

    init(fluent: Fluent, logger: Logger, bufferSize: Int = 512) {
        self.fluent = fluent
        self.logger = logger
        (stream, continuation) = AsyncStream<RetrievalTelemetrySample>.makeStream(
            bufferingPolicy: .bufferingNewest(bufferSize)
        )
    }

    /// Non-blocking. Safe from a request handler — never spawns a `Task`, never
    /// touches the DB. Dropped (logged) when the buffer is full or the worker
    /// has shut down.
    nonisolated func enqueue(_ sample: RetrievalTelemetrySample) {
        switch continuation.yield(sample) {
        case .dropped:
            logger.warning("retrieval telemetry inbox full; dropped \(sample.sourcePath.rawValue)")
        case .terminated:
            logger.debug("retrieval telemetry worker stopped; dropped \(sample.sourcePath.rawValue)")
        default:
            break
        }
    }

    /// Test-only: end the inbox so `run()` returns without a ServiceGroup.
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
                continuation.finish()
            }
            await group.next()
            group.cancelAll()
        }
    }

    /// Actor-isolated drain — one INSERT per sample on the long-lived Fluent.
    /// Volume is one row per grounding retrieval; a failed insert is logged and
    /// skipped so a transient DB error never stalls the drain.
    private func drain() async {
        for await sample in stream {
            do {
                try await RetrievalTelemetryEvent(sample).create(on: fluent.db())
            } catch {
                logger.warning("retrieval telemetry insert failed: \(error)")
            }
        }
    }
}
