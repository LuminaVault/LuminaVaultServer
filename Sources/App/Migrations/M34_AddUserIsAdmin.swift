import FluentKit
import SQLKit

/// HER-30 — adds `users.is_admin BOOL NOT NULL DEFAULT false`.
///
/// Dormant field today: `AdminTokenMiddleware` still gates admin routes on a
/// shared-secret header (`Sources/App/Middleware/AdminTokenMiddleware.swift`).
/// The column is seeded by `bootstrap-admin` so a follow-up RBAC swap can
/// flip the middleware to read `User.isAdmin` from the JWT claim without
/// another migration.
struct M34_AddUserIsAdmin: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(
            #"ALTER TABLE users ADD COLUMN IF NOT EXISTS is_admin BOOLEAN NOT NULL DEFAULT FALSE"#,
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(#"ALTER TABLE users DROP COLUMN IF EXISTS is_admin"#).run()
    }
}
