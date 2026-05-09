import FluentKit
import SQLKit

struct M00_EnableExtensions: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\"").run()
        try await sql.raw("CREATE EXTENSION IF NOT EXISTS \"pgcrypto\"").run()
        // pgvector — required for memories.embedding semantic search.
        // Postgres image must ship the vector extension (e.g. ankane/pgvector,
        // pgvector/pgvector, or a custom build). Stock postgres:alpine does NOT.
        try await sql.raw("CREATE EXTENSION IF NOT EXISTS \"vector\"").run()
    }

    func revert(on database: any Database) async throws {
        // extensions left in place (other databases may use them)
    }
}
