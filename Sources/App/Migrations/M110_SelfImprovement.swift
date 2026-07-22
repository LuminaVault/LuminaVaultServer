import FluentKit
import SQLKit

struct M110_SelfImprovement: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS self_improvement_settings (
            id UUID PRIMARY KEY,
            tenant_id UUID NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
            enabled BOOLEAN NOT NULL DEFAULT TRUE,
            curator_enabled BOOLEAN NOT NULL DEFAULT TRUE,
            interval_hours INTEGER NOT NULL DEFAULT 168,
            minimum_idle_hours INTEGER NOT NULL DEFAULT 2,
            consolidate BOOLEAN NOT NULL DEFAULT TRUE,
            prune_builtins BOOLEAN NOT NULL DEFAULT FALSE,
            backup_keep INTEGER NOT NULL DEFAULT 5,
            soul_review_enabled BOOLEAN NOT NULL DEFAULT TRUE,
            review_complex_sessions BOOLEAN NOT NULL DEFAULT TRUE,
            soul_review_window_days INTEGER NOT NULL DEFAULT 14,
            soul_review_cooldown_hours INTEGER NOT NULL DEFAULT 24,
            model_mode TEXT NOT NULL DEFAULT 'economy',
            last_activity_at TIMESTAMPTZ,
            last_curator_review_at TIMESTAMPTZ,
            last_soul_review_at TIMESTAMPTZ,
            next_review_at TIMESTAMPTZ,
            lease_until TIMESTAMPTZ,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """).run()
        try await sql.raw("""
        INSERT INTO self_improvement_settings (id, tenant_id, next_review_at)
        SELECT gen_random_uuid(), id, NOW() + INTERVAL '168 hours' FROM users
        ON CONFLICT (tenant_id) DO NOTHING
        """).run()
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS self_improvement_runs (
            id UUID PRIMARY KEY,
            tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            status TEXT NOT NULL,
            trigger TEXT NOT NULL,
            dry_run BOOLEAN NOT NULL DEFAULT TRUE,
            model_used TEXT,
            report_markdown TEXT,
            snapshot_json TEXT,
            actions_applied INTEGER NOT NULL DEFAULT 0,
            actions_skipped INTEGER NOT NULL DEFAULT 0,
            started_at TIMESTAMPTZ,
            ended_at TIMESTAMPTZ,
            failure_reason TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """).run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_self_improvement_runs_tenant_created ON self_improvement_runs (tenant_id, created_at DESC)").run()
        try await sql.raw("CREATE UNIQUE INDEX IF NOT EXISTS idx_self_improvement_runs_one_active ON self_improvement_runs (tenant_id, kind) WHERE status IN ('queued', 'running')").run()
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS self_improvement_changes (
            id UUID PRIMARY KEY,
            tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            run_id UUID REFERENCES self_improvement_runs(id) ON DELETE SET NULL,
            kind TEXT NOT NULL,
            state TEXT NOT NULL,
            trigger TEXT NOT NULL,
            title TEXT NOT NULL,
            summary TEXT NOT NULL,
            patch TEXT,
            proposed_markdown TEXT,
            base_sha256 TEXT,
            report_markdown TEXT,
            failure_reason TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            decided_at TIMESTAMPTZ,
            applied_at TIMESTAMPTZ
        )
        """).run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_self_improvement_changes_tenant_created ON self_improvement_changes (tenant_id, created_at DESC)").run()
        try await sql.raw("ALTER TABLE skills_state ADD COLUMN IF NOT EXISTS curator_pinned BOOLEAN NOT NULL DEFAULT FALSE").run()
        try await sql.raw("ALTER TABLE skills_state ADD COLUMN IF NOT EXISTS curator_state TEXT NOT NULL DEFAULT 'active'").run()
        try await sql.raw("ALTER TABLE skills_state ADD COLUMN IF NOT EXISTS curator_last_activity_at TIMESTAMPTZ").run()
        try await sql.raw("ALTER TABLE skills_state ADD COLUMN IF NOT EXISTS curator_archived_at TIMESTAMPTZ").run()
        try await sql.raw("ALTER TABLE conversation_messages ADD COLUMN IF NOT EXISTS tool_call_count INTEGER NOT NULL DEFAULT 0").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("ALTER TABLE conversation_messages DROP COLUMN IF EXISTS tool_call_count").run()
        try await sql.raw("ALTER TABLE skills_state DROP COLUMN IF EXISTS curator_archived_at").run()
        try await sql.raw("ALTER TABLE skills_state DROP COLUMN IF EXISTS curator_last_activity_at").run()
        try await sql.raw("ALTER TABLE skills_state DROP COLUMN IF EXISTS curator_state").run()
        try await sql.raw("ALTER TABLE skills_state DROP COLUMN IF EXISTS curator_pinned").run()
        try await sql.raw("DROP TABLE IF EXISTS self_improvement_changes").run()
        try await sql.raw("DROP TABLE IF EXISTS self_improvement_runs").run()
        try await sql.raw("DROP TABLE IF EXISTS self_improvement_settings").run()
    }
}
