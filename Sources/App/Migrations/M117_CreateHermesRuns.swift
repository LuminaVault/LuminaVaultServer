import FluentKit
import SQLKit

/// Phase 1 (Hermes runs) — one row per agent run LuminaVault started on the
/// tenant's Hermes. Persisted because the Hermes gateway keeps runs in
/// memory only (max 1000, 300 s TTL after they finish).
struct M117_CreateHermesRuns: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS hermes_runs (
            id UUID PRIMARY KEY,
            tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            hermes_run_id TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'queued',
            prompt TEXT NOT NULL,
            session_id TEXT,
            model TEXT,
            conversation_id UUID REFERENCES conversations(id) ON DELETE SET NULL,
            started_at TIMESTAMPTZ NOT NULL,
            finished_at TIMESTAMPTZ,
            last_event TEXT,
            last_seq INTEGER NOT NULL DEFAULT 0,
            pending_approval JSONB,
            summary TEXT,
            error TEXT,
            created_at TIMESTAMPTZ,
            updated_at TIMESTAMPTZ,
            CONSTRAINT uq_hermes_runs_tenant_hermes_run_id UNIQUE (tenant_id, hermes_run_id)
        )
        """).run()
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS idx_hermes_runs_tenant_started_at
            ON hermes_runs (tenant_id, started_at DESC)
        """).run()
        // Watcher re-attach on boot scans only the non-terminal rows.
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS idx_hermes_runs_active
            ON hermes_runs (status, started_at)
            WHERE status IN ('queued', 'running', 'waiting_for_approval')
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS hermes_runs").run()
    }
}
