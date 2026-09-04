import FluentKit
import SQLKit

/// Phase 1 (Hermes runs) — opt-out flags for the two new push categories
/// (`approval`, `runCompleted`). Same shape as M43: default TRUE so the
/// absence of a row (or of the column value) means "allowed".
struct M119_AddHermesRunApnsCategoryPrefs: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        ALTER TABLE apns_category_prefs
            ADD COLUMN IF NOT EXISTS approval_enabled BOOLEAN NOT NULL DEFAULT TRUE,
            ADD COLUMN IF NOT EXISTS run_completed_enabled BOOLEAN NOT NULL DEFAULT TRUE
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        ALTER TABLE apns_category_prefs
            DROP COLUMN IF EXISTS approval_enabled,
            DROP COLUMN IF EXISTS run_completed_enabled
        """).run()
    }
}
