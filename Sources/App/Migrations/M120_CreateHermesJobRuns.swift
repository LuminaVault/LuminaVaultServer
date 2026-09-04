import FluentKit
import SQLKit

/// Hermes Mirror Phase 2 (Collect) — one row per run of a mirrored Hermes
/// cron job, plus the per-job high-water mark the collector resumes from.
///
/// `hermes_run_key` is Hermes' own identity for the run (the run session id
/// on a dashboard, the `cron/output/<job>/<stamp>.md` file stem on a managed
/// Hermes, `push:<key>` for a webhook delivery). It is unique per tenant, so
/// re-collecting the same window is a no-op — the collector relies on that
/// instead of trusting timestamps.
///
/// `vault_file_id` / `skill_run_log_id` are nullable and set once the run's
/// output has been filed into the vault and the Today feed. `skill_run_log`
/// is a raw-SQL table with no FK-able Fluent model, so that column carries no
/// constraint; the vault FK is `ON DELETE SET NULL` so deleting a job's
/// output file does not delete the run history.
struct M120_CreateHermesJobRuns: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await runMigrationScript(#"""
        CREATE TABLE IF NOT EXISTS hermes_job_runs (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            hermes_job_id TEXT NOT NULL,
            hermes_run_key TEXT NOT NULL,
            status TEXT NOT NULL,
            started_at TIMESTAMPTZ NOT NULL,
            finished_at TIMESTAMPTZ,
            output TEXT,
            error TEXT,
            tokens JSONB,
            vault_file_id UUID REFERENCES vault_files(id) ON DELETE SET NULL,
            skill_run_log_id UUID,
            collected_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (tenant_id, hermes_run_key)
        );
        CREATE INDEX IF NOT EXISTS hermes_job_runs_tenant_started_idx
            ON hermes_job_runs (tenant_id, started_at DESC);
        CREATE INDEX IF NOT EXISTS hermes_job_runs_tenant_job_started_idx
            ON hermes_job_runs (tenant_id, hermes_job_id, started_at DESC);
        ALTER TABLE hermes_mirrored_jobs
            ADD COLUMN IF NOT EXISTS runs_high_water_at TIMESTAMPTZ;
        ALTER TABLE hermes_mirrored_jobs
            ADD COLUMN IF NOT EXISTS runs_collected_at TIMESTAMPTZ;
        """#, on: sql)
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("ALTER TABLE hermes_mirrored_jobs DROP COLUMN IF EXISTS runs_collected_at").run()
        try await sql.raw("ALTER TABLE hermes_mirrored_jobs DROP COLUMN IF EXISTS runs_high_water_at").run()
        try await sql.raw("DROP TABLE IF EXISTS hermes_job_runs").run()
    }
}
