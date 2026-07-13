import FluentKit
import SQLKit

struct M92_CreateWorkflows: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await runMigrationScript(#"""
        CREATE TABLE IF NOT EXISTS workflows (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            name TEXT NOT NULL, description_text TEXT, enabled BOOLEAN NOT NULL DEFAULT TRUE,
            draft_definition JSONB NOT NULL, draft_revision INTEGER NOT NULL DEFAULT 1,
            published_version_id UUID, is_legacy_job BOOLEAN NOT NULL DEFAULT FALSE, legacy_skill_name TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (tenant_id, name)
        );
        CREATE INDEX IF NOT EXISTS workflows_tenant_updated_idx ON workflows(tenant_id, updated_at DESC);
        CREATE TABLE IF NOT EXISTS workflow_versions (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            workflow_id UUID NOT NULL REFERENCES workflows(id) ON DELETE CASCADE, version INTEGER NOT NULL,
            definition JSONB NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), UNIQUE (workflow_id, version)
        );
        ALTER TABLE workflows ADD CONSTRAINT workflows_published_version_fk
            FOREIGN KEY (published_version_id) REFERENCES workflow_versions(id) ON DELETE SET NULL;
        CREATE TABLE IF NOT EXISTS workflow_runs (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            workflow_id UUID NOT NULL REFERENCES workflows(id) ON DELETE CASCADE,
            version_id UUID NOT NULL REFERENCES workflow_versions(id) ON DELETE RESTRICT,
            status TEXT NOT NULL, trigger_kind TEXT NOT NULL, input JSONB NOT NULL DEFAULT '{}'::jsonb,
            conversation_id UUID, lease_owner TEXT, lease_expires_at TIMESTAMPTZ,
            started_at TIMESTAMPTZ, ended_at TIMESTAMPTZ, error_message TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
        CREATE INDEX IF NOT EXISTS workflow_runs_claim_idx ON workflow_runs(status, lease_expires_at, created_at);
        CREATE INDEX IF NOT EXISTS workflow_runs_tenant_idx ON workflow_runs(tenant_id, created_at DESC);
        CREATE TABLE IF NOT EXISTS workflow_node_runs (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(), run_id UUID NOT NULL REFERENCES workflow_runs(id) ON DELETE CASCADE,
            node_id UUID NOT NULL, node_name TEXT NOT NULL, status TEXT NOT NULL, attempt INTEGER NOT NULL DEFAULT 1,
            input_snapshot JSONB, output_snapshot JSONB, error_message TEXT, started_at TIMESTAMPTZ, ended_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), UNIQUE (run_id, node_id, attempt)
        );
        CREATE TABLE IF NOT EXISTS workflow_approvals (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            run_id UUID NOT NULL REFERENCES workflow_runs(id) ON DELETE CASCADE,
            workflow_id UUID NOT NULL REFERENCES workflows(id) ON DELETE CASCADE, node_id UUID NOT NULL,
            title TEXT NOT NULL, message TEXT, status TEXT NOT NULL DEFAULT 'pending', decision_note TEXT,
            expires_at TIMESTAMPTZ NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), UNIQUE (run_id, node_id)
        );
        CREATE INDEX IF NOT EXISTS workflow_approvals_pending_idx ON workflow_approvals(tenant_id, status, expires_at);
        """#, on: sql)
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await runMigrationScript(#"""
        DROP TABLE IF EXISTS workflow_approvals; DROP TABLE IF EXISTS workflow_node_runs; DROP TABLE IF EXISTS workflow_runs;
        ALTER TABLE workflows DROP CONSTRAINT IF EXISTS workflows_published_version_fk;
        DROP TABLE IF EXISTS workflow_versions; DROP TABLE IF EXISTS workflows;
        """#, on: sql)
    }
}
