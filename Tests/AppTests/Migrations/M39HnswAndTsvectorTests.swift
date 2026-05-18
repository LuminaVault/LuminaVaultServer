@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import SQLKit
import Testing

/// HER-234 — verifies the M39 migration ends in the expected schema state:
///   - `content_tsv` generated column present
///   - `idx_memories_content_tsv` GIN index present
///   - `idx_memories_embedding_hnsw` HNSW index present
///   - the old IVFFlat `idx_memories_embedding` is gone
@Suite(.serialized)
struct M39HnswAndTsvectorTests {
    private struct PgIndexRow: Codable {
        let indexname: String
    }
    private struct PgAttrRow: Codable {
        let attname: String
    }

    @Test
    func `migration produces hnsw + tsv schema`() async throws {
        try await withTestFluent(label: "lv.test.m39") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()

            guard let sql = fluent.db() as? any SQLDatabase else {
                Issue.record("SQL driver required")
                return
            }

            let indexes = try await sql.raw("""
            SELECT indexname FROM pg_indexes WHERE tablename = 'memories'
            """).all(decoding: PgIndexRow.self).map(\.indexname)

            #expect(indexes.contains("idx_memories_embedding_hnsw"))
            #expect(indexes.contains("idx_memories_content_tsv"))
            #expect(!indexes.contains("idx_memories_embedding"))

            let columns = try await sql.raw("""
            SELECT attname FROM pg_attribute
            WHERE attrelid = 'memories'::regclass AND attnum > 0 AND NOT attisdropped
            """).all(decoding: PgAttrRow.self).map(\.attname)

            #expect(columns.contains("content_tsv"))
        }
    }

    @Test
    func `migrations are idempotent`() async throws {
        try await withTestFluent(label: "lv.test.m39.idempotent") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            // Re-run; should be a no-op.
            try await fluent.migrate()
        }
    }
}
