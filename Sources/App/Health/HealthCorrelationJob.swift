import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging

/// HER-146 sweep summary. Same shape as
/// `HermesProfileReconcileSummary` so the admin response format is
/// consistent across nightly jobs.
struct HealthCorrelationSweepSummary: Codable, Sendable {
    let usersScanned: Int
    let memoriesCreated: Int
    let skippedInsufficientHistory: Int
    let skippedAlreadyRan: Int
    let skippedNoEvents: Int
    let skippedNoSynthesis: Int
    let failures: [String]
}

/// HER-146 driver. Iterates every user and invokes
/// `HealthCorrelationService.correlate`. Designed to run from host cron
/// (e.g. nightly `curl POST /v1/admin/health/correlate`) until the
/// skills system (HER-148) supersedes this with a per-user
/// `weekly-correlation` skill executed by `CronScheduler`.
///
/// Per-user errors are caught and accumulated into `failures`; one bad
/// tenant does not abort the sweep.
struct HealthCorrelationJob: Sendable {
    let fluent: Fluent
    let service: HealthCorrelationService
    let logger: Logger

    func runForAllUsers(now: Date = Date()) async throws -> HealthCorrelationSweepSummary {
        let users = try await User.query(on: fluent.db()).all()
        var created = 0
        var skippedHistory = 0
        var skippedAlready = 0
        var skippedNoEvents = 0
        var skippedNoSynth = 0
        var failures: [String] = []

        for user in users {
            do {
                let outcome = try await service.correlate(user: user, now: now)
                switch outcome {
                case .saved: created += 1
                case .skippedInsufficientHistory: skippedHistory += 1
                case .skippedAlreadyRanThisWeek: skippedAlready += 1
                case .skippedNoRecentEvents: skippedNoEvents += 1
                case .skippedNoSynthesis: skippedNoSynth += 1
                }
            } catch {
                failures.append("\(user.username): \(error)")
                logger.warning("health-correlation failed for \(user.username): \(error)")
            }
        }

        logger.info("health-correlation sweep: scanned=\(users.count) created=\(created) skippedHistory=\(skippedHistory) skippedAlready=\(skippedAlready) skippedNoEvents=\(skippedNoEvents) skippedNoSynth=\(skippedNoSynth) failures=\(failures.count)")
        return HealthCorrelationSweepSummary(
            usersScanned: users.count,
            memoriesCreated: created,
            skippedInsufficientHistory: skippedHistory,
            skippedAlreadyRan: skippedAlready,
            skippedNoEvents: skippedNoEvents,
            skippedNoSynthesis: skippedNoSynth,
            failures: failures
        )
    }

    /// Targeted run for a single user — used by `POST /v1/admin/health/correlate/:userID`
    /// for manual triggering / debugging.
    func runForUser(id: UUID, now: Date = Date()) async throws -> HealthCorrelationOutcome {
        guard let user = try await User.find(id, on: fluent.db()) else {
            throw HTTPError(.notFound, message: "user not found")
        }
        return try await service.correlate(user: user, now: now)
    }
}
