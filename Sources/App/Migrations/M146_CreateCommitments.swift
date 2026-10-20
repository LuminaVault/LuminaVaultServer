import FluentKit
import SQLKit

/// Commitments ("open loops"): first-person promises kb-compile pulls out of
/// the user's notes — "I'll send Ana the deck", "I need to renew my passport".
///
/// A separate table, not a memory kind: `MemoryKindDTO` is a strict enum in
/// Shared, so a new case would break older clients decoding memory lists.
///
/// - `normalized_text` is lowercased, whitespace-collapsed `text` without
///   trailing punctuation. The partial unique index on
///   `(tenant_id, normalized_text) WHERE state = 'open'` is what stops a
///   re-compile of the same note from adding the promise twice; once it is
///   done or dropped, the same words may open a new one.
/// - `surfaced_count` is how many daily briefs have shown it. The brief stops
///   at 3 ("no nagging"); the list endpoint still shows it.
/// - `memory_id` / `source_vault_file_id` are lineage and survive the source
///   being deleted (`SET NULL`).
struct M146_CreateCommitments: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.requiresSQL
        }
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS commitments (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            tenant_id UUID NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
            memory_id UUID NULL REFERENCES memories(id) ON DELETE SET NULL,
            source_vault_file_id UUID NULL REFERENCES vault_files(id) ON DELETE SET NULL,
            text TEXT NOT NULL,
            normalized_text TEXT NOT NULL,
            due_at TIMESTAMPTZ NULL,
            state TEXT NOT NULL DEFAULT 'open' CHECK (state IN ('open', 'done', 'dropped')),
            surfaced_count INT NOT NULL DEFAULT 0,
            created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            done_at TIMESTAMPTZ NULL
        )
        """).run()
        try await sql.raw("""
        CREATE UNIQUE INDEX IF NOT EXISTS commitments_open_unique
        ON commitments (tenant_id, normalized_text) WHERE state = 'open'
        """).run()
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS commitments_tenant_state
        ON commitments (tenant_id, state, created_at DESC)
        """).run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("commitments").delete()
    }
}

private enum MigrationError: Error { case requiresSQL }
