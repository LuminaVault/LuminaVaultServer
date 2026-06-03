import FluentKit
import SQLKit

/// M74 — `nvidia_batch_jobs`: persisted ledger for long-running NVIDIA GPU
/// batch work (NeMo-class data-prep / fine-tune runs) dispatched to a
/// tenant's own NVIDIA-backed Hermes.
///
/// Follows the `hermes_gateway_apply_jobs` (M69) persisted-job pattern so a
/// reconnecting client can render an accurate snapshot after an app/server
/// restart. `steps_json` holds the JSON-encoded progress array.
///
/// NOTE: this is the storage foundation only. There is **no executor wired
/// yet** — NIM exposes no remote batch API, and there is no control channel
/// into a BYO-Hermes GPU box (it can't be `docker exec`'d like the managed
/// container). The table + model exist so the dispatch seam can be filled in
/// when such a channel exists; until then no rows are produced.
struct M74_CreateNvidiaBatchJobs: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw M74Error.requiresSQL
        }

        try await sql.raw(#"""
        CREATE TABLE IF NOT EXISTS nvidia_batch_jobs (
            id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            tenant_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            skill_ref     TEXT NOT NULL,
            state         TEXT NOT NULL,
            steps_json    TEXT NOT NULL DEFAULT '[]',
            error_message TEXT NULL,
            created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """#).run()

        try await sql.raw(
            #"CREATE INDEX IF NOT EXISTS nvidia_batch_jobs_tenant_created_idx ON nvidia_batch_jobs(tenant_id, created_at DESC)"#,
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw M74Error.requiresSQL
        }
        try await sql.raw("DROP TABLE IF EXISTS nvidia_batch_jobs").run()
    }
}

private enum M74Error: Error { case requiresSQL }
