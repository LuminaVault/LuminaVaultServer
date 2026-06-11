import FluentKit
import SQLKit

/// M73 — `cost_ledger` table for daily per-tenant per-provider **USD** spend.
///
/// Parallel to `usage_meter` (M31), but priced in money rather than tokens.
/// `usage_meter` answers "how many tokens" for tier caps; `cost_ledger`
/// answers "how many dollars" so paid upstreams (NVIDIA NIM in *managed*
/// mode, where the platform holds the key) can enforce a real budget and
/// be reconciled against the provider's bill.
///
/// USD is stored as **micro-dollars** (`BIGINT`, 1 USD = 1_000_000 micros)
/// to avoid floating-point drift in a money column.
///
/// Composite PK `(tenant_id, day, provider)` — one row per user/day/provider.
/// BYOK spend (user's own key) is NOT recorded here: the platform pays
/// nothing, so there is nothing to meter.
struct M73_CreateCostLedger: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw M73Error.requiresSQL
        }

        try await sql.raw(#"""
        CREATE TABLE IF NOT EXISTS cost_ledger (
            tenant_id   UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            day         DATE NOT NULL,
            provider    TEXT NOT NULL,
            usd_micros  BIGINT NOT NULL DEFAULT 0,
            calls       BIGINT NOT NULL DEFAULT 0,
            PRIMARY KEY (tenant_id, day, provider)
        )
        """#).run()

        try await sql.raw(
            #"CREATE INDEX IF NOT EXISTS cost_ledger_tenant_day_idx ON cost_ledger(tenant_id, day)"#
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw M73Error.requiresSQL
        }
        try await sql.raw("DROP TABLE IF EXISTS cost_ledger").run()
    }
}

private enum M73Error: Error { case requiresSQL }
