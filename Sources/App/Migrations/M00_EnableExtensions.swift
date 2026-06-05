import FluentKit
import SQLKit

struct M00_EnableExtensions: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.transaction { tx in
            guard let sql = tx as? any SQLDatabase else { return }
            // HER-335 — `CREATE EXTENSION IF NOT EXISTS` is not race-free under
            // concurrent workers: two sessions can both observe "missing" and
            // one loses on `pg_extension_name_index`. Serialize extension setup
            // with a transaction-scoped advisory lock.
            // Lock key 33500 is derived from HER-335 and reserved for this
            // migration so all workers coordinate on the same extension-
            // bootstrap critical section.
            try await sql.raw("SELECT pg_advisory_xact_lock(33500)").run()
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
    }

    func revert(on _: any Database) async throws {
        // extensions left in place (other databases may use them)
    }
}
