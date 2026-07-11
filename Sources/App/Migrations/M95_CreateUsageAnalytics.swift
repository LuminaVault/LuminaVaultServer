import FluentKit
import SQLKit

/// First-party, content-free usage intelligence scoped to a vault and actor.
struct M95_CreateUsageAnalytics: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        try await sql.raw("""
        ALTER TABLE memories
            ADD COLUMN IF NOT EXISTS last_reviewed_at TIMESTAMPTZ,
            ADD COLUMN IF NOT EXISTS review_count BIGINT NOT NULL DEFAULT 0
        """).run()
        try await sql.raw("""
        UPDATE memories
        SET last_reviewed_at = COALESCE(last_accessed_at, created_at)
        WHERE last_reviewed_at IS NULL
        """).run()

        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS analytics_events (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            vault_id UUID NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
            actor_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            event_name TEXT NOT NULL,
            source TEXT NOT NULL CHECK (source IN ('server', 'ios', 'web')),
            occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            dimensions JSONB NOT NULL DEFAULT '{}'::jsonb,
            idempotency_key TEXT
        )
        """).run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS analytics_events_vault_time_idx ON analytics_events(vault_id, occurred_at DESC)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS analytics_events_actor_time_idx ON analytics_events(actor_user_id, occurred_at DESC)").run()
        try await sql.raw("CREATE UNIQUE INDEX IF NOT EXISTS analytics_events_idempotency_idx ON analytics_events(actor_user_id, idempotency_key) WHERE idempotency_key IS NOT NULL").run()

        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS analytics_daily_rollups (
            day DATE NOT NULL,
            vault_id UUID NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
            actor_user_id UUID REFERENCES users(id) ON DELETE CASCADE,
            metric TEXT NOT NULL,
            dimension_key TEXT NOT NULL DEFAULT '',
            value BIGINT NOT NULL DEFAULT 0,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            PRIMARY KEY(day, vault_id, actor_user_id, metric, dimension_key)
        )
        """).run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS analytics_rollups_vault_day_idx ON analytics_daily_rollups(vault_id, day DESC)").run()

        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS analytics_recommendation_states (
            vault_id UUID NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
            user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            recommendation_id TEXT NOT NULL,
            dismissed_at TIMESTAMPTZ,
            snoozed_until TIMESTAMPTZ,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            PRIMARY KEY(vault_id, user_id, recommendation_id)
        )
        """).run()

        try await sql.raw("""
        ALTER TABLE router_executions
            ADD COLUMN IF NOT EXISTS vault_id UUID REFERENCES vaults(id) ON DELETE SET NULL,
            ADD COLUMN IF NOT EXISTS actor_user_id UUID REFERENCES users(id) ON DELETE SET NULL
        """).run()
        // Historical router records are safely attributable only to the user's
        // personal vault, whose id intentionally matches the user id.
        try await sql.raw("""
        UPDATE router_executions
        SET vault_id = tenant_id, actor_user_id = tenant_id
        WHERE vault_id IS NULL
          AND EXISTS (SELECT 1 FROM vaults v WHERE v.id = router_executions.tenant_id
                      AND v.personal_owner_user_id = router_executions.tenant_id)
        """).run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS router_executions_vault_time_idx ON router_executions(vault_id, occurred_at DESC)").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS analytics_recommendation_states").run()
        try await sql.raw("DROP TABLE IF EXISTS analytics_daily_rollups").run()
        try await sql.raw("DROP TABLE IF EXISTS analytics_events").run()
        try await sql.raw("ALTER TABLE router_executions DROP COLUMN IF EXISTS actor_user_id, DROP COLUMN IF EXISTS vault_id").run()
        try await sql.raw("ALTER TABLE memories DROP COLUMN IF EXISTS review_count, DROP COLUMN IF EXISTS last_reviewed_at").run()
    }
}
