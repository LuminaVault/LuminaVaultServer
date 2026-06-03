import FluentKit
import SQLKit

/// Adds nullable `allowed_providers` / `blocked_providers` JSONB columns to
/// `user_llm_preferences` for provider routing constraints (Phase 2 item 6).
/// Nullable (no backfill): a NULL or empty list means "all providers
/// allowed", matching the wire default of an empty array.
struct M76_AddProviderListsToLLMPrefs: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        ALTER TABLE user_llm_preferences
        ADD COLUMN IF NOT EXISTS allowed_providers JSONB
        """).run()
        try await sql.raw("""
        ALTER TABLE user_llm_preferences
        ADD COLUMN IF NOT EXISTS blocked_providers JSONB
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        ALTER TABLE user_llm_preferences
        DROP COLUMN IF EXISTS allowed_providers
        """).run()
        try await sql.raw("""
        ALTER TABLE user_llm_preferences
        DROP COLUMN IF EXISTS blocked_providers
        """).run()
    }
}
