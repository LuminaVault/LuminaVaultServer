import FluentKit
import SQLKit

/// Phase 1 (Hermes runs) — every SSE event the run watcher consumed, with a
/// per-run monotonic `seq` so clients can resume the feed after a
/// reconnect (`GET /v1/hermes/runs/{id}/events?after=<seq>`).
struct M118_CreateHermesRunEvents: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS hermes_run_events (
            id UUID PRIMARY KEY,
            run_id UUID NOT NULL REFERENCES hermes_runs(id) ON DELETE CASCADE,
            seq INTEGER NOT NULL,
            event TEXT NOT NULL,
            payload JSONB NOT NULL DEFAULT '{}'::jsonb,
            at TIMESTAMPTZ NOT NULL,
            CONSTRAINT uq_hermes_run_events_run_seq UNIQUE (run_id, seq)
        )
        """).run()
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS idx_hermes_run_events_run_seq
            ON hermes_run_events (run_id, seq)
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS hermes_run_events").run()
    }
}
