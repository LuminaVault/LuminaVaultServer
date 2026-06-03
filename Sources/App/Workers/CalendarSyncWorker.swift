import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import ServiceLifecycle

/// HER-340 — polls connected Google Calendar accounts on a fixed interval
/// and runs an incremental sync per tenant. Same `ServiceLifecycle.Service`
/// loop shape as `SynthesisWorker`/`CronScheduler`: tick, catch+log, sleep.
///
/// Incremental sync (Google `syncToken`) makes the steady state near-free —
/// when nothing changed Google returns an empty delta — so a 15-minute poll
/// is cheap. Accounts in `needs_reauth` are skipped by `CalendarSyncService`.
/// Bounded concurrency (`maxConcurrent`) avoids a thundering herd at scale;
/// single-replica only (a second replica would double-poll — add a Postgres
/// advisory lock when horizontally scaling, same caveat as the other workers).
actor CalendarSyncWorker: Service {
    private let fluent: Fluent
    private let syncService: CalendarSyncService
    private let logger: Logger
    private let tickInterval: Duration
    private let maxConcurrent: Int

    init(
        fluent: Fluent,
        syncService: CalendarSyncService,
        logger: Logger,
        tickInterval: Duration = .seconds(900),
        maxConcurrent: Int = 4,
    ) {
        self.fluent = fluent
        self.syncService = syncService
        self.logger = logger
        self.tickInterval = tickInterval
        self.maxConcurrent = maxConcurrent
    }

    func run() async throws {
        logger.info("calendar.sync.worker started", metadata: ["tick": "\(tickInterval)"])
        while !Task.isCancelled {
            do {
                let synced = try await tick()
                if synced > 0 {
                    logger.info("calendar.sync.worker tick", metadata: ["accounts": "\(synced)"])
                }
            } catch {
                logger.warning("calendar.sync.worker tick error: \(error)")
            }
            try? await Task.sleep(for: tickInterval)
        }
    }

    /// Sync every connected account with bounded concurrency. Returns the
    /// number of accounts processed.
    @discardableResult
    func tick() async throws -> Int {
        let tenantIDs = try await CalendarAccount.query(on: fluent.db())
            .filter(\.$status == "connected")
            .all()
            .map(\.tenantID)
        guard !tenantIDs.isEmpty else { return 0 }

        var processed = 0
        var index = 0
        while index < tenantIDs.count {
            let batch = tenantIDs[index ..< min(index + maxConcurrent, tenantIDs.count)]
            try await withThrowingTaskGroup(of: Void.self) { group in
                for tenantID in batch {
                    let service = syncService
                    group.addTask {
                        _ = try? await service.sync(tenantID: tenantID)
                    }
                }
                try await group.waitForAll()
            }
            processed += batch.count
            index += maxConcurrent
        }
        return processed
    }
}
