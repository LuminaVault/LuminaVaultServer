import FluentKit
import SQLKit

/// Adds `guided_start_dismissed_at` to `onboarding_state` — the nullable
/// timestamp behind the guided-start card's dismiss `×`.
///
/// Unlike every other column on this table it is **two-way**: `PATCH
/// /v1/onboarding` with `guidedStartDismissed: true` stamps it and `false`
/// clears it back to `NULL` (Settings › "Show me around"). It lives here
/// rather than on a preferences endpoint so one `GET /v1/onboarding` answers
/// the whole card-visibility question. See
/// `LuminaVaultShared/docs/guided-start.md`.
struct M129_AddOnboardingGuidedStartDismissed: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        ALTER TABLE onboarding_state
        ADD COLUMN IF NOT EXISTS guided_start_dismissed_at TIMESTAMPTZ
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        ALTER TABLE onboarding_state
        DROP COLUMN IF EXISTS guided_start_dismissed_at
        """).run()
    }
}
