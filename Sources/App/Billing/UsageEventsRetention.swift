import Foundation
import HummingbirdFluent
import Logging
import SQLKit

/// How long `usage_events` rows are kept.
///
/// The table was low-volume — a row per memory-compile run — until voice
/// metering started writing one per transcription attempt. Nothing breaks
/// soon, which is exactly the problem: unbounded growth becomes a slow
/// problem nobody attributes to the change that caused it.
///
/// Disabled by default. Deleting a tenant's usage history is irreversible, so
/// it has to be something an operator turns on deliberately rather than
/// something that starts happening because a service got wired in.
struct UsageEventsRetentionPolicy: Sendable, Equatable {
    /// Days of history to keep. Zero or negative disables retention.
    let retentionDays: Int
    /// Rows per DELETE. Bounded so one sweep cannot hold a long transaction
    /// over a table the hot path is inserting into.
    let batchSize: Int

    static let defaultBatchSize = 5000
    static let maxBatchSize = 10000

    init(retentionDays: Int, batchSize: Int = defaultBatchSize) {
        self.retentionDays = retentionDays
        self.batchSize = min(max(1, batchSize), Self.maxBatchSize)
    }

    var isEnabled: Bool {
        retentionDays > 0
    }

    /// Rows older than this are deletable.
    ///
    /// `nil` when disabled, rather than a cutoff so far back it happens to
    /// match nothing: a caller that forgets to check `isEnabled` then cannot
    /// issue the DELETE by accident.
    func cutoff(now: Date = Date()) -> Date? {
        guard isEnabled else { return nil }
        return now.addingTimeInterval(-Double(retentionDays) * 86400)
    }
}

/// Deletes `usage_events` past the retention window.
///
/// Batched and idempotent: run it as often as you like. Driven by the admin
/// route rather than an in-process timer, matching `MemoryPruningJob` — the
/// host cron already owns periodic maintenance for this deployment, and an
/// internal scheduler would run it once per replica.
struct UsageEventsRetentionService {
    let fluent: Fluent
    let policy: UsageEventsRetentionPolicy
    let logger: Logger

    struct Summary: Codable, Sendable, Equatable {
        let enabled: Bool
        let retentionDays: Int
        let cutoff: Date?
        let deleted: Int
        /// True when the sweep stopped at `maxBatches` with rows still older
        /// than the cutoff. Run it again; do not raise the batch size to
        /// compensate, which is how a maintenance job starts blocking writes.
        let moreRemaining: Bool
    }

    /// Bounded so a first run against a long-neglected table cannot become an
    /// unbounded delete loop holding the connection for an unpredictable time.
    static let maxBatches = 20

    func sweep(now: Date = Date()) async throws -> Summary {
        guard let cutoff = policy.cutoff(now: now) else {
            return Summary(
                enabled: false,
                retentionDays: policy.retentionDays,
                cutoff: nil,
                deleted: 0,
                moreRemaining: false
            )
        }
        guard let sql = fluent.db() as? any SQLDatabase else {
            logger.warning("usage_events retention requires SQL driver, skipping sweep")
            return Summary(
                enabled: true,
                retentionDays: policy.retentionDays,
                cutoff: cutoff,
                deleted: 0,
                moreRemaining: false
            )
        }

        struct DeletedRow: Decodable { let id: UUID }

        var deleted = 0
        var moreRemaining = false
        for batch in 1 ... Self.maxBatches {
            // Delete by primary key from a bounded subquery rather than a bare
            // `DELETE ... WHERE occurred_at < cutoff`: that would take one
            // long-running lock over an arbitrary number of rows on a table
            // the transcription path writes to synchronously.
            let rows = try await sql.raw("""
            DELETE FROM usage_events
            WHERE id IN (
                SELECT id FROM usage_events
                WHERE occurred_at < \(bind: cutoff)
                ORDER BY occurred_at
                LIMIT \(bind: policy.batchSize)
            )
            RETURNING id
            """).all(decoding: DeletedRow.self)

            deleted += rows.count
            if rows.count < policy.batchSize {
                break
            }
            if batch == Self.maxBatches {
                moreRemaining = true
            }
        }

        if deleted > 0 || moreRemaining {
            logger.info("usage_events retention sweep", metadata: [
                "deleted": .string("\(deleted)"),
                "cutoff": .string(ISO8601DateFormatter().string(from: cutoff)),
                "more_remaining": .string("\(moreRemaining)"),
            ])
        }

        return Summary(
            enabled: true,
            retentionDays: policy.retentionDays,
            cutoff: cutoff,
            deleted: deleted,
            moreRemaining: moreRemaining
        )
    }
}
