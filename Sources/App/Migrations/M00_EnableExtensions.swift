import FluentKit
import SQLKit

struct M00_EnableExtensions: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\"").run()
        try await sql.raw("CREATE EXTENSION IF NOT EXISTS \"pgcrypto\"").run()
        // pgvector — semantic search on memories.embedding.
        // Image MUST ship vector (we use `pgvector/pgvector:pg18`). Stock
        // postgres:alpine does NOT.
        try await sql.raw("CREATE EXTENSION IF NOT EXISTS \"vector\"").run()
        // pg_trgm — trigram fuzzy text search on vault_files.path,
        // memories.content, etc. Bundled with vanilla Postgres.
        try await sql.raw("CREATE EXTENSION IF NOT EXISTS \"pg_trgm\"").run()
        // PostGIS / TimescaleDB are NOT enabled here — they require image
        // changes (see docs/integration.md "Extension matrix" section).
    }

    func revert(on database: any Database) async throws {
        // extensions left in place (other databases may use them)
    }
}
