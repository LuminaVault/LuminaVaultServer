import FluentKit
import SQLKit

/// Production hardening for Automation 2.0. The unique dedupe key makes
/// schedule/webhook delivery safe across replicas, while `workflow_id` is the
/// bridge used to move legacy Jobs away from the in-process skill scheduler.
struct M93_HardenWorkflowAutomation: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await runMigrationScript(#"""
        ALTER TABLE workflow_runs ADD COLUMN IF NOT EXISTS dedupe_key TEXT;
        CREATE UNIQUE INDEX IF NOT EXISTS workflow_runs_dedupe_idx
            ON workflow_runs(workflow_id, dedupe_key) WHERE dedupe_key IS NOT NULL;
        ALTER TABLE skills_state ADD COLUMN IF NOT EXISTS workflow_id UUID REFERENCES workflows(id) ON DELETE SET NULL;
        CREATE INDEX IF NOT EXISTS skills_state_workflow_idx
            ON skills_state(workflow_id) WHERE workflow_id IS NOT NULL;
        """#, on: sql)
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await runMigrationScript(#"""
        DROP INDEX IF EXISTS skills_state_workflow_idx;
        ALTER TABLE skills_state DROP COLUMN IF EXISTS workflow_id;
        DROP INDEX IF EXISTS workflow_runs_dedupe_idx;
        ALTER TABLE workflow_runs DROP COLUMN IF EXISTS dedupe_key;
        """#, on: sql)
    }
}
