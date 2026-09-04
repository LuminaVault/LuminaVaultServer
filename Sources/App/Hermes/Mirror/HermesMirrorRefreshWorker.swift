import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import ServiceLifecycle

/// Hermes Mirror — keeps every linked Hermes fresh in the background.
///
/// Every `tickInterval` (15 min) it walks `user_hermes_config` rows that have
/// a dashboard URL, keyset-paginated by id in pages of `pageSize` (no
/// `User.query().all()`), and for each tenant runs a skills + jobs sync and
/// continues any capped vault import left behind by a request. Tenants are
/// processed with bounded concurrency, a per-tenant time budget, and full
/// failure isolation — one broken Hermes never stalls the others. A small
/// start jitter keeps replicas from ticking in lockstep.
actor HermesMirrorRefreshWorker: Service {
    private let fluent: Fluent
    private let service: HermesMirrorService
    private let logger: Logger
    private let tickInterval: Duration
    private let pageSize: Int
    private let maxConcurrent: Int
    private let perTenantBudget: Duration
    private let maxJitter: Duration

    init(
        fluent: Fluent,
        service: HermesMirrorService,
        logger: Logger,
        tickInterval: Duration = .seconds(900),
        pageSize: Int = 100,
        maxConcurrent: Int = 4,
        perTenantBudget: Duration = .seconds(60),
        maxJitter: Duration = .seconds(30)
    ) {
        self.fluent = fluent
        self.service = service
        self.logger = logger
        self.tickInterval = tickInterval
        self.pageSize = max(1, pageSize)
        self.maxConcurrent = max(1, maxConcurrent)
        self.perTenantBudget = perTenantBudget
        self.maxJitter = maxJitter
    }

    func run() async throws {
        logger.info("hermes.mirror.worker started", metadata: ["tick": "\(tickInterval)"])
        try? await Task.sleep(for: Self.jitter(upTo: maxJitter))
        while !Task.isCancelled {
            do {
                let summary = try await tick()
                if summary.processed > 0 {
                    logger.info("hermes.mirror.worker tick", metadata: [
                        "processed": "\(summary.processed)", "failed": "\(summary.failed)", "timedOut": "\(summary.timedOut)",
                    ])
                }
            } catch {
                logger.warning("hermes.mirror.worker tick error: \(HermesMirrorService.describe(error))")
            }
            try? await Task.sleep(for: tickInterval)
        }
    }

    struct TickSummary: Sendable, Equatable {
        var processed = 0
        var failed = 0
        var timedOut = 0
    }

    /// One pass over every configured tenant. Returns counts for logging/tests.
    @discardableResult
    func tick() async throws -> TickSummary {
        var summary = TickSummary()
        var cursor: UUID?
        while true {
            let page = try await configuredTenants(after: cursor)
            guard !page.isEmpty else { break }
            cursor = page.last?.rowID
            let tenantIDs = page.map(\.tenantID)
            var index = 0
            while index < tenantIDs.count {
                let batch = Array(tenantIDs[index ..< min(index + maxConcurrent, tenantIDs.count)])
                let outcomes = await withTaskGroup(of: Outcome.self, returning: [Outcome].self) { group in
                    for tenantID in batch {
                        group.addTask { [service, perTenantBudget, logger] in
                            await Self.refresh(tenantID: tenantID, service: service, budget: perTenantBudget, logger: logger)
                        }
                    }
                    var collected: [Outcome] = []
                    for await outcome in group {
                        collected.append(outcome)
                    }
                    return collected
                }
                for outcome in outcomes {
                    summary.processed += 1
                    switch outcome {
                    case .ok: break
                    case .failed: summary.failed += 1
                    case .timedOut: summary.timedOut += 1
                    }
                }
                index += maxConcurrent
            }
            if page.count < pageSize {
                break
            }
        }
        return summary
    }

    struct ConfiguredTenant: Sendable, Equatable {
        let rowID: UUID
        let tenantID: UUID
    }

    /// Keyset page of tenants with a dashboard URL, ordered by row id.
    func configuredTenants(after cursor: UUID?) async throws -> [ConfiguredTenant] {
        var query = UserHermesConfig.query(on: fluent.db())
            .filter(\.$cronDashboardURL != nil)
            // swiftlint:disable:next empty_string
            .filter(\.$cronDashboardURL != "")
            .sort(\.$id)
            .limit(pageSize)
        if let cursor {
            query = query.filter(\.$id > cursor)
        }
        return try await query.all().compactMap { row in
            guard let id = row.id else { return nil }
            return ConfiguredTenant(rowID: id, tenantID: row.tenantID)
        }
    }

    enum Outcome: Sendable {
        case ok
        case failed
        case timedOut
    }

    /// Sync skills + jobs, collect finished job runs, then continue a pending
    /// vault import, inside one time budget. Errors are logged, never
    /// propagated.
    ///
    /// Collect runs after the jobs sync so it sees the current job set, and
    /// before the vault import so a slow import cannot starve it — a job's
    /// output reaching the Today feed is the phase's whole point.
    static func refresh(tenantID: UUID, service: HermesMirrorService, budget: Duration, logger: Logger) async -> Outcome {
        await withTaskGroup(of: Outcome.self, returning: Outcome.self) { group in
            group.addTask {
                do {
                    let status = try await service.sync(tenantID: tenantID, scopes: [.skills, .jobs])
                    let collected = try await service.collectAllJobRuns(tenantID: tenantID)
                    if collected.inserted > 0 || collected.failed > 0 {
                        logger.info("hermes.mirror.worker collect", metadata: [
                            "tenant": .string(tenantID.uuidString),
                            "jobs": "\(collected.jobs)", "runs": "\(collected.inserted)",
                            "files": "\(collected.filesWritten)", "failed": "\(collected.failed)",
                        ])
                    }
                    if try await service.hasPendingVaultImport(tenantID: tenantID) {
                        _ = try await service.importVault(tenantID: tenantID, requestedPath: nil)
                    }
                    return status.lastStatus == .failed ? .failed : .ok
                } catch {
                    logger.warning("hermes.mirror.worker tenant refresh failed", metadata: [
                        "tenant": .string(tenantID.uuidString),
                        "error": "\(HermesMirrorService.describe(error))",
                    ])
                    return .failed
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: budget)
                    return .timedOut
                } catch {
                    return .ok
                }
            }
            let first = await group.next() ?? .failed
            group.cancelAll()
            if first == .timedOut {
                logger.warning("hermes.mirror.worker tenant refresh exceeded budget", metadata: [
                    "tenant": .string(tenantID.uuidString), "budget": "\(budget)",
                ])
            }
            return first
        }
    }

    static func jitter(upTo maximum: Duration) -> Duration {
        let components = maximum.components
        let totalMilliseconds = components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
        guard totalMilliseconds > 0 else { return .zero }
        return .milliseconds(Int64.random(in: 0 ... totalMilliseconds))
    }
}
