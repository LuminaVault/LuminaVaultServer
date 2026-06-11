import FluentKit
import SQLKit

/// HER-172 — opt-in flag for the ContextRouter middleware.
///
/// Default `false`: the middleware burns a `capability=low` LLM call per
/// chat message to decide which skill (if any) to prepend. Free / Trial
/// tiers cannot afford that against their daily Mtok budget. Pro / Ultimate
/// users flip the flag on via Settings; the EntitlementChecker enforces
/// tier separately so a downgrade silently flips this back to no-op.
struct M24_AddUserContextRouting: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(
            #"ALTER TABLE users ADD COLUMN IF NOT EXISTS context_routing BOOLEAN NOT NULL DEFAULT FALSE"#
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(#"ALTER TABLE users DROP COLUMN IF EXISTS context_routing"#).run()
    }
}
