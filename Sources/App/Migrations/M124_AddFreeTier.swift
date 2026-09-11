import FluentKit
import SQLKit

/// Widens `users_tier_check` to admit `free`, and converts already-expired
/// trials onto it.
///
/// `free` is where a user lands when their 14-day trial ends: chat, memory and
/// capture on the zero-cost lane (`FreeLanePolicy` / `FreeLaneGate`), no
/// platform-funded inference, and no archive clock. `lapsed` keeps its old
/// meaning — a *paid* subscription ended — and remains the only tier
/// `LapseArchiverJob` moves to cold storage.
///
/// **Existing `lapsed` rows are deliberately left alone.** Rewriting them to
/// `free` would cancel every pending cold-storage archive on a population that
/// is by definition already ≥90 days stale. Under the new capability matrix
/// `lapsed` gains chat anyway, so the user-visible outcome of leaving them is
/// identical to converting them, at none of the risk.
struct M124_AddFreeTier: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.requiresSQL
        }
        // Order matters: the constraint has to admit 'free' before the backfill
        // can write it, or the UPDATE violates the constraint still in force.
        try await sql.raw(
            #"ALTER TABLE users DROP CONSTRAINT IF EXISTS users_tier_check"#
        ).run()
        try await sql.raw(#"""
        DO $$ BEGIN
            ALTER TABLE users ADD CONSTRAINT users_tier_check
            CHECK (tier IN ('free', 'trial', 'pro', 'ultimate', 'lapsed', 'archived'));
        EXCEPTION WHEN duplicate_object THEN NULL; END $$;
        """#).run()

        // Byte-for-byte the transition `LapseArchiverJob.lapseIfExpired` now
        // makes on its next nightly run, including the `tier_override` guard
        // that exempts founders and testers. Doing it here means the first
        // login after deploy is already correct, instead of "still says trial,
        // still 402s" for up to 24 hours.
        try await sql.raw(#"""
        UPDATE users SET tier = 'free'
        WHERE tier = 'trial'
          AND tier_expires_at IS NOT NULL
          AND tier_expires_at < now()
          AND tier_override = 'none'
        """#).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.requiresSQL
        }
        // Live 'free' rows must go before the narrow constraint comes back, or
        // the revert fails on its own data. `lapsed` is the closest pre-`free`
        // meaning: no chat, vault read + export only.
        try await sql.raw(#"UPDATE users SET tier = 'lapsed' WHERE tier = 'free'"#).run()
        try await sql.raw(
            #"ALTER TABLE users DROP CONSTRAINT IF EXISTS users_tier_check"#
        ).run()
        // `M15.revert` drops this constraint outright rather than restoring it,
        // so re-adding it here explicitly is what keeps a revert idempotent.
        try await sql.raw(#"""
        DO $$ BEGIN
            ALTER TABLE users ADD CONSTRAINT users_tier_check
            CHECK (tier IN ('trial', 'pro', 'ultimate', 'lapsed', 'archived'));
        EXCEPTION WHEN duplicate_object THEN NULL; END $$;
        """#).run()
    }
}

private enum MigrationError: Error { case requiresSQL }
