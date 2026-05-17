import FluentKit
import SQLKit

/// HER-35 — adds a flag to `users` so the client can gate the new
/// post-auth "Create My Vault" screen. Before this migration the server
/// implicitly created the tenant vault inside `DefaultAuthService.register`
/// (via `SOULService.initIfMissing`). The new flow moves that work to an
/// explicit `POST /v1/vault/create` so the moment is user-driven.
///
/// Backfill: existing users already have a vault folder + SOUL.md, so we
/// set them to `TRUE`. New users created after this migration start
/// `FALSE` and must hit `POST /v1/vault/create` before reaching the home
/// screen.
///
/// Idempotent via `ADD COLUMN IF NOT EXISTS`.
struct M37_AddUserVaultInitialized: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw M37Error.requiresSQL
        }
        try await sql.raw("ALTER TABLE users ADD COLUMN IF NOT EXISTS vault_initialized BOOLEAN NOT NULL DEFAULT FALSE").run()
        try await sql.raw("UPDATE users SET vault_initialized = TRUE WHERE vault_initialized = FALSE").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw M37Error.requiresSQL
        }
        try await sql.raw("ALTER TABLE users DROP COLUMN IF EXISTS vault_initialized").run()
    }
}

private enum M37Error: Error { case requiresSQL }
