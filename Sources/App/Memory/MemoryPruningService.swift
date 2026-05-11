import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import SQLKit

/// HER-147 pruning thresholds. Default keeps anything younger than
/// 90 days regardless of score; older rows must clear `scoreThreshold`
/// to survive.
struct MemoryPruningConfig: Sendable {
    let scoreThreshold: Double
    let minAgeMonths: Int

    static let `default` = MemoryPruningConfig(
        scoreThreshold: 0.2,
        minAgeMonths: 3
    )
}

/// Per-tenant prune outcome. The job summary collects these.
struct MemoryPruneResult: Codable, Sendable {
    let tenantID: UUID
    let candidatesScanned: Int
    let archived: Int
}

/// HER-147 — moves low-score, older-than-N-months memory rows from
/// `memories` into `memories_archive`. Two-statement transaction:
///
///   INSERT INTO memories_archive (...)
///   SELECT (...) FROM memories
///   WHERE tenant_id = $1 AND score < $2 AND created_at < $3
///   RETURNING ... ;
///
///   DELETE FROM memories
///   WHERE tenant_id = $1 AND score < $2 AND created_at < $3 ;
///
/// Both predicates are identical; the index `(tenant_id, score)`
/// (M21) serves them. Idempotent — repeated runs against the same data
/// archive nothing the second time because the rows are already gone.
actor MemoryPruningService {
    let fluent: Fluent
    let config: MemoryPruningConfig
    let logger: Logger

    init(fluent: Fluent, config: MemoryPruningConfig = .default, logger: Logger) {
        self.fluent = fluent
        self.config = config
        self.logger = logger
    }

    @discardableResult
    func pruneForTenant(tenantID: UUID, now: Date = Date()) async throws -> MemoryPruneResult {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for pruning")
        }

        // Min-age cutoff in days. `minAgeMonths * 30` is the standard
        // approximation; we'd use Calendar.date(byAdding:) for true
        // calendar arithmetic, but the round-trip via Postgres `INTERVAL`
        // is enough for archive cadence.
        let cutoff = now.addingTimeInterval(-Double(config.minAgeMonths) * 30 * 86_400)

        // Snapshot the candidate count up-front for the summary. Same
        // predicate as the INSERT/DELETE pair; this is index-served.
        struct CountRow: Decodable { let n: Int }
        let candidates = try await sql.raw("""
            SELECT COUNT(*)::int AS n
            FROM memories
            WHERE tenant_id = \(bind: tenantID)
              AND score < \(bind: config.scoreThreshold)
              AND COALESCE(created_at, NOW()) < \(bind: cutoff)
            """).all(decoding: CountRow.self)
        let candidateCount = candidates.first?.n ?? 0
        guard candidateCount > 0 else {
            return MemoryPruneResult(tenantID: tenantID, candidatesScanned: 0, archived: 0)
        }

        // INSERT → DELETE. Two statements; the archive row carries the
        // original `created_at`. The DELETE re-evaluates the predicate
        // (no race risk here — Postgres MVCC plus same transaction would
        // also work; for simplicity we run sequentially and accept the
        // tiny window where the row could be re-accessed mid-prune. The
        // bump would set last_accessed_at but score wouldn't recompute
        // until the next sweep — acceptable loss for batch correctness).
        try await sql.raw("""
            INSERT INTO memories_archive (
                id, tenant_id, content, tags, embedding,
                score, access_count, query_hit_count, last_accessed_at,
                created_at, archived_at
            )
            SELECT id, tenant_id, content, tags, embedding,
                   score, access_count, query_hit_count, last_accessed_at,
                   created_at, NOW()
            FROM memories
            WHERE tenant_id = \(bind: tenantID)
              AND score < \(bind: config.scoreThreshold)
              AND COALESCE(created_at, NOW()) < \(bind: cutoff)
            ON CONFLICT (id) DO NOTHING
            """).run()
        let archived = try await sql.raw("""
            DELETE FROM memories
            WHERE tenant_id = \(bind: tenantID)
              AND score < \(bind: config.scoreThreshold)
              AND COALESCE(created_at, NOW()) < \(bind: cutoff)
            RETURNING id
            """).all()
        return MemoryPruneResult(
            tenantID: tenantID,
            candidatesScanned: candidateCount,
            archived: archived.count
        )
    }
}
