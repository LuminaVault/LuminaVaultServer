import FluentKit
import SQLKit

/// Durable run events, lease recovery metadata, and atomic managed-inference
/// accounting for Cerberus Studio.
struct M109_CerberusStudio: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await runMigrationScript(#"""
        ALTER TABLE workflow_runs ADD COLUMN IF NOT EXISTS pause_reason TEXT;
        ALTER TABLE workflow_runs ADD COLUMN IF NOT EXISTS managed_spend_usd_micros BIGINT NOT NULL DEFAULT 0;
        ALTER TABLE workflow_runs ADD COLUMN IF NOT EXISTS managed_spend_limit_usd_micros BIGINT NOT NULL DEFAULT 0;
        ALTER TABLE workflow_runs ADD COLUMN IF NOT EXISTS lease_heartbeat_at TIMESTAMPTZ;

        ALTER TABLE workflow_node_runs ADD COLUMN IF NOT EXISTS selected_provider TEXT;
        ALTER TABLE workflow_node_runs ADD COLUMN IF NOT EXISTS selected_model TEXT;
        ALTER TABLE workflow_node_runs ADD COLUMN IF NOT EXISTS tokens_in BIGINT;
        ALTER TABLE workflow_node_runs ADD COLUMN IF NOT EXISTS tokens_out BIGINT;
        ALTER TABLE workflow_node_runs ADD COLUMN IF NOT EXISTS managed_cost_usd_micros BIGINT;

        ALTER TABLE workflow_approvals ADD COLUMN IF NOT EXISTS memory_ids UUID[] NOT NULL DEFAULT '{}';

        CREATE TABLE IF NOT EXISTS workflow_run_events (
            sequence BIGSERIAL PRIMARY KEY,
            tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            run_id UUID NOT NULL REFERENCES workflow_runs(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            node_id UUID,
            message TEXT,
            data JSONB NOT NULL DEFAULT '{}'::jsonb,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
        CREATE INDEX IF NOT EXISTS workflow_run_events_replay_idx
            ON workflow_run_events(run_id, sequence);
        CREATE INDEX IF NOT EXISTS workflow_run_events_retention_idx
            ON workflow_run_events(created_at);

        CREATE TABLE IF NOT EXISTS workflow_spend_buckets (
            scope_key TEXT NOT NULL,
            period_kind TEXT NOT NULL,
            period_start DATE NOT NULL,
            spent_usd_micros BIGINT NOT NULL DEFAULT 0,
            reserved_usd_micros BIGINT NOT NULL DEFAULT 0,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            PRIMARY KEY (scope_key, period_kind, period_start),
            CHECK (spent_usd_micros >= 0),
            CHECK (reserved_usd_micros >= 0)
        );
        """#, on: sql)
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await runMigrationScript(#"""
        DROP TABLE IF EXISTS workflow_spend_buckets;
        DROP TABLE IF EXISTS workflow_run_events;
        ALTER TABLE workflow_approvals DROP COLUMN IF EXISTS memory_ids;
        ALTER TABLE workflow_node_runs DROP COLUMN IF EXISTS managed_cost_usd_micros;
        ALTER TABLE workflow_node_runs DROP COLUMN IF EXISTS tokens_out;
        ALTER TABLE workflow_node_runs DROP COLUMN IF EXISTS tokens_in;
        ALTER TABLE workflow_node_runs DROP COLUMN IF EXISTS selected_model;
        ALTER TABLE workflow_node_runs DROP COLUMN IF EXISTS selected_provider;
        ALTER TABLE workflow_runs DROP COLUMN IF EXISTS lease_heartbeat_at;
        ALTER TABLE workflow_runs DROP COLUMN IF EXISTS managed_spend_limit_usd_micros;
        ALTER TABLE workflow_runs DROP COLUMN IF EXISTS managed_spend_usd_micros;
        ALTER TABLE workflow_runs DROP COLUMN IF EXISTS pause_reason;
        """#, on: sql)
    }
}
