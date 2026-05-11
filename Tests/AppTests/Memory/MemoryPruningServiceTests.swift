@testable import App
import FluentKit
import FluentPostgresDriver
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import SQLKit
import Testing

/// HER-147 DB-touching tests for `MemoryScoringService` + `MemoryPruningService`.
/// Run with `docker compose up -d postgres`.
@Suite(.serialized)
struct MemoryPruningServiceTests {
    fileprivate struct Harness {
        let fluent: Fluent
        let scoring: MemoryScoringService
        let pruning: MemoryPruningService
        let user: User
    }

    private static func withHarness<T: Sendable>(
        scoringConfig: MemoryScoringConfig = .default,
        pruningConfig: MemoryPruningConfig = .default,
        _ body: @Sendable (Harness) async throws -> T,
    ) async throws -> T {
        let logger = Logger(label: "test.memory-prune")
        let fluent = Fluent(logger: logger)
        fluent.databases.use(
            .postgres(configuration: TestPostgres.configuration()),
            as: .psql,
        )
        let scoring = MemoryScoringService(fluent: fluent, config: scoringConfig, logger: logger)
        let pruning = MemoryPruningService(fluent: fluent, config: pruningConfig, logger: logger)

        // Ephemeral user.
        let username = "mp-\(UUID().uuidString.prefix(8).lowercased())"
        let user = User(email: "\(username)@test.luminavault", username: username, passwordHash: "x")
        try await user.save(on: fluent.db())

        let harness = Harness(fluent: fluent, scoring: scoring, pruning: pruning, user: user)
        do {
            let result = try await body(harness)
            try await fluent.shutdown()
            return result
        } catch {
            try? await fluent.shutdown()
            throw error
        }
    }

    /// Inserts a memory row with explicit `created_at`, `access_count`, `query_hit_count`.
    /// Raw SQL so the test can backdate `created_at` (Fluent's @Timestamp on .create
    /// will overwrite a save-time value).
    private static func insertMemory(
        fluent: Fluent,
        tenantID: UUID,
        content: String,
        createdAt: Date,
        accessCount: Int = 0,
        queryHitCount: Int = 0,
    ) async throws -> UUID {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "need SQL")
        }
        let id = UUID()
        try await sql.raw("""
        INSERT INTO memories
            (id, tenant_id, content, created_at, access_count, query_hit_count, score)
        VALUES
            (\(bind: id), \(bind: tenantID), \(bind: content),
             \(bind: createdAt), \(bind: accessCount), \(bind: queryHitCount), 0)
        """).run()
        return id
    }

    @Test
    func `recompute updates score to formula`() async throws {
        try await Self.withHarness { h in
            let tenantID = try h.user.requireID()
            let now = Date()
            let day = 86400.0

            // Three rows with varied access patterns.
            let fresh = try await Self.insertMemory(
                fluent: h.fluent, tenantID: tenantID,
                content: "fresh", createdAt: now,
            )
            let oldQuiet = try await Self.insertMemory(
                fluent: h.fluent, tenantID: tenantID,
                content: "old quiet", createdAt: now.addingTimeInterval(-180 * day),
            )
            let oldPopular = try await Self.insertMemory(
                fluent: h.fluent, tenantID: tenantID,
                content: "old popular",
                createdAt: now.addingTimeInterval(-180 * day),
                accessCount: 100,
                queryHitCount: 30,
            )

            let updated = try await h.scoring.recomputeForTenant(tenantID: tenantID, now: now)
            #expect(updated == 3)

            // Pull rows back, compare to the pure-math formula.
            let f = try #require(try await Memory.find(fresh, on: h.fluent.db()))
            #expect(abs(f.score - 1.0) < 1e-6)

            let q = try #require(try await Memory.find(oldQuiet, on: h.fluent.db()))
            #expect(q.score < 0.05, "180d-old, untouched → recency term decays to near-zero (\(q.score))")

            let p = try #require(try await Memory.find(oldPopular, on: h.fluent.db()))
            #expect(p.score > 10, "heavily used row stays high regardless of age (\(p.score))")
        }
    }

    @Test
    func `prune archives low score old rows only`() async throws {
        try await Self.withHarness { h in
            let tenantID = try h.user.requireID()
            let now = Date()
            let day = 86400.0

            // (a) Fresh, low score → kept (under min-age).
            let recent = try await Self.insertMemory(
                fluent: h.fluent, tenantID: tenantID,
                content: "recent low-score", createdAt: now,
            )
            // (b) Old, low score → archived.
            let oldLow = try await Self.insertMemory(
                fluent: h.fluent, tenantID: tenantID,
                content: "old & quiet", createdAt: now.addingTimeInterval(-180 * day),
            )
            // (c) Old, high score → kept (above threshold even though old).
            let oldHigh = try await Self.insertMemory(
                fluent: h.fluent, tenantID: tenantID,
                content: "old & loved",
                createdAt: now.addingTimeInterval(-180 * day),
                accessCount: 100,
                queryHitCount: 30,
            )

            _ = try await h.scoring.recomputeForTenant(tenantID: tenantID, now: now)
            let result = try await h.pruning.pruneForTenant(tenantID: tenantID, now: now)
            #expect(result.archived == 1)

            // Row state.
            #expect(try await Memory.find(recent, on: h.fluent.db()) != nil)
            #expect(try await Memory.find(oldLow, on: h.fluent.db()) == nil, "low-score old row must be archived")
            #expect(try await Memory.find(oldHigh, on: h.fluent.db()) != nil)

            // Archive row materialised.
            let archived = try await MemoryArchive
                .query(on: h.fluent.db(), tenantID: tenantID)
                .filter(\.$id == oldLow)
                .first()
            #expect(archived != nil)
        }
    }

    @Test
    func `prune is idempotent`() async throws {
        try await Self.withHarness { h in
            let tenantID = try h.user.requireID()
            let now = Date()
            _ = try await Self.insertMemory(
                fluent: h.fluent, tenantID: tenantID,
                content: "drop me", createdAt: now.addingTimeInterval(-180 * 86400),
            )
            _ = try await h.scoring.recomputeForTenant(tenantID: tenantID, now: now)

            let first = try await h.pruning.pruneForTenant(tenantID: tenantID, now: now)
            #expect(first.archived == 1)

            let second = try await h.pruning.pruneForTenant(tenantID: tenantID, now: now)
            #expect(second.archived == 0, "second prune over same data must be a no-op")
        }
    }

    @Test
    func `tenant isolation during prune`() async throws {
        try await Self.withHarness { h in
            // Second ephemeral user.
            let mallory = User(email: "m-\(UUID()).local", username: "m-\(UUID().uuidString.prefix(6).lowercased())", passwordHash: "x")
            try await mallory.save(on: h.fluent.db())
            let aliceID = try h.user.requireID()
            let malloryID = try mallory.requireID()
            let now = Date()
            let oldDate = now.addingTimeInterval(-180 * 86400)

            // Both users get an old, low-score row.
            let aliceMem = try await Self.insertMemory(
                fluent: h.fluent, tenantID: aliceID,
                content: "alice old", createdAt: oldDate,
            )
            let malloryMem = try await Self.insertMemory(
                fluent: h.fluent, tenantID: malloryID,
                content: "mallory old", createdAt: oldDate,
            )

            _ = try await h.scoring.recomputeAll(now: now)

            // Prune Alice only — Mallory's row must remain untouched.
            _ = try await h.pruning.pruneForTenant(tenantID: aliceID, now: now)
            #expect(try await Memory.find(aliceMem, on: h.fluent.db()) == nil)
            #expect(try await Memory.find(malloryMem, on: h.fluent.db()) != nil)
        }
    }
}
