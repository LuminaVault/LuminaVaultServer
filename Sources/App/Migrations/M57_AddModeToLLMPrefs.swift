import FluentKit
import SQLKit

/// HER-300 — Adds `mode` column to `user_llm_preferences` distinguishing
/// server-managed default routing (`managed`) from BYOK with user-supplied
/// keys (`byok`). Existing rows are backfilled to `byok` because they were
/// created by users who explicitly configured a primary provider + chain
/// via Settings; that's BYOK semantics. New rows default to `managed` so
/// the "Choose Your Brain" onboarding screen can record a managed-mode
/// preference without forcing a key entry.
struct M57_AddModeToLLMPrefs: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        ALTER TABLE user_llm_preferences
        ADD COLUMN IF NOT EXISTS mode TEXT
        """).run()
        try await sql.raw("""
        UPDATE user_llm_preferences
        SET mode = 'byok'
        WHERE mode IS NULL
        """).run()
        try await sql.raw("""
        ALTER TABLE user_llm_preferences
        ALTER COLUMN mode SET DEFAULT 'managed'
        """).run()
        try await sql.raw("""
        ALTER TABLE user_llm_preferences
        ALTER COLUMN mode SET NOT NULL
        """).run()
        try await sql.raw("""
        ALTER TABLE user_llm_preferences
        ADD CONSTRAINT user_llm_preferences_mode_check
        CHECK (mode IN ('managed', 'byok'))
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        ALTER TABLE user_llm_preferences
        DROP CONSTRAINT IF EXISTS user_llm_preferences_mode_check
        """).run()
        try await sql.raw("""
        ALTER TABLE user_llm_preferences
        DROP COLUMN IF EXISTS mode
        """).run()
    }
}
