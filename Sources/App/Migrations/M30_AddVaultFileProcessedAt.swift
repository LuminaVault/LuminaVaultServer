import FluentKit
import SQLKit

/// Adds the marker used by the automatic kb-compile job.
///
/// `NULL` means the raw vault file still needs to be compiled into Hermes'
/// memory store. A successful per-user background compile stamps every row
/// included in that run with the completion time. Any later write to the raw
/// file resets this column to NULL so the next scheduled pass retries it.
struct M30_AddVaultFileProcessedAt: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        ALTER TABLE vault_files
        ADD COLUMN IF NOT EXISTS processed_at TIMESTAMPTZ
        """).run()
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS idx_vault_files_unprocessed
        ON vault_files (tenant_id, processed_at)
        WHERE processed_at IS NULL
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS idx_vault_files_unprocessed").run()
        try await sql.raw("ALTER TABLE vault_files DROP COLUMN IF EXISTS processed_at").run()
    }
}
