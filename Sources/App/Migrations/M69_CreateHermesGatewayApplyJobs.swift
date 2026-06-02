import FluentKit
import SQLKit

/// Tenant-scoped job ledger for the "apply gateway config" flow
/// (`POST /v1/me/hermes-gateways/apply`). One row per apply; `steps_json`
/// holds the JSON-encoded `[HermesGatewayApplyStep]` snapshot.
struct M69_CreateHermesGatewayApplyJobs: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw M69Error.requiresSQL
        }

        try await sql.raw(#"""
        CREATE TABLE IF NOT EXISTS hermes_gateway_apply_jobs (
            id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            tenant_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            state         TEXT NOT NULL,
            steps_json    TEXT NOT NULL DEFAULT '[]',
            error_message TEXT NULL,
            created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """#).run()

        try await sql.raw(
            #"CREATE INDEX IF NOT EXISTS hermes_gateway_apply_jobs_tenant_created_idx ON hermes_gateway_apply_jobs(tenant_id, created_at DESC)"#,
        ).run()
        // Backs the single-flight guard: at most one running job per tenant.
        try await sql.raw(
            #"CREATE UNIQUE INDEX IF NOT EXISTS hermes_gateway_apply_jobs_one_running_idx ON hermes_gateway_apply_jobs(tenant_id) WHERE state = 'running'"#,
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw M69Error.requiresSQL
        }
        try await sql.raw("DROP TABLE IF EXISTS hermes_gateway_apply_jobs").run()
    }
}

private enum M69Error: Error { case requiresSQL }
