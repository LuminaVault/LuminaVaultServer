import FluentKit
import SQLKit

/// Resurfacing ("to revisit"): `next_review_at` is when a memory the user
/// asked to see again comes due (`soon` / `later` on `POST /v1/memory/:id/review`),
/// and `resurface_muted` is the `never` answer. The partial index serves the
/// `due` lane of `GET /v1/me/resurface`.
struct M142_AddMemoryResurfacing: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.requiresSQL
        }
        try await sql.raw("""
        ALTER TABLE memories
            ADD COLUMN IF NOT EXISTS next_review_at TIMESTAMPTZ,
            ADD COLUMN IF NOT EXISTS resurface_muted BOOLEAN NOT NULL DEFAULT false
        """).run()
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS memories_resurface_due_idx
            ON memories (tenant_id, next_review_at)
            WHERE next_review_at IS NOT NULL AND NOT resurface_muted
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.requiresSQL
        }
        try await sql.raw("DROP INDEX IF EXISTS memories_resurface_due_idx").run()
        try await sql.raw("""
        ALTER TABLE memories
            DROP COLUMN IF EXISTS next_review_at,
            DROP COLUMN IF EXISTS resurface_muted
        """).run()
    }
}

private enum MigrationError: Error { case requiresSQL }
