import FluentKit
import SQLKit

/// Adds subscription-tier fields to `users`. Backs the RevenueCat + Apple
/// StoreKit billing layer (see `docs/superpowers/specs/2026-05-10-billing-tiers-revenuecat-design.md`).
///
/// Columns:
/// - `tier`               : enum-via-CHECK (`trial`, `pro`, `ultimate`, `lapsed`, `archived`), default `trial`
/// - `tier_expires_at`    : when trial / billing-period ends. Drives `lapse-archiver` cron.
/// - `tier_override`      : ops bypass (`none`, `pro`, `ultimate`). Always wins over RC-driven tier.
/// - `revenuecat_user_id` : stable RC subscriber id (set after first IAP).
struct M15_AddTierFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.requiresSQL
        }
        try await sql.raw(
            #"ALTER TABLE users ADD COLUMN IF NOT EXISTS tier TEXT NOT NULL DEFAULT 'trial'"#,
        ).run()
        try await sql.raw(
            #"ALTER TABLE users ADD COLUMN IF NOT EXISTS tier_expires_at TIMESTAMPTZ"#,
        ).run()
        try await sql.raw(
            #"ALTER TABLE users ADD COLUMN IF NOT EXISTS tier_override TEXT NOT NULL DEFAULT 'none'"#,
        ).run()
        try await sql.raw(
            #"ALTER TABLE users ADD COLUMN IF NOT EXISTS revenuecat_user_id TEXT"#,
        ).run()
        // CHECK constraints. IF NOT EXISTS isn't supported for constraints; guard via DO block.
        try await sql.raw(#"""
        DO $$ BEGIN
            ALTER TABLE users ADD CONSTRAINT users_tier_check
            CHECK (tier IN ('trial', 'pro', 'ultimate', 'lapsed', 'archived'));
        EXCEPTION WHEN duplicate_object THEN NULL; END $$;
        """#).run()
        try await sql.raw(#"""
        DO $$ BEGIN
            ALTER TABLE users ADD CONSTRAINT users_tier_override_check
            CHECK (tier_override IN ('none', 'pro', 'ultimate'));
        EXCEPTION WHEN duplicate_object THEN NULL; END $$;
        """#).run()
        try await sql.raw(
            #"CREATE UNIQUE INDEX IF NOT EXISTS users_revenuecat_user_id_key ON users(revenuecat_user_id) WHERE revenuecat_user_id IS NOT NULL"#,
        ).run()
        try await sql.raw(
            #"CREATE INDEX IF NOT EXISTS users_tier_expires_idx ON users(tier_expires_at) WHERE tier_expires_at IS NOT NULL"#,
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.requiresSQL
        }
        try await sql.raw("DROP INDEX IF EXISTS users_tier_expires_idx").run()
        try await sql.raw("DROP INDEX IF EXISTS users_revenuecat_user_id_key").run()
        try await sql.raw("ALTER TABLE users DROP CONSTRAINT IF EXISTS users_tier_override_check").run()
        try await sql.raw("ALTER TABLE users DROP CONSTRAINT IF EXISTS users_tier_check").run()
        try await sql.raw("ALTER TABLE users DROP COLUMN IF EXISTS revenuecat_user_id").run()
        try await sql.raw("ALTER TABLE users DROP COLUMN IF EXISTS tier_override").run()
        try await sql.raw("ALTER TABLE users DROP COLUMN IF EXISTS tier_expires_at").run()
        try await sql.raw("ALTER TABLE users DROP COLUMN IF EXISTS tier").run()
    }
}

private enum MigrationError: Error { case requiresSQL }
