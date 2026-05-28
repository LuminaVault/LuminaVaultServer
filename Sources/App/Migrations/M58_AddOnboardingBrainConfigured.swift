import FluentKit
import SQLKit

/// HER-300 — Adds `brain_configured_completed` (one-way latch) +
/// timestamp to `onboarding_state`. Flipped to true when the user
/// finishes the "Choose Your Brain" onboarding step (either accepts the
/// managed default or saves a BYOK key). Mirrors the other onboarding
/// flag columns.
struct M58_AddOnboardingBrainConfigured: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        ALTER TABLE onboarding_state
        ADD COLUMN IF NOT EXISTS brain_configured_completed BOOLEAN NOT NULL DEFAULT FALSE
        """).run()
        try await sql.raw("""
        ALTER TABLE onboarding_state
        ADD COLUMN IF NOT EXISTS brain_configured_completed_at TIMESTAMPTZ
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        ALTER TABLE onboarding_state
        DROP COLUMN IF EXISTS brain_configured_completed_at
        """).run()
        try await sql.raw("""
        ALTER TABLE onboarding_state
        DROP COLUMN IF EXISTS brain_configured_completed
        """).run()
    }
}
