import FluentKit
import SQLKit

/// Retrieval quality telemetry (content-free) + its weekly roll-up.
/// Backs `RetrievalTelemetryEvent` / `RetrievalLeakReport`. See those models
/// and `RetrievalTelemetryWorker` / `RetrievalLeakReportWorker`.
struct M108_CreateRetrievalTelemetry: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS retrieval_telemetry_events (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            tenant_id UUID NOT NULL,
            source_path TEXT NOT NULL,
            space_id UUID,
            hit_count INT NOT NULL,
            zero_hit BOOLEAN NOT NULL,
            top_distance DOUBLE PRECISION,
            mean_distance DOUBLE PRECISION,
            limit_requested INT NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """).run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS retrieval_telemetry_tenant_time_idx ON retrieval_telemetry_events(tenant_id, created_at DESC)").run()
        // Supports the 90-day retention DELETE (scans by age across tenants).
        try await sql.raw("CREATE INDEX IF NOT EXISTS retrieval_telemetry_time_idx ON retrieval_telemetry_events(created_at)").run()

        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS retrieval_leak_reports (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            tenant_id UUID NOT NULL,
            period_start TIMESTAMPTZ NOT NULL,
            period_end TIMESTAMPTZ NOT NULL,
            total_retrievals INT NOT NULL,
            zero_hit_count INT NOT NULL,
            zero_hit_rate DOUBLE PRECISION NOT NULL,
            mean_top_distance DOUBLE PRECISION,
            worst_source TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """).run()
        // One report per tenant per window — drives worker idempotency.
        try await sql.raw("CREATE UNIQUE INDEX IF NOT EXISTS retrieval_leak_reports_window_idx ON retrieval_leak_reports(tenant_id, period_start, period_end)").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS retrieval_leak_reports").run()
        try await sql.raw("DROP TABLE IF EXISTS retrieval_telemetry_events").run()
    }
}
