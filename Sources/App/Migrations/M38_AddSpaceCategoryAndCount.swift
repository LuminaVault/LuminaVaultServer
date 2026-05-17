import FluentKit
import SQLKit

/// HER-35 — adds three columns to `spaces` to back the new client UI:
///
/// - `category` — free-form bucket label (e.g. "ai", "stocks") rendered as
///   a segmented control on the Spaces tab. Null for un-categorised
///   spaces. Indexed on `(tenant_id, category)` so the filter is cheap.
/// - `note_count` — denormalized memo count for the Space card. Default 0.
///   Counter writes are out of scope for this migration; the column hooks
///   the schema in place so a future ingest-path PR can flip it on without
///   touching the wire format again.
/// - `last_compiled_at` — timestamp of the last KB compile run that
///   included this Space. Null until the compile pipeline starts updating
///   it (separate PR).
///
/// Idempotent via `ADD COLUMN IF NOT EXISTS` + `CREATE INDEX IF NOT EXISTS`.
struct M38_AddSpaceCategoryAndCount: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw M38Error.requiresSQL
        }
        try await sql.raw("ALTER TABLE spaces ADD COLUMN IF NOT EXISTS category TEXT").run()
        try await sql.raw("ALTER TABLE spaces ADD COLUMN IF NOT EXISTS note_count INTEGER NOT NULL DEFAULT 0").run()
        try await sql.raw("ALTER TABLE spaces ADD COLUMN IF NOT EXISTS last_compiled_at TIMESTAMPTZ").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_spaces_tenant_category ON spaces (tenant_id, category)").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw M38Error.requiresSQL
        }
        try await sql.raw("DROP INDEX IF EXISTS idx_spaces_tenant_category").run()
        try await sql.raw("ALTER TABLE spaces DROP COLUMN IF EXISTS last_compiled_at").run()
        try await sql.raw("ALTER TABLE spaces DROP COLUMN IF EXISTS note_count").run()
        try await sql.raw("ALTER TABLE spaces DROP COLUMN IF EXISTS category").run()
    }
}

private enum M38Error: Error { case requiresSQL }
