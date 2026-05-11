import FluentKit
import SQLKit

/// Per-tenant progress on each achievement sub-entry. The catalog (archetypes
/// + sub-achievements + thresholds) lives in code (`AchievementCatalog`) so
/// content edits never need a migration — only schema changes do.
///
/// `progress_count` is monotonically incremented by `AchievementsService.record`
/// from controller hot-paths (memory upsert, chat completion, KB compile, query,
/// vault upload, SOUL configure, space creation). `unlocked_at` is set the
/// first time `progress_count` crosses the catalog's threshold and is never
/// rewritten after, which makes re-firing past the threshold idempotent.
///
/// `(tenant_id, achievement_key)` is unique so per-user state stays one row.
/// `ON DELETE CASCADE` against `users` keeps account-deletion clean.
struct M28_CreateAchievementProgress: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS achievement_progress (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            achievement_key TEXT NOT NULL,
            progress_count BIGINT NOT NULL DEFAULT 0,
            unlocked_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (tenant_id, achievement_key)
        )
        """).run()
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS idx_achievement_progress_tenant_unlocked
        ON achievement_progress (tenant_id, unlocked_at DESC)
        WHERE unlocked_at IS NOT NULL
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS idx_achievement_progress_tenant_unlocked").run()
        try await sql.raw("DROP TABLE IF EXISTS achievement_progress").run()
    }
}
