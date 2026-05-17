@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import SQLKit
import Testing

/// HER-234 — verifies per-tenant partial HNSW index lifecycle. Each test
/// uses a unique tenant UUID so parallel test execution can't collide on
/// the deterministic index name.
@Suite(.serialized)
struct TenantVectorIndexServiceTests {
    private struct PgIndexRow: Codable {
        let indexname: String
    }

    private static func indexExists(_ name: String, on sql: any SQLDatabase) async throws -> Bool {
        let rows = try await sql.raw("""
        SELECT indexname FROM pg_indexes
        WHERE tablename = 'memories' AND indexname = \(bind: name)
        """).all(decoding: PgIndexRow.self)
        return !rows.isEmpty
    }

    @Test
    func `ensureIndex creates a partial hnsw index for the tenant`() async throws {
        try await withTestFluent(label: "lv.test.tenantidx.create") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()

            let tenantID = UUID()
            let service = TenantVectorIndexService(
                fluent: fluent,
                logger: Logger(label: "lv.test.tenantidx"),
            )
            try await service.ensureIndex(for: tenantID)

            guard let sql = fluent.db() as? any SQLDatabase else {
                Issue.record("SQL driver required")
                return
            }
            let name = TenantVectorIndexService.indexName(for: tenantID)
            #expect(try await Self.indexExists(name, on: sql))

            // Cleanup so a re-run on the same DB doesn't accumulate indexes.
            try await service.dropIndex(for: tenantID)
        }
    }

    @Test
    func `ensureIndex is idempotent`() async throws {
        try await withTestFluent(label: "lv.test.tenantidx.idem") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()

            let tenantID = UUID()
            let service = TenantVectorIndexService(
                fluent: fluent,
                logger: Logger(label: "lv.test.tenantidx"),
            )
            try await service.ensureIndex(for: tenantID)
            try await service.ensureIndex(for: tenantID)
            try await service.dropIndex(for: tenantID)
        }
    }

    @Test
    func `dropIndex removes the index and is idempotent`() async throws {
        try await withTestFluent(label: "lv.test.tenantidx.drop") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()

            let tenantID = UUID()
            let service = TenantVectorIndexService(
                fluent: fluent,
                logger: Logger(label: "lv.test.tenantidx"),
            )
            try await service.ensureIndex(for: tenantID)
            try await service.dropIndex(for: tenantID)

            guard let sql = fluent.db() as? any SQLDatabase else {
                Issue.record("SQL driver required")
                return
            }
            let name = TenantVectorIndexService.indexName(for: tenantID)
            #expect(try await Self.indexExists(name, on: sql) == false)

            // Second drop is a no-op.
            try await service.dropIndex(for: tenantID)
        }
    }

    @Test
    func `index name is deterministic and quote-safe`() {
        let uuid = UUID(uuidString: "11111111-2222-3333-4444-555566667777")!
        let name = TenantVectorIndexService.indexName(for: uuid)
        #expect(name == "idx_memories_emb_t_11111111222233334444555566667777")
        #expect(name.count <= 63) // Postgres identifier limit.
    }
}
