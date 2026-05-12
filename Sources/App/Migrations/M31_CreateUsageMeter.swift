import FluentKit
import SQLKit

/// M31 — `usage_meter` table for daily per-tenant per-model token metering.
///
/// Composite PK `(tenant_id, day, model)` — one row per user/day/model.
/// No UUID PK; this is a metering/aggregation table, not a resource.
/// `BIGINT` stores raw token counts to avoid float precision issues.
///
/// Supports the cost dashboard query:
///   SELECT model, SUM(mtok_in), SUM(mtok_out)
///   FROM usage_meter WHERE day = CURRENT_DATE GROUP BY model;
struct M31_CreateUsageMeter: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw M31Error.requiresSQL
        }

        try await sql.raw(#"""
        CREATE TABLE IF NOT EXISTS usage_meter (
            tenant_id  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            day        DATE NOT NULL,
            model      TEXT NOT NULL,
            mtok_in    BIGINT NOT NULL DEFAULT 0,
            mtok_out   BIGINT NOT NULL DEFAULT 0,
            PRIMARY KEY (tenant_id, day, model)
        )
        """#).run()

        try await sql.raw(
            #"CREATE INDEX IF NOT EXISTS usage_meter_tenant_day_idx ON usage_meter(tenant_id, day)"#,
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw M31Error.requiresSQL
        }
        try await sql.raw("DROP TABLE IF EXISTS usage_meter").run()
    }
}

private enum M31Error: Error { case requiresSQL }
